#!/usr/bin/env bash
# Applies Claude's triage: adds the labels that are on the allowlist and posts the comment, if any.
#
#   post-triage.sh <owner/repo> <issue-number> <result-json>
#
# The allowlist is enforced here, not trusted to the model: `approved` for example would open a
# used-by pull request. DRY_RUN=1 prints what would happen.
set -euo pipefail

repo="$1"
issue="$2"
result_json="$3"

allowed='["bug","enhancement","question","documentation","needs-info","host-app","area: audio","area: video","area: hdr-dv","area: subtitles","area: live","area: io","area: api"]'
footer="<sub>Automated triage by Quint (Claude). A maintainer reads every issue and will follow up.</sub>"

labels=$(jq -c --argjson allowed "$allowed" '[.structured_output.labels[]? | select(. as $l | $allowed | index($l))] | unique' "$result_json")
comment=$(jq -r '.structured_output.comment // ""' "$result_json")

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "labels: $labels"
  echo "comment:"
  echo "$comment"
  exit 0
fi

if [[ "$(jq length <<< "$labels")" -gt 0 ]]; then
  args=()
  while IFS= read -r label; do args+=(--add-label "$label"); done < <(jq -r '.[]' <<< "$labels")
  gh issue edit "$issue" --repo "$repo" "${args[@]}" > /dev/null
  echo "Labels: $(jq -r 'join(", ")' <<< "$labels")"
fi

if [[ -n "${comment//[[:space:]]/}" ]]; then
  printf '%s\n\n%s\n' "${comment:0:4000}" "$footer" | gh issue comment "$issue" --repo "$repo" --body-file - > /dev/null
  echo "Posted a comment."
else
  echo "No comment."
fi
