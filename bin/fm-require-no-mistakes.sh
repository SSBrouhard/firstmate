#!/usr/bin/env bash
set -eu

marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

if printf '%s' "${PR_BODY:-}" | grep -qF -- "$marker"; then
  echo "Found no-mistakes signature in PR #${PR_NUMBER:-unknown} body."
  exit 0
fi

commit_messages=${PR_COMMIT_MESSAGES:-}
if [ -z "$commit_messages" ] &&
  [ -n "${PR_NUMBER:-}" ] &&
  [ -n "${GITHUB_REPOSITORY:-}" ] &&
  command -v gh >/dev/null 2>&1; then
  commit_messages=$(
    gh api --paginate "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/commits" \
      --jq '.[].commit.message' 2>/dev/null || true
  )
fi

if printf '%s\n' "$commit_messages" | grep -qE '^no-mistakes\('; then
  echo "Found no-mistakes commit evidence in PR #${PR_NUMBER:-unknown}."
  exit 0
fi

{
  echo "::error::This PR was not raised through no-mistakes."
  echo
  echo "Contributions to this repository must be submitted via 'git push no-mistakes'."
  echo "That pipeline runs the required review/test/lint/CI steps and writes a"
  echo "deterministic '## Pipeline' section into the PR body containing:"
  echo
  echo "    $marker"
  echo
  echo "If a follow-up edit replaced the PR body, at least one PR commit must retain"
  echo "the no-mistakes(...) subject written by the gate."
  echo
  echo "See CONTRIBUTING.md for setup and the full workflow."
  echo
  echo "PR author: ${PR_AUTHOR:-unknown}"
} >&2
exit 1
