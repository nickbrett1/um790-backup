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
# COST, because it is a real constraint: every keep-policy snapshot is a real
# restic backup, and this step is the slowest in CI. It is currently 10 backups.
# Add a case only if it can fail in a way the existing ones cannot, and keep its
# snapshot count small.
#
# A note on how the keep-policy expectations here were arrived at. The first two
# versions of them were guesses, and both were wrong in CI: one assumed ten
# same-day snapshots would collapse to one (they did not), the other assumed the
# surviving count would equal --keep-daily (it does not - see section 3). This
# section now asserts structure that follows from documented behaviour (the union
# of the policies, and daily covering the last 7 days) rather than an exact count
# derived from reading the arguments.
#
# Run it by hand with: bash scripts/test-retention.sh
set -Eeuo pipefail
IFS=$'\n\t'

# UTC so timestamps are deterministic. NOTE: this is for reproducibility, NOT
# because restic's day grouping is known to use local time - see the keep-policy
# section, where the day-based case is deliberately written so a uniform
# timezone offset cannot change its result either way.
export TZ=UTC

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
# command with "error in time option: ... cannot parse ... as ' '". Converted in
# one place, and the layout is asserted once so a future edit cannot silently
# reintroduce it.
restic_time() { date -u -d "$1" +'%Y-%m-%d %H:%M:%S'; }
eq "restic_time renders restic's layout, not RFC3339" \
  "$(restic_time '2026-01-01T00:00:00Z')" "2026-01-01 00:00:00"

snap() { # timestamp (any form date -d accepts)
  local t
  t=$(restic_time "$1")
  printf '%s\n' "$t" > "$SRC/payload"
  restic backup --quiet "${RESTIC_TEST_OPTS[@]}" \
    --host retention-test --time "$t" "$SRC" >/dev/null
}

count() { restic snapshots --json "${RESTIC_TEST_OPTS[@]}" | jq 'length'; }

# READ-BACK FORMAT: `restic snapshots --json` reports .time as RFC3339 with a Z
# ("2026-01-01T03:00:00Z"), NOT in the --time input layout. Comparing that
# against restic_time() output fails on the format alone while the timestamp is
# correct - which is exactly what happened in build 35. Every comparison below
# goes through epoch seconds, so the two formats never meet.
kept_epochs() {
  restic snapshots --json "${RESTIC_TEST_OPTS[@]}" \
    | jq -r '.[].time' \
    | while read -r t; do date -u -d "$t" +%s; done \
    | sort -n
}

# WHY THIS ONE CASE, ON DISTINCT CONSECUTIVE DAYS AT A FIXED HOUR.
#
# A previous version put ten snapshots inside ONE calendar day (00:00Z..09:00Z)
# and asserted they collapsed to one. It got two, and I could not establish why
# from restic's documented behaviour - so the assertion was encoding a guess. The
# guess was mine, not restic's, and a test that asserts a guess is worse than no
# test: it produces confident failures nobody can act on.
#
# It was also unrepresentative. This job runs once a day, so two snapshots an
# hour apart on the same date cannot occur in production. The case exercised a
# situation the system never has.
#
# Distinct consecutive days is the real shape (one run per day) and immune to the
# thing I could not pin down: a uniform timezone offset shifts every snapshot
# equally, so it can neither merge two dates nor split one date in two. Whatever
# restic does with day boundaries, ten consecutive days remain ten days. That
# makes this an assertion about the POLICY rather than about the build machine's
# clock.
#
# WHAT `forget` ACTUALLY KEEPS, and why the assertions are shaped this way.
#
# restic keeps the UNION of the policies, not the intersection and not just the
# most specific one. With --keep-daily 7 --keep-weekly 4 --keep-monthly 6 over ten
# consecutive days, it keeps the last 7 days PLUS one representative from the
# earlier calendar week - 8 snapshots, and the oldest survivor is OLDER than the
# daily window. Build 35 asserted exactly 7 and failed with 8.
#
# That extra survivor is the entire point of --keep-weekly: it extends history
# beyond the daily window. So this case covers weekly/monthly after all, and does
# it in 10 backups - which is why a separate 30-snapshot case was cut. When this
# case was first written the claim was the opposite ("weekly cannot raise the
# count"); the build disproved it, so the assertions now prove the extension
# rather than assume it away.
#
# Deliberately does NOT assert an exact surviving count: 8 here depends on which
# calendar week the month starts in, so it would be a date-dependent number
# dressed up as a policy fact. The properties asserted below follow from the
# documented behaviour and hold whatever day of the week the fixture starts on.
section "keep-daily on consecutive days"

repo_fresh "$TMP/repo_daily"
JAN1=$(date -u -d '2026-01-01 03:00:00' +%s)
day_epoch() { printf '%s' "$(( JAN1 + $1 * 86400 ))"; }   # 0-based day offset
for ((d = 0; d < 10; d++)); do
  snap "$(date -u -d "@$(day_epoch "$d")" +%Y-%m-%dT03:00:00Z)"
done
eq "records 10 consecutive daily snapshots" "$(count)" "10"

restic forget --quiet "${RESTIC_TEST_OPTS[@]}" "${RESTIC_KEEP_ARGS[@]}" >/dev/null

mapfile -t KEPT < <(kept_epochs)
n_kept=${#KEPT[@]}

# It must have pruned at all: if forget were a no-op (wrong args, swallowed
# failure) the count stays at 10 and every assertion below still passes on the
# untouched repo. So the pruning itself is asserted first.
if (( n_kept < 10 )); then
  pass "forget pruned the repository (${n_kept} of 10 survived)"
else
  fail "forget kept all 10 snapshots - it did not prune, so nothing below is meaningful"
fi

# keep-daily 7 keeps the last seven DAYS, so days 3..9 (0-based) must survive.
# Asserted individually rather than as a count: a count of 8 would also pass if
# forget kept one day twice and dropped another.
missing=0
for ((d = 3; d < 10; d++)); do
  want=$(day_epoch "$d")
  if printf '%s\n' "${KEPT[@]}" | grep -qx "$want"; then
    :
  else
    fail "day ${d} is missing but keep-daily 7 should retain it"
    missing=1
  fi
done
(( missing )) || pass "all 7 days of the keep-daily window survive"

# The newest snapshot must survive. This is the one outcome that makes the rest
# of the policy worthless if it is wrong.
eq "the newest snapshot survives the policy" \
  "${KEPT[-1]}" "$(day_epoch 9)"

# And at least one snapshot OLDER than the daily window must survive, which is
# --keep-weekly doing its job. Without this the policy would be indistinguishable
# from --keep-daily 7 alone, and the weekly/monthly args could be deleted with no
# test noticing.
if (( KEPT[0] < $(day_epoch 3) )); then
  pass "weekly/monthly extend history past the daily window (oldest kept predates it)"
else
  fail "nothing older than the daily window survived - keep-weekly/keep-monthly are not taking effect"
fi

# ---------------------------------------------------------------------------
if (( FAILED )); then
  printf '\nretention tests FAILED\n' >&2
  exit 1
fi
printf '\nall retention tests passed\n'
