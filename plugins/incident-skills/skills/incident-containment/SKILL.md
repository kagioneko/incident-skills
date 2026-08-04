---
name: incident-containment
description: >
  分析済みの所見に基づき、攻撃者の通信・セッション・認証情報を可逆的に封じ込める。
  dry-run が既定。実行は管理プレーン側を優先し、全操作をロールバック手順とともに記録する。
---

# インシデント封じ込め（Containment）

> [!CAUTION]
> **このスキルはモデルから自動的に呼び出されない。**
> Codexでは `agents/openai.yaml`、Claude Codeではインストール時のfrontmatterにより、ユーザーが明示した場合のみ起動する。
>
> ネットワーク遮断・セッション終了・認証失効は、誤ると
> **自分がロックアウトされ、証拠が失われ、正規利用者が遮断される。**
> 封じ込めの「判断と案の提示」は `incident-response` が行う。
> 本スキルは、承認された案を**実行可能な形にする**ためだけに使う。

---

## 0. 既定は dry-run

本スキルは、明示的に実行を指示されるまで、**コマンドを出力するだけで実行しない。**

```
既定:        コマンドを生成して表示。実行しない
--execute:   ユーザーが明示した場合のみ実行を提案（それでも最終実行はユーザー）
```

### 承認は Plan ID で行う

`--execute` だけでは弱い。**提示した案と、実際に実行される案が同一である保証がない。**
会話が長引けば別の案が挟まるし、レベルが暗黙に上がることもある。

そこで、封じ込め案を生成した時点で**プランを構造化データとして確定し、ハッシュを付ける。**

> [!IMPORTANT]
> **表示テキストのハッシュではなく、正規化した構造化データのハッシュを使う。**
> 表示のハッシュだと、空白・改行・日付形式・コメントの違いだけで値が変わり、
> 指差し確認として機能しない。

#### プランの正規形

> [!CAUTION]
> **ハッシュ対象に、変化する値を含めてはいけない。**
> `status` を `proposed → approved → executed` と更新する設計なので、
> これをハッシュ対象に入れると**承認した瞬間に Plan ID が変わり、
> 実行時の照合が必ず失敗する。**
> よって、不変部（`plan`）と可変部（`lifecycle`）を分離する。

```json
{
  "plan": {
    "schema_version": 1,
    "target_id": "server-01",
    "level": 2,
    "execution_layer": "conoha-security-group",
    "preserve_cidrs_v4": ["100.64.12.34/32", "203.0.113.10/32"],
    "preserve_cidrs_v6": [],
    "preserve_interfaces": ["tailscale0"],
    "preserve_egress_ports": [41641, 443, 53, 123],
    "block_ingress": true,
    "block_egress": true,
    "rollback_action": "restore-security-group:sg-1234",
    "evidence_snapshot_id": "snapshot-5678",
    "evidence_snapshot_time": "2026-08-01T05:12:00Z",
    "created_at": "2026-08-01T05:12:30Z",
    "expires_at": "2026-08-01T05:42:30Z"
  },
  "lifecycle": {
    "status": "proposed",
    "approved_at": null,
    "executed_at": null
  }
}
```

**`plan` オブジェクトのみをハッシュする。** `lifecycle` は監査イベントとして追記され、
Plan ID には影響しない。

### `plan.rules` は、実行するルールと1対1で対応させる

> [!CAUTION]
> **要約したポート番号のリストでは、承認識別子にならない。**
> `"preserve_egress_ports": [41641, 443, 53, 123]` のような書き方では、
> TCP か UDP か、受信か送信か、IPv4 か IPv6 か、宛先はどこか、
> conntrack 状態は何を許すかが表現できない。
>
> 実際、この形式で承認したプランに `3478/udp` が含まれていないのに、
> 実行コマンド側では許可している、という不一致が起きていた。
> **Plan に無い通信許可が実行されるなら、Plan ID は意味がない。**

各ルールをこの粒度で列挙する。

```json
{
  "family": "ipv4",
  "hook": "OUTPUT",
  "chain": "IR_CONTAINMENT_OUT",
  "interface": null,
  "protocol": "udp",
  "source": null,
  "destination": "0.0.0.0/0",
  "destination_port": 3478,
  "conntrack_states": ["NEW", "ESTABLISHED"],
  "action": "RETURN",
  "comment": "Tailscale STUN"
}
```

### 実行スクリプトそのものもハッシュ対象に含める

ルールを構造化しても、**実際に走るスクリプトが別物なら意味がない。**

```json
{
  "execution_bundle_sha256": "生成した適用スクリプトの SHA-256",
  "rollback_bundle_sha256":  "生成したロールバックスクリプトの SHA-256"
}
```

実行直前に、スクリプトのハッシュを再計算して一致を確認する。
一致しなければ実行しない。

```bash
sha256sum -c plan_bundles.sha256 || { echo "スクリプトが承認時と異なります" >&2; exit 1; }
```

