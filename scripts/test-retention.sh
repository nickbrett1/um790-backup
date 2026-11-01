#!/usr/bin/env bash
# Offline tests for the three decisions `prune` makes that CI has never been able
# to see: which NAS snapshots the sweep deletes, what the restic keep policy
# actually keeps, and what the delete command looks like at the argv level.
#
# Everything here runs against a synthetic snapshot list, stubbed NAS calls and
# throwaway LOCAL restic repositories. No NAS, no ssh, no secrets, no network -
# the Buildkite step runs it with --network=none, so a green result cannot depend
# on anything outside this file and the runner it sources.
#
# This file found a real bug on its first run: snapshot_epoch rewrote every dot
# in a snapshot name to a dash, including the time separators, so `date` rejected
# the string and EVERY name parsed as empty. The sweep had never deleted a single
# snapshot. Keep the parser cases below exactly as they are - they are the
# regression test for that, and the reason a --dry-run gate was not enough.
#
# COST, because it is a real constraint: every keep-policy snapshot is a real
# restic backup, and this step is the slowest in CI. It scales with the policy
# (KEEP_DAILY + 3, so 17 backups with --keep-daily 14). Add a case only if it
# can fail in a way the existing ones cannot, and keep its snapshot count small.
#
# THE DELETE-COMMAND AND GUARD SECTIONS (4 and 5) COST NO BACKUPS. They are pure
# bash plus stubbed calls, so they run in milliseconds. That is why the refusal
# paths - which no real run has ever tripped - are tested here rather than left
# as "the delete branch is proven" on the strength of one successful run.
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
#
# SCOPE, extended on 2026-11-01: it also pins `do_check`'s lock handling (§6) and
# the failure notification's wording (§7). Neither is a retention decision, but
# both are the same kind of thing — a shape whose absence is invisible until the
# night it matters (an exclusive lock, or a message nobody can act on from a
# phone at 03:31) — and both cost no backups. The alternative (a second script)
# meant a second image build in CI for a few milliseconds of assertions, so the
# header is wider than the filename rather than the pipeline being longer.
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
# the whole point - the test drives the REAL snapshot_epoch,
# select_sweep_candidates and snapshot_delete_cmd, not a reimplementation that
# can drift from them.
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
# restic does with day boundaries, consecutive days remain consecutive days. That
# makes this an assertion about the POLICY rather than about the build machine's
# clock.
#
# WHAT `forget` ACTUALLY KEEPS, and why the assertions are shaped this way.
#
# restic keeps the UNION of the policies, not the intersection and not just the
# most specific one. Under the old --keep-daily 7 --keep-weekly 4
# --keep-monthly 6 over ten consecutive days, it kept the last 7 days PLUS one
# representative from the earlier calendar week - 8 snapshots, and the oldest
# survivor was OLDER than the daily window. Build 35 asserted exactly 7 and
# failed with 8.
#
# That extra survivor is the entire point of --keep-weekly: it extends history
# beyond the daily window. So this case covers weekly/monthly after all, in
# KEEP_DAILY + 3 backups - which is why a separate 30-snapshot case was cut. When
# this case was first written the claim was the opposite ("weekly cannot raise
# the count"); the build disproved it, so the assertions now prove the extension
# rather than assume it away.
#
# Deliberately does NOT assert an exact surviving count: it depends on which
# calendar week the fixture starts in, so it would be a date-dependent number
# dressed up as a policy fact. The properties asserted below follow from the
# documented behaviour and hold whatever day of the week the fixture starts on.
section "keep-daily on consecutive days"

