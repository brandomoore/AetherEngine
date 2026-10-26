#!/usr/bin/env bash
# Runs Claude Code headless for the review and triage workflows and writes its JSON result.
#
#   run-claude.sh <prompt-file> <schema-file> <result-json> <max-turns> <data-dir>
#
# Claude gets exactly three tools, Read, Glob and Grep: no shell, no network, no GitHub token.
# Everything it needs was fetched into plain files beforehand, and what it produces is structured
# JSON that a separate step posts. Untrusted text (a PR, an issue) can therefore only shape the
# words of that one comment. Headless Claude Code reads nothing outside its working directory (the
# base checkout) and the data directory added here, which already keeps /proc and the home directory
# out of reach; the OAuth token is in this process's environment, so the reads that could reach it
# or any other credential are also denied by name (Grep and Glob honour Read denials too).
# Needs CLAUDE_CODE_OAUTH_TOKEN; CLAUDE_MODEL overrides the model.
set -euo pipefail

prompt_file="$1"
schema_file="$2"
result_json="$3"
max_turns="$4"
data_dir="$5"

home="${HOME:?}"
temp="${RUNNER_TEMP:-/nonexistent-runner-temp}"

settings=$(jq -n --arg home "$home" --arg temp "$temp" '{
  permissions: {
    deny: [
      "Read(//proc/**)",
      "Read(//sys/**)",
      "Read(//dev/**)",
      "Read(//etc/**)",
      "Read(//root/**)",
      "Read(/\($temp)/**)",
      "Read(/\($home)/work/_actions/**)",
      "Read(/\($home)/.claude.json)",
      "Read(/\($home)/.claude/.credentials.json)",
      "Read(/\($home)/.config/**)",
      "Read(/\($home)/.ssh/**)",
      "Read(/\($home)/.docker/**)",
      "Read(/\($home)/.npmrc)",
      "Read(/\($home)/.gitconfig)"
    ]
  }
}')

claude -p \
  --model "${CLAUDE_MODEL:-claude-opus-5-5}" \
  --max-turns "$max_turns" \
  --output-format json \
  --tools "Read,Glob,Grep" \
  --strict-mcp-config \
  --setting-sources "" \
  --add-dir "$data_dir" \
  --settings "$settings" \
  --json-schema "$(cat "$schema_file")" \
  < "$prompt_file" > "$result_json"

jq -r '"turns=\(.num_turns) cost_usd=\(.total_cost_usd) denials=\(.permission_denials | length) error=\(.is_error)"' "$result_json"
jq -r '.permission_denials[]? | "DENIED \(.tool_name): \(.tool_input.file_path // .tool_input.pattern // (.tool_input | tostring))"' "$result_json"
if jq -e --arg d "$data_dir" '[.permission_denials[]? | (.tool_input.file_path // .tool_input.path // "") | select(startswith($d))] | length > 0' "$result_json" > /dev/null; then
  echo "Claude was denied a read inside the data directory; not posting a review built without it." >&2
  exit 1
fi
if [[ "$(jq -r '.structured_output | type' "$result_json")" != "object" ]]; then
  echo "No structured output. Claude's closing message:" >&2
  jq -r '.result // ""' "$result_json" | head -c 3000 >&2
  exit 1
fi
