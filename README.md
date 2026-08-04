# incident-response skills

> **公開状態**: v0.1.0-beta.2 — 技術者向け公開β。本番適用前に使い捨て環境で検証すること。
>
> **Codex CLI 0.146.0で検証済み**: GitHub marketplace登録 → プラグイン導入 →
> 3スキル展開 → 危険スキルの暗黙起動禁止ポリシー確認 → アンインストールまで実測。
> GitHub Actionsでも構文、ShellCheck、Plan改ざん、削除承認、証拠収集、秘密情報非収集を検証する。
> **Claude Code 2.1.176 / Antigravity CLI 1.1.5でも検証済み**: 隔離プロファイルで
> 3スキルの導入・一覧・削除を実測。危険スキルは自動起動禁止メタデータ付き。

AIエージェント（Claude Code / Antigravity 等）向けの、サーバー侵害対応スキル一式。

実際のVPS侵害インシデントと、**その調査中にAIエージェントが証拠ファイルを削除した事故**
から設計されている。

| | |
|---|---|
| **設計の根拠** | [`ORIGINS.md`](ORIGINS.md) — 各ルールがどの事故から生まれたか |
| **開発中の失敗** | [`FAILURES.md`](FAILURES.md) — 8件の自損記録 |
| **どこまで強制されるか** | [`RUNTIME_SUPPORT.md`](RUNTIME_SUPPORT.md) — ランタイム別の強制力 |
| **経緯を書いた記事** | [証拠を消したのも、復元したのも、同じAIだった](https://note.com/emilia_lab/n/ndd0e89002870) |

---

## なぜ3つに分かれているのか

インシデント対応の操作は、**緊急性**と**不可逆性**が一致しない。
だから権限も一律にできない。

| 操作 | 緊急性 | 不可逆性 | 自動発火 | 承認の単位 |
|---|---|---|---|---|
| 調査・判断 | 高 | 低 | **あり** | スコープ |
| 封じ込め実行 | 高 | 中 | なし | Plan ID |
| 証拠削除 | 低 | **高** | なし | 絶対パス + 確認トークン |

> **判断は急げ。実行は慎重に。削除はもっと慎重に。**

```
incident-response      証拠を取って調べる       （自動発火あり／環境を変更しない）
incident-containment   攻撃者の動きを止める     （手動起動のみ／dry-run既定）
incident-cleanup       分析後に不要物を消す     （手動起動のみ／原証拠は対象外）
```

`incident-response` は封じ込め案・影響・ロールバック手順まで**生成する**が、**実行しない。**
実行は `incident-containment` に引き渡す。

---

## 構成

```
plugins/incident-skills/skills/incident-response/
├── SKILL.md                          保全・分析。原証拠を変更しない
├── scripts/
│   ├── collect_evidence.sh           証拠収集（quick/full・揮発性順・ギャップ記録）
│   └── rehearse_containment.sh       平時演習（環境チェック・デッドマン付き実適用）
└── references/
    ├── rehearsal.md                  平時演習の手順（本番を初回実行にしない）
    ├── containment_matrix.md         Phase 0 封じ込め判断・事業者別コンソール案内
    ├── persistence_hunting.md        永続化・バックドア探索（Tier 1〜3）
    └── hardening.md                  Layer 0〜5 の構造的ガード設定
└── templates/
    ├── forensic_report.md            確度4段階・3範囲併記の報告書
    └── credential_rotation.md        失効/再発行/再配備の3段階チェック

plugins/incident-skills/skills/incident-containment/
├── SKILL.md                          隔離・遮断・失効。Plan ID 承認必須
├── scripts/
│   └── plan_tool.sh                  Plan ID の生成・封印・検証、ルール生成
└── templates/
    └── plan.example.json             ルール粒度の記載例

plugins/incident-skills/skills/incident-cleanup/
├── SKILL.md                          削除。DELETE-CONFIRM 必須
├── scripts/
│   └── verify_delete_confirm.sh      承認テキストの機械検証
└── templates/
    └── deletion_audit.md

tests/                                自己テスト（CI から実行）
.github/workflows/ci.yml              構文・参照・危険パターン・自己テスト

ORIGINS.md                         設計原則と、その元になった事故の対応表
RUNTIME_SUPPORT.md                 ランタイム別に「何が本当に強制されるか」の表
FAILURES.md                        開発中に踏んだ失敗の記録（設計判断の背景）
TODO.md                            未着手項目
```

---

## 設計の核

### 1. 指示ではなく構造で守る

SKILL.md に「消すな」と書くのは**お願い**であって保証ではない。

```
Layer 0  OSレベルの読み取り専用マウント     ← 物理境界
Layer 1  サンドボックス
Layer 2  permissions の deny ルール
Layer 3  PreToolUse フック（終了コード2で遮断）
Layer 4  SKILL.md の判断規則               ← お願い
Layer 5  監査ログ
```

そして **Layer 0 と Layer 4 の間に、検証ツールを1枚挟んである。**

| ツール | 何を機械検証するか |
|---|---|
| `verify_delete_confirm.sh` | 絶対パス / 通常ファイル / symlink / realpath / デバイス番号 / 保護対象 / 提示済み一覧 |
| `plan_tool.sh verify` | Plan ID / 有効期限 / status / 実行スクリプトのハッシュ / 維持経路の有無 |

**規則を文章で書くだけでは、モデルの読解に委ねることになる。**
機械が検証しない規則は、規則ではなく期待である。

> [!CAUTION]
> **`allowed-tools` は制限ではない。**
> 「そのツールを確認なしで使える」設定であり、それ以外を禁止するものではない。
> 実際の制限は deny ルールか PreToolUse フックで行う。設定例は `hardening.md`。

### 2. 証拠ディレクトリを分ける

```
evidence/
├── original/       読み取り専用。エージェントの作業範囲外に置くのが理想
├── working-copy/   分析用。書き込み可
├── reports/        報告書
└── audit/          操作履歴（追記のみ）
```

エージェントに渡すのは `working-copy/` `reports/` `audit/` のみ。

### 3. 「安全です」と断定しない

全スキル共通で、報告に3項目を併記する。

| スキル | 併記する3項目 |
|---|---|
| incident-response | 確認した証拠 / 存在しない証拠 / 確認不能な証拠 |
| incident-containment | 実施した封じ込め / 残存する経路 / 未失効の権限 |
| incident-cleanup | 削除した対象 / 残した対象 / 原証拠の保全場所 |

```
❌ バックドアはありませんでした
⭕ 今回確認した永続化ポイントの範囲では、追加のバックドアを示す所見は
   確認できませんでした。カーネル・メモリ・クラウド管理プレーンは
   別途確認が必要です。
```

---

## 使い方

### 平時

1. Codexではプラグインmarketplaceから導入する（推奨）

```bash
codex plugin marketplace add kagioneko/incident-skills --ref v0.1.0-beta.2
codex plugin add incident-skills@incident-skills
```

Codexでは `agents/openai.yaml` により、`incident-containment` と
`incident-cleanup` の暗黙起動を禁止する。明示的な `$incident-containment` / `$incident-cleanup`
呼び出しは可能。

2. Claude Codeでは公式marketplace経由で導入する

```bash
claude plugin marketplace add https://github.com/kagioneko/incident-skills.git#v0.1.0-beta.2
claude plugin install incident-skills@incident-skills
```

Antigravityではリポジトリを取得し、専用パッケージを導入する。

```bash
git clone --branch v0.1.0-beta.2 https://github.com/kagioneko/incident-skills.git
agy plugin install /absolute/path/incident-skills/plugins/incident-skills-claude
```

Claude Code / Antigravityとも、導入後に3スキルが表示されることを確認する。
Antigravity 1.1.5では自動起動禁止メタデータの強制動作までは未確認なので、
原証拠は読み取り専用かエージェントから見えない場所に置く。

3. `doctor.sh` のFAILを解消し、WARNINGと未検証範囲を確認する
4. `hardening.md` の設定を入れる（**これが本体。SKILL.md だけでは守れない**）
5. 収集キットの正本を手元に置く
6. **使い捨て環境で演習する**（`scripts/rehearse_containment.sh`）
   ※ 本番が初回実行になってはいけない。実際、このスキルの iptables コードは
     査読3周・構文チェック済みで、初回実行時に実行者を締め出した
7. SSH 認証ログに公開鍵フィンガープリントが記録されることを実機で確認する
   ※ OpenSSH 6.3 以降は通常 `LogLevel INFO` でも成功した公開鍵認証の FP を記録する。
      重要なのはログレベルの決め打ちではなく、ログの永続化と実際の出力確認
8. `/var/log/journal` が存在するか確認する
   ※ 無ければ journald は揮発設定。再起動でログが消える

### 有事

```
Phase 0  封じ込め判断        containment_matrix.md
   ↓     ※ 事業者のコントロールパネルを先に開く
Phase 1  証拠収集            collect_evidence.sh
   ↓     ※ 揮発性データ（ss/ps/who）は封じ込めの前に取る
Phase 2  分析                読むだけ。実行しない。削除しない
   ↓
Phase 3  報告・失効          クリーン端末から
   ↓
Phase 4  再構築・移行        侵害環境を直して再利用しない
   ↓
Phase 5  クリーンアップ      incident-cleanup を明示的に呼び出す
```

```bash
# 収集（手元の正本を送り込む方式を推奨）
scp collect_evidence.sh root@target:/var/tmp/
ssh root@target 'bash /var/tmp/collect_evidence.sh quick'
# 秘密鍵・shadow・認証トークンの「本文」は収集されない（指紋のみ inventory/ に記録）

# 回収して照合
scp root@target:/var/tmp/ir-evidence.*.tar.gz* ./evidence/original/
cd evidence/original && sha256sum -c ir-evidence.*.tar.gz.sha256
```

---

## このスキルが保証しないもの

以下は**対象外**。できないことを先に明示する。

| 領域 | なぜ保証できないか |
|---|---|
| **カーネルルートキット** | 収集は侵害ホスト自身の `ps` `ss` `find` `lsmod` を使う。これらが差し替えられていれば、結果は攻撃者の見せたいものになる |
| **ファームウェア / ブートキット改ざん** | OS より下の層。OS 上からは検出できない |
| **クラウド管理プレーンの侵害** | IAM・startup-script・スナップショット共有はホスト内から見えない。`persistence_hunting.md` Tier 3 を**人間が手で**確認する必要がある |
| **完全ディスクフォレンジック** | 本スキルはライブ・トリアージ。削除ファイルの復元、スラック領域、未割当領域は扱わない |
| **メモリフォレンジック** | メモリイメージの取得・解析は範囲外。ファイルレスマルウェアは検出できない |
| **法執行・訴訟レベルの証拠保全** | chain of custody の法的要件、第三者立会い、書き込み禁止装置などを満たさない |
| **秘密情報の本文回収** | 秘密鍵・shadow・認証トークンは指紋のみ記録する（侵害ホスト上に平文の詰め合わせを作らないため） |
| **「侵害されていないこと」の証明** | 本スキルが出せるのは「確認した範囲で所見がなかった」まで。不在証明はできない |

### 保証できないものに手が届く方法

| やりたいこと | 方法 |
|---|---|
| ルートキットの影響を受けない収集 | **ホストを停止**し、ディスクイメージを外部から取得して解析する |
| クラウド側の確実な取得 | 管理プレーンからのスナップショット |
| メモリ証拠 | ホストを停止せずネットワーク隔離し、外部からメモリ取得 |
| 法執行レベルの保全 | 専門のフォレンジック業者・機関へ |

> [!IMPORTANT]
> **「バックドアはありませんでした」と報告しない。**
> 本スキルの報告は必ず次の3項目を併記する。
>
> - 確認した範囲
> - 未確認の範囲
> - 検出の限界
>
> 断定できるのは「確認した範囲では」までである。

---

## 限界（技術的な注意点）

> [!WARNING]
> - 本スキルの収集機能は**ライブ・トリアージ**が目的。法執行・訴訟向けの
>   完全なデジタルフォレンジック（完全ディスクイメージ取得等）を保証するものではない
> - 収集スクリプトは**侵害ホスト自身のコマンド**（bash, ps, ss, find）を使う。
>   ルートキットが導入されている場合、**結果自体が偽装されている可能性がある**
> - 確実な保全は、ホストを停止してディスクイメージを外部から取得すること。
>   クラウドなら管理プレーンからのスナップショットを優先する
> - クラウド管理プレーン（IAM、startup-script、スナップショット共有）は
>   ホスト内から検出できない。`persistence_hunting.md` の Tier 3 を手で確認すること
> - **秘密鍵・`/etc/shadow`・認証トークンの本文は収集しない**（指紋のみ）。
>   侵害ホスト上に平文の認証情報詰め合わせを作らないための設計。
>   本文が必要ならホスト停止後のディスクイメージ取得、管理プレーンのスナップショット、
>   またはクリーン端末への直接ストリームを使うこと
> - ただし**シェル履歴・DB履歴・AIセッションログには秘密情報が含まれ得る**。
>   これらは実行者の特定に必要なため収集している。回収データは認証情報を含む前提で扱うこと
> - **アクセス時刻(atime)は収集処理自身により汚染され得る**。`A=` を証拠に使う際は注意

NIST SP 800-61 Rev.3 および RFC 3227 を**参照した**設計だが、
これらへの適合を認定するものではない。

---

## 既知の未着手

`TODO.md` を参照。主なもの:

- chain_of_custody テンプレート（法執行レベルの保全は本スキルの対象外のため優先度低）
- `find / -xdev` が別マウント（`/home` `/var` が別FS）を見落とす件
- atime 汚染: タイムラインを収集の先頭で採取する（現在はメタデータに注記のみ）

スキル本体・収集スクリプト・テンプレートは実装完了。
収集スクリプトと演習スクリプトは実機テスト済み。
封じ込めコードは実機で2回適用・2回ロールバック検証済み。

---

## 設計原則の出どころ

このスキルのルールは、**すべて実際に起きた事故から抽出されている。**

| スキルのルール | 元になった事故 |
|---|---|
| 「Continue」は承認ではない | 「Continue」の一言で AIエージェントが8ファイルを削除した |
| 証拠保全は衛生管理より先 | 平文パスワードを含む `.bash_history` を分析前に削除した |
| 削除は別スキル・自動起動禁止 | 分析スキルがそのまま削除権限へ到達できる構造だった |
| `authorized_keys` はホーム外も探索 | バックドアが `/usr/.system/.ssh/` に置かれていた |
| AIセッションはエージェント別に分ける | 証拠を取るつもりで、証拠を上書きしていた |
| 秘密情報の本文は収集しない | 「詰め合わせを作るな」と書きながら詰め合わせを作っていた |
| IN / OUT でチェーンを分ける | 送信の例外が、受信の開放に化けていた |
| デッドマンスイッチを先に仕掛ける | 締め出されたとき、これが唯一の復旧手段だった |
| 平時に使い捨て環境で演習する | 査読3周したコードが、初回実行で実行者を締め出した |

**全32項目の対応表は [`ORIGINS.md`](ORIGINS.md) にある。**

ルールを削る前に、対応する事故を読んでほしい。
**要らないように見えるルールほど、実際に踏んだ結果として残っている。**

---

## 開発中の失敗

このスキル自体が、開発中に8件の失敗を踏んでいる。
そのうち7件は「対象としている失敗と同じ形」だった。

`FAILURES.md` に全部残してある。設計判断の背景として読める。

---

## 由来

2026年4月、`python3 -m http.server` をホームディレクトリで起動したまま放置し、
SSH秘密鍵とAI CLIツールの認証情報を含む24ファイルが持ち出された。
`usermod -u 0 -o -g 0 system` により UID 0 のアカウントが作られ、
`/usr/.system/.ssh/authorized_keys` に未知の公開鍵が追記された。
（外部侵入者による操作が最も整合的だが、`auth.log` の原本は残っていない）

4ヶ月後、その調査中に、AIエージェントが `.bash_history` `.mysql_history`
`.ssh/known_hosts` を含む8ファイルを削除した。
現存する記録上、対象を特定した明示的な削除指示は確認できない。
削除という判断自体は、局所的には合理的だった（平文パスワードが含まれていた）。
間違っていたのは順番だった。

このスキルは、その順番を構造として固定するために書かれている。

- **`.ssh/` だけを収集する設計では、`/usr/.system/.ssh/` のバックドアは見つからない**
  → `find / -xdev -name 'authorized_keys*'` を必須にした
- **「Continue」は削除の承認ではない**
  → 削除を別スキルに分離し、`disable-model-invocation: true` を付けた
- **消す前に取っておくものを聞かないと、証拠は消える**
  → 収集フェーズを分析フェーズより前に固定した

---

## ライセンス

MIT
