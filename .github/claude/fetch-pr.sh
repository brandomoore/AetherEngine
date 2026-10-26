#!/usr/bin/env bash
# Collects everything the reviewer reads about a pull request into plain files.
#
#   fetch-pr.sh <owner/repo> <pr-number> <head-sha> <out-dir>
#
# Run from a checkout of the base branch, with GH_TOKEN set. Writes:
#   pr.json             title, body, author, base, head, changed files
#   discussion.md       conversation and reviews, including earlier automated reviews
#   review-comments.md  inline review comments
#   pr.diff             the diff GitHub shows
#   head/<path>         every changed file as it is at the PR head
#
# The head files come from git objects (`git show`), never from a checkout, and nothing here
# executes them. Instruction files a PR adds or edits (CLAUDE.md, AGENTS.md, anything under
# .claude/) get a `.pr-data` suffix, so Claude Code can never pick one up as instructions.
set -euo pipefail

repo="$1"
pr="$2"
head_sha="$3"
out="$4"

mkdir -p "$out/head"

gh pr view "$pr" --repo "$repo" \
  --json number,title,body,author,baseRefName,headRefOid,headRepositoryOwner,isDraft,files \
  > "$out/pr.json"
gh pr view "$pr" --repo "$repo" --comments > "$out/discussion.md"
gh api --paginate "repos/$repo/pulls/$pr/comments" \
  --jq '.[] | "\(.user.login) on \(.path):\(.line // .original_line // "?"):\n\(.body)\n---"' \
  > "$out/review-comments.md"
if ! gh pr diff "$pr" --repo "$repo" > "$out/pr.diff" 2> "$out/diff-error.txt"; then
  echo "GitHub did not return the diff ($(head -c 300 "$out/diff-error.txt")). Read the changed files under head/ instead." > "$out/pr.diff"
fi
rm -f "$out/diff-error.txt"

git fetch --quiet --no-tags --no-recurse-submodules --depth=1 origin "+refs/pull/${pr}/head:refs/remotes/pr/head"
if [[ "$(git rev-parse refs/remotes/pr/head)" != "$head_sha" ]]; then
  echo "The PR head moved past $head_sha; a newer run reviews it." >&2
  exit 1
fi

jq -r '.files[].path' "$out/pr.json" | while IFS= read -r path; do
  case "$path" in /*|*..*) continue ;; esac
  [[ "$(git cat-file -t "$head_sha:$path" 2>/dev/null)" == "blob" ]] || continue
  [[ "$(git cat-file -s "$head_sha:$path")" -le 1048576 ]] || continue
  target="$out/head/$path"
  name="${path##*/}"
  if [[ "$name" == CLAUDE.md || "$name" == AGENTS.md || "$path" == .claude/* || "$path" == */.claude/* ]]; then
    target="$target.pr-data"
  fi
  mkdir -p "$(dirname "$target")"
  git show "$head_sha:$path" > "$target"
done

echo "Fetched PR #$pr at ${head_sha:0:8}: $(jq '.files | length' "$out/pr.json") changed files, $(wc -l < "$out/pr.diff") diff lines."