> [!IMPORTANT]
> ### 正規化・照合はツールで行う
>
> ```bash
> # Plan ID を計算
> scripts/plan_tool.sh id plan.json
>
> # 実行/ロールバックスクリプトのハッシュを封入し、Plan ID を再計算
> scripts/plan_tool.sh seal plan.json --exec apply.sh --rollback rollback.sh
>
> # 実行直前に検証（ID一致・期限・status・スクリプトのハッシュ・維持経路）
> scripts/plan_tool.sh verify plan.json --plan-id <ID> \
>     --exec apply.sh --rollback rollback.sh
>
> # plan.rules から iptables コマンドを生成（実行はしない）
> scripts/plan_tool.sh rules plan.json
> ```
>
> **`verify` が exit 0 を返したときだけ実行してよい。**
> ハッシュの照合を人間や言語モデルが目視で行うのは、照合ではない。
>
> `rules` で生成したコマンドを使えば、**承認したプランと実行内容が構造的に一致する。**
> 手書きすると、プランに無い許可（例: `3478/udp`）が紛れ込む。

**シリアライズ規則**: キー順を辞書順に固定 / UTF-8 / 余計な空白なし / 配列順を固定

```bash
# 生成例（plan 部分のみを対象にする）
jq -S -c '.plan' plan.json | tr -d '\n' | sha256sum
```

これで Plan ID が「見た目の指差し確認」から、
**実行内容に一意に結びついた承認識別子**になる。

#### ユーザーへの表示

```
━━━ 封じ込めプラン ━━━
Plan ID      : SHA256:a1b2c3d4e5f6...
Target       : server-01 (203.0.113.42)
Level        : 2 (Host Isolation)
実行レイヤ    : ConoHa セキュリティグループ（管理プレーン）

維持する経路  : Tailscale 100.64.12.34/32 (tailscale0)
              : 管理接続 203.0.113.10/32 → 22/tcp
維持する egress: 41641/udp, 443/tcp, 53, 123/udp
              ⚠ 443 を開けるため、C2が443を使う場合は遮断されません
遮断する経路  : public eth0 ingress/egress（上記以外すべて）

ロールバック  : rollback_server-01_20260801T0512Z.sh
              （実行前に別端末へ保存してください）
証拠取得済み  : ss / ps / who / auth.log / lsof   ✅
帯域外経路    : VNCコンソール ログイン確認済み    ✅

作成         : 2026-08-01T05:12:30Z
有効期限     : 2026-08-01T05:42:30Z（30分）
基準スナップ  : 2026-08-01T05:12:00Z
状態         : proposed
━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 有効期限

> [!CAUTION]
> **インシデントの状況は変わる。古い封じ込め案の誤実行を防ぐ。**

`lifecycle.status` は `proposed → approved → executed` と遷移する。
**この遷移で Plan ID は変わらない**（ハッシュ対象は `plan` のみ）。

以下の場合は `invalidated` にして、**実行せず再生成を求める。**

- `expires_at` を過ぎた
- 基準スナップショット以降に接続状態が変化した
- 対象・レベル・維持経路のいずれかが変更された

```
このプランは失効しています（作成から30分以上経過）。
最新の接続状態から再生成してください。

  Plan ID   : SHA256:a1b2c3...
  作成      : 2026-08-01T05:12:30Z
  現在      : 2026-08-01T05:51:02Z
```

実行の要求には、**このプランを指すIDを含めてもらう。**

```
contain.sh \
  --level 2 \
  --preserve-cidr 100.64.12.34/32 \
  --plan-id a1b2c3d4e5f6 \
  --confirm-token "CONTAIN-HOST:server-01" \
  --execute
```

`--plan-id` が現在のプランと一致しなければ、**実行せず再提示する。**

### 実行前チェック（すべて必須）

- [ ] Phase 1（揮発性データの取得）が完了している
- [ ] **ロールバック手順が生成され、別端末に保存されている**
- [ ] **管理経路が隔離後も残ることを検証済み**（下記）
- [ ] 維持する経路（`--preserve-cidr`）がユーザーによって指定されている
- [ ] `--plan-id` が現在のプランと一致している
- [ ] 確認トークン `CONTAIN-HOST:<ホスト名>` を含む承認がある

「Continue」「やって」「大丈夫」「OK」は承認とみなさない。

### 帯域外管理経路の「検証」

> [!CAUTION]
> **確認ではなく検証。** 「コンソールありますか？」→「たぶんある」では不十分。
> リモートVPSで、SSHセッションの中から自分の接続元を遮断するコマンドを実行するのは、
> **自殺ボタンを押すのと同じ。**

実行の前に、以下を**実際に試してもらう。**

```
封じ込めの前に、SSH以外の管理経路が生きていることを確認してください。
「あるはず」ではなく、いま実際に開いてログインできることを確認します。

□ 事業者のコンソール（VNC / シリアルコンソール）を開いた
□ そこからログインできた
□ ログイン用のパスワードを控えてある
   ※ 鍵認証のみの設定だと、コンソールから入れない場合があります

コンソールから入れない場合は、Level 2 を実行しないでください。
先に、コンソールログインを有効にするか、
管理プレーン側でのみ（ホストに触れずに）隔離してください。
```

### 実行順序（この順を守る）

```
1. ロールバック手順を生成
2. 管理経路が残ることを検証        ← ここを飛ばすと詰む
3. ロールバック手順を別端末へ保存
4. 封じ込めを実行
5. 結果を検証（接続が残っていないか、自分が入れるか）
```

---

## 1. ロールバックを先に出す

> [!IMPORTANT]
> **戻し方を提示してから、やり方を提示する。**
> 順序を逆にしない。戻せない操作は、戻せないと明記してから提案する。

出力の形式は必ずこの順。

```
━━━ ロールバック手順 ━━━
（この操作を取り消す方法。実行前に控えてください）

    <戻すコマンド / 管理画面の操作>

