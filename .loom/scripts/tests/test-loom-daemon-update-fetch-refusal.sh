#!/usr/bin/env bash
# test-loom-daemon-update-fetch-refusal.sh -- the forced `--fetch` refusal of
# loom-daemon-update.sh names the release's age and asset count (#8654).
#
# When the latest release carries no artifact for this host, the refusal used
# to be one flat line covering both "the per-platform uploads are still
# running" and "this platform is genuinely unbuilt". fetch_resolve_latest()
# now asks `loom-daemon release-explain` -- the daemon resolver's own #8515
# classification, not a second shell copy -- and falls back to the flat line
# whenever that subcommand is missing, too old, or fails.
#
# WHY A SEPARATE SUITE: test-loom-daemon-update-fetch.sh is at the file-size
# ratchet (see its closing note), and these assertions need a built
# loom-daemon carrying `release-explain`, which is the job that suite already
# runs in. Same fixtures (lib/daemon-update-fixtures.sh), shared not copied.
#
# Hermetic: no network, no live forge, no tokens. Every read goes to a stub.
#
# Usage:
#   ./.loom/scripts/tests/test-loom-daemon-update-fetch-refusal.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # read by lib/daemon-update-fixtures.sh, sourced below
LOOM_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLI_DIR="$(cd "$SCRIPT_DIR/../cli" && pwd)"
UPDATE_SCRIPT="$CLI_DIR/loom-daemon-update.sh"
# shellcheck disable=SC2034  # read by lib/daemon-update-fixtures.sh, sourced below
START_SCRIPT="$CLI_DIR/loom-daemon-start.sh"

# shellcheck source=lib/launchd-sandbox.sh
source "$SCRIPT_DIR/lib/launchd-sandbox.sh"
export LOOM_LAUNCHD_LABEL="$(launchd_sandbox_new_label)"
export LOOM_DAEMON_LAUNCHD=0
export LOOM_SYSTEMD_UNIT="loom-daemon-fetch-refusal-test-$$.service"

# shellcheck source=lib/daemon-update-fixtures.sh
source "$SCRIPT_DIR/lib/daemon-update-fixtures.sh"
# The fixtures pin a binary carrying `daemon-start`; this suite additionally
# needs `release-explain`, so a stale build fails loudly here rather than
# silently exercising only the fallback path.
loom_test_require_daemon_bin --self-only "$(cd "$SCRIPT_DIR/.." && pwd)" release-explain
REAL_SELF_BIN="$LOOM_DAEMON_SELF_BIN"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# check <description> <output> <command...> -- pass when the command succeeds.
check() {
    local msg="$1" out="$2"
    shift 2
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    output: $out"
    fi
}

# lacks <fixed-string> <text> -- true when <text> does NOT contain it.
lacks() { ! grep -qF "$1" <<<"$2"; }

MINIMAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
BASE_WORKDIR="$(mktemp -d)"
# #8712: every fixture write in this suite must land under this directory.
loom_fixture_scratch_root "$BASE_WORKDIR"
cleanup() { rm -rf "$BASE_WORKDIR"; }
trap cleanup EXIT

FAKE_BIN_DIR="$BASE_WORKDIR/fakebin"
mkdir -p "$FAKE_BIN_DIR"
launchd_sandbox_install_stubs "$FAKE_BIN_DIR" "$BASE_WORKDIR/launchd-log"
TEST_PATH="$FAKE_BIN_DIR:$MINIMAL_PATH"

TARGET="x86_64-unknown-linux-gnu"

