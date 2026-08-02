#!/usr/bin/env bash
set -uo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RUNTIME=auto
TARGET=""
MODE=dry-run
INCLUDE_PRIVILEGED=auto
FORCE=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [--runtime auto|claude-code|codex|antigravity]
                    [--target DIR] [--dry-run|--apply]
                    [--include-privileged] [--force]

Default behavior is dry-run. On runtimes where automatic-invocation controls
are unverified, only incident-response is installed unless
--include-privileged is explicitly supplied.
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime) [ "$#" -ge 2 ] || die '--runtime requires a value'; RUNTIME=$2; shift 2 ;;
    --target) [ "$#" -ge 2 ] || die '--target requires a value'; TARGET=$2; shift 2 ;;
    --dry-run) MODE=dry-run; shift ;;
    --apply) MODE=apply; shift ;;
    --include-privileged) INCLUDE_PRIVILEGED=yes; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

detect_runtime() {
  found=""
  if [ -n "${CODEX_HOME:-}" ] || [ -d "${HOME}/.codex" ] || command -v codex >/dev/null 2>&1; then found="${found} codex"; fi
  if [ -d "${HOME}/.claude" ] || command -v claude >/dev/null 2>&1; then found="${found} claude-code"; fi
  if [ -d "${HOME}/.antigravity" ] || command -v antigravity >/dev/null 2>&1; then found="${found} antigravity"; fi
  set -- $found
  [ "$#" -eq 1 ] || {
    [ "$#" -eq 0 ] && die 'runtime could not be detected; pass --runtime and, if needed, --target'
    die "multiple runtimes detected:${found}; pass --runtime"
  }
  printf '%s\n' "$1"
}

[ "$RUNTIME" = auto ] && RUNTIME="$(detect_runtime)"
case "$RUNTIME" in claude-code|codex|antigravity) ;; *) die "unsupported runtime: $RUNTIME" ;; esac
ADAPTER="$ROOT/adapters/$RUNTIME/adapter.conf"
[ -f "$ADAPTER" ] || die "adapter not found: $ADAPTER"
# shellcheck disable=SC1090
. "$ADAPTER"
[ -n "$TARGET" ] || TARGET=$DEFAULT_SKILLS_DIR
[ -n "$TARGET" ] || die "$DISPLAY_NAME has no verified default skills directory; pass --target"
case "$TARGET" in /*) ;; *) die "target must be an absolute path: $TARGET" ;; esac
[ "$INCLUDE_PRIVILEGED" = auto ] && INCLUDE_PRIVILEGED=$DEFAULT_INSTALL_PRIVILEGED

skills="incident-response"
[ "$INCLUDE_PRIVILEGED" = yes ] && skills="$skills incident-containment incident-cleanup"
note "Runtime: $DISPLAY_NAME ($RUNTIME)"
note "Target:  $TARGET"
note "Mode:    $MODE"
note "Skills:  $skills"
note "Automatic-invocation control: $AUTO_INVOCATION_CONTROL"
[ "$INCLUDE_PRIVILEGED" = yes ] || note 'Safety: privileged skills are not installed.'

for skill in $skills; do
  src="$ROOT/$skill"; dst="$TARGET/$skill"
  [ -f "$src/SKILL.md" ] || die "source skill missing: $src"
  if [ -e "$dst" ] && [ "$FORCE" -ne 1 ]; then die "destination exists: $dst"; fi
  if [ -e "$dst" ] && [ ! -f "$dst/.incident-skills-managed" ]; then die "refusing unmanaged destination: $dst"; fi
  note "PLAN copy $src -> $dst"
done

[ "$MODE" = apply ] || { note 'DRY-RUN complete; no files changed.'; exit 0; }
mkdir -p "$TARGET"
MANIFEST="$TARGET/.incident-skills-install.tsv"
tmp_manifest="$(mktemp "${TMPDIR:-/tmp}/incident-skills-manifest.XXXXXX")" || die 'mktemp failed'
trap 'rm -f "$tmp_manifest"' EXIT
printf 'schema_version\t1\nruntime\t%s\ninstalled_at_utc\t%s\n' "$RUNTIME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp_manifest"
for skill in $skills; do
  src="$ROOT/$skill"; dst="$TARGET/$skill"
  if [ -e "$dst" ]; then rm -rf -- "$dst"; fi
  cp -R -- "$src" "$dst"
  : > "$dst/.incident-skills-managed"
  printf 'skill\t%s\n' "$skill" >> "$tmp_manifest"
done
mv -- "$tmp_manifest" "$MANIFEST"
trap - EXIT
note "Installed. Run: $ROOT/doctor.sh --runtime $RUNTIME --target $TARGET"
