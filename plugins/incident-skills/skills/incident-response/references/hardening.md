# 構造的ガードの設定

SKILL.md は判断方針であって、強制力ではない。
実際の保証は以下の層が担う。**上ほど強い。**

```
Layer 0  OSレベルの読み取り専用マウント     ← 物理境界
Layer 1  サンドボックス
Layer 2  permissions の deny ルール
Layer 3  PreToolUse フック
Layer 4  SKILL.md                          ← お願い
Layer 5  監査ログ
```

---

## Layer 0: 原証拠を書けなくする（最重要）

### Linux / WSL

```bash
# イメージ化して読み取り専用マウント
sudo mount -o ro,loop,noexec,nosuid,nodev evidence.img /mnt/evidence-ro

# 作業コピーだけ書き込み可能に
rsync -a /mnt/evidence-ro/ ~/ir/evidence/working-copy/
```

### Windows

読み取り専用「属性」は権限のあるプロセスから解除できるため、境界にならない。

```powershell
# VHDX 化して読み取り専用でマウント
Mount-VHD -Path D:\evidence\original.vhdx -ReadOnly

# あるいは NTFS ACL で明示的に拒否
$acl = Get-Acl D:\evidence\original
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "$env:USERNAME", "Write,Delete", "ContainerInherit,ObjectInherit", "None", "Deny")
$acl.AddAccessRule($rule)
Set-Acl D:\evidence\original $acl
```

### 最低限（強度は低い）

```bash
chmod -R a-w evidence/original/    # root からは解除できる
```

---

## Layer 2: deny ルール

`.claude/settings.json`（分析セッション用）

```json
{
  "permissions": {
    "deny": [
      "Edit(//absolute/path/to/evidence/original/**)",
      "Write(//absolute/path/to/evidence/original/**)",
      "Bash(rm:*)",
      "Bash(rmdir:*)",
      "Bash(mv:*)",
      "Bash(truncate:*)",
      "Bash(shred:*)",
      "Bash(dd:*)",
      "Bash(chattr:*)"
    ]
  }
}
```

> [!CAUTION]
> **`allowed-tools` は制限ではない。**
> 「そのツールを確認なしで使える」設定であり、それ以外を禁止するものではない。
> ツールを実際に制限するには deny ルールか PreToolUse フックを使う。

> [!CAUTION]
> **Bash の文字列マッチだけでは不十分。**
> 以下は上記の deny を素通りする。
>
> ```
> python -c 'import os; os.remove("x")'
> perl -e 'unlink "x"'
> find . -delete
> : > file          # 中身を空にする
> ```
>
> だからこそ Layer 0（読み取り専用マウント）が必要になる。

---

## Layer 3: PreToolUse フック

終了コード **2** でツール呼び出し自体を止められる。

`.claude/settings.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit",
        "hooks": [
          { "type": "command", "command": "$HOME/ir/hooks/guard_evidence.sh" }
        ]
      }
    ]
  }
}
```

`hooks/guard_evidence.sh` — **これは作業ディレクトリに自分で作成するファイル**
（本リポジトリには同梱していない。以下をコピーして使う）

```bash
#!/usr/bin/env bash
# 標準入力から JSON でツール呼び出し情報を受け取る
# 終了コード 2 でツール実行を遮断する

set -uo pipefail

INPUT="$(cat)"
EVIDENCE_ORIGINAL="${IR_EVIDENCE_ORIGINAL:-$HOME/ir/evidence/original}"
AUDIT_LOG="${IR_AUDIT_LOG:-$HOME/ir/evidence/audit/tool_calls.log}"

mkdir -p "$(dirname "$AUDIT_LOG")"
printf '%s %s\n' "$(date -Is)" "$INPUT" >> "$AUDIT_LOG"

# 原証拠ディレクトリへの言及を含む操作を遮断
if printf '%s' "$INPUT" | grep -qF "$EVIDENCE_ORIGINAL"; then
    echo "BLOCKED: 原証拠ディレクトリへの操作は禁止されています: $EVIDENCE_ORIGINAL" >&2
    echo "分析は working-copy/ で行ってください。" >&2
    exit 2
fi

# 破壊的コマンドを遮断
if printf '%s' "$INPUT" \
    | grep -qE '\b(rm|rmdir|shred|truncate|chattr|mkfs|dd)\b|--delete\b|-delete\b'; then
    echo "BLOCKED: 分析フェーズでの破壊的操作は禁止されています。" >&2
    echo "削除が必要な場合は incident-cleanup スキルを明示的に呼び出してください。" >&2
    exit 2
fi

exit 0
```

```bash
chmod +x ~/ir/hooks/guard_evidence.sh
```

> [!NOTE]
> フックもまた完全ではない。難読化されたコマンドは通り得る。
> フックは Layer 0 の代わりではなく、Layer 0 の**補助**である。

---

## ディレクトリ構成

```
ir/
├── evidence/
│   ├── original/       # 読み取り専用。エージェントの作業範囲外に置くのが理想
│   ├── working-copy/   # 書き込み可。ここだけをエージェントに渡す
│   ├── reports/        # 書き込み可
│   └── audit/          # 追記のみ
├── hooks/
│   └── guard_evidence.sh
└── .claude/
    └── settings.json
```

エージェントに渡す作業ディレクトリは `working-copy/` `reports/` `audit/` のみ。

---

## 検証

設定したら、必ず動作を確認する。

```bash
# 遮断されるべき（エラーになれば成功）
echo '{"tool":"Bash","command":"rm -rf evidence/original"}' | ./hooks/guard_evidence.sh
echo "exit code: $?"   # 2 になるはず

# 通るべき
echo '{"tool":"Read","file":"evidence/working-copy/auth.log"}' | ./hooks/guard_evidence.sh
echo "exit code: $?"   # 0 になるはず
```

**設定しただけで検証しないのは、設定していないのとほぼ同じ。**