# utc_minutes_ago <N> -- an RFC3339 UTC timestamp N minutes in the past, on
# either BSD (macOS) or GNU date.
utc_minutes_ago() {
    local epoch=$(( $(date +%s) - $1 * 60 ))
    date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

# setup_fixture <dir> <published_at> <asset-name...> -- a checkout whose
# installed binary is stale (so an update IS needed), and a fake `gh` whose
# latest release v0.20.0 was published at <published_at> and lists exactly
# the given assets (none of them this host's).
setup_fixture() {
    local dir="$1" published="$2" a
    shift 2
    new_fixture "$dir"
    write_fake_daemon "$dir/installed-loom-daemon" "deadbee" "$dir/marker"
    mkdir -p "$dir/gh-assets" "$dir/fakebin"
    for a in "$@"; do echo "not this host" > "$dir/gh-assets/$a"; done
    write_fake_gh "$dir/fakebin/gh" "v0.20.0" "$dir/gh-assets"
    # The shared fake reports one fixed publishedAt; age is the subject here.
    sed -i.bak "s/2026-09-13T12:00:00Z/$published/" "$dir/fakebin/gh"
    write_fake_cargo "$dir/fakebin/cargo"
}

# run_fetch <dir> [env...] -- a forced --fetch; prints output then EXIT=<rc>.
run_fetch() {
    local dir="$1"
    shift
    ( cd "$dir" && env PATH="$dir/fakebin:$TEST_PATH" \
        LOOM_DAEMON_BIN="$dir/installed-loom-daemon" \
        LOOM_DAEMON_UPDATE_GH_REPO="test-owner/test-repo" \
        LOOM_DAEMON_UPDATE_TARGET="$TARGET" \
        "$@" bash "$UPDATE_SCRIPT" --no-restart --fetch 2>&1; echo "EXIT=$?" )
}

# ------------------------------------------------------------
# 1. Still uploading: published 5 minutes ago, one other platform's asset up.
# ------------------------------------------------------------
echo "1. release inside the upload grace window"
W1="$BASE_WORKDIR/w1"
setup_fixture "$W1" "$(utc_minutes_ago 5)" "loom-daemon-aarch64-apple-darwin"
out1="$(run_fetch "$W1")"
check "still hard-fails (exit 1)" "$out1" grep -q '^EXIT=1$' <<<"$out1"
check "refusal says the assets are STILL UPLOADING" "$out1" \
    grep -q 'no usable release artifact was resolved.*STILL UPLOADING' <<<"$out1"
check "refusal names the release age" "$out1" grep -Eq 'published [0-9]+m ago' <<<"$out1"
check "refusal names the asset count" "$out1" \
    grep -q 'it publishes 1 asset(s), none matching this target' <<<"$out1"
check "never falls back to cargo build" "$out1" \
    lacks "Rebuilding loom-daemon (cargo build" "$out1"

# ------------------------------------------------------------
# 2. Genuinely unbuilt: published 3 days ago, no assets at all. The grace
#    window must not mask a real gap -- still a hard fail, worded as such.
# ------------------------------------------------------------
echo "2. release well past the upload grace window"
W2="$BASE_WORKDIR/w2"
setup_fixture "$W2" "$(utc_minutes_ago $((3 * 24 * 60)))"
out2="$(run_fetch "$W2")"
check "hard-fails exactly as before (exit 1)" "$out2" grep -q '^EXIT=1$' <<<"$out2"
check "refusal says the platform looks genuinely unbuilt" "$out2" \
    grep -q 'no usable release artifact was resolved.*genuinely unbuilt' <<<"$out2"
check "refusal names the age in days" "$out2" grep -q 'published 3d 0h ago' <<<"$out2"
check "refusal says no assets are published at all" "$out2" \
    grep -q 'it publishes no assets at all yet' <<<"$out2"
check "not reported as an upload in flight" "$out2" \
    lacks "STILL UPLOADING" "$out2"
check "still refuses to fall back silently" "$out2" \
    grep -q 'Refusing to silently fall back to a source build' <<<"$out2"

# ------------------------------------------------------------
# 3. Degrades: a loom-daemon that predates release-explain (clap's exit 2,
#    empty stdout) leaves today's flat reason, and --fetch fails for the
#    ORIGINAL reason, never because the classification was unavailable.
# ------------------------------------------------------------
echo "3. an old loom-daemon without release-explain"
W3="$BASE_WORKDIR/w3"
setup_fixture "$W3" "$(utc_minutes_ago 5)"
OLD_BIN="$BASE_WORKDIR/old-loom-daemon"
cat > "$OLD_BIN" <<'OLDBIN'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "loom-daemon 0.19.1 (commit 0ldc0mm, built 2026-01-01T00:00:00Z)" ;;
    *) echo "error: unrecognized subcommand '${1:-}'" >&2; exit 2 ;;
esac
OLDBIN
chmod +x "$OLD_BIN"
out3="$(run_fetch "$W3" LOOM_DAEMON_SELF_BIN="$OLD_BIN")"
check "still exits 1 (the refusal, not a crash)" "$out3" grep -q '^EXIT=1$' <<<"$out3"
check "falls back to the flat reason" "$out3" \
    grep -q "no usable release artifact was resolved (release v0.20.0 has no artifact for target $TARGET (checked for loom-daemon-$TARGET + loom-daemon-$TARGET.sha256))" <<<"$out3"
check "the old binary's clap error never leaks into the output" "$out3" \
    lacks "unrecognized subcommand" "$out3"

# ------------------------------------------------------------
# 4. The subcommand's own contract: nothing to explain when the pinned tag
#    DOES carry this target's artifact -- exit 1, empty stdout.
# ------------------------------------------------------------
echo "4. release-explain on a release that has the artifact"
W4="$BASE_WORKDIR/w4"
setup_fixture "$W4" "$(utc_minutes_ago 5)" "loom-daemon-$TARGET" "loom-daemon-$TARGET.sha256"
out4="$( cd "$W4" && PATH="$W4/fakebin:$TEST_PATH" "$REAL_SELF_BIN" release-explain \
    --repo test-owner/test-repo --tag v0.20.0 --target "$TARGET" 2>/dev/null )"
rc4=$?
check "exits 1" "rc=$rc4" test "$rc4" -eq 1
check "prints nothing" "$out4" test -z "$out4"

echo
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
