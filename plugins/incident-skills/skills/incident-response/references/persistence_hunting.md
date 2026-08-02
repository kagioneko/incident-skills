# 永続化・バックドア探索

> [!CAUTION]
> **このドキュメントは「バックドアの不存在確認」ではない。**
>
> 侵害ホスト自身の `find` `ps` `ss` を使っている以上、ルートキットが隠せば見えない。
> 結果は必ず「確認した範囲」「未確認の範囲」「検出の限界」を併記して報告する。
>
> ```
> ❌ バックドアはありませんでした
>
> ⭕ 今回確認した永続化ポイントの範囲では、追加のバックドアを示す
>    所見は確認できませんでした。カーネル・メモリ・クラウド管理
>    プレーンは別途確認が必要です。
> ```

---

## Tier 1: 収集スクリプトで自動取得（`collect_evidence.sh`）

| 分類 | 対象 | 見つかるもの |
|---|---|---|
| 特権 | `/etc/passwd` の UID 0 | root以外のUID 0 アカウント |
| SSH | `authorized_keys` 全探索（`-xdev`） | **ホーム外に置かれた鍵** |
| SSH | `sshd -T` の実効設定 | `AuthorizedKeysFile` の変更 |
| 定期実行 | cron / at / systemd timers | 定期的な再感染 |
| サービス | systemd units | 常駐バックドア |
| 実行 | SUID/SGID | 権限昇格の踏み台 |
| ロード | `ld.so.preload` / `ld.so.conf.d` | ライブラリ差し替え |
| シェル | `.bashrc` / `.profile` 等 | ログイン時の実行 |
| 整合性 | `debsums -c` / `rpm -Va` | 改ざんされたシステムバイナリ |
| 時系列 | MACタイムライン | 侵入時刻の推定 |
| AI | エージェントのセッションログ | 実行者の特定 |

### 実例（2026年4月のVPS侵害）

```bash
mkdir -p /usr/.system/.ssh/
usermod -u 0 -o -g 0 system
echo "ssh-ed25519 AAAA..." >> /usr/.system/.ssh/authorized_keys
```

`~/.ssh/` と `/home/*/` だけを収集する設計では、**この鍵は取得できない。**
`find / -xdev -name 'authorized_keys*'` が必要。

`-o`（UID重複の許可）が付いた `usermod` は、正当な用途がほぼない。
**`/etc/passwd` に root 以外の UID 0 があれば、それだけで所見になる。**

---

## Tier 2: 追加すべき探索項目

### OS・認証まわり

```bash
# PAM の改ざん（認証をすり抜けるモジュール）
cp -a /etc/pam.d "$OUT/"
cp /etc/nsswitch.conf "$OUT/"
cp -a /etc/security "$OUT/"

# ログイン時に実行される場所
cp -a /etc/profile /etc/profile.d /etc/bash.bashrc /etc/zsh "$OUT/"
cp /etc/rc.local "$OUT/" 2>/dev/null
cp -a /etc/init.d "$OUT/"

# sshd の Match ブロック（特定ユーザーだけ設定を変える手口）
grep -n -A20 '^Match' /etc/ssh/sshd_config > "$OUT/sshd_match_blocks.txt"
grep -Ei 'authorizedkeyscommand|authorizedkeyscommanduser' \
    "$OUT/sshd_effective_full.txt" > "$OUT/sshd_authkeys_command.txt"

# 不自然なユーザー
awk -F: '$7 !~ /(nologin|false)$/ {print}' /etc/passwd > "$OUT/users_with_shell.txt"
awk -F: '$6 !~ /^(\/home|\/root|\/var|\/nonexistent)/ {print}' /etc/passwd \
    > "$OUT/users_odd_home.txt"
getent group sudo wheel adm docker > "$OUT/privileged_groups.txt"
```

**`AuthorizedKeysCommand` が要注意。** 鍵をファイルではなく外部コマンドの出力から取得する設定で、
任意のスクリプトを鍵の供給源にできる。ファイル検索では絶対に見つからない。

**`docker` グループは実質 root 相当。** ここに知らないユーザーがいたら所見。

### コンテナ

```bash
for cid in $(docker ps -aq); do
    docker inspect "$cid" > "$OUT/docker/inspect_${cid}.json"
done
cp /etc/docker/daemon.json "$OUT/docker/" 2>/dev/null
```

inspect の結果から、以下をチェックする。

