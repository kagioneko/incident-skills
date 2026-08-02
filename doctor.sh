#!/usr/bin/env bash
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RUNTIME=auto; TARGET=""; FAIL=0; WARN=0
ok() { printf 'OK      %s\n' "$*"; }
warn() { printf 'WARNING %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf 'FAIL    %s\n' "$*"; FAIL=$((FAIL + 1)); }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime) [ "$#" -ge 2 ] || die '--runtime requires a value'; RUNTIME=$2; shift 2 ;;
    --target) [ "$#" -ge 2 ] || die '--target requires a value'; TARGET=$2; shift 2 ;;
    -h|--help) echo 'Usage: ./doctor.sh [--runtime auto|claude-code|codex|antigravity] [--target DIR]'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
detect_runtime() {
  found=""
  if [ -n "${CODEX_HOME:-}" ] || [ -d "${HOME}/.codex" ] || command -v codex >/dev/null 2>&1; then found="${found} codex"; fi
  if [ -d "${HOME}/.claude" ] || command -v claude >/dev/null 2>&1; then found="${found} claude-code"; fi
  if [ -d "${HOME}/.antigravity" ] || command -v antigravity >/dev/null 2>&1; then found="${found} antigravity"; fi
  set -- $found; [ "$#" -eq 1 ] || return 1; printf '%s\n' "$1"
}
[ "$RUNTIME" = auto ] && { RUNTIME="$(detect_runtime)" || die 'runtime detection ambiguous; pass --runtime'; }
ADAPTER="$ROOT/adapters/$RUNTIME/adapter.conf"; [ -f "$ADAPTER" ] || die "adapter missing: $ADAPTER"
# shellcheck disable=SC1090
. "$ADAPTER"
[ -n "$TARGET" ] || TARGET=$DEFAULT_SKILLS_DIR
[ -n "$TARGET" ] || die 'no verified default directory; pass --target'
printf 'Runtime: %s (%s)\nTarget:  %s\n\n' "$DISPLAY_NAME" "$RUNTIME" "$TARGET"
for c in bash realpath sha256sum; do command -v "$c" >/dev/null 2>&1 && ok "$c available" || fail "$c missing"; done
command -v jq >/dev/null 2>&1 && ok 'jq available' || warn 'jq missing; plan_tool.sh cannot run'
for skill in incident-response incident-containment incident-cleanup; do
  if [ -f "$TARGET/$skill/SKILL.md" ]; then
    ok "$skill installed"
    [ -f "$TARGET/$skill/.incident-skills-managed" ] && ok "$skill installer-managed" || warn "$skill not installer-managed"
  elif [ "$skill" = incident-response ]; then fail 'incident-response missing'
  else warn "$skill not installed (safe default on unverified runtimes)"; fi
done
[ "$AUTO_INVOCATION_CONTROL" = verified ] && ok 'automatic-invocation control verified by adapter' || warn 'automatic-invocation control UNKNOWN; privileged skills must remain opt-in'
warn 'OS read-only/ACL protection is not proven here; verify evidence/original separately'
for tool in incident-containment/scripts/plan_tool.sh incident-cleanup/scripts/verify_delete_confirm.sh; do
  [ ! -f "$TARGET/$tool" ] || { [ -x "$TARGET/$tool" ] && ok "$tool executable" || fail "$tool not executable"; }
done
printf '\nSummary: %d failure(s), %d warning(s)\n' "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ]
