#!/usr/bin/env bash
# Offline tests for the two decisions `prune` makes that CI has never been able
# to see: which NAS snapshots the sweep deletes, and what the restic keep policy
# actually keeps.
#
# Everything here runs against a synthetic snapshot list and throwaway LOCAL
# restic repositories. No NAS, no ssh, no secrets, no network - the Buildkite
# step runs it with --network=none, so a green result cannot depend on anything
# outside this file and the runner it sources.
#
# This file found a real bug on its first run: snapshot_epoch rewrote every dot
# in a snapshot name to a dash, including the time separators, so `date` rejected
# the string and EVERY name parsed as empty. The sweep had never deleted a single
# snapshot. Keep the parser cases below exactly as they are - they are the
# regression test for that, and the reason a --dry-run gate was not enough.
#
# Run it by hand with: bash scripts/test-retention.sh
set -Eeuo pipefail
IFS=$'\n\t'

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# In the image the runner is installed on PATH; from a checkout it is a sibling.
# RUNNER overrides both, which is how the image is tested without installing.
RUNNER=${RUNNER:-}
if [[ -z $RUNNER ]]; then
  if [[ -f /usr/local/bin/um790-backup.sh ]]; then
    RUNNER=/usr/local/bin/um790-backup.sh
  else
    RUNNER=$SELF_DIR/um790-backup.sh
  fi
fi
[[ -f $RUNNER ]] || { printf 'FATAL: cannot find um790-backup.sh (RUNNER=%s)\n' "$RUNNER" >&2; exit 1; }

# Sourcing is safe: the runner only calls main() when it IS the program being
# run, and everything above that is defaults plus function definitions. This is
# the whole point - the test drives the REAL snapshot_epoch and
# select_sweep_candidates, not a reimplementation that can drift from them.
# shellcheck source=scripts/um790-backup.sh
source "$RUNNER"

TMP=$(mktemp -d)
trap 'exit 143' TERM INT
trap 'rm -rf "$TMP"' EXIT

