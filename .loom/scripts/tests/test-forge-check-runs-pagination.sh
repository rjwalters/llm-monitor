#!/usr/bin/env bash
# test-forge-check-runs-pagination.sh - Unit tests for forge_get_check_runs'
# full pagination and its fail-closed short-read contract (#8895).
#
# Bug (#8895): the GitHub branch of `forge_get_check_runs` issued ONE request
# to `GET /repos/{nwo}/commits/{sha}/check-runs` with no `per_page` and no
# `--paginate`, so GitHub's default page size of 30 applied:
#
#   $ gh api repos/rjwalters/loom/commits/c53dcaa85/check-runs \
#       --jq '"\(.total_count) \(.check_runs|length)"'
#   39 30
#
# Nine of this repo's 39 check-runs per head were therefore invisible to
# `merge-pr.sh --auto`'s settle-wait (`_wait_for_checks_then_sync_merge`) —
# invisible both to its pending count and to its failed-required
# classification. Since #8410 removed the server-side auto-merge arm, that
# settle-wait is the ONLY check-settling mechanism, which made the hidden rows
# a live "merge while CI is still unsettled" gap.
#
# The fix, in two halves — this suite pins BOTH, because either alone leaves
# the hole open:
#   1. `per_page=100` + `--paginate`: retrieve every check-run, not one page.
#   2. Fail closed when the retrieved row count is SHORT of the forge's own
#      `total_count`: return `$FORGE_CHECK_RUNS_RC_TRUNCATED` (45) and withhold
#      the partial rollup, so a future growth past any page size (or a
#      mid-pagination mutation) can never be read as settlement. Half 1 without
#      half 2 is a page-size race waiting to happen; half 2 without half 1 just
#      relocates the outage.
#
# Surfaces exercised:
#   Part 1 — the helper's pagination, with `gh` PATH-shimmed to serve page
#            fixtures (the pattern from test-merge-pr-check-runs-404-fallback.sh).
#   Part 2 — the helper's short-read fail-closed rc, plus the reads that must
#            NOT be classified as short (legitimately empty, over-reported).
#   Part 3 — `_wait_for_checks_then_sync_merge`'s loop-level handling: a
#            truncated read must never settle, and must recover when a later
#            poll comes back complete.
#   Part 4 — source-wiring assertions, so a refactor that drops `--paginate`
#            or the short-read check fails here rather than in production.
#
# Usage:
#   ./.loom/scripts/tests/test-forge-check-runs-pagination.sh

# SC2034: globals (PR_JSON, PR_NUMBER, REPO_NWO, GH, LOOM_AUTO_MERGE_*,
# LOOM_CHECK_RUNS_404_STREAK) are read only by the function extracted+sourced
# from merge-pr.sh, which shellcheck cannot see.
# shellcheck disable=SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FORGE_HELPERS_SRC="$HELPERS_DIR/lib/forge-helpers.sh"
MERGE_PR_SRC="$HELPERS_DIR/merge-pr.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<<"$haystack"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected substring: '$needle'"
        echo "    In: '$haystack'"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<<"$haystack"; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Unexpected substring: '$needle'"
        echo "    In: '$haystack'"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    fi
}

if [[ ! -f "$FORGE_HELPERS_SRC" ]]; then
    echo "SKIP: source-tree-only test, $FORGE_HELPERS_SRC not found (not shipped into an installed repo)" >&2
    exit 0
fi

# Defines FORGE_CHECK_RUNS_RC_NOT_FOUND, FORGE_CHECK_RUNS_RC_TRUNCATED and
# forge_get_check_runs.
# shellcheck disable=SC1090
source "$FORGE_HELPERS_SRC"
# forge-helpers.sh sets `-euo pipefail` for its own callers; `errexit` in
# particular would abort this suite the moment a scenario's subshell exits
# non-zero (which Part 3 deliberately provokes), so put the options back the
# way this file declared them.
set +e
set -uo pipefail
FORGE_TYPE="github"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" 2>/dev/null || true' EXIT
STUB_DIR="$WORK_DIR/bin"
PAGES_DIR="$WORK_DIR/pages"
mkdir -p "$STUB_DIR" "$PAGES_DIR"
STUB_ARGV_FILE="$WORK_DIR/argv.txt"
: > "$STUB_ARGV_FILE"