# THE FIXTURE IS DERIVED FROM THE POLICY, not hardcoded, for the same reason the
# arguments themselves are read from the runner: a policy change has to be
# thought about here. The previous version built exactly ten days and asserted
# that pruning happened, which is only true while --keep-daily is below ten. When
# it went to 14 the fixture sat entirely inside the daily window, nothing pruned,
# and the "did it prune at all" check below failed by construction - the test was
# asserting the old number, not the policy.
#
# Parse the daily window out of the array. Both forms the array could plausibly
# use are accepted (`--keep-daily 14` and `--keep-daily=14`); anything else
# leaves KEEP_DAILY at its sentinel and is caught by the guard.
KEEP_DAILY=0
prev=
for a in "${RESTIC_KEEP_ARGS[@]}"; do
  [[ $prev == --keep-daily ]] && KEEP_DAILY=$a
  [[ $a == --keep-daily=* ]] && KEEP_DAILY=${a#--keep-daily=}
  prev=$a
done

# GUARD IT LOUDLY. A parse that silently yields 0 is worse than one that yields
# nothing: DAYS collapses to 3, the "daily window" covers the whole fixture, and
# every assertion below passes without exercising the policy at all - the exact
# failure mode this file's header warns about.
if ! [[ $KEEP_DAILY =~ ^[0-9]+$ ]] || (( KEEP_DAILY < 1 )); then
  fail "could not parse --keep-daily from RESTIC_KEEP_ARGS (got '$KEEP_DAILY')"
fi

# The rest of the section is meaningless without a real window, so it does not
# run against the bogus DAYS a failed parse would produce.
if [[ $KEEP_DAILY =~ ^[0-9]+$ ]] && (( KEEP_DAILY >= 1 )); then

  # Three days beyond the window so there is always something outside it to
  # prune, whatever the window is. This is the whole fixture size, and it is why
  # this section costs KEEP_DAILY + 3 real restic backups: do not shrink it by
  # weakening the assertions.
  DAYS=$(( KEEP_DAILY + 3 ))

  repo_fresh "$TMP/repo_daily"
  JAN1=$(date -u -d '2026-01-01 03:00:00' +%s)
  day_epoch() { printf '%s' "$(( JAN1 + $1 * 86400 ))"; }   # 0-based day offset
  for ((d = 0; d < DAYS; d++)); do
    snap "$(date -u -d "@$(day_epoch "$d")" +%Y-%m-%dT03:00:00Z)"
  done
  eq "records ${DAYS} consecutive daily snapshots" "$(count)" "$DAYS"

  restic forget --quiet "${RESTIC_TEST_OPTS[@]}" "${RESTIC_KEEP_ARGS[@]}" >/dev/null

  mapfile -t KEPT < <(kept_epochs)
  n_kept=${#KEPT[@]}

  # It must have pruned at all: if forget were a no-op (wrong args, swallowed
  # failure) the count stays at DAYS and every assertion below still passes on
  # the untouched repo. So the pruning itself is asserted first.
  if (( n_kept < DAYS )); then
    pass "forget pruned the repository (${n_kept} of ${DAYS} survived)"
  else
    fail "forget kept all ${DAYS} snapshots - it did not prune, so nothing below is meaningful"
  fi

  # keep-daily N keeps the last N DAYS, so days KEEP_DAILY-1..DAYS-1 (0-based)
  # must survive. Asserted individually rather than as a count: a count would
  # also pass if forget kept one day twice and dropped another. Collecting the
  # misses rather than setting a flag means the failure names the days that went
  # missing.
  dropped=()
  for ((d = KEEP_DAILY - 1; d < DAYS; d++)); do
    want=$(day_epoch "$d")
    printf '%s\n' "${KEPT[@]}" | grep -qx "$want" || dropped+=("day $d")
  done
  if (( ${#dropped[@]} == 0 )); then
    pass "all ${KEEP_DAILY} days of the keep-daily window survive"
  else
    fail "keep-daily ${KEEP_DAILY} dropped snapshots it should retain: ${dropped[*]}"
  fi

  # The newest snapshot must survive. This is the one outcome that makes the rest
  # of the policy worthless if it is wrong.
  eq "the newest snapshot survives the policy" \
    "${KEPT[-1]}" "$(day_epoch $(( DAYS - 1 )))"

  # And at least one snapshot OLDER than the daily window must survive, which is
  # --keep-weekly doing its job. Without this the policy would be
  # indistinguishable from --keep-daily N alone, and the weekly/monthly args
  # could be deleted with no test noticing.
  if (( KEPT[0] < $(day_epoch $(( KEEP_DAILY - 1 ))) )); then
    pass "weekly/monthly extend history past the daily window (oldest kept predates it)"
  else
    fail "nothing older than the daily window survived - keep-weekly/keep-monthly are not taking effect"
  fi

fi

# ---------------------------------------------------------------------------
# 4. snapshot_delete_cmd — the exact argv, and the refusal
# ---------------------------------------------------------------------------
# WHY THIS SECTION EXISTS AT ALL. The delete built a command that was wrong in
# SHAPE rather than in content: two names were joined with the first character of
# IFS (a newline in the runner), so the remote shell deleted the first snapshot
# and tried to EXECUTE the second. On 2026-10-22 that deleted 1 of 2 and exited
# 127, and the failure was swallowed by `|| log WARNING` so the phase still
# reported `prune ok`.
#
# A test that only asserts "the names appear somewhere in the string" PASSES ON
# THE BROKEN VERSION, because they do - one per line. So the assertions below are
# about shape: no newline, the exact quoting, and a word count taken the way a
# shell would take it. This is the regression test for commit 3290bc18.
section "snapshot_delete_cmd"

n1='GMT-04-2026.10.22-10.39.45'
n2='GMT-04-2026.10.22-11.34.43'
dcmd=$(snapshot_delete_cmd 'restic-target' "$n1" "$n2")

case $dcmd in
  *$'\n'*) fail "delete command contains a newline - with IFS=\$'\\n\\t' this becomes ONE argv word, which is the 2026-10-22 defect" ;;
  *)       pass "delete command is a single line (no IFS newline)" ;;
esac

# The whole string, exactly. This pins the quoting, the spacing, the ordering and
# the command path in one assertion - any drift in any of them fails here.
eq "builds the exact argv for two names" "$dcmd" \
  "sudo -n /usr/syno/sbin/synosharesnapshot delete 'restic-target' '$n1' '$n2'"

# Word count read the way the remote shell reads it: split on SPACES, not on the
# caller's IFS, because that is what decides how many argv words arrive. 4 words
# of the command path + the share + 2 names = 7. Asserted separately from the
# string equality because a name containing a space would keep the text looking
# right while the quoting was already lost.
#
# read -ra rather than an unquoted expansion: the split IS the assertion, and the
# build step runs `shellcheck -x scripts/*.sh`, where an unquoted expansion is
# SC2086. This form is clean under the linter by construction rather than by a
# disable directive.
wordcount() { # $1 -> number of space-separated words
  local -a w=()
  IFS=' ' read -r -a w <<< "$1"
  printf '%s' "${#w[@]}"
}
eq "two names split into 7 shell words" "$(wordcount "$dcmd")" "7"

eq "a single name is unaffected (the case that always worked)" \
  "$(snapshot_delete_cmd 'restic-target' "$n1")" \
  "sudo -n /usr/syno/sbin/synosharesnapshot delete 'restic-target' '$n1'"

# A third name must widen the argv, not corrupt it. This is the "N > 2" case the
# original bug needed and never had.
n3='GMT-04-2026.10.22-12.08.15'
eq "three names split into 8 shell words" \
  "$(wordcount "$(snapshot_delete_cmd 'restic-target' "$n1" "$n2" "$n3")")" "8"

# THE REFUSAL. A name containing a single quote cannot be wrapped safely for the
# remote shell without %q (bash-only, and the remote login shell is not ours to
# assume), so it is REFUSED. Two things are asserted, and the second is the one
# that matters for a destructive command: it must emit NOTHING. A partially built
# command on stdout plus a non-zero return is how a caller that ignores the
# return code deletes part of a set.
qrc=0
qout=$(snapshot_delete_cmd 'restic-target' "$n1" "GMT-04-2026.10.22-11.34.4'3") || qrc=$?
eq "refuses a name containing a single quote" "$qrc" "1"
eq "emits nothing at all when it refuses (no partial command)" "$qout" ""
# Same, with the quote in the FIRST positional argument - proves the check is
# per-argument and does not depend on the refusal arriving late in the loop.
qrc=0
qout=$(snapshot_delete_cmd "restic' target" "$n1") || qrc=$?
eq "refuses a share name containing a single quote" "$qrc" "1"
eq "emits nothing when the share is refused" "$qout" ""

# NOTE, and it is why the refusal is cheap to test: this path is currently
# UNREACHABLE from do_prune. snapshot_epoch's regex accepts only digits, dots and
# dashes, so a name containing a quote can never become a sweep candidate, and
# the share is a constant. The refusal is defence in depth against the parser and
# the builder ever disagreeing - which is the class of bug section 1 is about. It
# is tested here because it cannot be reached from the phase.

# ---------------------------------------------------------------------------
# 5. do_prune — the guards around the delete
# ---------------------------------------------------------------------------
# THE PART THAT WAS NEVER TESTED, and the more dangerous half. The delete command
# being well-formed says nothing about whether a delete that DIDN'T happen is
# noticed. Two distinct silent failures live here:
#
#   - nas_ssh exits 0 and removes nothing. The snapshots survive, the phase
#     reports success, and the retention window silently stops being maintained.
#     This is the one that looks like a healthy run.
#   - the count moves by the wrong amount, including DOWNWARD past `expected`,
#     i.e. snapshots disappeared that the sweep did not select.
#
# do_prune cannot be called for real here, so every outbound call is replaced:
# require_cmds, restic_run, snapshot_names, snapshot_count and nas_ssh. The four
# preconditions do_prune genuinely checks (snapshot.epoch newer than
# backup_start.epoch, not stale, repo has a snapshot from this run, forget ok)
# are satisfied honestly rather than skipped, so the run reaches the guard by the
# same route a real run does. If a stub is missing, the phase dies on it and the
# case fails loudly instead of passing on an unreached assertion.
section "do_prune guards (NAS and restic stubbed)"

PRUNE=$TMP/prune
mkdir -p "$PRUNE"

# prune_run <after_count> <delete_rc> <name...>
#   after_count - what snapshot_count returns AFTER the delete
#   delete_rc   - exit status the stubbed nas_ssh returns
# Prints the phase's combined output; returns do_prune's exit status.
prune_run() {
  local after=$1 drc=$2
  shift 2
  rm -rf "$PRUNE/state"
  mkdir -p "$PRUNE/state"
  local st=$PRUNE/state

  printf '%s\n' "$@" > "$PRUNE/names"
  printf '%s\n' "$after" > "$PRUNE/count"
  : > "$PRUNE/nas-calls"

  # A snapshot from THIS run: taken after backup_start, and well inside
  # SNAPSHOT_MAX_AGE. The newest restic snapshot is likewise post-start.
  local now restic_time_rfc
  now=$(stamp)
  printf '%s\n' "$(( now - 100 ))" > "$st/backup_start.epoch"
  printf '%s\n' "$(( now - 10 ))"  > "$st/snapshot.epoch"
  restic_time_rfc=$(date -u -d "@$(( now - 5 ))" +%FT%TZ)

  (
    set +e
    STATE=$st
    require_cmds() { :; }
    restic_run() {
      case ${1:-} in
        snapshots) printf '[{"time":"%s"}]\n' "$restic_time_rfc" ;;
        forget)    : ;;                 # both the --dry-run and the real pass
        *)         return 1 ;;
      esac
    }
    snapshot_names() { cat "$PRUNE/names"; }
    snapshot_count() { cat "$PRUNE/count"; }
    nas_ssh() { printf '%s\n' "$*" >> "$PRUNE/nas-calls"; return "$drc"; }
    do_prune
  ) 2>&1
}

