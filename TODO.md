# P0 修正リスト

**状態: 第3次査読完了 + 実機検証済み / collect_evidence.sh v3.2（2026-08-01）**
**残: テンプレート本文の肉付けのみ（スタブ配置済み・参照切れなし）**

作成: 2026-08-01
出典: チャッピー（ChatGPT）によるレビュー

---

## ✅ P0-1【完了】: `default deny outgoing` が Tailscale を殺す【実害あり】

**場所**: `incident-containment/SKILL.md` § 5 ホスト上からのLevel 2

**問題**: outbound を全遮断すると、維持するはずの Tailscale 経路自体が死ぬ。
既存セッションは一時的に生きても、切断後に再接続できない。
**唯一の脱出経路を自分で塞ぐ。**

**修正**: outbound 遮断時に、以下を明示的に許可する。

```bash
# Tailscale の維持に必要
sudo ufw allow out 41641/udp          # 直接接続
sudo ufw allow out 443/tcp            # DERP中継 + コーディネーションサーバー
sudo ufw allow out 53                 # DNS
sudo ufw allow out 123/udp            # NTP（時刻ずれは証拠の信頼性に影響）
# 証拠の転送先があれば、そこも
```

同様に検討が必要なもの:
- クラウドのメタデータサーバー（169.254.169.254）
- 管理エージェント／監視の疎通
- 証拠アーカイブの転送先

**「維持する経路を許可する」は、その経路が依存する通信も許可すること。**

---

## ✅ P0-2【完了】: `100.64.0.0/10` 丸ごとを信頼しない

**場所**: `incident-containment/SKILL.md` § 3 許可リスト

**問題**: `100.64.0.0/10` は CGNAT 帯全体。Tailscale が使う範囲であって、
自分の管理端末を指すものではない。

**修正**:

```bash
IR_TRUSTED_TAILSCALE_NODES="100.64.12.34/32"   # 確認済みノードのみ
IR_TRUSTED_INTERFACE="tailscale0"              # またはインターフェース指定
```

「Tailscale全体」ではなく「確認済みの管理ノード」。

---

## ✅ P0-3【完了】: `ufw reset` はロールバックではない

**場所**: `incident-containment/SKILL.md` § 5 ロールバック手順

**問題**: `ufw --force reset` は現行設定を初期化する破壊的操作。
バックアップからのファイル復元も、ufwの状態やディストリ差異で確実とは限らない。

**修正**: 既存設定を全消しせず、**専用チェーンで最小差分**にする。

```bash
# 実行前に保存
iptables-save  > /root/ir_backup/iptables.rules
ip6tables-save > /root/ir_backup/ip6tables.rules
nft list ruleset > /root/ir_backup/nftables.rules

# 隔離は専用チェーンで
iptables -N IR_CONTAINMENT
iptables -I INPUT  1 -j IR_CONTAINMENT
iptables -I OUTPUT 1 -j IR_CONTAINMENT
# ... ルールは IR_CONTAINMENT チェーンにのみ追加

# ロールバックはチェーン削除だけ
iptables -D INPUT  -j IR_CONTAINMENT
iptables -D OUTPUT -j IR_CONTAINMENT
iptables -F IR_CONTAINMENT
iptables -X IR_CONTAINMENT
```

利点: 既存FWを壊さない / 実施内容が特定できる / 戻すのが確実

---

## ✅ P0-4【完了】: Plan ID は正規化JSONからハッシュする

**場所**: `incident-containment/SKILL.md` § 0 Plan ID

**問題**: 表示テキストのハッシュだと、空白・改行・日付形式・コメントで値が変わる。
指差し確認にならない。

**修正**: プランを構造化データとして定義し、正規形をハッシュする。

```json
{
  "schema_version": 1,
  "target_id": "server-01",
  "level": 2,
  "execution_layer": "conoha-security-group",
  "preserve_cidrs": ["100.64.12.34/32"],
  "block_ingress": true,
  "block_egress": true,
  "rollback_action": "restore-security-group:sg-1234",
  "evidence_snapshot_id": "snapshot-5678"
}
```

シリアライズ規則: キー順固定 / UTF-8 / 余計な空白なし / 配列順固定 → SHA-256

