#!/usr/bin/env bash
set -uo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.codex"
pass=0; fail=0
check() { if "$@"; then pass=$((pass+1)); else echo "FAIL: $*"; fail=$((fail+1)); fi; }

CODEX_TARGET="$TMP/codex-skills"
"$ROOT/install.sh" --runtime codex --target "$CODEX_TARGET" > "$TMP/codex-dry.txt"
check test ! -e "$CODEX_TARGET"
"$ROOT/install.sh" --runtime codex --target "$CODEX_TARGET" --apply > "$TMP/codex-apply.txt"
check test -f "$CODEX_TARGET/incident-response/SKILL.md"
check test -f "$CODEX_TARGET/incident-containment/SKILL.md"
check test -f "$CODEX_TARGET/incident-cleanup/SKILL.md"
check grep -q '^  allow_implicit_invocation: false$' "$CODEX_TARGET/incident-containment/agents/openai.yaml"
check grep -q '^  allow_implicit_invocation: false$' "$CODEX_TARGET/incident-cleanup/agents/openai.yaml"
"$ROOT/doctor.sh" --runtime codex --target "$CODEX_TARGET" > "$TMP/codex-doctor.txt"
check grep -q 'Summary: 0 failure' "$TMP/codex-doctor.txt"
if "$ROOT/install.sh" --runtime codex --target "$CODEX_TARGET" --apply > /dev/null 2>&1; then check false; else check true; fi
"$ROOT/uninstall.sh" --target "$CODEX_TARGET" > "$TMP/codex-uninstall-dry.txt"
check test -f "$CODEX_TARGET/incident-response/SKILL.md"
"$ROOT/uninstall.sh" --target "$CODEX_TARGET" --apply > /dev/null
check test ! -e "$CODEX_TARGET/incident-response"

CLAUDE_TARGET="$TMP/claude-skills"
"$ROOT/install.sh" --runtime claude-code --target "$CLAUDE_TARGET" --apply > /dev/null
check grep -q '^disable-model-invocation: true$' "$CLAUDE_TARGET/incident-containment/SKILL.md"
check grep -q '^disable-model-invocation: true$' "$CLAUDE_TARGET/incident-cleanup/SKILL.md"
if grep -q '^disable-model-invocation: true$' "$CLAUDE_TARGET/incident-response/SKILL.md"; then check false; else check true; fi
"$ROOT/doctor.sh" --runtime claude-code --target "$CLAUDE_TARGET" > "$TMP/claude-doctor.txt"
check grep -q 'Summary: 0 failure' "$TMP/claude-doctor.txt"

ANTIGRAVITY_TARGET="$TMP/antigravity-skills"
"$ROOT/install.sh" --runtime antigravity --target "$ANTIGRAVITY_TARGET" --apply > /dev/null
check test -f "$ANTIGRAVITY_TARGET/incident-response/SKILL.md"
check test ! -e "$ANTIGRAVITY_TARGET/incident-cleanup"

printf '%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
