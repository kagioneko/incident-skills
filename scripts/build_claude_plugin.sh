#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/plugins/incident-skills/skills"
OUTPUT=${1:-"$ROOT/plugins/incident-skills-claude"}
VERSION=${INCIDENT_SKILLS_VERSION:-0.1.0-beta.2}
case "$OUTPUT" in /*) ;; *) echo "ERROR: output must be absolute" >&2; exit 2 ;; esac
[ -d "$SOURCE" ] || { echo "ERROR: source skills missing" >&2; exit 1; }
if [ -e "$OUTPUT" ]; then
  [ -f "$OUTPUT/.incident-skills-generated" ] || { echo "ERROR: refusing unmanaged output: $OUTPUT" >&2; exit 1; }
  rm -rf -- "${OUTPUT:?}"
fi
mkdir -p "$OUTPUT/.claude-plugin" "$OUTPUT/skills"
for skill in incident-response incident-containment incident-cleanup; do
  cp -R -- "$SOURCE/$skill" "$OUTPUT/skills/$skill"
  rm -rf -- "$OUTPUT/skills/$skill/agents"
  if [ "$skill" != incident-response ]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/incident-frontmatter.XXXXXX")"
    awk 'BEGIN { n=0 } /^---[[:space:]]*$/ { n++; if (n == 2) print "disable-model-invocation: true" } { print }' \
      "$OUTPUT/skills/$skill/SKILL.md" > "$tmp"
    mv -- "$tmp" "$OUTPUT/skills/$skill/SKILL.md"
  fi
done
cat > "$OUTPUT/.claude-plugin/plugin.json" <<EOF
{
  "\$schema": "https://anthropic.com/claude-code/plugin.schema.json",
  "name": "incident-skills",
  "version": "$VERSION",
  "description": "Incident response, containment, and cleanup workflows with explicit safety boundaries.",
  "author": { "name": "kagioneko" },
  "skills": ["./skills/"]
}
EOF
cat > "$OUTPUT/plugin.json" <<EOF
{
  "name": "incident-skills",
  "version": "$VERSION",
  "description": "Incident response, containment, and cleanup workflows with explicit safety boundaries.",
  "skills": ["./skills/"]
}
EOF
: > "$OUTPUT/.incident-skills-generated"