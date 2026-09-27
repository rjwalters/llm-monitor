#!/usr/bin/env bash
# require-complexity-marker.sh - Check that an issue carries a complexity tier
# AND a points estimate before it is marked curated (#4238, #9056).
#
# The tier drives the downstream Builder model choice, so an unclassified issue
# silently costs either quality (cheap model on money/security work) or money
# (frontier model on a file split). The points marker is a coarse, uncalibrated
# holistic estimate of expected total sweep cost, laying the groundwork for
# comparing it against the actual token/duration/cycle burn a successful sweep
# already assembles (Issue #9056). This turns "please remember to classify" into
# a command the Curator can run that fails loudly on either marker.
#
#   require-complexity-marker.sh <issue> [repo]   # exit 0 = both markers valid
#                                                 # exit 1 = missing/invalid marker
#                                                 # exit 2 = could not fetch (retry/check quota)
set -uo pipefail

ISSUE="${1:-}"
[[ -n "$ISSUE" ]] || { echo "usage: require-complexity-marker.sh <issue> [repo]" >&2; exit 2; }

# Resolve the repo explicitly. A bare `gh issue view` targets the default remote,
# which is wrong wherever `origin` is not where the issues live (a fork checkout,
# most obviously) — it looks up a same-numbered issue in another repository and
# reports whatever that one says.
REPO="${2:-${LOOM_REPO:-}}"
if [[ -z "$REPO" ]]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
  # shellcheck source=/dev/null
  source "$ROOT/.loom/scripts/lib/forge-helpers.sh" 2>/dev/null || true
  if declare -F forge_get_repo_nwo >/dev/null; then
    REPO="$(forge_get_repo_nwo gh 2>/dev/null || true)"
  fi
fi
[[ -n "$REPO" ]] || { echo "could not determine repo; pass it explicitly or set LOOM_REPO" >&2; exit 2; }

# Fetch the issue body, distinguishing a fetch FAILURE from a genuinely empty
# body (#4472). `gh issue view` is a GraphQL call; under quota exhaustion (routine
# at fleet scale, epic #4432) it fails, and a swallowed failure would parse as an
# empty tier and print the BLOCKED-missing text — indistinguishable from an
# unmarked issue, blocking curation while quota is out. So: try GraphQL, fall back
# to REST (which draws on a separate quota), and only if BOTH fail exit 2
# ("could not evaluate", already this script's semantics for repo-resolution
# failures) rather than 1 (missing marker). An empty body from a *successful*
# fetch remains exit 1. Fetched ONCE and reused for both the tier and points
# checks below (#9056) — no second round trip.
body="$(gh issue view "$ISSUE" -R "$REPO" --json body -q .body 2>/dev/null)" ||
  body="$(gh api "repos/$REPO/issues/$ISSUE" --jq .body 2>/dev/null)" || {
    echo "BLOCKED: could not fetch issue $REPO#$ISSUE body (both GraphQL and REST failed — likely GitHub API quota exhaustion). Retry or check quota; this is not a curation defect." >&2
    exit 2
  }

# ---- Complexity tier ---------------------------------------------------
#
# Anchor to the canonical HTML-comment marker form (`<!-- loom:complexity=<tier>
# -->`) rather than a bare `loom:complexity=[a-z]*` substring, and take the LAST
# such match (#4840). A bare substring match also fires on prose that merely
# *discusses* the marker syntax — e.g. an issue about the complexity-marker
# feature itself quoting `` `<!-- loom:complexity=<tier> -->` `` as literal
# example text. There the `<` right after `=` matches zero `[a-z]` chars,
# producing an empty match that `head -1` picked over the real marker later in
# the body, making a validly-marked issue look unmarked. Anchoring to the full
# `<!-- ... -->` comment form excludes that placeholder text (the literal `<`
# breaks the `-->` anchor), and `tail -1` picks the marker nearest the end of
# the body, matching where the marker is conventionally placed.
tier="$(printf '%s' "$body" | grep -oE '<!--[[:space:]]*loom:complexity=[a-z]*[[:space:]]*-->' | tail -1 | sed -E 's/.*complexity=([a-z]*).*/\1/')"

case "$tier" in
  mechanical|routine|complex)
    echo "ok: $REPO#$ISSUE is tagged $tier"
    ;;
  "")
    cat >&2 <<'EOF'
BLOCKED: issue has no complexity marker.

Add exactly one of these to the issue body before applying loom:curated:

  <!-- loom:complexity=mechanical -->   a mistake is obvious on reading it
  <!-- loom:complexity=routine -->      mistake would surface in tests/review
  <!-- loom:complexity=complex -->      mistake could pass tests and review unseen

Torn between two? Take the higher one.
EOF
    exit 1
    ;;
  *)
    echo "BLOCKED: issue $ISSUE has an invalid tier '$tier' (expected mechanical|routine|complex)" >&2
    exit 1
    ;;
esac

# ---- Points estimate marker (Issue #9056) ------------------------------
#
# Validated by `loom-daemon check-points-marker`, not inline shell: epic
# #7810's `shell-budget` CI gate ratchets `contract`-category portable shell
# DOWN, never up, and .loom/docs/shell-language-policy.md's answer is new
# executable logic is a daemon subcommand, not more portable shell. The body
# is piped on stdin -- already fetched above for the tier check, so this
# costs no second `gh` call. `loom_exec_script_helper` (lib/script-helper.sh)
# resolves the binary and `exec`s the subcommand -- never returns -- so this
# is deliberately this script's LAST statement; its own exit code (0 valid,
# 1 missing/invalid marker) becomes this script's exit code unmodified.
# LOOM_SCRIPT_HELPER_MISSING_RC=2 overrides the library's default missing-
# binary code (1): a missing daemon is an environment problem here, the same
# bucket as a body-fetch failure above, never a curation defect.
# requires-daemon: check-points-marker >= 0.19.446   #9056 -- brand-new subcommand landing in this same PR; the exact shipping version is set by the next post-merge auto-bump and cannot be known at authoring time, so this pins to the current VERSION as the best available floor (scripts/check-daemon-subcommand-versions.sh's own doc: a declared floor is not asserted as the historically-exact first release, only bounded to not exceed VERSION).
# shellcheck source=lib/script-helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/script-helper.sh"
printf '%s' "$body" | LOOM_SCRIPT_HELPER_MISSING_RC=2 loom_exec_script_helper check-points-marker --issue "$ISSUE" --repo "$REPO"