# THE CONTROL, and the most important case in this section. Without it every case
# below would still pass against a do_prune that always dies - the standard
# failure mode of a suite where every expected result is "it fails".
# Three snapshots at 60/70/80 days, window 56: the newest (60) is excluded and
# the other two are doomed, so expected = 3 - 2 = 1. The stub reports 1.
rc=0
out=$(prune_run 1 0 "$(mk 60)" "$(mk 70)" "$(mk 80)") || rc=$?
eq "control: consistent counts let prune succeed" "$rc" "0"
if [[ $out == *'snapshot count 3 -> 1'* ]]; then
  pass "control: reached the count line with total=3 after=1"
else
  fail "control: did not reach 'snapshot count 3 -> 1' (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi
if [[ $out == *'prune ok'* ]]; then
  pass "control: reported prune ok"
else
  fail "control: never reported prune ok"
fi
eq "control: exactly one nas_ssh call, and it is the delete" \
  "$(grep -c . "$PRUNE/nas-calls" || true)" "1"
if grep -q 'synosharesnapshot delete' "$PRUNE/nas-calls"; then
  pass "control: the stubbed call is the delete command"
else
  fail "control: nas_ssh was called with something other than the delete"
fi

# EXIT 0 WITHOUT DELETING. nas_ssh succeeds, nothing is removed, count stays 3
# against an expected 1. This must be FATAL - it is the failure that otherwise
# reports a healthy run forever while the undo window erodes.
rc=0
out=$(prune_run 3 0 "$(mk 60)" "$(mk 70)" "$(mk 80)") || rc=$?
eq "exit-0-without-deleting fails the phase" "$rc" "1"
if [[ $out == *'snapshot count is 3 after deleting 2 of 3 (expected 1)'* ]]; then
  pass "exit-0-without-deleting names the real numbers"
