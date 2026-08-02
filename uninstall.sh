#!/usr/bin/env bash
set -uo pipefail
TARGET=""; MODE=dry-run
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || { echo 'ERROR: --target requires a value' >&2; exit 2; }; TARGET=$2; shift 2 ;;
    --dry-run) MODE=dry-run; shift ;;
    --apply) MODE=apply; shift ;;
    -h|--help) echo 'Usage: ./uninstall.sh --target DIR [--dry-run|--apply]'; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TARGET" ] || { echo 'ERROR: --target is required' >&2; exit 2; }
case "$TARGET" in /*) ;; *) echo 'ERROR: target must be absolute' >&2; exit 2 ;; esac
MANIFEST="$TARGET/.incident-skills-install.tsv"
[ -f "$MANIFEST" ] || { echo "ERROR: managed manifest missing: $MANIFEST" >&2; exit 1; }
skills="$(awk -F '\t' '$1 == "skill" { print $2 }' "$MANIFEST")"
[ -n "$skills" ] || { echo 'ERROR: manifest has no skills' >&2; exit 1; }
for skill in $skills; do
  case "$skill" in incident-response|incident-containment|incident-cleanup) ;; *) echo "ERROR: invalid manifest entry: $skill" >&2; exit 1 ;; esac
  dst="$TARGET/$skill"; [ -f "$dst/.incident-skills-managed" ] || { echo "ERROR: managed marker missing: $dst" >&2; exit 1; }
  printf 'PLAN remove %s\n' "$dst"
done
[ "$MODE" = apply ] || { echo 'DRY-RUN complete; no files changed.'; exit 0; }
for skill in $skills; do rm -rf -- "${TARGET:?}/$skill"; done
rm -f -- "$MANIFEST"; echo 'Uninstalled manifest-managed incident skills.'