━━━ 現在の設定のバックアップ ━━━

    <実行前に保存すべき設定と、その保存コマンド>

━━━ 実行する操作 ━━━

    <封じ込めコマンド>

━━━ 影響 ━━━

    <止まるもの / 切れるもの>
```

---

## 2. 封じ込めレベル

可逆性の高い順に実施する。**いきなり Level 3 以上へ飛ばない。**

| Level | 名称 | 内容 | 可逆性 |
|---|---|---|---|
| **0** | Observe | 保存・分析のみ。環境を変更しない | 完全 |
| **1** | Block Source | 特定IP/CIDRからの**新規**通信を遮断 | 高 |
| **2** | Isolate Host | 調査経路以外の入出力を遮断 | 高 |
| **3** | Terminate Session | 証拠保存後、確認済みの不正セッションを終了 | **不可逆** |
| **4** | Revoke Identity | SSH鍵・APIキー・IAMセッション・トークンを失効 | **不可逆** |

### レベル選択の指針

- **Level 1 は単独では弱い。** 攻撃者は別IP・別経路・アウトバウンドへ切り替えられる
- **通常は Level 2 から。** ホスト全体の隔離のほうが、特定IPのブロックより堅い
- **Level 3 の前に必ず Level 0 を完了する。** セッションを切ると接続情報が消える
- **Level 4 はクリーン端末から。** 侵害環境で新しい認証情報を扱わない

> [!WARNING]
> **ファイアウォールの変更は、確立済みのTCP接続を切らない。**
> AWS のセキュリティグループも、追跡中の接続は終了せず、新規通信のみが遮断される。
> Level 2 を実施しても、既存セッションは Level 3 を行うまで残る。
> **「遮断した＝追い出した」ではない。**

---

## 3. 判定は許可リストで行う

> [!CAUTION]
> **「現在の接続元IP以外を蹴る」を使わない。**
>
> 自宅回線のIPは変わる。IPv4とIPv6が混在する。NAT・VPN・Tailscale・踏み台がある。
> 管理者が複数いる。監視やバックアップの正規接続がある。
> 誤判定すると、正規利用者と自分自身を遮断する。

判定は事前登録した許可元に基づく。

```bash
IR_TRUSTED_CIDRS="203.0.113.0/24,198.51.100.5/32"   # 管理接続を許可するCIDR
IR_TRUSTED_TAILSCALE_NODES="100.64.12.34/32"         # 確認済みの管理ノードのみ
IR_TRUSTED_INTERFACE="tailscale0"                    # またはインターフェース指定
IR_BREAK_GLASS_IPS="192.0.2.10/32"                   # 緊急時の最終手段
IR_ALLOWED_ADMIN_USERS="nekosan,deploy"              # 正規の管理ユーザー
```

> [!CAUTION]
> **`100.64.0.0/10` を丸ごと許可しない。**
> これは CGNAT 用のアドレス帯全体であり、Tailscale が使う範囲ではあるが、
> **あなたの管理端末を指すものではない。**
> 同じ帯域を使う他のノードや、tailnet に参加した攻撃者のデバイスも含まれ得る。
>
> 許可するのは、**確認済みノードの `/32`** か、`tailscale0` インターフェース経由という
> 条件のいずれか。範囲ではなく個体で指定する。

**「ユーザー以外を蹴る」ではなく「許可リストにない管理接続を封じ込め候補にする」。**

### 未設定のまま事故が起きた場合（大半はこれ）

事前登録は、たいてい済んでいない。そして**現在進行形の侵害中に、ゼロから自由回答を待つのは遅い。**

> [!CAUTION]
> ### 許可候補 ≠ 信頼済み
>
> **検出した接続元を、自動的に信頼済みにしてはならない。**
> いま入られている最中なのだから、検出された接続元に攻撃者が含まれている可能性がある。
>
> スキルは**候補を抽出して提示するだけ**。どれを維持するかはユーザーが選ぶ。

> [!CAUTION]
> ### 侵害サーバー上で `curl ifconfig.me` を使わない
>
> それで得られるのは**サーバー自身の外向きIP**であって、SSHクライアントの接続元ではない。
> その値を許可元にすると、**自分を許可したつもりで自分を遮断する。**
>
> サーバー側で接続元を得るなら `SSH_CONNECTION` を使う。
>
> ```bash
> read -r CLIENT_IP CLIENT_PORT SERVER_IP SERVER_PORT <<< "${SSH_CONNECTION:?SSH接続情報なし}"
> printf 'client_ip=%s\n'       "$CLIENT_IP"
> printf 'server_ip=%s\n'       "$SERVER_IP"
> printf 'server_ssh_port=%s\n' "$SERVER_PORT"   # ← SSHポートも固定22と決めつけない
> ```
>
> `curl -4 ifconfig.me` を使うなら、**管理者のローカル端末で実行する**こと。
>
> **ただし `SSH_CONNECTION` の値も自動で信頼しない。** その接続自体が攻撃者のものかもしれない。
> 次と突き合わせて「候補」にする:
> `auth.log` の該当エントリ / `ss -tnp` / 使用した鍵のフィンガープリント /
> Tailscale 管理画面のデバイス一覧 / ユーザー本人の端末側で確認したIP

### SSH ポートを 22 と決めつけない

待受ポートを変更している環境では、`--dport 22` だけ許可しても再接続できない。
現在の接続は ESTABLISHED で一時的に残るが、切断したら終わり。

```bash
sshd -T | grep -i '^port '        # 実効の待受ポート
ss -tlnp | grep sshd              # 実際に LISTEN しているポート
echo "${SSH_CONNECTION##* }"      # 現在の接続が使っているサーバー側ポート
```

スキル側で候補を自動抽出し、判断材料を添えて提示する。

```
許可元の候補を検出しました。
このうち、隔離後も維持する経路を指定してください。
（検出＝安全ではありません。心当たりのないものは選ばないでください）