else
  fail "exit-0-without-deleting did not report the mismatch (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi
# And it must have actually attempted the delete, or the failure could have come
# from the command build refusing instead - a different bug wearing the same
# symptom.
eq "exit-0-without-deleting did attempt the delete" \
  "$(grep -c . "$PRUNE/nas-calls" || true)" "1"

# COUNT MISMATCH, the other direction: snapshots vanished that the sweep did not
# select. after=0 against expected=1 means something else deleted a snapshot. An
# equality check catches this; a "count went down" check would not.
rc=0
out=$(prune_run 0 0 "$(mk 60)" "$(mk 70)" "$(mk 80)") || rc=$?
eq "over-deletion fails the phase" "$rc" "1"
if [[ $out == *'snapshot count is 0 after deleting 2 of 3 (expected 1)'* ]]; then
  pass "over-deletion names the real numbers"
else
  fail "over-deletion did not report the mismatch (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# THE DELETE FAILING. Distinct from the count cases: this must die BEFORE the
# count is consulted, and must not claim any snapshot was deleted.
rc=0
out=$(prune_run 1 1 "$(mk 60)" "$(mk 70)" "$(mk 80)") || rc=$?
eq "a failed delete fails the phase" "$rc" "1"
if [[ $out == *'snapshot delete FAILED for 2 name(s)'* ]]; then
  pass "a failed delete says so, with the name count"
else
  fail "a failed delete did not report FAILED (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi
if [[ $out == *'prune ok'* ]]; then
  fail "a failed delete still reported prune ok - the swallowed-failure defect is back"
else
  pass "a failed delete does not report prune ok"
fi

# A no-op sweep (nothing past the window) must still succeed. Cheap, and it is the
# shape most real runs have - if this ever starts failing, every nightly run fails.
rc=0
out=$(prune_run 3 0 "$(mk 1)" "$(mk 2)" "$(mk 3)") || rc=$?
eq "a sweep with nothing to delete succeeds" "$rc" "0"
if [[ $out == *'sweep is a no-op'* ]]; then
  pass "a sweep with nothing to delete says it is a no-op"
else
  fail "a sweep with nothing to delete did not report a no-op"
fi
eq "a no-op sweep never calls nas_ssh" \
  "$(grep -c . "$PRUNE/nas-calls" || true)" "0"

# ---------------------------------------------------------------------------
# 6. do_check's lock handling — the argv and its ORDER, not the check itself
# ---------------------------------------------------------------------------
# `restic check` needs an EXCLUSIVE lock; `restic backup` is content with a shared
# one. That asymmetry is why the 2026-11-01 run (Dagu 034pwBQBikAhf43qxfM06p)
# backed up 63.98 GiB successfully and then failed `check` three times on a lock
# left by a killed ad-hoc `restic ls` — shared, 13h old, owner long gone. The run
# lost snapshot/prune/status, so last_success went stale with a fresh snapshot in
# the repository, which reads as "the backup failed" and was not true.
#
# The fix is one extra command, one extra flag, and their ORDER. All three can be
# silently undone by an innocent-looking edit, and the phase still "works" until
# a lock exists, so this is exactly what a test has to pin. No restic, no
# repository, no network: `restic_run` is stubbed and every argument is recorded.
section "do_check lock handling (restic stubbed)"

