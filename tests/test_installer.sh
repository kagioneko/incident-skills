#!/usr/bin/env bash
set -uo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.codex"; TARGET="$TMP/skills"
pass=0; fail=0
check() { if "$@"; then pass=$((pass+1)); else echo "FAIL: $*"; fail=$((fail+1)); fi; }
"$ROOT/install.sh" --runtime codex --target "$TARGET" > "$TMP/dry.txt"; check test ! -e "$TARGET"
"$ROOT/install.sh" --runtime codex --target "$TARGET" --apply > "$TMP/apply.txt"
check test -f "$TARGET/incident-response/SKILL.md"; check test ! -e "$TARGET/incident-cleanup"; check test -f "$TARGET/.incident-skills-install.tsv"
"$ROOT/doctor.sh" --runtime codex --target "$TARGET" > "$TMP/doctor.txt"; check grep -q 'Summary: 0 failure' "$TMP/doctor.txt"
"$ROOT/uninstall.sh" --target "$TARGET" > "$TMP/uninstall-dry.txt"; check test -f "$TARGET/incident-response/SKILL.md"
"$ROOT/uninstall.sh" --target "$TARGET" --apply > "$TMP/uninstall.txt"; check test ! -e "$TARGET/incident-response"
printf '%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
