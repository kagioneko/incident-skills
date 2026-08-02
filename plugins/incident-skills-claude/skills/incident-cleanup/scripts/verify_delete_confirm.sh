#!/usr/bin/env bash
#
# verify_delete_confirm.sh - DELETE-CONFIRM の機械検証
#
# 使い方:
#   verify_delete_confirm.sh --working-copy <DIR> [--proposed <FILE>] < confirm.txt
#
#   標準入力から DELETE-CONFIRM ブロックを受け取り、全パスを検証する。
#   すべて通れば、検証済みパスを1行ずつ標準出力へ書き、exit 0。
#   1件でも失敗したら、何も出力せず exit 1（部分実行を防ぐため）。
#
# 検証項目:
#   1. 1行目が DELETE-CONFIRM のみ
#   2. 絶対パス（相対パス・グロブ・チルダを拒否）
#   3. 通常ファイル（ディレクトリ・デバイス等を拒否）
#   4. シンボリックリンクでない
#   5. realpath 解決後も working-copy 配下
#   6. working-copy と同一ファイルシステム（bind mount 対策）
#   7. 保護対象に該当しない
#   8. --proposed 指定時、提示済み一覧に含まれる
#
# なぜ必要か:
#   これらの規則は SKILL.md に文章で書かれていたが、
#   検証はモデルの読解に委ねられていた。
#   規則を読み違えれば、説明がどれだけ丁寧でも突破される。
#   機械が検証しない規則は、規則ではなく期待である。
#

set -uo pipefail

WORKING=""
PROPOSED=""
QUIET=0

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --working-copy) WORKING="${2:-}"; shift 2 ;;
        --proposed)     PROPOSED="${2:-}"; shift 2 ;;
        --quiet)        QUIET=1; shift ;;
        -h|--help)      usage ;;
        *) echo "REJECT: 不明なオプション: $1" >&2; exit 2 ;;
    esac
done

[ -n "$WORKING" ] || { echo "REJECT: --working-copy は必須です" >&2; exit 2; }
[ -d "$WORKING" ] || { echo "REJECT: working-copy が存在しません: $WORKING" >&2; exit 2; }

WORKING_RP="$(realpath -e "$WORKING" 2>/dev/null)" || {
    echo "REJECT: working-copy を解決できません: $WORKING" >&2; exit 2; }
WORKING_DEV="$(stat -c %d "$WORKING_RP" 2>/dev/null)" || {
    echo "REJECT: working-copy のデバイス番号を取得できません" >&2; exit 2; }

# 保護対象（単独では削除させない）
PROTECTED_NAMES='^(\.bash_history|\.zsh_history|\.mysql_history|\.psql_history|known_hosts|authorized_keys|auth\.log|MANIFEST\.sha256|COLLECTION_GAPS\.txt|COLLECTION_METADATA\.txt|timeline_mac\.txt|all_authorized_keys\.txt)$'
PROTECTED_PATHS='(/ai_sessions/|/\.claude/|/\.codex/|/\.gemini/|/\.antigravity/)'

err() { [ "$QUIET" -eq 1 ] || echo "REJECT: $*" >&2; }

# ---- 入力の読み取り ----
LINES=()
while IFS= read -r line || [ -n "$line" ]; do
    # 前後の空白と CR を除去
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    LINES+=("$line")
done

[ "${#LINES[@]}" -ge 2 ] || { err "入力が空、または対象がありません"; exit 1; }

# 1. ヘッダ
if [ "${LINES[0]}" != "DELETE-CONFIRM" ]; then
    err "1行目が 'DELETE-CONFIRM' ではありません: '${LINES[0]}'"
    exit 1
fi

TARGETS=()
for ((i=1; i<${#LINES[@]}; i++)); do
    [ -n "${LINES[$i]}" ] || continue
    TARGETS+=("${LINES[$i]}")
done
[ "${#TARGETS[@]}" -ge 1 ] || { err "削除対象が1件もありません"; exit 1; }

FAIL=0
VERIFIED=()

for p in "${TARGETS[@]}"; do
    # 2. 絶対パス / グロブ / チルダ
    case "$p" in
        /*) ;;
        *) err "絶対パスではない: $p"; FAIL=1; continue ;;
    esac
    case "$p" in
        *'*'*|*'?'*|*'['*|*'~'*|*'$'*|*'`'*)
            err "グロブ・チルダ・展開文字を含む: $p"; FAIL=1; continue ;;
    esac

    # 存在確認
    if [ ! -e "$p" ]; then
        err "存在しない: $p"; FAIL=1; continue
    fi

    # 4. シンボリックリンクでない（realpath より先に見る）
    if [ -L "$p" ]; then
        err "シンボリックリンクは対象にできない: $p"; FAIL=1; continue
    fi

    # 3. 通常ファイル
    if [ ! -f "$p" ]; then
        err "通常ファイルではない（ディレクトリは別手順）: $p"; FAIL=1; continue
    fi

    # 5. realpath 解決後も working-copy 配下
    rp="$(realpath -e "$p" 2>/dev/null)" || { err "解決できない: $p"; FAIL=1; continue; }
    case "$rp" in
        "$WORKING_RP"/*) ;;
        *) err "working-copy の外を指している: $p -> $rp"; FAIL=1; continue ;;
    esac

    # 6. 同一ファイルシステム（bind mount 対策）
    dev="$(stat -c %d "$rp" 2>/dev/null)" || { err "デバイス番号を取得できない: $p"; FAIL=1; continue; }
    if [ "$dev" != "$WORKING_DEV" ]; then
        err "別マウントの実体を指している: $p (dev=$dev, working-copy dev=$WORKING_DEV)"
        FAIL=1; continue
    fi

    # 7. 保護対象
    base="$(basename "$rp")"
    if printf '%s' "$base" | grep -Eq "$PROTECTED_NAMES"; then
        err "保護対象（フォレンジック証拠）: $p"; FAIL=1; continue
    fi
    if printf '%s' "$rp" | grep -Eq "$PROTECTED_PATHS"; then
        err "保護対象（AIセッションログ配下）: $p"; FAIL=1; continue
    fi

    # 8. 提示済み一覧との照合
    if [ -n "$PROPOSED" ]; then
        if ! grep -Fxq "$p" "$PROPOSED" 2>/dev/null; then
            err "提示した一覧に含まれていない: $p"; FAIL=1; continue
        fi
    fi

    VERIFIED+=("$rp")
done

if [ "$FAIL" -ne 0 ]; then
    [ "$QUIET" -eq 1 ] || {
        echo "" >&2
        echo "★ 検証に失敗しました。バッチ全体を中止します。" >&2
        echo "  部分実行はしません。対象を修正して再度承認してください。" >&2
    }
    exit 1
fi

printf '%s\n' "${VERIFIED[@]}"
exit 0
