#!/usr/bin/env bash
# test-require-complexity-marker.sh - Tests for require-complexity-marker.sh's
# fetch-failure vs absent-marker distinction (#4472), the pre-existing
# tier-parsing behaviour it must not regress, and the second `loom:points`
# marker gate added alongside it (#9056).
#
# The bug (#4472): the body fetch swallowed every `gh` failure with `|| true`
# `2>/dev/null`, so a GraphQL quota exhaustion produced an empty body that parsed
# as an empty tier and printed the BLOCKED-missing text — indistinguishable from
# a genuinely unmarked issue, blocking curation while quota was out. The fix adds
# a GraphQL->REST fallback and, on total fetch failure, exits 2 ("could not
# evaluate", the script's existing usage/repo-resolution exit code) with a
# fetch-error message instead of exit 1 (missing marker).
#
# #9056 extends the same script to ALSO require a valid `<!-- loom:points=<N>
# -->` marker (closed vocabulary 1/2/3/5/8/13), read off the SAME fetched body —
# no second `gh` round trip. The tier check runs FIRST and exits immediately on
# a bad tier (unchanged, early-exit style); the points check is reached only
# once a valid tier is confirmed, and its validation moved into a
# `loom-daemon check-points-marker` subcommand rather than more inline shell
# (epic #7810's `shell-budget` gate ratchets `contract`-category shell lines
# down, never up — see the script's own comment at that call site). Every
# pre-#9056 success fixture (9001, 9004, 9007) therefore now carries a valid
# `loom:points` marker too, alongside its `loom:complexity` marker, so those
# scenarios keep exiting 0. A fake `loom-daemon` stub (below, alongside the
# fake `gh`) stands in for the real subcommand so this suite stays a fast,
# hermetic shell test with no `cargo build` dependency.
#
# Style matches test-resolve-tier-model.sh: a fake `gh` stub on PATH answers both
# the `gh issue view ... -q .body` (GraphQL) and `gh api repos/.../issues/... --jq
# .body` (REST) invocations, keyed off issue number, so scenarios can force
# GraphQL failure, REST fallback, or both-fail without network access. The repo is
# passed explicitly (2nd positional arg), so forge auto-detection is never hit.
#
# Usage:
#   ./defaults/scripts/tests/test-require-complexity-marker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MARKER_SCRIPT="$SCRIPTS_DIR/require-complexity-marker.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

assert_contains() {
    local needle="$1" haystack="$2" msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg (expected substring '$needle' in: $haystack)"
    fi
}

assert_not_contains() {
    local needle="$1" haystack="$2" msg="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg (unexpected substring '$needle' in: $haystack)"
    fi
}

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$expected', got '$actual')"
    fi
}

if [[ ! -x "$MARKER_SCRIPT" ]]; then
    echo -e "${RED}FATAL${NC}: $MARKER_SCRIPT not found or not executable" >&2
    exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-require-complexity-marker.XXXXXX")"
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---- Fake `gh` stub ---------------------------------------------------------
# Handles two invocations:
#   gh issue view <issue> -R <repo> --json body -q .body   (GraphQL path)
#   gh api repos/<repo>/issues/<issue> --jq .body          (REST fallback)
# Bodies are keyed off issue number; per-invocation success/failure is scripted
# so a scenario can force GraphQL failure with REST success (fallback), or both
# failing (fetch error / exit 2).
#
#   9001 = valid complexity + valid points via GraphQL
#   9002 = no marker via GraphQL (successful fetch, empty tier, empty points)
#   9003 = invalid/out-of-vocabulary tier via GraphQL (no points marker either)
#   9004 = GraphQL FAILS, REST returns valid complexity + valid points (fallback path)
#   9005 = both GraphQL and REST FAIL (fetch error)
#   9006 = GraphQL succeeds but returns an EMPTY body (successful fetch, no marker)
#   9007 = body has prose mentioning the COMPLEXITY marker syntax BEFORE the real
#          marker (#4840) -- the real marker must still be found; also carries a
#          valid points marker so this stays an exit-0 fixture under #9056
#   9010 = valid complexity, NO points marker at all (#9056)
#   9011 = valid complexity, out-of-vocabulary points value (#9056)
#   9012 = valid complexity + prose mentioning the POINTS marker syntax BEFORE
#          the real points marker (#9056, mirrors the #4840 fix for points)
#   9013 = valid complexity + TWO points markers -- the LAST must win (#9056)
#   9014 = NEITHER marker present -- ONLY the complexity BLOCKED message: the
#          tier check exits 1 first, so the points check never runs (#9056)
FAKE_BIN="$WORKDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
# GraphQL path: gh issue view <issue> -R <repo> --json body -q .body
if [[ "$1" == "issue" && "$2" == "view" ]]; then
    issue="$3"
    case "$issue" in
        9001) echo "Body.

