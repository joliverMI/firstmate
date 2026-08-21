#!/usr/bin/env bash
# Pin gh's ambiguous pull-request destination resolution to this repo's own
# "origin" remote, in both a project checkout and its no-mistakes gate, then
# fail loudly if the pin cannot be verified in either place.
#
# `gh pr create` (and other gh commands) resolve their target repository from
# the working directory's git remotes UNLESS a default is pinned - and when
# the resolved remote is a GitHub fork, gh defaults to the fork's PARENT, not
# the fork itself. joliverMI/firstmate is a real fork of the public
# kunchenguid/firstmate, so any `gh pr create` run without this pin lands on
# the parent. See docs/architecture.md "Pull request destination is pinned,
# never gh's default" for the incident and the full mechanism; no-mistakes'
# own PR step has no config surface to point it elsewhere.
#
# `gh repo set-default origin` writes that pin as git config
# (remote.origin.gh-resolved) - a purely local, non-destructive setting that
# works against an ordinary checkout or a bare repository (no-mistakes' gate
# is bare). This script applies and verifies the pin in both places, because
# no-mistakes' PR step runs `gh` from a worktree of its gate, not from the
# project checkout firstmate or a crewmate is sitting in; the gate's own
# origin remote is set up by `no-mistakes init` and is not this script's
# concern.
#
# Verification is a destination check, not an existence check: the pin must read
# back through `gh repo set-default --view` AND name this project's own
# origin owner/repository. A pin that merely exists proves nothing - a repointed
# origin pins gh just as successfully to the wrong repository - so a read that
# fails, reads back empty, or names anything else is a refusal, never a pass.
#
# Usage: fm-pr-destination-guard.sh <project-dir>
# Exit 0: the destination is pinned and verified to be this project's own
#         repository (or origin is not GitHub, so this guard's fork-parent
#         default does not apply).
# Exit 1: origin is missing or unparseable, the gate cannot be discovered, or
#         the pin could not be read back and confirmed to name this project's
#         own repository. Never silently proceeds.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

DIR=${1:?usage: fm-pr-destination-guard.sh <project-dir>}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }

ORIGIN_URL=$(git -C "$DIR" config --get remote.origin.url 2>/dev/null || true)
if [ -z "$ORIGIN_URL" ]; then
  echo "error: $DIR has no 'origin' remote; cannot pin a pull-request destination" >&2
  exit 1
fi

case "$ORIGIN_URL" in
  *github.com*) ;;
  *)
    echo "skip: $DIR's origin ($ORIGIN_URL) is not github.com; gh's fork-parent default this guard closes is GitHub-specific"
    exit 0
    ;;
esac

# The project checkout's own origin is the single source of truth for where this
# project's pull requests belong. The gate is checked against this same value,
# not against its own origin: a gate whose origin drifted to the fork parent
# would otherwise verify happily against itself.
if ! fm_pr_github_remote_owner_repo "$ORIGIN_URL"; then
  echo "error: $DIR's origin ($ORIGIN_URL) is on github.com but is not a parseable owner/repository URL; the pull-request destination cannot be verified" >&2
  exit 1
fi
EXPECTED="$FM_PR_REMOTE_OWNER/$FM_PR_REMOTE_REPO"
EXPECTED_LC=$(fm_pr_lower "$EXPECTED")

pin_and_verify() {  # <dir> <label>
  local dir=$1 label=$2 resolved viewed
  if ! ( cd "$dir" && gh repo set-default origin ) >/dev/null 2>&1; then
    echo "error: could not pin the pull-request destination for $label ($dir)" >&2
    exit 1
  fi
  resolved=$(cd "$dir" && git config --get remote.origin.gh-resolved 2>/dev/null || true)
  if [ -z "$resolved" ]; then
    echo "error: pull-request destination pin did not take effect for $label ($dir) - remote.origin.gh-resolved is still unset" >&2
    exit 1
  fi
  if ! viewed=$(cd "$dir" && gh repo set-default --view 2>/dev/null); then
    echo "error: could not read back the pinned pull-request destination for $label ($dir); it stays unverified and this guard refuses rather than assume it" >&2
    exit 1
  fi
  viewed=$(printf '%s' "$viewed" | head -n1 | tr -d '[:space:]')
  if [ -z "$viewed" ]; then
    echo "error: the pinned pull-request destination for $label ($dir) read back empty; an unnamed destination is never a verified one" >&2
    exit 1
  fi
  if [ "$(fm_pr_lower "$viewed")" != "$EXPECTED_LC" ]; then
    echo "error: $label ($dir) resolves pull requests to $viewed, not this project's own $EXPECTED; refusing to proceed" >&2
    exit 1
  fi
}

pin_and_verify "$DIR" "the project checkout"

GATE=$(cd "$DIR" && no-mistakes status 2>/dev/null | sed -n 's/^ *gate: *//p' | head -n1)
if [ -z "$GATE" ] || [ ! -d "$GATE" ]; then
  echo "error: could not discover $DIR's no-mistakes gate (run 'no-mistakes init' first); the pull-request destination is unverified" >&2
  exit 1
fi
pin_and_verify "$GATE" "the no-mistakes gate"

echo "pinned: $EXPECTED is the sole pull-request destination for $DIR and its no-mistakes gate"