| 項目 | 危険な値 | 意味 |
|---|---|---|
| `HostConfig.Privileged` | `true` | ホストへほぼ無制限にアクセスできる |
| `HostConfig.PidMode` | `host` | ホストのプロセスが見える／操作できる |
| `HostConfig.NetworkMode` | `host` | ホストのネットワークスタックを共有 |
| `HostConfig.Binds` | `/:/host` 等 | **ホストルートのマウント＝実質root** |
| `HostConfig.Binds` | `/var/run/docker.sock` | **Docker API 経由で権限昇格できる** |
| `HostConfig.CapAdd` | `SYS_ADMIN` 等 | 危険なケーパビリティ |
| `HostConfig.RestartPolicy` | `always` | 削除しても再起動で復活する |
| `Config.Entrypoint` / `Cmd` | 見覚えのない値 | ペイロード |

### カーネル・高度な永続化（別枠：高度調査）

```bash
lsmod > "$OUT/kernel/lsmod.txt"
cp -a /etc/modules /etc/modules-load.d /etc/modprobe.d "$OUT/kernel/"
dmesg > "$OUT/kernel/dmesg.txt"

# eBPF（近年のステルス永続化）
bpftool prog show > "$OUT/kernel/bpf_prog.txt" 2>/dev/null
bpftool net show  > "$OUT/kernel/bpf_net.txt" 2>/dev/null

# 署名されていないモジュール
for mod in $(lsmod | awk 'NR>1 {print $1}'); do
    modinfo "$mod" 2>/dev/null | grep -qi 'signature' \
        || echo "UNSIGNED: $mod"
done > "$OUT/kernel/unsigned_modules.txt"
```

> [!WARNING]
> **カーネルルートキットが入っている場合、`lsmod` 自身が嘘をつく。**
> ホスト内コマンドでの検出には原理的な限界がある。
> 疑わしい場合は、メモリイメージを取得して外部で解析するか、
> ホストを信頼せずに廃棄・再構築する。

---

## Tier 3: クラウド管理プレーン（人間が手で確認する）

> [!IMPORTANT]
> **ホスト内スクリプトでは絶対に見つからない。**
> そして、**OSのバックドアを全部消しても、ここに管理者キーが残っていれば再侵入される。**
>
> 実際、侵害の発覚がクラウド側の不審アクティビティ通知だった、というケースは多い。
> OS側だけ再構築して終わりにしない。

### チェックリスト（そのままユーザーに提示する）

```
□ IAM ユーザーが増えていないか
□ 既存ユーザーにアクセスキーが追加されていないか
   （キーの「最終使用日時」と「使用リージョン」を確認）
□ サービスアカウントキーが新規発行されていないか
□ IAM ロール / ポリシーの権限が変更されていないか
□ 信頼ポリシー（AssumeRole）に外部アカウントが追加されていないか
□ OS Login / プロジェクトメタデータの SSH 鍵
□ startup-script / user-data が書き換えられていないか
   ※ ここに仕込まれると、インスタンスを再作成しても復活する
□ 不審なスナップショット / AMI / マシンイメージ
   ※ 他アカウントへの共有設定が付いていないか
□ ファイアウォール / セキュリティグループの新規ルール
□ DNS レコードの変更（特に MX / TXT / NS）
□ 監査ログ（CloudTrail / Cloud Audit Logs）が無効化されていないか
□ ログの保存先バケットが変更・削除されていないか
□ 請求アラート・課金の急増（暗号通貨採掘の兆候）
□ 未使用リージョンでのリソース作成
   ※ 普段使わないリージョンは見落としやすく、狙われやすい
```

**`startup-script` / `user-data` が最も見落とされる。**
ここを書き換えられていると、OSを完全に再インストールしても、
インスタンス起動時に再びバックドアが設置される。

---

## 報告テンプレート

```markdown
## 永続化・バックドア探索の結果

### 確認した範囲
- [Tier 1] 特権アカウント、authorized_keys 全探索、sshd 実効設定、
  cron/at/systemd、SUID/SGID、ld.so.preload、シェル初期化、
  パッケージ整合性、MACタイムライン、AIセッションログ
- [Tier 2] PAM / NSS / profile.d / sshd Match ブロック / コンテナ設定

### 未確認の範囲
- カーネルモジュール・eBPF（高度調査を実施していない）
- メモリイメージ（取得していない）
- クラウド管理プレーン（ユーザー確認待ち）

### 検出の限界
本調査は侵害ホスト自身のコマンドを使用しているため、
ルートキットが導入されている場合、結果が偽装されている可能性がある。

### 所見
| # | 内容 | 根拠 | 確度 |
|---|---|---|---|
| 1 | UID 0 のアカウント `system` が存在 | /etc/passwd | 確定 |
| 2 | /usr/.system/.ssh/authorized_keys に未知の公開鍵 | all_authorized_keys.txt | 確定 |
| 3 | 上記は外部からの侵入によるもの | 鍵の出所が説明できない / 対応する ssh-keygen が履歴にない | 強く示唆 |
```

**確度は「確定 / 強く示唆 / 可能性 / 判定不能」の4段階で付ける。**
ログに直接記録されているものだけが「確定」。
