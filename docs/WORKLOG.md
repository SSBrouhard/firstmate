# Worklog

Notable tracked changes on this public fork's `main`.
The fetch-only Kun mirror lives on `upstream-main` and is not described here.

## 2026-08-26

- Merged Kun `main` (`9ce69ac`) into this public fork while keeping the unique public commits reachable: dispatch outcome memory and stuck escalation (`aee508a`), escalate lifecycle lock and launch-marker hardening (`85bcbcd`), and the public-fork remotes recipe (`93178ef`).
- Catch-up used a merge commit, not a rebase or force-push. `upstream` stays fetch-only.

## 2026-08-18

- Added [FORK.md](../FORK.md) for remotes, the fetch-only `upstream-main` mirror of Kun's `main`, and the review-first reconcile path.
- Published `origin/upstream-main` as a clean SHA-identical mirror of `upstream/main`.