これで Plan ID が「見た目の確認」から「実行内容に結びついた承認識別子」になる。

---

## ✅ P0-5【完了】: プランに有効期限を持たせる

**問題**: インシデント状況は変わる。古い封じ込め案を後から誤実行する事故を防ぐ。

**修正**: プランに以下を追加。

```
created_at            : 2026-08-01T05:12:00Z
expires_at            : 2026-08-01T05:30:00Z
evidence_snapshot_time: 2026-08-01T05:12:00Z
status                : proposed / approved / executed / invalidated
```

期限切れなら実行せず、以下を返す。

```
このプランは失効しています。
最新の接続状態から再生成してください。
```

---

## ✅ P0-6【完了】: 鍵フィンガープリントは常には取れない

**場所**: `incident-containment/SKILL.md` § 3 候補リストの出力例

**問題**: `ss` だけでは「この接続が authorized_keys の何番目の鍵で認証されたか」は分からない。
sshd の `LogLevel VERBOSE` で auth.log にフィンガープリントが残っていれば対応付け可能だが、
常に取れるとは限らない。

**修正**: 出力を2種類に分ける。**推測で対応付けない。**

```
鍵フィンガープリント: SHA256:xY3k...  （auth.log から確認済み）
```
```
鍵フィンガープリント: 判定不能（auth.log に記録なし / LogLevel が INFO）
```

---

## ✅ P1【完了】: 3兄弟共通の報告ルール

「実施した範囲 / 未実施の範囲 / 確認できていない範囲」を全スキルで併記する。

| スキル | 併記する3項目 |
|---|---|
| incident-response | 確認した証拠 / 存在しない証拠 / 確認不能な証拠 |
| incident-containment | 実施した封じ込め / 残存する経路 / 未失効の権限 |
| incident-cleanup | 削除した対象 / 残した対象 / 原証拠の保全場所 |

---

## 既知の未着手（前回から継続）

- ~~`collect_evidence.sh` のモード分割~~ ✅ quick / full の2モード（sensitive は v3.2 で廃止。下記参照）
- ~~`save()` の失敗記録（`COLLECTION_GAPS.txt`）~~ ✅ 完了（missing / failed / skipped の3区分）
- ~~`COLLECTION_METADATA.txt`~~ ✅ 完了（collector自身のSHA-256・実行UID・時刻同期状態・ギャップ件数）
- ~~SKILL.md frontmatter の `allowed-tools` 書式~~ ✅ 完了
- 「NIST準拠」表現 → 本リポジトリ版には該当箇所なし（ちぐらさん版をマージする際に要対応）
- テンプレート本文の肉付け（forensic_report / credential_rotation / deletion_audit）
  ※ スタブは配置済み。参照切れは解消
- ~~sensitive モードの平文一時ファイル~~ → **v3.2 でモードごと廃止**（tar パイプ化だけでは、その前段で平文ディレクトリを作っていたため不十分だった）
- ~~IPv4/IPv6 の分離~~ ✅ ip6tables に IPv4 CIDR を渡さない。ICMPv6 は通す
- chain_of_custody テンプレート（未着手）


---

## 第2次査読で発見・修正（2026-08-01）

| # | 内容 | 対応 |
|---|---|---|
| ✅ P0-1 | READMEに `DELETE-CONFIRM` と書いてあるのに未実装 | incident-cleanup に検証規則を実装（絶対パス・realpath解決後もworking-copy内） |
| ✅ P0-2 | Plan ID のハッシュ対象に可変な `status` が含まれ、承認時にIDが変わる | `plan`（不変）と `lifecycle`（可変）に分離し、`plan` のみハッシュ |
| ✅ P0-3 | **sensitiveモードが平文の秘密詰め合わせディレクトリを作っていた** | **モードごと廃止。** 秘密の本文は一切収集せず指紋のみ |
| ✅ P0-4 | マニフェスト作成後に証拠内ファイルへ追記され不整合 | 凍結順序を固定。パッケージングログを証拠ディレクトリ外へ |
| ✅ P0-5 | チェーン再実行でジャンプ重複、ロールバックが非対称 | 既存チェーンがあれば停止。ロールバックは全削除＋検証 |

### P1（未対応）