# =============================================================================
# `gh` stub: emulates `gh api <endpoint> --paginate --header H --jq FILTER`
# =============================================================================
# Real `gh --paginate --jq` applies the filter to EACH page and streams one
# filtered result per page (gh refuses `--slurp` together with `--jq`), so the
# helper has to fold the per-page objects itself. The stub reproduces exactly
# that: the caller's own jq filter, once per page fixture, in order.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV_FILE"
if [[ "${1:-}" != "api" ]]; then
  echo "stub gh: unexpected invocation: $*" >&2
  exit 2
fi
shift
jq_filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jq_filter="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "${STUB_MODE:-pages}" in
  # A `gh` that exits 0 having printed nothing at all: NOT an authoritative
  # "this commit has no check-runs".
  empty-stdout) exit 0 ;;
  pages) : ;;
  *) echo "stub gh: unknown STUB_MODE '${STUB_MODE:-}'" >&2; exit 2 ;;
esac
shopt -s nullglob
for page in "$STUB_PAGES_DIR"/page-*.json; do
  jq -c "$jq_filter" "$page" || exit 1
done
exit 0
STUB
chmod +x "$STUB_DIR/gh"

export STUB_ARGV_FILE STUB_PAGES_DIR="$PAGES_DIR"
_ORIG_PATH="$PATH"

# Writes one page fixture. Rows are named check-<index> so a fold that drops or
# duplicates a page is visible in the unique-name count, not just the length.
mk_page() {  # <page-number> <total_count> <row-count> <name-offset>
    jq -nc --argjson t "$2" --argjson n "$3" --argjson off "$4" \
      '{total_count: $t,
        check_runs: [range($n) | {name: "check-\(. + $off)",
                                  status: "completed",
                                  conclusion: "success",
                                  html_url: "https://example.test/\(. + $off)"}]}' \
      > "$PAGES_DIR/page-$2-$(printf '%03d' "$1").json"
}

reset_pages() {
    rm -f "$PAGES_DIR"/page-*.json
    : > "$STUB_ARGV_FILE"
    unset STUB_MODE
}

HELPER_RC=0
HELPER_OUT=""
HELPER_ERR=""
run_helper() {  # <sha>
    local err_file rc=0
    err_file="$(mktemp)"
    HELPER_OUT="$(PATH="$STUB_DIR:$_ORIG_PATH" forge_get_check_runs "owner/repo" "$1" 2>"$err_file")" || rc=$?
    HELPER_RC="$rc"
    HELPER_ERR="$(cat "$err_file")"
    rm -f "$err_file"
}

rows_in() { jq -r '.check_runs | length' <<<"$1" 2>/dev/null || echo "PARSE-ERROR"; }
uniq_rows_in() { jq -r '[.check_runs[].name] | unique | length' <<<"$1" 2>/dev/null || echo "PARSE-ERROR"; }
total_in() { jq -r '.total_count' <<<"$1" 2>/dev/null || echo "PARSE-ERROR"; }

# =============================================================================
# Part 1: the helper retrieves EVERY check-run
# =============================================================================
echo "Testing forge_get_check_runs pagination (#8895)..."

# (1a) THE bug, reproduced at the size that produced it: 39 check-runs on one
# head. With per_page=100 that is a single page, so the helper must return all
# 39 — the pre-fix helper returned 30.
reset_pages
mk_page 1 39 39 0
run_helper "sha-39"
assert_eq "0" "$HELPER_RC" "(1a) 39 check-runs: rc 0"
assert_eq "39" "$(rows_in "$HELPER_OUT")" "(1a) 39 check-runs: all 39 rows returned (pre-fix: 30)"
assert_eq "39" "$(total_in "$HELPER_OUT")" "(1a) 39 check-runs: total_count preserved"

# The request itself must carry both halves of the pagination fix.
argv="$(cat "$STUB_ARGV_FILE")"
assert_contains "$argv" "per_page=100" "(1a) request asks for per_page=100 (not GitHub's default 30)"
assert_contains "$argv" "--paginate" "(1a) request passes --paginate so a >100-check repo is not capped either"

# (1b) Multi-page: 250 check-runs across 100 + 100 + 50. Every page's rows must
# be folded into one rollup — the Test Plan's ">100 check-runs" case.
reset_pages
mk_page 1 250 100 0
mk_page 2 250 100 100
mk_page 3 250 50 200
run_helper "sha-250"
assert_eq "0" "$HELPER_RC" "(1b) 250 check-runs across 3 pages: rc 0"
assert_eq "250" "$(rows_in "$HELPER_OUT")" "(1b) 250 check-runs: every page's rows folded into one rollup"
assert_eq "250" "$(uniq_rows_in "$HELPER_OUT")" "(1b) 250 check-runs: no page dropped or double-counted"
assert_eq "250" "$(total_in "$HELPER_OUT")" "(1b) 250 check-runs: total_count preserved across pages"