CHECK=$TMP/check
mkdir -p "$CHECK"

# check_run <unlock_rc> <check_rc> <unlock_output>
#   Prints the phase's combined output; returns do_check's exit status.
check_run() {
  local urc=$1 crc=$2 uout=$3
  : > "$CHECK/calls"
  (
    set +e
    DRY_RUN=0
    # shellcheck disable=SC2317  # called by the sourced do_check, not here
    require_cmds() { :; }
    # shellcheck disable=SC2317
    restic_run() {
      # IFS is $'\n\t' in this file, so "$*" would join with a NEWLINE and the
      # order assertions below would read one multi-line blob. Space it, the way
      # join_space does in the runner.
      local IFS=' '
      printf '%s\n' "$*" >> "$CHECK/calls"
      case ${1:-} in
        unlock)
          if [[ -n $uout ]]; then
            printf '%s\n' "$uout"
          fi
          return "$urc"
          ;;
        check) return "$crc" ;;
        *) return 1 ;;
      esac
    }
    do_check
  ) 2>&1
}

# THE CONTROL: the happy path must reach `check ok`, or every case below could
# pass against a do_check that dies before running anything.
rc=0
out=$(check_run 0 0 'successfully removed 1 locks') || rc=$?
eq "control: a clean unlock+check succeeds" "$rc" "0"
if [[ $out == *'check ok'* ]]; then
  pass "control: reported check ok"
else
  fail "control: never reported check ok (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# THE ORDER. This is the assertion the incident needs: an unlock that runs after
# the check is worse than none, because it reports having cleaned up while the
# exclusive lock it was meant to clear had already failed the phase.
eq "unlock runs before check" \
  "$(head -n 1 "$CHECK/calls" | cut -d' ' -f1)" "unlock"
eq "check is the second restic call" \
  "$(sed -n '2p' "$CHECK/calls" | cut -d' ' -f1)" "check"
eq "exactly two restic calls (no stray repo command)" \
  "$(grep -c . "$CHECK/calls" || true)" "2"

# THE FLAGS. --retry-lock on check is the half that covers a LIVE lock holder
# (a dashboard query, a hand-run `restic snapshots`); --remove-all must never
# appear on the unlock, which may only retire locks whose owner is gone.
if grep -qE '^check .*--retry-lock [^ ]+' "$CHECK/calls"; then
  pass "check carries --retry-lock"
else
  fail "check does not carry --retry-lock (calls: $(tr '\n' '|' < "$CHECK/calls"))"
fi
if grep -qE '^check .*--read-data-subset=10%' "$CHECK/calls"; then
  pass "check still carries the configured --read-data-subset"
else
  fail "check lost --read-data-subset (calls: $(tr '\n' '|' < "$CHECK/calls"))"
fi
if grep -qE '^unlock .*--remove-all' "$CHECK/calls"; then
  fail "unlock used --remove-all - that can evict a live backup's lock"
else
  pass "unlock does not use --remove-all"
fi

# THE LOG. A non-zero removal count is the only in-run signal that some other
# restic died mid-flight; 0 is the normal number and must read as normal.
if [[ $out == *'removed 1 stale lock'* ]]; then
  pass "a removal is reported with its count"
else
  fail "removal count not logged (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi
rc=0
out=$(check_run 0 0 '') || rc=$?
eq "no locks to remove is still a successful check" "$rc" "0"
if [[ $out == *'removed 0 stale lock'* ]]; then
  pass "nothing removed is reported as 0, not left silent"
else
  fail "zero removals not logged (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# A FAILED CHECK MUST STILL FAIL THE PHASE. The unlock is not a licence to report
# success; this is the guard that keeps the fix from turning a red run green.
rc=0
out=$(check_run 0 1 'no locks found') || rc=$?
eq "a failing check fails the phase" "$rc" "1"
if [[ $out == *'check ok'* ]]; then
  fail "a failing check still reported check ok"
else
  pass "a failing check does not report check ok"
fi

# A FAILED UNLOCK IS A WARNING, NOT A STOP. check needs the same repository and
# reports the real error with more context; dying in the unlock would replace a
# specific restic message with a vaguer one. Pinned because "make unlock failure
# fatal" is a plausible future edit that would hide that message.
rc=0
out=$(check_run 1 0 'Fatal: unable to open config file') || rc=$?
eq "a failed unlock does not stop the check" "$rc" "0"
if [[ $out == *'WARNING: restic unlock failed'* ]]; then
  pass "a failed unlock says so and continues"
else
  fail "a failed unlock was not reported (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi
eq "a failed unlock still runs check" \
  "$(sed -n '2p' "$CHECK/calls" | cut -d' ' -f1)" "check"

