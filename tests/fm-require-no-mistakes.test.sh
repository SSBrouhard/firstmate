#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/bin/fm-require-no-mistakes.sh"

marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

out=$(PR_NUMBER=12 PR_BODY="body $marker" "$SCRIPT")
case "$out" in
  *"Found no-mistakes signature in PR #12 body."*) ;;
  *) echo "expected body marker acceptance, got: $out" >&2; exit 1 ;;
esac

out=$(PR_NUMBER=12 PR_BODY='body replaced during follow-up' PR_COMMIT_MESSAGES='feat: start
no-mistakes(test): record validation
fix: finish' "$SCRIPT")
case "$out" in
  *"Found no-mistakes commit evidence in PR #12."*) ;;
  *) echo "expected commit evidence acceptance, got: $out" >&2; exit 1 ;;
esac

set +e
err=$(PR_NUMBER=12 PR_AUTHOR=captain PR_BODY='manual body' PR_COMMIT_MESSAGES='feat: manual change' "$SCRIPT" 2>&1 >/dev/null)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  echo "expected manual PR rejection" >&2
  exit 1
fi

case "$err" in
  *"This PR was not raised through no-mistakes"*) ;;
  *) echo "expected rejection error, got: $err" >&2; exit 1 ;;
esac