┌─ 候補1 ─────────────────────────────────
│ 203.0.113.10/32   現在のSSH接続元
│   ユーザー      : nekosan
│   鍵FP          : SHA256:xY3k...（auth.log から確認済み）
│                   ※取得できない場合は「判定不能」と表示されます
│   接続開始      : 2026-08-01 05:02:11
│   TTY           : pts/0
│   経路          : 直接（VPN経由ではない）
│   ⚠ これはあなたの接続ですか？
└──────────────────────────────────────

┌─ 候補2 ─────────────────────────────────
│ 100.64.12.34/32   Tailscale インターフェース
│   状態          : tailscale0 up
│   経路          : オーバーレイ（公開IPを閉じても残る）
│   ✅ 推奨：これを維持すれば、公開側を全遮断しても入れます
└──────────────────────────────────────

┌─ 候補3 ─────────────────────────────────
│ 未設定           クラウド管理用CIDR
│   IR_TRUSTED_CIDRS が設定されていません
└──────────────────────────────────────

┌─ 候補4 ─────────────────────────────────
│ 未確認           監視 / バックアップ / CI からの接続
│   遮断すると、これらのジョブが失敗します
└──────────────────────────────────────

追加で許可が必要な接続元はありますか？
  □ 別の作業場所（職場 / モバイル回線 / テザリング）
  □ 他の管理者
  □ ロードバランサ / リバースプロキシ
  □ IPv6（curl -6 ifconfig.me）※ v4 だけ許可して v6 で締め出す事故が多い

回線のIPは変わりますか？
  → 動的IPなら、単一IPではなくVPN経由の維持を推奨します
```

**候補2（オーバーレイ経路）があれば、それを維持するのが最も安全。**
公開IPを全部閉じても入れるうえ、攻撃者の経路とは独立している。

### 鍵フィンガープリントは常に取得できるわけではない

> [!CAUTION]
> **`ss` や `ps` だけでは「この接続がどの鍵で認証されたか」は分からない。**
> OpenSSH 6.3 以降は通常、成功した公開鍵認証のフィンガープリントを
> `LogLevel INFO` でも記録する。対応付けは、認証ログに実際の記録がある場合に限る。
> 古い OpenSSH、ログ未保全、ログ形式・出力先の違いも考慮する。
>
> **取得できなければ「判定不能」と書く。推測で対応付けない。**

```bash
# auth.log にフィンガープリントが残っているか確認
grep -E 'Accepted (publickey|password)' /var/log/auth.log | tail -50

# 記録がある場合の例:
#   Accepted publickey for nekosan from 203.0.113.10 port 51234 ssh2:
#     ED25519 SHA256:xY3k...

# バージョン、現在のログレベル、ログ出力先も記録
sshd -V 2>&1 || true
sshd -T | grep -i loglevel
```

出力は必ずどちらかの形にする。

```
鍵FP: SHA256:xY3k...  （auth.log から確認済み、2026-08-01T05:02:11 のエントリ）
```
```
鍵FP: 判定不能（認証ログに該当エントリなし）
```

> [!NOTE]
> OpenSSH 6.2 以前では、成功した公開鍵認証の FP を得るために
> `LogLevel VERBOSE` が必要だった。6.3 以降へその要件を持ち込まない。
> 平時に、実際の認証ログと永続化を確認する。侵害後に設定を変えても過去のログは戻らない。

---

## 4. 実行順序

```
1. 接続状態を保存        ss / ps / who / w / loginctl / sshd ログ
2. 接続とプロセスを対応付ける
                         IP・PID・ユーザー・TTY・開始時刻・親プロセス