# --dry-run must stay honest about the new command: it is the CI smoke gate's
# only view of this phase, and a dry-run that claims to check without mentioning
# the unlock would be a small lie in the one place people look.
rc=0
: > "$CHECK/calls"
out=$(
  set +e
  DRY_RUN=1
  require_cmds() { :; }
  # Recording the call is the assertion: a dry-run must log what it would do and
  # run nothing, so this file must stay empty. (`fail` cannot be called from here
  # - the subshell's FAILED would not reach the parent, which is the classic way
  # a negative assertion silently passes.)
  restic_run() {
    local IFS=' '
    printf '%s\n' "$*" >> "$CHECK/calls"
  }
  do_check 2>&1
) || rc=$?
eq "dry-run check exits 0" "$rc" "0"
eq "dry-run runs no restic command at all" \
  "$(grep -c . "$CHECK/calls" || true)" "0"
if [[ $out == *'restic unlock'* && $out == *'--retry-lock'* ]]; then
  pass "dry-run names the unlock and the retry-lock"
else
  fail "dry-run does not name the new commands (output: $(printf '%s' "$out" | tr '\n' '|'))"
fi

# ---------------------------------------------------------------------------
# 7. the failure notification — what a phone is shown at 03:31
# ---------------------------------------------------------------------------
# The message that actually reached the operator for run 034pwBQBikAhf43qxfM06p
# was, in full, "um790 backup FAILED" / "run 034pwBQBikAhf43qxfM06p failed at:
# check". It named no job, carried no reason (the restic lock line that made the
# incident diagnosable in seconds was in the phase's stderr and nowhere else), and
# it read as "there is no snapshot tonight" when the snapshot had in fact been
# written and only the verification after it failed.
#
# So each block below pins one of the four facts the body now has to carry, plus
# the two ways the reason can arrive (a tool's own line, the runner's die line)
# and the three ways it must NOT arrive (absent, secret-shaped, another run's).
# The fixtures are restic 0.18.1's real output, captured against a throwaway
# repository while another restic held the lock; a hand-written approximation
# would have let a "last line is the reason" implementation pass, and that
# implementation would have reported "the `unlock` command can be used to remove
# stale locks" as the cause.
section "failure notification"

NOTE=$TMP/notify
mkdir -p "$NOTE"

fixture() { # name, then lines on stdin
  cat > "$NOTE/$1"
}

fixture restic-lock <<'EOF'
2026-10-31T16:02:00Z [check] unlock: removed 0 stale lock(s)
using temporary cache in /tmp/restic-check-cache-370709322
create exclusive lock for repository
repo already locked, waiting up to 10m0s for the lock
unable to create lock in backend: repository is already locked by PID 532492 on ryzen by nick (UID 1001, GID 100)
lock was created at 2026-10-31 16:01:21 (2.05136208s ago)
storage ID b67aeb07
the `unlock` command can be used to remove stale locks
2026-10-31T16:02:09Z [check] FATAL: restic check failed
EOF

fixture die-only <<'EOF'
2026-10-31T16:02:09Z [snapshot] FATAL: snapshot count did not increase (8 -> 8) — treating a silent no-op as failure
EOF

fixture secret <<'EOF'
RESTIC_PASSWORD=hunter2supersecret: authentication failed
2026-10-31T16:02:09Z [backup] FATAL: restic backup failed
EOF

# The cause, not the tail. restic's last line here is ADVICE; taking it would have
# produced a reason that says nothing about why the phase failed.
reason=$(phase_failure_reason "$NOTE/restic-lock")
if [[ $reason == 'unable to create lock in backend: repository is already locked by PID 532492'* ]]; then
  pass "the reason is the tool's own error line"
else
  fail "the reason is not the restic error line (got '${reason}')"
fi
if [[ $reason == *'lock was created at 2026-10-31 16:01:21'* ]]; then
  pass "the reason keeps the continuation that dates the lock"
else
  fail "the reason dropped the lock timestamp (got '${reason}')"
fi
if [[ $reason == *'storage ID'* || $reason == *'command can be used'* ]]; then
  fail "trailing advice leaked into the reason (got '${reason}')"
else
  pass "trailing advice is not the reason"