# (1c) Page-boundary case from the Test Plan: exactly 30 check-runs — the size
# at which the old default page size happened to be correct. Must still work.
reset_pages
mk_page 1 30 30 0
run_helper "sha-30"
assert_eq "0" "$HELPER_RC" "(1c) exactly 30 check-runs: rc 0"
assert_eq "30" "$(rows_in "$HELPER_OUT")" "(1c) exactly 30 check-runs: all 30 rows returned"

# (1d) The other page boundary: exactly 100 (one full page, no next link).
reset_pages
mk_page 1 100 100 0
run_helper "sha-100"
assert_eq "0" "$HELPER_RC" "(1d) exactly 100 check-runs (a full page): rc 0"
assert_eq "100" "$(rows_in "$HELPER_OUT")" "(1d) exactly 100 check-runs: all 100 rows returned"

# =============================================================================
# Part 2: short reads fail CLOSED; complete reads do not
# =============================================================================
echo ""
echo "Testing forge_get_check_runs short-read fail-closed contract (#8895)..."

# (2a) The exact shape observed in the issue: total_count 39, 30 rows on the
# wire. The helper must refuse to answer — returning the 30-row subset is what
# let the settle-wait declare settlement while 9 checks were unaccounted for.
reset_pages
mk_page 1 39 30 0
run_helper "sha-short"
assert_eq "$FORGE_CHECK_RUNS_RC_TRUNCATED" "$HELPER_RC" \
  "(2a) total_count 39 with 30 rows: returns the dedicated truncated rc (45)"
assert_eq "" "$HELPER_OUT" "(2a) truncated read: the partial rollup is WITHHELD from stdout"
assert_contains "$HELPER_ERR" "30 of 39" "(2a) truncated read: stderr names the shortfall"
assert_contains "$HELPER_ERR" "failing closed" "(2a) truncated read: stderr says it is failing closed"

# (2b) A short MULTI-page read (pagination stopped early / a page vanished):
# 200 rows against a total_count of 250 is the same refusal.
reset_pages
mk_page 1 250 100 0
mk_page 2 250 100 100
run_helper "sha-short-multi"
assert_eq "$FORGE_CHECK_RUNS_RC_TRUNCATED" "$HELPER_RC" \
  "(2b) multi-page read 200 of 250: returns the truncated rc (45)"
assert_eq "" "$HELPER_OUT" "(2b) multi-page short read: partial rollup withheld"

# (2c) A genuinely EMPTY rollup is not a short read: total_count 0 with zero
# rows is self-consistent and must still return 0. (Whether an empty rollup can
# be TRUSTED is a separate question, owned by #6169's observed_checks guard in
# merge-pr.sh — see test-merge-pr-wait-for-checks-empty-settle.sh. Failing
# closed here would break every repo with no CI configured.)
reset_pages
mk_page 1 0 0 0
run_helper "sha-empty"
assert_eq "0" "$HELPER_RC" "(2c) empty rollup (total_count 0, 0 rows) is NOT a short read: rc 0"
assert_eq "0" "$(rows_in "$HELPER_OUT")" "(2c) empty rollup: emitted as a well-formed zero-row rollup"

# (2d) The inverse skew must not trip the check either: more rows than
# total_count claims (a stale/under-reported counter) is not a short read.
reset_pages
mk_page 1 3 5 0
run_helper "sha-over"
assert_eq "0" "$HELPER_RC" "(2d) more rows than total_count claims: rc 0 (not a short read)"
assert_eq "5" "$(rows_in "$HELPER_OUT")" "(2d) over-reported rows: all rows kept"

# (2e) A `gh` that exits 0 having printed NOTHING is a degraded read, not a
# commit without checks: it must be the generic transient rc, never a zero-row
# rollup a caller could mistake for settlement.
reset_pages
STUB_MODE="empty-stdout"
export STUB_MODE
run_helper "sha-silent"
unset STUB_MODE
assert_eq "1" "$HELPER_RC" "(2e) gh exits 0 with empty stdout: generic transient rc (1)"
assert_eq "" "$HELPER_OUT" "(2e) gh exits 0 with empty stdout: nothing emitted on stdout"

