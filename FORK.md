# This public fork

This repository is the [`SSBrouhard/firstmate`](https://github.com/SSBrouhard/firstmate) public fork of Kun Cheng's [`kunchenguid/firstmate`](https://github.com/kunchenguid/firstmate).
It is not Kun's repository, and it is not a private Firstmate home.

## Layout

- `origin` is this public fork: `https://github.com/SSBrouhard/firstmate.git`.
- `upstream` is Kun's repository: `https://github.com/kunchenguid/firstmate.git`.
- `upstream` is fetch-only.
- Never push to `upstream`.
- `upstream-main` is a clean mirror of Kun's `main`, with no extra commits from this fork.
- `main` is this fork's customized line.

`upstream-main` exists so you can see new Kun commits without changing `main`.
Refreshing the mirror is not the same as reconciling those commits into `main`.

## Initialize remotes and the mirror branch

Use these remotes.
Do not add a third remote or change any other clone's remotes.

```sh
git remote add origin https://github.com/SSBrouhard/firstmate.git
git remote add upstream https://github.com/kunchenguid/firstmate.git
git remote set-url --push upstream DISABLED
```

If the remotes already exist, keep them and confirm the push URL is disabled:

```sh
git remote get-url --push upstream
# expected: DISABLED
```

Then create the fetch-only mirror and publish it on this fork:

```sh
git fetch origin
git fetch upstream
git branch -f upstream-main upstream/main
git push -u origin upstream-main
```

`upstream-main`, `origin/upstream-main`, and `upstream/main` must share one SHA after that push.
Do not put fork-only files such as this page on `upstream-main`.

## Refresh `upstream-main`

Refresh is fetch-only.
Do not merge `upstream-main` into `main` as part of the refresh.

```sh
git fetch upstream
git branch -f upstream-main upstream/main
git push origin upstream-main
```

Confirm the three names still share one SHA, and confirm `git remote get-url --push upstream` is still `DISABLED`.

## Review and reconcile new Kun commits

Do not merge `upstream-main` into `main` blindly.
This fork's `main` has already diverged, so a raw merge is not a refresh.

1. Refresh `upstream-main` with the steps above.
2. List the new commits: `git log --oneline main..upstream-main`.
3. Review the incoming patch: `git diff main...upstream-main`.
4. Import only the commits you intend to take, one commit or one reviewed range at a time, onto a feature branch from this fork's `main`.
5. Land that branch through this fork's normal PR path against `SSBrouhard/firstmate`.

Never open a PR against `kunchenguid/firstmate` for this work.
Never push to `upstream`.

## Handle conflicts

When a Kun commit touches a file this fork already customized, stop and inspect both sides before editing.
Keep this fork's remotes, the fetch-only `upstream` push URL, and the clean `upstream-main` mirror intact.
Resolve the conflict on the import branch, then continue the reviewed import.
If the conflict would require rewriting history on `upstream-main` or pushing to Kun, stop instead.

Do not force this fork's `main` to match Kun's `main`.
Do not treat a conflict as a reason to catch `main` up in one merge.