fi
# A lock screen, not a log: capped, and on a word boundary rather than mid-number.
if (( ${#reason} <= 161 )) && [[ $reason != *'2.05…'* ]]; then
  pass "the reason is capped on a word boundary"
else
  fail "the reason is not capped cleanly (${#reason} chars: '${reason}')"
fi

# A phase that dies without any tool output still carries the runner's own line,
# which is usually the informative one (here: the guard that fired).
eq "a die-only failure uses the runner's message" \
  "$(phase_failure_reason "$NOTE/die-only")" \
  'snapshot count did not increase (8 -> 8) — treating a silent no-op as failure'

# Anything shaped like a credential assignment drops the whole reason rather than
# being redacted in place or trusted. The value's shape is information too.
eq "a secret-shaped reason is dropped" \
  "$(phase_failure_reason "$NOTE/secret")" ""
eq "a bare password match without an assignment is not a secret" \
  "$(reason_is_secret_shaped 'wrong password or no key found'; echo "rc=$?")" "rc=1"
eq "a token assignment is secret-shaped" \
  "$(reason_is_secret_shaped 'api_token: abc123'; echo "rc=$?")" "rc=0"
eq "an unreadable capture yields no reason" "$(phase_failure_reason /nonexistent/xyz)" ""

# THE PHASE IS TRANSLATED. `check` reads like a health check to anyone who is not
# this script, and it is precisely the phase that runs AFTER the backup.
eq "check is translated" "$(phase_description check)" "restic repository check"
eq "dumps is translated" "$(phase_description dumps)" "database dumps"
eq "prune is translated" "$(phase_description prune)" "snapshot prune"
eq "an unknown phase has no description" "$(phase_description nonsense)" ""

# WHAT STILL HOLDS, from the phase order and not from a guess. Both directions
# are asserted: claiming a snapshot when there is none is as wrong as the reverse.
for p in check snapshot prune status; do
  eq "a failure in ${p} is after the backup" "$(failure_snapshot_state "$p")" "after"
done
for p in preflight config dumps backup; do
  eq "a failure in ${p} is before the backup" "$(failure_snapshot_state "$p")" "before"
done
eq "an unknown phase claims nothing" "$(failure_snapshot_state 'unknown step')" "unknown"

# THE FOUR FACTS, in the body.
body=$(failure_body check "$reason" 034pwBQBikAhf43qxfM06p)
if [[ $body == 'restic backup of /srv on ryzen — restic repository check failed'* ]]; then
  pass "1. the body names the job and the phase in operator words"
else
  fail "1. the body does not name the job (body: $(printf '%s' "$body" | tr '\n' '|'))"
fi
if [[ $body == *$'\n'why:\ unable\ to\ create\ lock* ]]; then
  pass "2. the body carries the reason"
else
  fail "2. the body lost the reason (body: $(printf '%s' "$body" | tr '\n' '|'))"
fi
if [[ $body == *$'\nsafe: this run'"'"'s snapshot is in the repository'* ]]; then
  pass "3. a post-backup failure says the snapshot is safe"
else
  fail "3. a post-backup failure does not say the snapshot is safe"
fi
if [[ $body == *$'\nrun 034pwBQBikAhf43qxfM06p'* ]]; then
  pass "4. the body keeps the run id on its own line"
else
  fail "4. the body does not carry the run id"
fi

# The pre-backup phases must NOT claim a snapshot, and the unknown phase must say
# nothing at all about one (a confident wrong answer is worse than silence).
for p in preflight config dumps backup; do
  b=$(failure_body "$p" '' r1)
  if [[ $b == *'safe: no snapshot from this run'* && $b != *'in the repository'* ]]; then
    pass "${p} says no snapshot was written"
  else
    fail "${p} claimed something about the snapshot (body: $(printf '%s' "$b" | tr '\n' '|'))"
  fi
done
unknown_body=$(failure_body 'unknown step' '' r1)
if [[ $unknown_body == *'safe:'* ]]; then
  fail "an unknown phase claimed a snapshot state"
else
  pass "an unknown phase says nothing about the snapshot"
fi
eq "an unknown phase is not named in the title" "$(failure_title 'unknown step')" "um790 backup FAILED"
eq "the title names the phase" "$(failure_title check)" "um790 backup FAILED: check"
# A phase we do not have a description for is still a fact, so it is shown
# verbatim - with no invented prose and no snapshot claim.
eq "an unrecognised phase is shown verbatim in the title" \
  "$(failure_title verify)" "um790 backup FAILED: verify"
eq "an unrecognised phase is shown verbatim in the body" \
  "$(failure_body verify '' r1 | head -n 1)" "restic backup of /srv on ryzen — verify failed"

# The body has to stay readable on a lock screen.
body_len=$(failure_body check "$reason" 034pwBQBikAhf43qxfM06p | wc -c)
if (( body_len <= 320 )); then
  pass "the body fits a lock screen (${body_len} chars)"
else
  fail "the body is ${body_len} chars, too long for a lock screen"
fi
# ...and no empty "why: " line when there is no reason. Absent, not blank.
eq "no reason means no why line at all" \
  "$(failure_body check '' r1 | grep -c '^why:' || true)" "0"

# END TO END THROUGH do_fail, with curl stubbed: what is actually POSTed, how
# many times, and whether the reason is consumed. `notify` shells out to `curl`
# and `do_fail` posts exactly once - that is the in-image half of "one message
# per run"; the other half is the wrapper's sentinel, which is host-side.
mkdir -p "$NOTE/bin"
cat > "$NOTE/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Records one record per invocation, one argv entry per line.
{ printf -- '---CALL---\n'; printf '%s\n' "$@"; } >> "${CURL_ARGV:?}"
STUB
chmod +x "$NOTE/bin/curl"

# fail_run <phase> <run-id> <reason-or-empty> <recorded-run-id-or-empty>
fail_run() {
  local where=$1 runid=$2 reason=${3:-} recorded=${4:-$2}
  local state=$NOTE/state
  rm -rf "$state"; mkdir -p "$state"
  : > "$state/run.lock"
  if [[ -n $reason ]]; then
    printf 'run=%s\nreason=%s\n' "$recorded" "$reason" > "$state/last_failure"
  fi
  : > "$NOTE/argv"
  (
    set +e
    STATE=$state
    DAG_STATUS=$where
    DAG_RUN_ID=$runid
    NTFY_URL=http://ntfy.invalid/topic
    # shellcheck disable=SC2030  # deliberately local to this subshell
    PATH="$NOTE/bin:$PATH"
    # shellcheck disable=SC2030
    export CURL_ARGV=$NOTE/argv
    do_fail
  ) 2>"$NOTE/log"
}

fail_run check 034pwBQBikAhf43qxfM06p 'unable to create lock in backend: repository is already locked by PID 532492'
eq "one message per run" "$(grep -c -- '---CALL---' "$NOTE/argv" || true)" "1"
if grep -qx 'Title: um790 backup FAILED: check' "$NOTE/argv"; then
  pass "the posted title names the phase"
else
  fail "the posted title does not name the phase (argv: $(tr '\n' '|' < "$NOTE/argv"))"
fi
if grep -qx 'Priority: high' "$NOTE/argv"; then
  pass "a failure is still high priority"
else
  fail "the priority changed"
fi
if grep -qx 'why: unable to create lock in backend: repository is already locked by PID 532492' "$NOTE/argv"; then
  pass "the posted body carries the recorded reason"
else
  fail "the posted body lost the reason (argv: $(tr '\n' '|' < "$NOTE/argv"))"
fi
eq "the posted body says the snapshot is safe" \
  "$(grep -cx "safe: this run's snapshot is in the repository" "$NOTE/argv" || true)" "1"
eq "the run id is in the posted body" \
  "$(grep -cx 'run 034pwBQBikAhf43qxfM06p' "$NOTE/argv" || true)" "1"
eq "do_fail releases the run lock" "$([[ -f $NOTE/state/run.lock ]] && echo present || echo gone)" "gone"
eq "do_fail exits 0" "$(fail_run check r1 'x' >/dev/null 2>&1; echo $?)" "0"

# The reason is consumed: one failure, one message. Re-running do_fail for the
# same run must not carry a stale cause.
fail_run check 034pwBQBikAhf43qxfM06p 'unable to create lock in backend: x'
do_fail_again() {
  (
    set +e
    STATE=$NOTE/state; DAG_STATUS=check; DAG_RUN_ID=034pwBQBikAhf43qxfM06p
    NTFY_URL=http://ntfy.invalid/topic
    # shellcheck disable=SC2030,SC2031
    PATH="$NOTE/bin:$PATH"
    # shellcheck disable=SC2030,SC2031
    export CURL_ARGV=$NOTE/argv2
    : > "$NOTE/argv2"
    do_fail
  ) 2>/dev/null
}
do_fail_again
eq "the reason is consumed by the first message" \
  "$(grep -c '^why:' "$NOTE/argv2" || true)" "0"

# Another run's reason is never attached to this run's message (and is still
# consumed, so it cannot leak forward either).
fail_run check 034pwBQBikAhf43qxfM06p 'unable to create lock in backend: yesterday' some-other-run
eq "another run's reason is ignored" "$(grep -c '^why:' "$NOTE/argv" || true)" "0"
eq "another run's reason is not left behind" \
  "$([[ -f $NOTE/state/last_failure ]] && echo present || echo gone)" "gone"

# A secret-shaped record is refused at the point of use too, not only at the point
# of capture: a reason file written by an older image must not leak a credential.
fail_run backup r1 'RESTIC_PASSWORD=hunter2supersecret'
eq "a secret-shaped recorded reason is refused" "$(grep -c '^why:' "$NOTE/argv" || true)" "0"
eq "the rest of the message still goes out" \
  "$(grep -c -- '---CALL---' "$NOTE/argv" || true)" "1"

# THE PHASE'S EXIT CODE IS STILL THE STEP'S EXIT CODE. main() streams the phase's
# stderr through tee to capture the reason; that must not swallow the status, and
# a phase that succeeds must record nothing. Run the real thing as a program
# against a repository that cannot be opened, with no notifier in sight.
CAPRUN=$NOTE/run
mkdir -p "$CAPRUN"
rc=0
BASE="$CAPRUN/base" RESTIC_REPOSITORY="$CAPRUN/not-a-repository" RESTIC_PASSWORD=x \
  DAG_RUN_ID=caprun bash "$RUNNER" check >"$CAPRUN/out" 2>&1 || rc=$?
eq "a failing phase still exits non-zero through the capture" "$rc" "1"
if [[ -f $CAPRUN/base/state/last_failure ]] &&
   grep -q '^reason=Fatal: repository does not exist' "$CAPRUN/base/state/last_failure"; then
  pass "the failing phase recorded its reason for the fail container"
else
  fail "the failing phase recorded no reason ($(tr '\n' '|' < "$CAPRUN/out"))"
fi
if grep -q 'recorded failure reason for check' "$CAPRUN/out"; then
  pass "the reason is also in the log"
else
  fail "the reason is not in the log"
fi

# ---------------------------------------------------------------------------
if (( FAILED )); then
  printf '\nretention tests FAILED\n' >&2
  exit 1
fi
printf '\nall retention tests passed\n'
