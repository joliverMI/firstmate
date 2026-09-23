#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> prints the block on
# stdout with no trailing blank line. The caller validates the mode; an unknown
# mode is refused rather than silently rendered as the pipeline contract.
# The direct-PR block names bin/fm-pr-destination-guard.sh through the caller's
# FM_ROOT, so a caller must set FM_ROOT before invoking this function.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

fm_dod_block() {  # <mode> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch, then open the PR with its destination named in the very same command that creates it. Never let a tool choose that destination: \`gh pr create\` defaults to a fork's parent rather than the fork itself, \`gh repo view\` with no repository argument picks a remote by gh's own preference order (\`upstream\` before \`origin\`), and \`gh-axi\` drops an empty \`--repo\` and falls back to that same default - so a destination that is merely computed earlier, in some other command, fails open onto the parent.
First write the PR title and body into files, each with a quoted heredoc delimiter so the shell expands and executes nothing inside them. Text you author is never safe to inline: an apostrophe in a title ends the quoted string and kills the whole line with a syntax error before any of it runs, and a markdown body naming commands or paths in backticks would be executed before \`gh-axi\` ever saw it, its output substituted into the body.
\`cat > "\$(git rev-parse --absolute-git-dir)/fm-pr-title.txt" <<'FM_PR_TITLE'\` … your title, verbatim … \`FM_PR_TITLE\`
\`cat > "\$(git rev-parse --absolute-git-dir)/fm-pr-body.md" <<'FM_PR_BODY'\` … your body, verbatim … \`FM_PR_BODY\`
Then name the destination and create the PR as one command, so the create call cannot run at all unless the destination was determined with certainty:
\`set -- --title "\$(cat "\$(git rev-parse --absolute-git-dir)/fm-pr-title.txt")" --body-file "\$(git rev-parse --absolute-git-dir)/fm-pr-body.md"; OWNER_REPO=\$("$FM_ROOT/bin/fm-pr-destination-guard.sh" . --print-destination); case \$? in 0) gh-axi pr create --repo "\$OWNER_REPO" "\$@" ;; 3) gh-axi pr create "\$@" ;; *) exit 1 ;; esac\`
Your words go only into those two files; the create command itself is fixed text - run it exactly as written, as one command line, and do not edit or split it. Both files are named by your own worktree's git directory, so they are yours alone - crewmates run concurrently on one host under one user, and a fixed path in a shared directory would let another task's title or body silently replace yours between the write and the create. That guard mode reads this repo's own \`origin\` remote, makes no network call, and never prints a guess: exit 0 means it printed \`owner/repo\` and \`--repo\` carries that verified value straight into the create call - that flag being set from the guard's own value IS the destination guarantee, so there is no separate comparison left to make by eye; exit 3 means this repo is not on a GitHub host, where gh's fork-parent default cannot apply, so the PR is created without a destination override as it always was; any other exit means the destination is undetermined on a repo where the hazard is real, so nothing is created - append \`blocked: {its exact error}\` to the status file and stop. Otherwise append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 7) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