<!-- loom:complexity=routine -->
<!-- loom:points=3 -->
" ; exit 0 ;;
        9002) echo "An issue body with no complexity marker at all." ; exit 0 ;;
        9003) echo "Drifted marker.

<!-- loom:complexity=trivial -->
" ; exit 0 ;;
        9004) exit 1 ;;   # GraphQL quota exhausted -> forces REST fallback
        9005) exit 1 ;;   # GraphQL fails ...
        9006) echo "" ; exit 0 ;;
        9007) echo "Meta issue about the complexity-marker feature itself, which
legitimately quotes the marker syntax as literal example text before the real
marker appears (#4840): \`<!-- loom:complexity=<tier> -->\`.

<!-- loom:complexity=mechanical -->
<!-- loom:points=1 -->
" ; exit 0 ;;
        9010) echo "Body with a valid tier but no points marker.

<!-- loom:complexity=routine -->
" ; exit 0 ;;
        9011) echo "Body with an out-of-vocabulary points value.

<!-- loom:complexity=routine -->
<!-- loom:points=21 -->
" ; exit 0 ;;
        9012) echo "Meta issue about the points-marker feature itself, quoting
the syntax as literal example text before the real marker appears: \`<!--
loom:points=<N> -->\`.

<!-- loom:complexity=routine -->
<!-- loom:points=5 -->
" ; exit 0 ;;
        9013) echo "Drifted points marker, corrected further down.

<!-- loom:complexity=routine -->
<!-- loom:points=1 -->

Recalibrated:

<!-- loom:points=8 -->
" ; exit 0 ;;
        9014) echo "Neither marker present at all." ; exit 0 ;;
        *) echo "" ; exit 0 ;;
    esac
fi
# REST fallback path: gh api repos/<repo>/issues/<issue> --jq .body
if [[ "$1" == "api" ]]; then
    # 2nd arg looks like repos/owner/repo/issues/<issue>
    issue="${2##*/}"
    case "$issue" in
        9004) echo "Recovered via REST.

<!-- loom:complexity=complex -->
<!-- loom:points=13 -->
" ; exit 0 ;;
        9005) exit 1 ;;   # ... and REST fails too -> fetch error
        *) exit 1 ;;
    esac
fi
exit 1
FAKEGH
chmod +x "$FAKE_BIN/gh"

# ---- Fake `loom-daemon` stub -------------------------------------------
# The real points-marker validation now lives in
# `loom-daemon check-points-marker` (Issue #9056, moved out of inline shell
# to keep epic #7810's `shell-budget` gate a non-event — see
# require-complexity-marker.sh's own comment at the call site). This fake
# reimplements just that one subcommand's contract (stdin body in, `--issue`/
# `--repo` for the message label, exit 0/1, matching message text) so this
# suite stays a fast, hermetic shell test with no `cargo build` dependency —
# the real Rust logic has its own unit tests in
# `loom-daemon/src/points_marker.rs`, run via cargo. Placed on `$PATH` ahead
# of any real installed `loom-daemon` by `run_marker` below, exactly like the
# fake `gh`.
cat > "$FAKE_BIN/loom-daemon" <<'FAKEDAEMON'
#!/usr/bin/env bash
if [[ "$1" == "check-points-marker" ]]; then
    shift
    issue=""
    repo=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue) issue="$2"; shift 2 ;;
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    body="$(cat)"
    raw="$(printf '%s' "$body" | grep -oE '<!--[[:space:]]*loom:points=[0-9]*[[:space:]]*-->' | tail -1 | sed -E 's/.*points=([0-9]*).*/\1/')"
    label="$issue"
    [[ -n "$repo" ]] && label="$repo#$issue"
    case "$raw" in
        1|2|3|5|8|13)
            echo "ok: $label is pointed $raw"
            exit 0
            ;;
        "")
            echo "BLOCKED: issue has no points estimate marker." >&2
            exit 1
            ;;
        *)
            echo "BLOCKED: issue $issue has an invalid points value '$raw' (expected one of 1, 2, 3, 5, 8, 13)" >&2
            exit 1
            ;;
    esac
fi
exit 1
FAKEDAEMON
chmod +x "$FAKE_BIN/loom-daemon"

REPO="owner/repo"

run_marker() {
    local issue="$1"
    PATH="$FAKE_BIN:$PATH" "$MARKER_SCRIPT" "$issue" "$REPO"
}

# -------- Test 1: script exists and is executable --------
echo "Test 1: script exists and is executable"
if [[ -x "$MARKER_SCRIPT" ]]; then
    pass "require-complexity-marker.sh is executable"
else
    fail "require-complexity-marker.sh is missing or not executable"
fi

# -------- Test 2: successful GraphQL fetch, valid marker -> exit 0 --------
echo "Test 2: valid marker via GraphQL -> exit 0"
out="$(run_marker 9001 2>&1)"; rc=$?
assert_eq "0" "$rc" "valid marker exits 0"
assert_contains "is tagged routine" "$out" "valid marker reports the tier"
assert_contains "is pointed 3" "$out" "valid marker also reports the points estimate (#9056)"

# -------- Test 3: successful fetch, no marker -> exit 1 BLOCKED --------
echo "Test 3: successful fetch, absent marker -> exit 1 BLOCKED (unchanged)"
out="$(run_marker 9002 2>&1)"; rc=$?
assert_eq "1" "$rc" "absent marker exits 1"
assert_contains "BLOCKED: issue has no complexity marker" "$out" "absent marker prints the BLOCKED-missing text"

# -------- Test 4: successful fetch, invalid tier -> exit 1 --------
echo "Test 4: successful fetch, invalid tier -> exit 1 (unchanged)"
out="$(run_marker 9003 2>&1)"; rc=$?
assert_eq "1" "$rc" "invalid tier exits 1"
assert_contains "invalid tier 'trivial'" "$out" "invalid tier names the offending value"

# -------- Test 5: GraphQL fails, REST fallback succeeds -> normal eval --------
echo "Test 5: GraphQL fails + REST fallback returns valid marker -> exit 0 on REST body"
out="$(run_marker 9004 2>&1)"; rc=$?
assert_eq "0" "$rc" "REST-fallback body with a valid marker exits 0"
assert_contains "is tagged complex" "$out" "REST-fallback body's tier is used"
assert_contains "is pointed 13" "$out" "REST-fallback body's points estimate is used (#9056)"
assert_not_contains "BLOCKED" "$out" "REST-fallback success never prints BLOCKED"

# -------- Test 6: both GraphQL and REST fail -> exit 2 fetch error --------
echo "Test 6: both fetches fail -> exit 2 fetch error, NOT exit 1 BLOCKED-missing"
out="$(run_marker 9005 2>&1)"; rc=$?
assert_eq "2" "$rc" "total fetch failure exits 2 (could not evaluate), not 1"
assert_contains "could not fetch" "$out" "fetch failure prints a fetch-error message"
assert_contains "quota" "$out" "fetch-error message names the likely cause (quota)"
assert_not_contains "issue has no complexity marker" "$out" "fetch failure never prints the BLOCKED-missing text"

# -------- Test 7: successful fetch of an EMPTY body -> exit 1 BLOCKED --------
# A successful-but-empty fetch must NOT be conflated with a fetch failure: it is
# a genuinely unmarked issue and stays exit 1, per the original report.
echo "Test 7: successful fetch of empty body -> exit 1 BLOCKED (not conflated with fetch failure)"
out="$(run_marker 9006 2>&1)"; rc=$?
assert_eq "1" "$rc" "empty-but-successful fetch exits 1 (missing marker), not 2"
assert_contains "BLOCKED: issue has no complexity marker" "$out" "empty-but-successful fetch prints the BLOCKED-missing text"
assert_not_contains "could not fetch" "$out" "empty-but-successful fetch is not a fetch error"

# -------- Test 8: prose mentioning the marker syntax before the real marker
# -------- is ignored -> exit 0 (#4840) --------
# The bug this issue reports: a body that *discusses* the marker syntax in
# prose before the real marker (e.g. a meta issue about the complexity-marker
# feature itself, quoting `<!-- loom:complexity=<tier> -->` as literal example
# text) used to produce an empty first match that `head -1` picked over the
# real marker later in the body, false-positively reporting BLOCKED even
# though a valid marker was present.
echo "Test 8: prose that mentions the marker syntax before the real marker is ignored -> exit 0"
out="$(run_marker 9007 2>&1)"; rc=$?
assert_eq "0" "$rc" "real marker found despite preceding prose mentions -> exit 0"
assert_contains "is tagged mechanical" "$out" "real marker (mechanical) is reported, not the empty prose match"
assert_contains "is pointed 1" "$out" "points marker alongside the complexity marker is still read (#9056)"
assert_not_contains "BLOCKED" "$out" "prose mention never triggers BLOCKED"

# ==== Points estimate marker (#9056) =========================================

# -------- Test 9: valid tier, but NO points marker -> exit 1 BLOCKED --------
echo "Test 9: valid tier, absent points marker -> exit 1 BLOCKED-missing-points"
out="$(run_marker 9010 2>&1)"; rc=$?
assert_eq "1" "$rc" "a valid tier does not excuse a missing points marker"
assert_contains "is tagged routine" "$out" "the valid tier is still reported"
assert_contains "BLOCKED: issue has no points estimate marker" "$out" "missing points prints its own BLOCKED text"

# -------- Test 10: valid tier, out-of-vocabulary points value -> exit 1 -----
echo "Test 10: valid tier, invalid points value -> exit 1 BLOCKED-invalid-points"
out="$(run_marker 9011 2>&1)"; rc=$?
assert_eq "1" "$rc" "an out-of-vocabulary points value is a curation defect"
assert_contains "invalid points value '21'" "$out" "invalid points value names the offending value"

# -------- Test 11: prose mentioning the POINTS marker syntax before the real
# -------- one is ignored -> exit 0 (points mirror of #4840) ----------------
echo "Test 11: prose mentioning the points marker syntax before the real one is ignored -> exit 0"
out="$(run_marker 9012 2>&1)"; rc=$?
assert_eq "0" "$rc" "real points marker found despite preceding prose mentions -> exit 0"
assert_contains "is pointed 5" "$out" "real points value (5) is reported, not the empty prose match"
assert_not_contains "BLOCKED" "$out" "prose mention never triggers BLOCKED"

# -------- Test 12: two points markers -- the LAST one wins ------------------
echo "Test 12: last points marker wins when more than one is present"
out="$(run_marker 9013 2>&1)"; rc=$?
assert_eq "0" "$rc" "a corrected later points marker still exits 0"
assert_contains "is pointed 8" "$out" "the LAST points marker (8) is used, not the drifted first one (1)"

# -------- Test 13: neither marker present -- the tier check short-circuits -
# The tier check runs (and exits) FIRST; the points check is only reached once
# a valid tier is already confirmed (early-exit style, mirroring the
# pre-#9056 script's own immediate `exit 1` on a bad tier). So a body with
# NEITHER marker reports only the complexity BLOCKED text, never reaching the
# points check at all -- not a combined report of both.
echo "Test 13: neither marker present -> exit 1, complexity BLOCKED text only (tier check short-circuits)"
out="$(run_marker 9014 2>&1)"; rc=$?
assert_eq "1" "$rc" "missing both markers exits 1"
assert_contains "BLOCKED: issue has no complexity marker" "$out" "complexity BLOCKED text is present"
assert_not_contains "BLOCKED: issue has no points estimate marker" "$out" "the points check never ran -- the tier check already exited"

# -------- Summary --------
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo -e "${RED}FAILED${NC}: $TESTS_FAILED test(s) failed"
    exit 1
fi
echo -e "${GREEN}OK${NC}: all tests passed"
exit 0