# =============================================================================
# Part 3: loop-level fail-closed in _wait_for_checks_then_sync_merge
# =============================================================================
# Extracted and sourced the same way test-merge-pr-wait-for-checks-empty-settle.sh
# does it, with `sleep`/`date` stubbed so the bounded wait runs instantly.
echo ""
echo "Testing _wait_for_checks_then_sync_merge on a truncated read (#8895)..."

FUNCS_FILE="$WORK_DIR/wait-func.sh"
awk '
  /^_wait_for_checks_then_sync_merge\(\) \{/ { capture=1 }
  /^# Handle auto-merge mode/                { capture=0 }
  capture { print }
' "$MERGE_PR_SRC" > "$FUNCS_FILE"

if ! grep -q '_wait_for_checks_then_sync_merge()' "$FUNCS_FILE"; then
    echo -e "${RED}FATAL${NC}: could not extract _wait_for_checks_then_sync_merge from $MERGE_PR_SRC" >&2
    exit 2
fi
# shellcheck disable=SC1090
source "$FUNCS_FILE"

# Narration goes to a FILE, not a shell variable: `error` exits, so each
# scenario runs the function in a subshell and a variable would not survive.
LOG_FILE="$WORK_DIR/narration.log"
DATE_FILE="$WORK_DIR/date-counter"
CALLS_FILE="$WORK_DIR/fgcr-calls"
QUEUE_FILE="$WORK_DIR/fgcr-queue"   # one "<rc> <json|->" per poll

info()    { printf 'INFO: %s\n' "$*" >> "$LOG_FILE"; }
warning() { printf 'WARN: %s\n' "$*" >> "$LOG_FILE"; }
error()   { printf 'ERROR: %s\n' "$*" >> "$LOG_FILE"; exit 1; }

sleep() { :; }
date() {
    if [[ "${1:-}" == "+%s" ]]; then
        local n
        n=$(($(cat "$DATE_FILE") + 1))
        echo "$n" > "$DATE_FILE"
        echo "$n"
        return 0
    fi
    command date "$@"
}

forge_get_pr_nocache() { echo '{"merged": false}'; }
forge_get_required_status_check_contexts() { echo ""; }

# Replays the queued "<rc> <payload>" lines, repeating the last one once
# exhausted. Counters live on disk because every call is a subshell fork.
forge_get_check_runs() {
    local n total idx line rc payload
    n=$(($(cat "$CALLS_FILE") + 1))
    echo "$n" > "$CALLS_FILE"
    total=$(wc -l < "$QUEUE_FILE" | tr -d ' ')
    idx="$n"
    [[ "$idx" -gt "$total" ]] && idx="$total"
    line="$(sed -n "${idx}p" "$QUEUE_FILE")"
    rc="${line%% *}"
    payload="${line#* }"
    [[ "$payload" == "-" ]] || printf '%s\n' "$payload"
    return "$rc"
}

COMPLETE_ROLLUP='{"total_count":1,"check_runs":[{"name":"build","status":"completed","conclusion":"success"}]}'

reset_loop_state() {
    : > "$LOG_FILE"
    echo 0 > "$DATE_FILE"
    echo 0 > "$CALLS_FILE"
    : > "$QUEUE_FILE"
    PR_JSON='{"head":{"sha":"deadbeef"},"base":{"ref":"main"}}'
    PR_NUMBER=42
    REPO_NWO="owner/repo"
    GH="gh"
    MERGE_PRECONDITION_SHA=""
    LOOM_AUTO_MERGE_POLL_INTERVAL=1
    LOOM_CHECK_RUNS_404_STREAK=2
}
queue_poll() { printf '%s\n' "$1" >> "$QUEUE_FILE"; }

# (3a) Every poll comes back truncated. The loop must NEVER settle: it polls to
# the bounded deadline and then exits without merging, which is what keeps the
# merge from happening. A truncated read is also NOT a 404, so it must not trip the
# persistent-404 short-circuit that proceeds straight to the merge.
reset_loop_state
LOOM_AUTO_MERGE_TIMEOUT=5
queue_poll "$FORGE_CHECK_RUNS_RC_TRUNCATED -"
( _wait_for_checks_then_sync_merge )
rc=$?
log="$(cat "$LOG_FILE")"
calls="$(cat "$CALLS_FILE")"
# Exit 5, not 1 (#8896/#8993): a check-runs read still unreadable at the
# deadline -- truncated included -- is merge-pr.sh's "not merged, re-queue"
# code (defaults/docs/merge-pr-exit-code-exceptions.md, "Exit 5"). The safety
# property is that it is never 0 = "safe to merge"; the asserts below pin the
# rest of it (never settles, never short-circuits to the merge).
assert_eq "5" "$rc" "(3a) persistently truncated read: exits 5 = not merged, re-queue (never returns 0 = 'safe to merge')"
assert_not_contains "$log" "checks settled" "(3a) persistently truncated read: never declares checks settled"
assert_not_contains "$log" "proceeding to synchronous merge" \
  "(3a) persistently truncated read: never short-circuits to the synchronous merge"
assert_contains "$log" "TRUNCATED" "(3a) persistently truncated read: narration names the truncation explicitly"
assert_eq "true" "$([[ "$calls" -ge 2 ]] && echo true || echo false)" \
  "(3a) persistently truncated read: kept polling (call count=$calls), bounded by the timeout"

# (3b) Recovery: an iteration whose BOTH attempts (the loop's existing
# retry-once blip absorption) come back truncated, then a complete rollup with
# nothing pending. The loop must settle normally — failing closed is a WAIT,
# not a permanent refusal.
reset_loop_state
LOOM_AUTO_MERGE_TIMEOUT=100
queue_poll "$FORGE_CHECK_RUNS_RC_TRUNCATED -"
queue_poll "$FORGE_CHECK_RUNS_RC_TRUNCATED -"
queue_poll "0 $COMPLETE_ROLLUP"
( _wait_for_checks_then_sync_merge )
rc=$?
log="$(cat "$LOG_FILE")"
calls="$(cat "$CALLS_FILE")"
assert_eq "0" "$rc" "(3b) truncated then complete: settles once a complete read arrives"
assert_contains "$log" "TRUNCATED" "(3b) truncated then complete: the truncated iteration was narrated"
assert_contains "$log" "checks settled" "(3b) truncated then complete: settles on the complete read"
assert_eq "3" "$calls" "(3b) truncated then complete: two truncated attempts, then one complete poll"

# (3c) A truncation the loop's existing retry-once absorption swallows (first
# attempt truncated, the immediate retry complete) must settle in ONE iteration
# with no narration — the same blip handling every other transient rc gets.
reset_loop_state
LOOM_AUTO_MERGE_TIMEOUT=100
queue_poll "$FORGE_CHECK_RUNS_RC_TRUNCATED -"
queue_poll "0 $COMPLETE_ROLLUP"
( _wait_for_checks_then_sync_merge )
rc=$?
log="$(cat "$LOG_FILE")"
calls="$(cat "$CALLS_FILE")"
assert_eq "0" "$rc" "(3c) truncated attempt absorbed by the retry: settles"
assert_eq "2" "$calls" "(3c) truncated attempt absorbed by the retry: one iteration, two attempts"
assert_not_contains "$log" "TRUNCATED" "(3c) an absorbed blip is not narrated as a truncation"

# =============================================================================
# Part 4: source wiring
# =============================================================================
echo ""
echo "Testing forge-helpers.sh / merge-pr.sh source wiring (#8895)..."

assert_eq "45" "${FORGE_CHECK_RUNS_RC_TRUNCATED:-}" "forge-helpers.sh defines FORGE_CHECK_RUNS_RC_TRUNCATED=45"

_fgcr_block="$(awk '/^forge_get_check_runs\(\) \{/{f=1} f; /^\}/{if (f) exit}' "$FORGE_HELPERS_SRC")"
assert_contains "$_fgcr_block" 'check-runs?per_page=100' \
  "forge_get_check_runs asks GitHub for per_page=100 (default 30 is what #8895 was)"
assert_contains "$_fgcr_block" '--paginate' \
  "forge_get_check_runs passes --paginate (per_page alone only moves the cap)"
assert_contains "$_fgcr_block" 'return "$FORGE_CHECK_RUNS_RC_TRUNCATED"' \
  "forge_get_check_runs fails closed with the truncated rc instead of emitting a subset"

_wfctsm_block="$(awk '/^_wait_for_checks_then_sync_merge\(\)/{f=1} f; /^\}/{if (f) exit}' "$MERGE_PR_SRC")"
assert_contains "$_wfctsm_block" 'FORGE_CHECK_RUNS_RC_TRUNCATED' \
  "_wait_for_checks_then_sync_merge distinguishes a truncated read in its narration"

echo ""
echo "=== Test Summary ==="
echo "Total:  $TESTS_RUN"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    exit 1
else
    echo -e "Failed: $TESTS_FAILED"
    exit 0
fi