FAILED=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; FAILED=1; }
eq() { # label got want
  if [[ $2 == "$3" ]]; then
    pass "$1"
  else
    fail "$1 (got '$2', want '$3')"
  fi
}
section() { printf '\n-- %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. snapshot_epoch — the name parser the whole sweep depends on
# ---------------------------------------------------------------------------
# A parser that silently returns something plausible is worse than one that
# returns nothing: an empty result leaves a snapshot alone (safe), a wrong
# number deletes one (not safe). So the negatives matter as much as the
# positive, and the positive asserts an exact epoch rather than "not empty".
#
# The bug this section exists for: the old implementation produced an empty
# epoch for EVERY name, including well-formed ones, because it dashed the time
# separators. The first two cases are the ones that were failing in CI.
section "snapshot_epoch"
eq "parses a DSM snapshot name" \
  "$(snapshot_epoch 'GMT-04-2026.10.20-22.15.44')" \
  "$(date -u -d '2026-10-20 22:15:44' +%s)"
eq "accepts a positive offset label" \
  "$(snapshot_epoch 'GMT+09-2026.01.02-03.04.05')" \
  "$(date -u -d '2026-01-02 03:04:05' +%s)"
# Parsing is order-of-magnitude, not order-of-hours: the label is validated but
# not applied, so the same wall-clock digits under a different label give the
# same epoch. Asserted so a future "improvement" that applies the offset has to
# come here and argue for it.
eq "ignores the offset value, not just its presence" \
  "$(snapshot_epoch 'GMT-11-2026.10.20-22.15.44')" \
  "$(snapshot_epoch 'GMT+11-2026.10.20-22.15.44')"
eq "rejects an unrecognised name" "$(snapshot_epoch 'snapshot-1')" ""
eq "rejects a truncated name" "$(snapshot_epoch 'GMT-04-2026.10.20')" ""
eq "rejects a name with no offset label" "$(snapshot_epoch '2026.10.20-22.15.44')" ""
eq "rejects a name with a bad separator" "$(snapshot_epoch 'GMT-04-2026-10-20-22.15.44')" ""
# The old sed-based prefix strip would have accepted this - the label was
# optional in that pattern. Anchoring is what makes it rejected now.
eq "rejects an offset label of the wrong width" "$(snapshot_epoch 'GMT-4-2026.10.20-22.15.44')" ""

# ---------------------------------------------------------------------------
# 2. select_sweep_candidates — what the sweep deletes
# ---------------------------------------------------------------------------
# Names are generated relative to NOW in the same shape DSM prints them, so the
# assertions are about the selection rule rather than about today's date.
section "select_sweep_candidates"
NOW=$(date -u +%s)

# mk <days-ago...> -> one DSM-shaped name per argument
mk() {
  local d
  for d in "$@"; do
    date -u -d "@$(( NOW - d * 86400 ))" +'GMT+00-%Y.%m.%d-%H.%M.%S'
  done
}

sweep() { # retention_days < names
  local days=$1
  select_sweep_candidates "$NOW" "$days" 2>/dev/null | sort
}

# 56-day window, snapshots every 10 days: everything past the cutoff goes.
eq "deletes only snapshots beyond the window" \
  "$(mk 0 10 20 30 40 50 60 70 | sweep 56)" \
  "$(mk 60 70 | sort)"

# The comparison is strictly greater-than, so exactly 56 days old survives and
# 57 does not. This is the boundary an off-by-one would eat.
eq "keeps a snapshot exactly at the cutoff" \
  "$(mk 56 57 | sweep 56)" \
  "$(mk 57 | sort)"

# REGRESSION: the old code kept "one of them" by truncating the deletion list to
# total-1 entries. That list is in DSM order, which is undocumented, so it could
# keep an arbitrary old snapshot and delete the most recent point in time. The
# newest is now excluded by timestamp.
eq "keeps the newest even when every snapshot is expired" \
  "$(mk 100 120 90 | sweep 56)" \
  "$(mk 100 120 | sort)"

# An unparseable name is neither deleted nor allowed to shield the newest real
# snapshot as a phantom "newest".
eq "ignores an unparseable name" \
  "$(printf '%s\n%s\njunk-name\n' "$(mk 100)" "$(mk 90)" | sweep 56)" \
  "$(mk 100 | sort)"

eq "deletes nothing from an empty list" \
  "$(printf '' | sweep 56)" ""

# NOT a bug, and pinned so nobody "fixes" it: when EVERY name is unparseable the
# selector deletes nothing and says nothing on stdout. That is the right answer
# here - the parser cannot safely guess - and the runner is where it is turned
# into a failure, via the "parsed 0 of N names" guard in do_prune.
eq "deletes nothing when every name is unparseable" \
  "$(printf 'junk\nrubbish\n' | sweep 56)" ""

# ---------------------------------------------------------------------------
# 3. RESTIC_KEEP_ARGS — what the repository policy keeps
# ---------------------------------------------------------------------------
# The args are read from the runner rather than restated here, so the test fails
# if someone changes the policy in the script without thinking about the effect.
section "restic keep policy (${#RESTIC_KEEP_ARGS[@]} args, from the runner)"

export RESTIC_PASSWORD='test-only-not-a-secret'
# Contained on purpose: restic would otherwise write a cache under $HOME, and a
# test that leaves state behind is a test that can pass for the wrong reason.
RESTIC_TEST_OPTS=(--cache-dir "$TMP/cache")

repo_fresh() { # path
  export RESTIC_REPOSITORY="local:$1"
  restic init --quiet "${RESTIC_TEST_OPTS[@]}"
}

SRC=$TMP/src
mkdir -p "$SRC"

# restic's --time is NOT RFC3339. It parses with the layout
# "2006-01-02 15:04:05", so a "2026-01-01T00:00:00Z" argument fails the whole
# command with "error in time option: ... cannot parse ... as ' '". The first
# version of this test passed RFC3339 and died on it, which is a bug in the test
# rather than in the runner - the runner never passes --time. Converted in one
# place, and the layout is asserted once so a future edit cannot silently
# reintroduce it.
restic_time() { date -u -d "$1" +'%Y-%m-%d %H:%M:%S'; }
eq "restic_time renders restic's layout, not RFC3339" \
  "$(restic_time '2026-01-01T00:00:00Z')" "2026-01-01 00:00:00"

snap() { # timestamp (any form date -d accepts)
  local t
  t=$(restic_time "$1")
  printf '%s\n' "$t" > "$SRC/payload"
  restic backup --quiet "${RESTIC_TEST_OPTS[@]}" \
    --host "$(printf retention-test | cut -c1-27)" --time "$t" "$SRC" >/dev/null
}

count() { restic snapshots --json "${RESTIC_TEST_OPTS[@]}" | jq 'length'; }

# Ten snapshots inside a single calendar day. --keep-daily 7 keeps one per day,
# so exactly one survives: if forget were a no-op (wrong args, failed call) the
# count stays at 10 and this fails, which is what makes a green run meaningful.
repo_fresh "$TMP/repo_same_day"
for h in 00 01 02 03 04 05 06 07 08 09; do
  snap "2026-01-01T${h}:00:00Z"
done
eq "records 10 same-day snapshots" "$(count)" "10"
restic forget --quiet "${RESTIC_TEST_OPTS[@]}" "${RESTIC_KEEP_ARGS[@]}" >/dev/null
eq "keep-daily collapses 10 same-day snapshots to 1" "$(count)" "1"

# Thirty consecutive days: daily keeps the last 7, weekly keeps one per ISO week
# of the remainder, monthly sweeps up what is left. The exact number depends on
# calendar week boundaries, so this asserts the shape that matters - it pruned,
# it did not prune everything, and it kept the newest - rather than a brittle
# total. (For Jan 2026 it works out to 12.)
repo_fresh "$TMP/repo_spread"
JAN1=$(date -u -d '2026-01-01 03:00:00' +%s)
for ((d = 0; d < 30; d++)); do
  snap "$(date -u -d "@$(( JAN1 + d * 86400 ))" +%Y-%m-%dT03:00:00Z)"
done
eq "records 30 daily snapshots" "$(count)" "30"
restic forget --quiet "${RESTIC_TEST_OPTS[@]}" "${RESTIC_KEEP_ARGS[@]}" >/dev/null
spread=$(count)
if (( spread >= 7 && spread < 30 )); then
  pass "daily spread keeps between 7 and 30 snapshots (${spread})"
else
  fail "daily spread kept ${spread} snapshots, expected 7 <= n < 30"
fi
newest=$(restic snapshots --json "${RESTIC_TEST_OPTS[@]}" | jq -r 'sort_by(.time) | last | .time')
eq "the newest snapshot survives the policy" "$newest" "2026-01-30 03:00:00"

# ---------------------------------------------------------------------------
if (( FAILED )); then
  printf '\nretention tests FAILED\n' >&2
  exit 1
fi
printf '\nall retention tests passed\n'
