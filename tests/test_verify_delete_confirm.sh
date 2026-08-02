#!/usr/bin/env bash
# verify_delete_confirm.sh の自己テスト
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
V="$PWD/plugins/incident-skills/skills/incident-cleanup/scripts/verify_delete_confirm.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
W="$TMP/evidence/working-copy"
mkdir -p "$TMP/evidence/original" "$W/proj/subdir" "$W/ai_sessions"
echo secret > "$W/proj/.env"
echo hist   > "$W/proj/.bash_history"
echo x      > "$W/proj/normal.txt"
echo orig   > "$TMP/evidence/original/auth.log"
echo sess   > "$W/ai_sessions/claude.jsonl"
ln -s ../../original/auth.log "$W/proj/link"

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
run(){ printf '%s\n' "$@" | bash "$V" --working-copy "$W" >/dev/null 2>&1; }
allow(){ local l="$1"; shift; if run "$@"; then ok "$l"; else ng "$l (should allow)"; fi; }
deny(){  local l="$1"; shift; if run "$@"; then ng "$l (should deny)"; else ok "$l"; fi; }

allow "normal file"          "DELETE-CONFIRM" "$W/proj/.env"
allow "multiple files"       "DELETE-CONFIRM" "$W/proj/.env" "$W/proj/normal.txt"
deny  "no header"            "$W/proj/.env"
deny  "bad header"           "DELETE CONFIRM" "$W/proj/.env"
deny  "relative path"        "DELETE-CONFIRM" "proj/.env"
deny  "glob"                 "DELETE-CONFIRM" "$W/proj/*"
deny  "tilde"                "DELETE-CONFIRM" "$(printf '~')/proj/.env"
deny  "directory"            "DELETE-CONFIRM" "$W/proj/subdir"
deny  "symlink"              "DELETE-CONFIRM" "$W/proj/link"
deny  "outside working-copy" "DELETE-CONFIRM" "$TMP/evidence/original/auth.log"
deny  "protected history"    "DELETE-CONFIRM" "$W/proj/.bash_history"
deny  "protected ai session" "DELETE-CONFIRM" "$W/ai_sessions/claude.jsonl"
deny  "nonexistent"          "DELETE-CONFIRM" "$W/proj/nope"
deny  "one bad aborts batch" "DELETE-CONFIRM" "$W/proj/.env" "$W/proj/.bash_history"

echo "  --- delete-confirm: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