3. クラウド側ログを保存  Flow Logs / 監査ログ / IAM 操作履歴
4. スナップショット取得  または証拠アーカイブ作成
5. 封じ込め案を提示      ← ここまでが incident-response の仕事
─────────────────────────────────────────────
6. 管理プレーン側から可逆的に隔離   ← 本スキル
7. 既存接続が残っていないか再確認
8. 実施内容とロールバック手順を監査ログへ記録
```

> [!CAUTION]
> **1〜4 を飛ばして 6 へ行かない。**
> 遮断した瞬間に、接続元・PID・対応関係が消える。
> 取得コストは数秒。失うと二度と取れない。

### 接続とプロセスの対応付け

```bash
# これを封じ込めの前に必ず取る
ss -tunap                                    # 接続 → PID
ps -eo pid,ppid,user,tty,lstart,cmd          # PID → ユーザー・開始時刻・親
who -a ; w -h                                # ログインセッション
loginctl list-sessions                       # systemd-logind 管理下のセッション
ls -l /proc/*/exe 2>/dev/null                # 実行ファイルの実体（削除済みバイナリの検出）
```

`/proc/<PID>/exe` が `(deleted)` を指していれば、**実行ファイルが削除済みのまま動いている**。
これはマルウェアの典型的な挙動なので、セッションを切る前に必ず記録する。

---

## 5. Level 2: ホスト隔離

### 管理プレーンから（推奨）

事業者別の該当箇所は `../incident-response/references/containment_matrix.md` を参照。

> [!IMPORTANT]
> **必ず管理プレーンを先に案内する。**
> ホスト上の ufw / iptables は、root を取られていれば攻撃者側から解除できる。

**AWS の推奨方式**: 隔離用の空のセキュリティグループを作り、インスタンスに**付け替える**。
元のセキュリティグループIDを控えておけば、付け直すだけで戻せる。

### ホスト上から（管理プレーンにアクセスできない場合の次善策）

> [!CAUTION]
> ### `ufw --force reset` を使わない
>
> `reset` は現行設定を初期化する**破壊的操作**であり、ロールバックではない。
> バックアップファイルからの復元も、ufw の状態やディストリビューションの差異で
> 確実に戻る保証がない。
>
> **既存設定を全消しせず、専用チェーンを追加する形で最小差分にする。**
> 戻すときはそのチェーンだけを削除すればよい。

> [!CAUTION]
> ### `default deny outgoing` は、維持したい経路も殺す
>
> **Tailscale や VPN は、経路の維持そのものに outbound 通信を必要とする。**
> outbound を全遮断すると、いま繋がっているセッションは一時的に生きても、
> 切断後に**再接続できなくなる。**
>
> つまり「Tailscale を残すつもりの設定」が、**唯一の脱出経路を塞ぐ。**
> 維持する経路を許可するとは、**その経路が依存する通信も許可すること。**

#### 1. 現在の設定を保存（ロールバックの材料）

```bash
sudo mkdir -p /root/ir_backup
sudo iptables-save  | sudo tee /root/ir_backup/iptables.rules  > /dev/null
sudo ip6tables-save | sudo tee /root/ir_backup/ip6tables.rules > /dev/null
sudo nft list ruleset 2>/dev/null | sudo tee /root/ir_backup/nftables.rules > /dev/null
sudo cp -a /etc/ufw /root/ir_backup/ufw 2>/dev/null
sudo ip addr > /root/ir_backup/interfaces_before.txt
```

#### 2. ロールバック手順（実行前に別端末へ保存すること）

```bash
#!/usr/bin/env bash
# rollback_<host>_<timestamp>.sh
# 隔離チェーンを外すだけ。既存ルールには触れない。
set -u

FAILED=0
for T in iptables ip6tables; do
    # フック名 : チェーン名 の対応
    for PAIR in "INPUT:IR_CONTAINMENT_IN" "OUTPUT:IR_CONTAINMENT_OUT" "FORWARD:IR_CONTAINMENT_FWD"; do
        HOOK="${PAIR%%:*}"; CHAIN="${PAIR##*:}"
        # ジャンプは重複している可能性があるため、無くなるまで削除する
        n=0
        while $T -C "$HOOK" -j "$CHAIN" 2>/dev/null; do
            $T -D "$HOOK" -j "$CHAIN" 2>/dev/null || break
            n=$((n+1))
            [ "$n" -gt 50 ] && { echo "$T $HOOK: 削除ループが異常" >&2; FAILED=1; break; }
        done
        [ "$n" -gt 0 ] && echo "$T $HOOK -> $CHAIN: ジャンプを $n 個削除"

        if $T -nL "$CHAIN" >/dev/null 2>&1; then
            $T -F "$CHAIN" 2>/dev/null
            $T -X "$CHAIN" 2>/dev/null || {
                echo "$T: $CHAIN を削除できません（参照が残っている可能性）" >&2
                FAILED=1
            }
        fi
        # 検証: 本当に消えたか
        if $T -nL "$CHAIN" >/dev/null 2>&1; then
            echo "$T: ★ $CHAIN がまだ存在します" >&2
            FAILED=1
        fi
    done
done

if [ "$FAILED" -eq 0 ]; then
    echo "隔離チェーンを削除しました。既存ルールは変更していません。"
else
    echo "★ ロールバックが完全ではありません。手動で確認してください:" >&2
    echo "   iptables  -nL --line-numbers | grep IR_CONTAINMENT" >&2
    echo "   ip6tables -nL --line-numbers | grep IR_CONTAINMENT" >&2
    exit 1
fi
```

> [!IMPORTANT]
> **ジャンプは1回の `-D` では消えない場合がある。**
> 隔離を再実行すると `-I` が重複して挿入されるため、無くなるまでループする。
> そして最後に「本当に消えたか」を検証する。
> `|| true` で握りつぶすと、**ロールバックが失敗しても成功したように見える。**

#### 3. 実行する操作（方向別チェーン方式）

> [!CAUTION]
> ### INPUT と OUTPUT で同じチェーンを共有してはいけない
>
> 単一チェーンを両方から呼ぶと、**送信の例外がそのまま受信の開放になる。**
> 例えば Tailscale 維持のために `--dport 443 -j RETURN` を入れると、
> 外部から**サーバーの 443/tcp へ接続できてしまう。** 53 も 123 も 3478 も同様。
> 「隔離した」つもりで穴を開けることになる。
>
> **方向ごとにチェーンを分ける。**
> - `IR_CONTAINMENT_IN` … 受信。管理経路だけ通す
> - `IR_CONTAINMENT_OUT` … 送信。Tailscale / DNS / NTP だけ通す
> - `IR_CONTAINMENT_FWD` … 転送。**Docker やブリッジ接続のコンテナはここを通る**
>
> `FORWARD` を処理しないと、**コンテナ経由の通信が隔離を丸ごと迂回する。**

##### 適用前の必須検証: 受信を必要とするものを洗い出す

> [!CAUTION]
> ### `ESTABLISHED` は「いま繋がっている接続」しか守らない
>
> **新しく張られてくる受信接続は、すべて DROP される。**
> SSH だけを許可リストに入れて隔離すると、次が全部落ちる。
>
> - 構成管理エージェント（オーケストレータから接続してくる型）
> - 監視のポーリング / ヘルスチェック
> - ロードバランサからのバックエンド接続
> - コンテナ / クラウドの管理プレーンからの接続
> - リモート作業に使っているツールそのもの
>
> **実測**: 本スキルの初回実行時、これで作業環境が停止した。
> 送信側（`curl https://`）は問題なく通っていたため、
> 「送信の設定ミス」だと誤診して切り分けに時間を要した。
> **原因は受信側だった。**

```bash
# 現在この host が受信している接続を全部出す
ss -tnp state established '( sport = :* )' 2>/dev/null | sed 1d \
    | awk '{print $4, $5, $6}' | sort -u

# 待受ポートとプロセス
ss -tlnp

# これらのうち「隔離後も必要なもの」をユーザーに選ばせる。
# 推測で埋めない。落とすと復旧手段を失うものがある。
```

##### 適用前の必須検証: conntrack

```bash
iptables -N IR_CT_TEST 2>/dev/null
if iptables -A IR_CT_TEST -m conntrack --ctstate ESTABLISHED -j RETURN 2>/dev/null; then
    echo "OK: conntrack 使用可能"
else
    echo "NG: conntrack が使えません（既存接続の保護が機能しません）"
fi
iptables -F IR_CT_TEST 2>/dev/null; iptables -X IR_CT_TEST 2>/dev/null
```

使えない場合は、ホスト側での隔離を避け、管理プレーン側から実施する。

##### 適用前の必須検証: デッドマンスイッチ

> [!IMPORTANT]
> **締め出されても、放っておけば戻る仕掛けを、適用の前に入れる。**
> 実測で、これが唯一の復旧手段になった。

```bash
# ロールバックスクリプトを先に用意しておく
setsid nohup bash -c 'sleep 600; bash /root/ir_backup/rollback.sh' >/dev/null 2>&1 &
echo "10分後に自動ロールバックします"
echo "  接続を確認できたら: pkill -f 'sleep 600'"
echo "  入れなくなったら:   何もせず10分待つ"
```

**`setsid nohup` は必須。** 締め出しで親シェルが死んでも、
ロールバックだけは生き残る必要がある。

実測では、これが**唯一の復旧手段**だった。2回のテストで2回とも自動発火し、
残骸チェーン0で完全復旧している。

##### 変数の確定

```bash
# --- 管理接続（P0-2 の手順で確定した値を入れる。推測で埋めない）---
ADMIN_V4=""          # 例: 203.0.113.10/32   ※SSH_CONNECTION から取得し、承認済みのもの
ADMIN_V6=""          # 例: 2001:db8::1/128
SSH_PORT=""          # 例: 22   ※固定で 22 と書かない。実際の待受ポート

TS_NODE_V4=""        # 確認済み Tailscale ノード /32
TS_NODE_V6=""        # 確認済み Tailscale ノード /128
TS_IF="tailscale0"

# 未確定のまま進まない
[ -n "$ADMIN_V4$ADMIN_V6" ] || { echo "FATAL: 管理接続元が未設定" >&2; exit 1; }
[ -n "$SSH_PORT" ]          || { echo "FATAL: SSHポートが未設定" >&2; exit 1; }
```

##### 既存チェーンの検査

```bash
for T in iptables ip6tables; do
    for C in IR_CONTAINMENT_IN IR_CONTAINMENT_OUT IR_CONTAINMENT_FWD; do
        if $T -nL "$C" >/dev/null 2>&1; then
            echo "既存の $C があります ($T)。自動で再利用しません。" >&2
            echo "先にロールバックを実行してください。" >&2
            exit 1
        fi
    done
done
```

##### IPv4

```bash
# ===== 受信 (INPUT) =====
iptables -N IR_CONTAINMENT_IN
iptables -A IR_CONTAINMENT_IN -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A IR_CONTAINMENT_IN -i lo -j RETURN
# 管理SSHのみ（ポートは実際の待受値）
[ -n "$ADMIN_V4" ] && iptables -A IR_CONTAINMENT_IN \
    -s "$ADMIN_V4" -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -j RETURN
# Tailscale
[ -n "$TS_NODE_V4" ] && iptables -A IR_CONTAINMENT_IN -s "$TS_NODE_V4" -j RETURN
iptables -A IR_CONTAINMENT_IN -i "$TS_IF" -j RETURN
# Tailscale の直接接続を受けるためのUDP（送信元ポートではなく待受ポート）
iptables -A IR_CONTAINMENT_IN -p udp --dport 41641 -j RETURN
iptables -A IR_CONTAINMENT_IN -j DROP

# ===== 送信 (OUTPUT) =====
iptables -N IR_CONTAINMENT_OUT
iptables -A IR_CONTAINMENT_OUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A IR_CONTAINMENT_OUT -o lo -j RETURN
iptables -A IR_CONTAINMENT_OUT -o "$TS_IF" -j RETURN
[ -n "$TS_NODE_V4" ] && iptables -A IR_CONTAINMENT_OUT -d "$TS_NODE_V4" -j RETURN
# Tailscale の維持に必要な送信（これがないと切断後に再接続できない）
iptables -A IR_CONTAINMENT_OUT -p udp --dport 41641 -j RETURN   # 直接接続
iptables -A IR_CONTAINMENT_OUT -p tcp --dport 443   -j RETURN   # DERP / コーディネーション
iptables -A IR_CONTAINMENT_OUT -p udp --dport 3478  -j RETURN   # STUN
# 基盤サービス
iptables -A IR_CONTAINMENT_OUT -p udp --dport 53  -j RETURN     # DNS
iptables -A IR_CONTAINMENT_OUT -p tcp --dport 53  -j RETURN
iptables -A IR_CONTAINMENT_OUT -p udp --dport 123 -j RETURN     # NTP
iptables -A IR_CONTAINMENT_OUT -j DROP

# ===== 転送 (FORWARD) — Docker / コンテナはここを通る =====
iptables -N IR_CONTAINMENT_FWD
iptables -A IR_CONTAINMENT_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A IR_CONTAINMENT_FWD -i "$TS_IF" -j RETURN
iptables -A IR_CONTAINMENT_FWD -o "$TS_IF" -j RETURN
iptables -A IR_CONTAINMENT_FWD -j DROP

# ===== 有効化（先頭へ挿入）=====
iptables -I INPUT   1 -j IR_CONTAINMENT_IN
iptables -I OUTPUT  1 -j IR_CONTAINMENT_OUT
iptables -I FORWARD 1 -j IR_CONTAINMENT_FWD
```

##### IPv6

> [!CAUTION]
> **IPv4 の CIDR を `ip6tables` に渡さない。** ルールが無効になり、
> 許可が1つも成立しないまま DROP だけが効いて締め出される。
>
> **`ipv6-icmp` を落とさない。** NDP（近隣探索）と PMTUD に必須。
> ここを DROP すると、許可ルールが正しくても通信が成立しない。

```bash
# IPv6 の許可元が未確定なら、勝手に進まない
if [ -z "$ADMIN_V6" ] && [ -z "$TS_NODE_V6" ] && [ "${APPLY_V6:-}" != "yes" ]; then
    cat >&2 <<'WARN'
IPv6 の許可元が設定されていません。
このまま適用すると IPv6 経由の接続がすべて遮断されます。

  A) IPv6 の許可元を設定する   → ip -6 addr / tailscale ip -6 / SSH_CONNECTION
  B) IPv6 は遮断してよいと確認済み → APPLY_V6=yes を設定して再実行
     （IPv4 でのみ接続していることを確認してから）
WARN
    exit 1
fi

ip6tables -N IR_CONTAINMENT_IN
ip6tables -A IR_CONTAINMENT_IN -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
ip6tables -A IR_CONTAINMENT_IN -i lo -j RETURN
ip6tables -A IR_CONTAINMENT_IN -p ipv6-icmp -j RETURN
[ -n "$ADMIN_V6" ] && ip6tables -A IR_CONTAINMENT_IN \
    -s "$ADMIN_V6" -p tcp --dport "$SSH_PORT" -m conntrack --ctstate NEW -j RETURN
[ -n "$TS_NODE_V6" ] && ip6tables -A IR_CONTAINMENT_IN -s "$TS_NODE_V6" -j RETURN
ip6tables -A IR_CONTAINMENT_IN -i "$TS_IF" -j RETURN
ip6tables -A IR_CONTAINMENT_IN -p udp --dport 41641 -j RETURN
ip6tables -A IR_CONTAINMENT_IN -j DROP

ip6tables -N IR_CONTAINMENT_OUT
ip6tables -A IR_CONTAINMENT_OUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -o lo -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -p ipv6-icmp -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -o "$TS_IF" -j RETURN
[ -n "$TS_NODE_V6" ] && ip6tables -A IR_CONTAINMENT_OUT -d "$TS_NODE_V6" -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -p udp --dport 41641 -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -p tcp --dport 443   -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -p udp --dport 3478  -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -p udp --dport 53  -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -p tcp --dport 53  -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -p udp --dport 123 -j RETURN
ip6tables -A IR_CONTAINMENT_OUT -j DROP

ip6tables -N IR_CONTAINMENT_FWD
ip6tables -A IR_CONTAINMENT_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
ip6tables -A IR_CONTAINMENT_FWD -p ipv6-icmp -j RETURN
ip6tables -A IR_CONTAINMENT_FWD -i "$TS_IF" -j RETURN
ip6tables -A IR_CONTAINMENT_FWD -o "$TS_IF" -j RETURN
ip6tables -A IR_CONTAINMENT_FWD -j DROP

ip6tables -I INPUT   1 -j IR_CONTAINMENT_IN
ip6tables -I OUTPUT  1 -j IR_CONTAINMENT_OUT
ip6tables -I FORWARD 1 -j IR_CONTAINMENT_FWD
```

> [!IMPORTANT]
> **`443/tcp` の送信を開けると、C2 通信も 443 を使える。**
> これは「Tailscale 経路の維持」と「C2 遮断」のトレードオフ。
> DERP サーバーの IP に絞れるなら絞る。絞れないなら、
> **このトレードオフをユーザーに明示したうえで選んでもらう。黙って開けない。**
>
> 管理プレーン側で隔離できるなら、この妥協は不要。

#### 4. 実行直後に検証

```bash
# 自分のセッションが生きているか（別端末から確認するのが確実）
# ※ 実際のホスト名に置き換えて実行すること
ssh -o ConnectTimeout=10 "$ADMIN_HOST" 'echo OK'

# Tailscale が生きているか
tailscale status
tailscale ping "$PEER_NODE"

# チェーンが効いているか
sudo iptables -L IR_CONTAINMENT -n -v --line-numbers
```

**入れなくなったら、コンソールから rollback スクリプトを実行する。**

#### 影響

```
・監視 / 死活監視エージェントが停止します
・バックアップジョブが失敗します
・certbot の証明書自動更新が止まります
・パッケージ更新ができなくなります
・許可リスト以外からのSSHが不可になります
  → 誤りがあると、あなたも入れなくなります
・443 を開けているため、C2通信が443を使う場合は遮断できません
```

**outbound の遮断は最重要だが、全遮断ではない。** 侵害時に怖いのは出ていくこと。
ただし、**自分の帰り道まで塞がないこと。**

---

## 6. Level 3: セッション終了

> [!CAUTION]
> **不可逆。** 実行前に Level 0 の記録が完了していること。

```bash
# 自分のセッションを特定する（これを落としてはいけない）
echo "自分のPID階層: $$ / $PPID"
tty
```

対象PIDを**一件ずつ**提示し、以下を併記してユーザーの確認を取る。

| PID | ユーザー | 接続元 | 開始時刻 | 実行ファイル | 自分か |
|---|---|---|---|---|---|

一括での `pkill` は提案しない。**対象を列挙し、個別に確認する。**

---

## 7. Level 4: 認証情報の失効

> [!CAUTION]
> ### 侵害された環境で、新しい認証情報を扱わない
>
> 侵害ホスト上で新しいAPIキー・パスワード・SSH秘密鍵を**作らない、置かない、貼らない。**
> root を取られたままなら、新しい鍵も即座に漏れる。
>
> 失効と再発行は**クリーンな端末**から。新しい鍵の配備は**新環境を構築してから**。

失効対象は `../incident-response/templates/credential_rotation.md` を使う。忘れられがちなもの:

- **TLS証明書と対応する秘密鍵**（`certbot revoke --reason keycompromise` → 旧鍵破棄 → 再発行 → 再配備まで1セット）
- **クラウドIAM**（アクセスキー、サービスアカウントキー、一時セッションの取消）
- **停止したサービスのDNS Aレコード**（ダングリングDNS）
- **`known_hosts` に載っていた接続先ホスト**
- **コマンドラインに直書きしたトークン**（`git clone https://user:token@...` は履歴に残る）
- **OAuth トークン**（各サービスの「すべてのセッションからログアウト」）

---

## 8. 記録

実施後、作業ディレクトリの `evidence/audit/containment_record.md` に残す
（このリポジトリ内のファイルではなく、Phase 0 で作成した作業ディレクトリ側）。

```markdown
| 日時(UTC) | Level | 実施内容 | 実施レイヤ | 実施者 | ロールバック手順 | 影響 |
|---|---|---|---|---|---|---|
| 2026-08-01T05:12Z | 2 | outbound全遮断 | ConoHa SG | ユーザー | 元SGへ付け替え | 監視/backup停止 |
```

> [!IMPORTANT]
> **遮断した時刻は、以降のログ解析の基準線になる。**
> 「この時刻以降のログは、封じ込め済みの環境で記録されたもの」という区別が必要。
> 必ず記録する。

---

## 9. 報告の書き方

> [!CAUTION]
> 「封じ込め完了」「攻撃者を排除しました」と断定しない。

```
❌ 攻撃者を遮断しました。安全な状態です。

⭕ Level 2（ホスト隔離）を管理プレーン側で実施しました。
   ・新規の inbound / outbound 通信は遮断されています
   ・確立済みのTCP接続は残っている可能性があります（Level 3 未実施）
   ・ホスト上のファイアウォールは変更していません
   ・クラウドIAM側の失効は未実施です（Level 4）
   ・カーネル・メモリレベルの永続化は未確認です
```

**実施した範囲、未実施の範囲、確認できていない範囲を併記する。**