- `find / -xdev` は別マウント（`/home` `/var` が別FSの場合）を見落とす
  → `findmnt` でローカルFSを列挙し、各マウントポイントを起点に探索する
- atime汚染: タイムラインを収集の先頭で採取する（現在はメタデータに注記のみ）
- chain_of_custody テンプレート


---

## 第3次査読で発見・修正（2026-08-01）

| # | 内容 | 対応 |
|---|---|---|
| ✅ P0-1 | **INPUT/OUTPUT で同じチェーンを共有し、送信例外が受信開放に化けていた**（443/53/123/3478 が外部から到達可能）。FORWARD 未処理でコンテナが隔離を迂回 | `IR_CONTAINMENT_IN` / `_OUT` / `_FWD` に分離。方向・プロトコル・conntrack状態を各ルールに明記 |
| ✅ P0-2 | 侵害サーバー上の `curl ifconfig.me` はサーバー自身のIP。自分を許可したつもりで自分を遮断する。SSHポートも22固定 | `SSH_CONNECTION` から取得（ただし自動信頼しない）。ポートは `sshd -T` / `ss -tlnp` で確認 |
| ✅ P0-3 | Plan にポート番号の羅列しかなく、実行内容と一致していなかった（3478/udp が Plan に無いのに許可されていた） | ルールを family/hook/protocol/direction/conntrack 粒度で構造化。実行・ロールバックスクリプト自体のSHA-256も承認対象に |
| ✅ P0-4 | **AIエージェントの証拠が上書きされていた**（`.claude/settings.json` が `.codex/settings.json` で消える）。来歴も失われる | エージェント別ディレクトリに分離。コピー先が存在したら `gap failed` に記録して中止 |
| ✅ P0-5 | DELETE-CONFIRM でディレクトリを承認でき、`rm -rf` で保護対象を巻き込めた。bind mount 越えも可能 | 通常ファイル限定。シンボリックリンク拒否、デバイス番号でFS同一性を検証。ディレクトリは別手順（全ファイル個別承認 → 最後に `rmdir`） |

### P1（第3次）

| # | 内容 | 対応 |
|---|---|---|
| ✅ | アーカイブ名が同一秒で衝突 | `mktemp` の suffix を `RUN_ID` としてアーカイブ名・ログ名に使用 |
| ✅ | マニフェスト除外が `! -name` で広すぎ（証拠内の別 MANIFEST.sha256 も除外） | `! -path './MANIFEST.sha256'` に変更 |
| ✅ | `inventory()` の失敗がギャップに記録されない | find/sha256sum の失敗と UNREADABLE 件数を `gap failed` に記録 |
| ✅ | `COLLECTION_METADATA` の二重追記 | Phase 8 の凍結ブロックで一度だけ書く |
| ✅ | sensitive 廃止後の残骸（README / forensic_report / TODO） | 全て更新 |


---

## 実機検証で発見・修正（2026-08-01）

査読を3周した iptables コードを、初めてサンドボックスで実行した。**締め出された。**

| # | 内容 | 対応 |
|---|---|---|
| ✅ | 本番が初回実行になっていた（査読・構文チェックのみで未実行） | `references/rehearsal.md` + `scripts/rehearse_containment.sh` を追加 |
| ✅ | 受信側の許可漏れ。SSH 以外の新規受信が全て落ち、作業ツールが停止 | 適用前に「受信を必要とするもの」を洗い出す手順を追加 |
| ✅ | 締め出し時の復旧手段が無かった | デッドマンスイッチ（`setsid nohup` + sleep + rollback）を必須化 |
| ✅ | **最初の診断が誤り**（conntrack のせいにした。実際は正常動作） | 実測値に基づく記述へ全面訂正 |
| ✅ | 開発中の失敗が記録されていなかった | `FAILURES.md` を追加（8件） |

### 実測記録

```
IR_CT_PROBE  ESTABLISHED,RELATED : 15 packets   ← conntrack は正常
IR_CT_PROBE  NEW                 :  2 packets

適用後 curl https://example.com  → 通る（送信は無傷）
適用後 新規の受信接続            → 落ちる（締め出しの原因）

[2026-08-01T06:47:55Z] rollback done   ← デッドマン1回目
[2026-08-01T06:54:01Z] rb2 done        ← デッドマン2回目
残骸チェーン: 0
```
