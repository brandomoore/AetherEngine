#!/usr/bin/env bash
# Collects what the triage step reads about a new issue into plain files.
#
#   fetch-issue.sh <owner/repo> <issue-number> <out-dir>
#
# Writes issue.json (the issue with its comments) and issues.json (number, title, state and labels
# of the 500 most recent issues and pull requests, for spotting duplicates). Needs GH_TOKEN.
set -euo pipefail

repo="$1"
issue="$2"
out="$3"

mkdir -p "$out"
gh issue view "$issue" --repo "$repo" --json number,title,body,author,labels,comments,createdAt > "$out/issue.json"
gh issue list --repo "$repo" --state all --limit 500 --json number,title,state,labels \
  --jq '[.[] | {number, title, state, labels: [.labels[].name]}]' > "$out/issues.json"
gh pr list --repo "$repo" --state all --limit 200 --json number,title,state \
  --jq '[.[] | {number, title, state, pr: true}]' > "$out/prs.json"
echo "Fetched issue #$issue and $(jq length "$out/issues.json") issues, $(jq length "$out/prs.json") PRs for comparison."
