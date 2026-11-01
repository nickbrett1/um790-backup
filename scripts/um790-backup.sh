#!/usr/bin/env bash
# um790-backup — phase runner. ONE phase per invocation; Dagu or a human sequences
# the phases. Everything here is safe to run by hand during an incident, which is
# deliberate: the guards that matter must not live only inside a scheduler.
#
#   usage: um790-backup.sh <phase> [--dry-run]
#          um790-backup.sh --dry-run          # validate settings only, exit 0
#
#   phases: preflight config dumps backup check snapshot prune status fail
#
# --dry-run is parsed anywhere on the command line, because the DAG passes it as a
# bare $1 and a human puts it last. It never requires secrets, never opens the repo,
# never touches /srv and never contacts the NAS: the CI smoke gate runs the image
# with no environment at all and this must still exit 0.
#
# This file is also SOURCED by scripts/test-retention.sh, which drives
# snapshot_epoch, select_sweep_candidates and snapshot_delete_cmd directly. That is
# why the entry point at the bottom is guarded: importing the functions must not run
# main.
set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# configuration (every value overridable; the defaults are the NAS facts)
# ---------------------------------------------------------------------------
# SSH to the NAS as a shell user, for the snapshot phase only. These are explicit
# flags rather than ~/.ssh/config on purpose: inside a container there is no user
# config, and a group-writable one is rejected outright by ssh (this bit us on the
# host during init).
NAS_HOST="${NAS_HOST:-192.168.1.2}"
NAS_PORT="${NAS_PORT:-2222}"      # sshd answers on 22 and 2222; neither is a default
NAS_USER="${NAS_USER:-nick}"      # in administrators, NOPASSWD sudo, ryzen key present
NAS_SSH_KEY="${NAS_SSH_KEY:-/run/ssh/id_ed25519_ryzen}"
SHARE="${SHARE:-restic-target}"
SNAPSHOT_MODE="${SNAPSHOT_MODE:-share}"          # share | subvol

# The repo path is SHARE-ROOTED, not /volume1-rooted: Synology's patched
# internal-sftp exposes a virtual namespace of share names, so /volume1 resolves to
# nothing and fails server-side with `not found share [volume1]`.
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-sftp:restic@${NAS_HOST}:/restic-target/um790}"
RESTIC_SSH_KEY="${RESTIC_SSH_KEY:-/run/ssh/id_ed25519_restic}"
KNOWN_HOSTS="${KNOWN_HOSTS:-/run/ssh/known_hosts}"
NTFY_URL="${NTFY_URL:-}"

# Writable, persistent, and excluded from the backup. Everything that must outlive
# this container goes here.
#
# Staging MUST be on a mounted path, not in the container's writable layer: the DAG
# runs each phase as its own `docker run --rm`, so anything written to the image
# filesystem is gone before the next phase starts - `config` and `dumps` would stage
# into a directory `backup` never sees. It also must not sit under a read-only /srv
# path (the original design used /srv/backup-staging, where `rm -rf` fails), and it
# must be excluded from the backup or each run backs up the previous run's staging.
BASE="${BASE:-/srv/.um790-backup}"
STAGE="${STAGE:-$BASE/staging}"
STATE="$BASE/state"
CACHE="$BASE/cache"

# The exclude list is authored in the repo and INSTALLED into $BASE by preflight.
# Two paths on purpose: /app is the image (read-only, and replaced wholesale on the
# next `docker pull`), while $BASE is the persistent mount that `backup` - a
# different container - can actually read. The repo copy is the source of truth: it
# is overwritten every run, so a hand-edited $EXCLUDES is not preserved. Edit
# deploy/exclude.txt and let the image carry it.
EXCLUDES_SRC="${EXCLUDES_SRC:-/app/deploy/exclude.txt}"
EXCLUDES="${EXCLUDES:-$BASE/exclude.txt}"

# ---------------------------------------------------------------------------
# NAS snapshot retention
# ---------------------------------------------------------------------------
# TIME-BASED, EXPRESSED IN WEEKS, and deliberately NOT a bare count of snapshots.
#
# This used to be KEEP_SNAPSHOTS=8 with SNAPSHOT_RETENTION_DAYS=$((KEEP * 7)),
# documented as "8 snapshots ~= 8 weeks of undo a bad prune". That `* 7` silently
# asserts the schedule is WEEKLY. Point the DAG at a daily cron and 8 snapshots
# becomes 8 DAYS of undo while every comment still says weeks - the window
# shrinks by 7x and nothing complains.
#
# The number that has to be right is the DURATION, so the duration is what is
# configured. A cadence change now moves the snapshot count (cost) instead of the
# safety margin (the thing you find out about when you need it).
#
# Scope: this governs the NAS-side Btrfs snapshots that `prune` sweeps. It is a
# separate axis from restic's own keep policy inside the repository, which is
# RESTIC_KEEP_ARGS below.
#
# Deprecated alias: KEEP_SNAPSHOTS. It now means weeks, not a count, because
# treating a stale count as a duration is exactly the bug above. Warn rather than
# ignore, so an env var left over in the Dagu config cannot silently decide the
# undo window.
if [[ -n ${KEEP_SNAPSHOTS:-} ]]; then
  printf '%s [validate] WARNING: KEEP_SNAPSHOTS is deprecated and now means WEEKS, not a snapshot count; use SNAPSHOT_RETENTION_WEEKS\n' \
    "$(date -u +%FT%TZ)" >&2
fi
SNAPSHOT_RETENTION_WEEKS="${SNAPSHOT_RETENTION_WEEKS:-${KEEP_SNAPSHOTS:-8}}"
SNAPSHOT_RETENTION_DAYS="${SNAPSHOT_RETENTION_DAYS:-$((SNAPSHOT_RETENTION_WEEKS * 7))}"

# A sweep window shorter than a couple of run intervals keeps roughly one
# snapshot, i.e. no undo at all. Not fatal (an operator may want it during a
# migration), but it must not pass silently.
if (( SNAPSHOT_RETENTION_DAYS < 14 )); then
  printf '%s [validate] WARNING: SNAPSHOT_RETENTION_DAYS=%s keeps about one snapshot; there would be no previous point in time to undo to\n' \
    "$(date -u +%FT%TZ)" "$SNAPSHOT_RETENTION_DAYS" >&2
fi

# 6h: prune must run within the same run as the snapshot it protects.
SNAPSHOT_MAX_AGE="${SNAPSHOT_MAX_AGE:-$((6 * 3600))}"

# restic's own retention policy, inside the repository. Named rather than written
# inline at the two call sites in do_prune so the offline test can apply the SAME
# arguments to a throwaway repository and assert what survives - a test that
# restated the policy would drift from it silently.
RESTIC_KEEP_ARGS=(--keep-daily 14 --keep-weekly 4 --keep-monthly 6)

# The size guard catches a WRONG MOUNT, not normal growth. It is measured with
# the exclude list applied (see measure_source_gb), because the raw /srv total
# includes ~19G that never enters the repository - /srv/appdata/backups,
# /srv/appdata/marketdata (the /srv/backups and /srv/marketdata trees until the
# data move lands), the Postgres clusters, caches and Dagu's own state. Guarding
# on the raw number meant a correct source failed a limit derived from the
# payload size, so the limit had to be set above a quantity it was never
# describing.
#
# 70G against a ~45G payload: generous enough that a few hundred GB of new data
# does not page anyone, small enough that "the whole disk got mounted at /srv"
# (hundreds of GB, and -xdev does not save you from a bind mount) still fails.
MAX_SOURCE_GB="${MAX_SOURCE_GB:-70}"
EXPECTED_MIN_CONTAINERS="${EXPECTED_MIN_CONTAINERS:-60}"
CHECK_READ_SUBSET="${CHECK_READ_SUBSET:-10%}"    # weekly cadence, so 10% each run

# How long `check` waits for a lock it did not create. `backup` has had
# --retry-lock 5m since it was written; `check` had NO lock handling at all, and
# that asymmetry is a defect of its own, not a missing nicety:
#
# 2026-11-01, Dagu run 034pwBQBikAhf43qxfM06p. `backup` succeeded — snapshot
# f35a24c4, 28,194 files / 63.98 GiB — and `check` then failed three times
# (initial plus two automatic retries) with
#
#     repository is already locked by PID 532492 on ryzen
#     lock was created at 2026-10-31 16:01:21 (12h54m43s ago)
#
# That lock was SHARED, from an ad-hoc `restic ls latest /srv/datasets...` in an
# interactive session killed before it could release it. Shared-vs-exclusive is
# the part that is not obvious: `restic backup` also takes a shared lock, so the
# backup phase was never blocked, while `restic check` needs an EXCLUSIVE one and
# could not start. A 13-hour-old lock belonging to a dead PID therefore cost the
# run its snapshot, prune and status phases — last_success went stale even though
# the snapshot had landed, which reads like "the backup failed" and was not.
# restic never removes a stale lock by itself, and nothing in the DAG had ever
# run `restic unlock`.
#
# do_check now runs `restic unlock` before checking, which retires the stale case
# entirely. This timeout covers the OTHER case, which the unlock cannot: a lock
# whose owner is still ALIVE — a dashboard query, a hand-run `restic snapshots`,
# an overlapping job holding shared for a few seconds. 10m is long against
# "a few seconds" and short against the 6h SNAPSHOT_MAX_AGE window a run has to
# finish inside, and it is the same shape as backup's 5m (longer because a check
# is the last thing an operator is waiting on at 02:00, and giving up early buys
# nothing: retrying the phase re-reads the whole 10% subset).
CHECK_RETRY_LOCK="${CHECK_RETRY_LOCK:-10m}"

# A DEADLINE ON THE SQLITE PRIMARY PATH, because sqlite3's `.backup` has none of
# its own: when the live database is locked, or keeps changing under the copy, the
# CLI sleeps 250ms and retries forever. Measured on 2026-10-30 — mailroom's
# `.backup` sat for 2h17m before failing, turning a 16m run into 2h33m, while the
# staged-copy fallback dumped the same 275MB database in about a second.
#
# 900s is generous for a database that normally dumps in under a second, and small
# against a multi-hour stall. Expiry takes the SAME branch as any other `.backup`
# failure — the staged copy — so this changes WHEN the fallback happens, never
# whether the dump is made. It cannot turn a good dump into a missing one.
SQLITE_BACKUP_TIMEOUT="${SQLITE_BACKUP_TIMEOUT:-900}"

PG_CONTAINERS=(litellm-db mcphub-postgres miniflux-db miniflux-explore-db)
# Every SQLite database that restic would otherwise copy as a RAW LIVE FILE.
#
# This list is the WAL-safety mechanism, not a curated selection: a database left
# off it is not merely undumped, it is copied mid-transaction by `restic backup`
# with its -wal sitting beside it, which is the corruption the `.backup` path
# exists to prevent.
#
# THE DRIFT GUARD BELOW DOES NOT CLOSE THIS. It only trips on *.db over 10M, so
# any live database under that size is invisible to it: neither dumped here nor
# reported, just silently copied raw. potato, n8n and vikunja were all in that
# blind spot (438K / 2.5M / 672K on 2026-10-22) and were added here for exactly
# that reason. The 10M threshold is a guardrail against unseen NEW databases, not
# a definition of which databases matter.
SQLITE_DBS=(
  "/srv/appdata/msgvault/msgvault.db|msgvault"
  "/srv/docker/phoenix/data/phoenix.db|phoenix"
  "/srv/docker/open-webui/data/webui.db|open-webui"
  "/srv/docker/pihole/config/pihole-FTL.db|pihole-ftl"
  "/srv/docker/mailroom/data/mailroom.db|mailroom"
  "/srv/docker/mailroom/data/dagster/history/runs/index.db|dagster-history"
  "/srv/appdata/reader/vg-books/reader.db|vg-books"
  "/srv/docker/potato/project/project.sqlite|potato"
  "/srv/docker/n8n/data/database.sqlite|n8n"
  "/srv/docker/vikunja/db/vikunja.db|vikunja"
)
#
# msgvault and vg-books were REPOINTED to /srv/appdata/... (from /srv/msgvault
# and /srv/reader) when the host's service data trees moved under /srv/appdata.
# The old paths are not kept alongside the new ones: an entry here is a hard
# failure when the file is absent (`[[ -f $dbpath ]] || die` below - "moved,
# renamed, or wrong mount"), so a duplicated entry would do nothing but break the
# run the moment the move lands. That is the stale-pattern trap, not a safety
# belt; the belt for the transition lives in deploy/exclude.txt, where a dead
# line is harmless.
#
# THE COST OF THAT CHOICE, stated plainly: between this image being pinned and
# the host move completing, these two entries named a path that did not exist
# yet, while the old ones still held the data. The dumps phase therefore FAILED
# LOUDLY at the first entry instead of quietly dumping the old location - and if
# it somehow got past that, the drift guard would fire on the now-unlisted old
# files (/srv/msgvault/msgvault.db ~8.2G, /srv/reader/vg-books/reader.db ~108M).
# So the pin and the host move belonged in the same sitting, and a run landing in
# the gap failed rather than producing a snapshot that silently lacks a database.
#
# The move COMPLETED and was verified on the host on 2026-10-30: both entries
# above name live files, no /srv/<name> original remains, and the transitional
# mirror lines in deploy/exclude.txt were removed with it. That is the shape to
# keep. An entry here is a promise that the file is at that path on every host
# this image runs against, checked at run time - so it can never be carried
# "just in case" the way an exclude line can, and a path in transition belongs in
# that file, never in this array.
#
# dagster-history was added on 2026-10-28 by the drift guard itself: Dagster's
# run-storage index grew past the 10M threshold (10,608,640B) and the 03:30 run
# died with "undiscovered SQLite >10M ... add it to SQLITE_DBS if it is live".
# It is live - the dagster daemon and mailroom write run/asset history into it -
# so dumping it is the correct arm, not the STATIC_SQLITE exemption and not an
# exclude. Two consequences worth knowing before someone "fixes" the log:
#   - it is WAL and, like mailroom.db, usually has no -wal at 03:30 because the
#     writers closed cleanly, so it takes the staged-copy fallback and logs a
#     WARNING every night. That WARNING is the designed path, not damage.
#   - the ~400 per-run *.db event logs beside it stay OFF this list: each is far
#     under the threshold, and dumping them individually would add ~400 copies
#     for no consistency gain. They are restic-copied raw, which is the
#     documented blind spot below, not an oversight.
#
# Deliberately NOT listed: /srv/docker/potato/project/datasets.sqlite. It does not
# exist today, and an entry in this array is a hard failure when the path is
# absent (see the `[[ -f $dbpath ]] || die` below). Potato creates it only in some
# modes. Add it here the moment it appears on disk - it is live WAL state, so it is
# the same class as project.sqlite, not a STATIC_SQLITE candidate.

# SQLite files that ARE in the backup set but are NOT live databases: frozen
# pre-migration copies sitting in a backups/ directory.
#
# They need their own category because the drift scan below exists to catch a live
# database whose raw file restic would copy mid-transaction. These are the opposite
# case - nothing has them open, the file is complete, and a byte-for-byte copy is
# the CORRECT thing to keep. Adding them to SQLITE_DBS would dump a copy of a copy
# (VACUUM INTO of an already-static file), which is pure waste and adds a failure
# mode; excluding them would discard the only copy of the pre-migration state.
#
# Each entry is a full path whose DIRECTORY is compared literally and whose basename
# may contain a glob. Only the basename globs, on purpose - see the match below.
#
# Verified on 2026-10-22 against real state: two files, 240,058,368B each, identical
# size but different sha256, mtime ~58.7 days older than mailroom.db, nothing
# holding either open.
STATIC_SQLITE=(
  "/srv/docker/mailroom/backups/mailroom_pre_*.db"
)

# The exemption's whole justification is "nothing is writing to it", and that can
# stop being true. A file rewritten inside this window is reported, because restic
# would then be copying a live file while calling it static.
STATIC_SQLITE_MAX_AGE_DAYS="${STATIC_SQLITE_MAX_AGE_DAYS:-7}"

DRY_RUN=0
PHASE=""

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${PHASE:-validate}" "$*" >&2; }
die()  { log "FATAL: $*"; exit 1; }
stamp() { date -u +%s; }

# Seconds -> something a person can read at a glance: 9180 -> "2h33m", 210 -> "3m",
# 42 -> "42s". The raw second count is still what last_success.json carries and
# what the log line prints; this is display only.
#
# Minutes are TRUNCATED, not rounded up, so the number never overstates a run that
# finished just under the next minute. A sub-minute run keeps its seconds rather
# than collapsing to "0m", which would read like a failure to measure.
human_duration() { # seconds
  local s=$1
  if (( s >= 3600 )); then
    printf '%dh%02dm\n' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  elif (( s >= 60 )); then
    printf '%dm\n' $(( s / 60 ))
  else
    printf '%ds\n' "$s"
  fi
}

usage() {
  cat >&2 <<'EOF'
usage: um790-backup.sh <phase> [--dry-run]
       um790-backup.sh --dry-run

phases:
  preflight  assert NAS reachable, repo openable, source sane; take the run lock
  config     reconstruct container configs from docker inspect, secrets redacted
  dumps      pg_dump the 4 Postgres DBs, VACUUM INTO the listed SQLite DBs
  backup     restic backup /srv + staging, then read the snapshot back to prove it
  check      unlock stale restic locks, then restic check (10% data, 10m lock wait)
  snapshot   create a Btrfs share snapshot on the NAS (must precede prune)
  prune      forget --prune + sweep old snapshots; refuses without this run's snapshot
  status     write the last_success heartbeat — only called when everything passed
  fail       record the failure and release the run lock

--dry-run: print what the phase would do and exit 0. Needs no secrets.
EOF
}

notify() { # priority title body
  local prio=$1 title=$2 body=$3
  if [[ -z $NTFY_URL ]]; then
    log "no NTFY_URL set; skipping notification"
    return 0
  fi
  # A broken notifier must never turn a failed backup into a green run, nor a
  # successful one into a red run.
  curl -fsS -m 10 -H "Title: $title" -H "Priority: $prio" -d "$body" "$NTFY_URL" >/dev/null \
    || log "WARNING: ntfy unreachable (this does not change the phase result)"
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  local positional=()
  while (( $# )); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --help|-h) usage; exit 0 ;;
      -*) usage; die "unknown option: $1" ;;
      *) positional+=("$1") ;;
    esac
    shift
  done

  if (( ${#positional[@]} > 1 )); then
    usage
    die "expected one phase, got ${#positional[@]}: ${positional[*]}"
  fi
  PHASE="${positional[0]:-}"
}

# Both a bare `--dry-run` (validate only) and an unknown phase are usage errors,
# never a silent "run everything". A no-argument invocation must not start work.
require_phase() {
  if [[ -z $PHASE ]]; then
    usage
    die "no phase given"
  fi
  case $PHASE in
    preflight|config|dumps|backup|check|snapshot|prune|status|fail) ;;
    *) usage; die "unknown phase: $PHASE" ;;
  esac
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
# restic is invoked through this so the sftp transport options are set in exactly
# one place. `sftp.args` is what the sftp backend passes to ssh; without it restic
# would use the default port and no key, and fail on a container that has no
# ~/.ssh/config.
RESTIC_OPTS=(
  --cache-dir "$CACHE"
  -o "sftp.args=-p ${NAS_PORT} -i ${RESTIC_SSH_KEY} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${KNOWN_HOSTS} -o LogLevel=ERROR"
)
restic_run() { command restic "${RESTIC_OPTS[@]}" "$@"; }

nas_ssh() {
  ssh -p "$NAS_PORT" -i "$NAS_SSH_KEY" \
      -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
      "${NAS_USER}@${NAS_HOST}" "$@"
}

require_cmds() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    die "missing required commands: ${missing[*]}"
  fi
}

# Join arguments with single spaces, whatever IFS happens to be.
#
# This exists because IFS is $'\n\t' at the top of this file, and `${arr[*]}` expands
# with the FIRST character of IFS. That made the delete command below
# newline-separated. Log lines want spaces; remote shell commands need more than
# just spaces (see snapshot_delete_cmd).
join_space() { local IFS=' '; printf '%s' "$*"; }

# The remote command for a multi-name snapshot delete, as a PURE function.
#
# WHY THIS IS SEPARATE AND WHY IT IS QUOTED BY HAND. The obvious spelling is
#
#     local quoted=()
#     for s in "${doomed[@]}"; do quoted+=("'${s}'"); done
#     nas_ssh "... delete '${SHARE}' ${quoted[*]}"
#
# and it is WRONG in a way nothing caught. `${quoted[*]}` inside a double-quoted
# string expands with the first character of IFS - which is a NEWLINE here - so
# the names arrived at the remote shell as a single argument containing newlines.
# The remote shell then ran `synosharesnapshot delete '<share>' '<first name>'` and
# tried to execute the remaining names as commands:
#
#     sh: line 1: GMT-04-2026.10.22-10.39.45: command not found
#
# Observed on a real run on 2026-10-22: TWO names selected, ONE deleted, exit 127
# swallowed by `|| log WARNING`, phase reported `prune ok`. A partial delete was
# therefore indistinguishable from a clean one, and it only happens when N > 1 -
# which is why every run before it looked healthy.
#
# Single-quote wrapping (not `printf %q`): %q can emit $'...' for awkward strings,
# which is bash-only, and the remote login shell is not ours to assume. A name
# containing a single quote cannot be wrapped safely this way, so it is REFUSED
# rather than escaped - a snapshot name is DSM-generated and never contains one,
# and refusing is the safe direction for a destructive command.
#
# Returns non-zero if any argument cannot be represented safely.
snapshot_delete_cmd() { # share name...
  local share=$1
  shift
  local out="sudo -n /usr/syno/sbin/synosharesnapshot delete" n
  for n in "$share" "$@"; do
    if [[ $n == *"'"* ]]; then
      return 1
    fi
    out+=" '${n}'"
  done
  printf '%s' "$out"
}

# --- the exclude list, as both restic and find(1) understand it ---------------
# EXCLUDE_OR holds an OR-list of find predicates, one per pattern in the exclude
# file, ready to be wrapped as \( "${EXCLUDE_OR[@]}" \) -prune -o ...
#
# It exists because two guards measured the FILESYSTEM while claiming to measure
# the BACKUP SET: the source-size limit ran `du /srv` and the SQLite drift scan ran
# `find /srv`, neither of which knows what restic will actually omit. So ~19G of
# deliberately excluded data counted against MAX_SOURCE_GB, and a database living
# under an excluded path was reported as a coverage hole it could never be. Both
# now measure the same set restic walks.
#
# Pattern translation, matching deploy/exclude.txt's own documented meanings:
#   /*     a path prefix          -> -path (prunes the whole subtree)
#   **/x   a basename at any depth -> -name
#   x      a bare name            -> -name
#
# Restic's glob dialect is richer than this (character classes, ** inside a
# segment). Anything it would match that find would not is a pattern whose purpose
# is pruning a directory tree, which is the /* form - so a divergence here costs
# accuracy in the guard, never data in the backup, which is still driven by
# --exclude-file in do_backup.
EXCLUDE_OR=()
load_excludes() {
  EXCLUDE_OR=()
  local pat
  local -a pred=()
  [[ -f $EXCLUDES ]] || return 0
  while IFS= read -r pat; do
    [[ -n $pat ]] || continue
    # Explicit `if`, not `[[ ]] && continue`: a false AND-list as the last command
    # in a loop body returns non-zero and exits the shell under set -e with no
    # message. Same trap as do_dumps.
    if [[ $pat == \#* ]]; then
      continue
    fi
    case $pat in
      '**/'*) pred=( -name "${pat#\*\*/}" ) ;;
      /*)     pred=( -path "$pat" ) ;;
      *)      pred=( -name "$pat" ) ;;
    esac
    if (( ${#EXCLUDE_OR[@]} )); then
      EXCLUDE_OR+=( -o )
    fi
    EXCLUDE_OR+=( "${pred[@]}" )
  done < "$EXCLUDES"
}

# Whole gigabytes of the source that restic would actually read, i.e. /srv with the
# excluded subtrees pruned, and the writable state tree pruned even if the exclude
# file were to lose that entry - staging is created by this phase and backed up
# explicitly, so counting it here would double-count it.
#
# THE FORMAT SPECIFIER IS LOAD-BEARING. The obvious `awk '{s+=$1} END {print s+0}'`
# is not integer-preserving on the awk that actually ships: the image carries mawk
# 1.3.4, whose OFMT is "%.6g", so a total of 31,806,800,000 bytes prints as
# 3.18068e+10 and the ^[0-9]+$ guard below rejects it. That fires for ANY /srv
# total >= 1,000,000 bytes, i.e. always, and it took preflight down on the first
# real run after passing CI - because CI's smoke gate only exercises `--dry-run`,
# which returns before this is ever called. printf "%.0f" is explicit and portable
# across mawk/gawk/busybox.
#
# The raw value is echoed in the failure message for the same reason: the previous
# message ("find returned no usable total") described the symptom and named
# nothing, so the cause had to be found by tracing the script with xtrace.
measure_source_gb() {
  local bytes
  bytes=$(find /srv -xdev \
            \( "${EXCLUDE_OR[@]}" -o -path "$STAGE" -o -path "$BASE" \) -prune -o \
            -type f -printf '%s\n' 2>/dev/null \
          | awk '{ s += $1 } END { printf "%.0f\n", s + 0 }')
  if [[ ! $bytes =~ ^[0-9]+$ ]]; then
    log "ERROR: byte total from find/awk was '${bytes}', which is not a plain integer"
    return 1
  fi
  printf '%s' $(( bytes / 1073741824 ))
}

# `synosharesnapshot list` prints a header line BEFORE the snapshots
# ("There has N snapshots of share [x]"), so wc -l is always count+1 and any
# tail -n +N is off by one. Always strip line 1.
snapshot_names() {
  nas_ssh "sudo -n /usr/syno/sbin/synosharesnapshot list '${SHARE}'" | tail -n +2
}

snapshot_count() {
  local n
  n=$(snapshot_names | grep -c . || true)
  printf '%s' "${n:-0}"
}

# Snapshot names look like GMT-04-2026.10.20-22.15.44. Age is computed from the
# timestamp part rather than from list order, because DSM's ordering is not
# documented and the design's `--reverse | tail -n +N` assumed it was.
#
# THE WHOLE NAME IS MATCHED IN ONE REGEX, and the separators are explicit. The
# previous version stripped the offset prefix with sed and then rewrote EVERY dot
# to a dash, which also rewrote the three time separators and handed `date` a
# string it cannot parse ("2026-10-20-22-15-44"). The result was empty for every
# real snapshot name, so select_sweep_candidates treated every snapshot as
# unparseable and the sweep deleted nothing, forever, while logging a warning per
# snapshot. Caught by scripts/test-retention.sh on its first run.
#
# Anchoring the offset label is load-bearing too: matching the bare
# YYYY.MM.DD-HH.MM.SS shape would accept a name with no label at all.
#
# The GMT±NN label is validated but NOT applied - the timestamp is read as UTC. A
# few hours cannot move a 56-day cutoff, and applying it would make the sweep
# depend on a label the NAS is free to write differently.
#
# Always returns 0. It is called as `ep=$(snapshot_epoch ...)` under `set -e`,
# where a non-zero status would kill the shell instead of reading as
# "unparseable".
snapshot_epoch() { # name -> epoch, empty on parse failure
  local name=$1
  if [[ $name =~ ^GMT[+-][0-9]{2}-([0-9]{4})\.([0-9]{2})\.([0-9]{2})-([0-9]{2})\.([0-9]{2})\.([0-9]{2})$ ]]; then
    # date reads "YYYY-MM-DD HH:MM:SS" in UTC (-u), so no offset surprises.
    date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null || true
  fi
  return 0
}

# Which snapshots the sweep may delete: a pure function of (now, window, names),
# which is what makes it testable without a NAS. scripts/test-retention.sh calls
# THIS function rather than a copy, so the test cannot drift from the runner.
#
# stdin:  snapshot names, one per line
# stdout: the names to delete, one per line
# stderr: warnings, so a caller can capture the list on its own
#
# Two properties that are load-bearing:
#   - a name that cannot be parsed is LEFT ALONE and logged. An empty result is
#     the safe answer; a guessed one deletes snapshots.
#   - the newest snapshot is never a candidate, even when every snapshot has
#     expired. This used to be done by truncating the deletion list to total-1
#     entries, which relied on DSM's list order - undocumented - so it could keep
#     an arbitrary OLD snapshot and delete the most recent point in time.
select_sweep_candidates() { # now_epoch retention_days
  local now=$1 days=$2 name ep
  local -a names=() epochs=()
  local newest=-1

  while read -r name; do
    [[ -n $name ]] || continue
    ep=$(snapshot_epoch "$name")
    if [[ -z $ep ]]; then
      printf 'WARNING: cannot parse snapshot name %q — leaving it alone\n' "$name" >&2
      continue
    fi
    names+=("$name")
    epochs+=("$ep")
    # Written as `if`, not `(( )) && ...`: a false AND-list as the last command in
    # a loop body returns non-zero, which exits the shell under set -e with no
    # message - the same trap documented in do_dumps.
    if (( ep > newest )); then
      newest=$ep
    fi
  done

  local i
  for i in "${!names[@]}"; do
    if (( epochs[i] == newest )); then
      continue
    fi
    if (( now - epochs[i] > days * 86400 )); then
      printf '%s\n' "${names[$i]}"
    fi
  done
}

# ---------------------------------------------------------------------------
# snapshot readback — prove the payload is IN the snapshot, not just on disk
# ---------------------------------------------------------------------------
# Every guard that existed before this one measured STAGING, and staging was being
# excluded from the snapshot. So a run could produce ~18G of perfectly good dumps,
# satisfy all of them, and still write a snapshot containing no database content at
# all - which is exactly what happened, on both runs, before anyone noticed.
#
# The defect was not exotic and it was not a restic bug: `restic backup /srv "$STAGE"`
# names staging as an EXPLICIT target, and restic silently drops an explicitly named
# path that falls beneath an excluded ancestor. exclude.txt carried the ancestor.
#
# Hence a READBACK rather than another on-disk assertion: the on-disk checks were
# the ones that were wrong, so repeating them in a new place would have reproduced
# the blind spot with more confidence.
#
# It asserts in both directions, because each catches a different mistake:
#   - the payload IS present (otherwise the backup is worthless), and
#   - state/, cache/, ssh/ and staging/.tmp are NOT (otherwise an exclude that
#     stopped matching silently starts putting run.lock, the restic cache and the
#     NAS PRIVATE KEYS into snapshots, which is the one that really matters).
#
# Cost is one listing of the snapshot - on the order of 10^5 lines, a few seconds,
# against a phase that just spent minutes uploading. Cheap enough to run every time,
# and pointless to run any less often.
assert_snapshot_contents() { # snapshot-id
  local snap=$1
  local -a got=()

  # ONE pass over the listing, counted by awk, because a large snapshot has enough
  # paths that walking it several times over an sftp transport is the dominant cost
  # of the phase.
  #
  # THE COUNTS COME BACK ONE PER LINE, NOT SPACE-SEPARATED, and that is deliberate.
  # IFS is $'\n\t' at the top of this file, so `read -r a b c` would not split on
  # spaces at all - everything would land in the first variable and the comparisons
  # below would compare the entire record against an integer. mapfile splits on
  # newlines regardless of IFS, which removes the trap rather than restating it.
  #
  # index($0,x)==1 is a prefix test, not a substring search: a path merely
  # MENTIONING "$BASE/ssh" deeper in the tree is not the ssh directory itself.
  # Only the counts are emitted, so nothing sensitive is ever printed.
  mapfile -t got < <(
    restic_run ls "$snap" 2>/dev/null | awk -v s="$STAGE" -v b="$BASE" '
      index($0, s "/pg/")     == 1 { pg++ }
      index($0, s "/sqlite/") == 1 { sq++ }
      index($0, s "/config/") == 1 { cf++ }
      index($0, s "/config/containers.txt") == 1 { ct=1 }
      index($0, s "/.tmp/")   == 1 { tp++ }
      index($0, b "/state/")  == 1 { st++ }
      index($0, b "/cache/")  == 1 { ca++ }
      index($0, b "/ssh/")    == 1 { sh++ }
      END {
        printf "%d\n%d\n%d\n%d\n%d\n%d\n%d\n%d\n",
               pg+0, sq+0, cf+0, ct+0, tp+0, st+0, ca+0, sh+0
      }
    '
  )
  (( ${#got[@]} == 8 )) \
    || die "could not read snapshot ${snap} back (got ${#got[@]}/8 counters) — the snapshot exists but cannot be verified, which is not the same as verified"

  local pg=${got[0]} sq=${got[1]} cf=${got[2]} ct=${got[3]}
  local tp=${got[4]} st=${got[5]} ca=${got[6]} sh=${got[7]}

  # --- the payload must be there -------------------------------------------
  (( ct == 1 )) \
    || die "snapshot ${snap} has no ${STAGE}/config/containers.txt — the config phase output did not reach the snapshot"
  (( pg >= ${#PG_CONTAINERS[@]} )) \
    || die "snapshot ${snap} has ${pg}/${#PG_CONTAINERS[@]} Postgres dumps — the dumps phase output did not reach the snapshot; check that deploy/exclude.txt still leaves staging/ reachable (an excluded ANCESTOR silently voids the explicit restic target)"
  (( sq >= ${#SQLITE_DBS[@]} )) \
    || die "snapshot ${snap} has ${sq}/${#SQLITE_DBS[@]} SQLite dumps — the dumps phase output did not reach the snapshot; same cause as the Postgres case above"
  (( cf >= ${#PG_CONTAINERS[@]} + ${#SQLITE_DBS[@]} )) \
    || die "snapshot ${snap} has only ${cf} files under ${STAGE}/config — the per-container inspect output is incomplete"

  # --- the excludes must still be working ----------------------------------
  # These are fatal rather than warnings: a snapshot that contains the restic/NAS
  # private keys is a credential exposure on a NAS share, and "we will look at it
  # later" is not a thing to leave in an automated run.
  (( tp == 0 )) || die "snapshot ${snap} contains ${tp} path(s) under ${STAGE}/.tmp — dump scratch leaked in"
  (( st == 0 )) || die "snapshot ${snap} contains ${st} path(s) under ${BASE}/state — runtime state (run.lock, *.epoch) leaked in"
  (( ca == 0 )) || die "snapshot ${snap} contains ${ca} path(s) under ${BASE}/cache — restic's cache leaked in"
  (( sh == 0 )) || die "snapshot ${snap} contains ${sh} path(s) under ${BASE}/ssh — SSH PRIVATE KEYS reached the snapshot; rotate them and fix deploy/exclude.txt"

  log "snapshot ${snap} verified: ${pg} pg dump(s), ${sq} sqlite dump(s), ${cf} config file(s); no state/cache/ssh/.tmp"
}

# ---------------------------------------------------------------------------
# preflight — fail before touching anything
# ---------------------------------------------------------------------------
do_preflight() {
  require_cmds restic ssh jq docker sqlite3 curl numfmt stat find

  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would install ${EXCLUDES_SRC} -> ${EXCLUDES}"
    log "dry-run: would assert RESTORE.md, NAS reachability, passwordless sudo,"
    log "dry-run: repo openable, source <= ${MAX_SOURCE_GB}G (excludes applied), then take the run lock"
    log "dry-run: repository=${RESTIC_REPOSITORY}"
    log "dry-run: staging=${STAGE} state=${STATE}"
    log "dry-run: snapshot retention=${SNAPSHOT_RETENTION_DAYS}d (${SNAPSHOT_RETENTION_WEEKS} weeks)"
    return 0
  fi

  : "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set (Doppler um790-backup/prd)}"

  # The restore path is the product, not an afterthought; no documented restore
  # means no backup.
  [[ -f /srv/RESTORE.md ]] \
    || die "RESTORE.md missing at /srv/RESTORE.md — restore path undocumented, refusing to back up"
  [[ -d /srv ]] || die "/srv is not mounted (read-only bind missing?)"

  # Everything writable hangs off BASE, so prove it is a mount and not the image
  # filesystem before writing a single file into it.
  [[ -d $BASE ]] || die "writable state mount ${BASE} missing (compose volume not mounted?)"
  install -d -m 0700 "$STATE" "$CACHE" || die "cannot create state/cache under ${BASE}"
  [[ -w $BASE ]] || die "${BASE} is not writable by uid $(id -u)"

  # A new run starts with no failure reason. The reason file is written by a
  # failed phase and consumed by the fail container of the SAME run (they are
  # both keyed on DAG_RUN_ID as well), and this is the third guard: a run whose
  # failure predates both of them must not hand its cause to tonight's message.
  rm -f "$STATE/last_failure" 2>/dev/null || true

  # Install the exclude list BEFORE any network work. It is a local precondition:
  # if the image was built without deploy/exclude.txt there is no backup worth
  # making, and finding that out after the NAS round-trip and under a taken lock
  # would mean a failed run has to be cleaned up rather than simply not started.
  #
  # `backup` hard-fails when $EXCLUDES is absent, and this is what guarantees it is
  # present in THAT container: $BASE is the one path both containers share.
  [[ -f $EXCLUDES_SRC ]] \
    || die "exclude list ${EXCLUDES_SRC} missing from the image — deploy/exclude.txt was not COPYed in"
  [[ -s $EXCLUDES_SRC ]] \
    || die "exclude list ${EXCLUDES_SRC} is empty — refusing to run with no excludes"
  install -m 0644 "$EXCLUDES_SRC" "$EXCLUDES" \
    || die "cannot install ${EXCLUDES_SRC} -> ${EXCLUDES}"
  # Count real patterns, not blank lines and not the explanatory comments: a
  # "36 patterns" log line that is mostly prose is worse than no number at all.
  log "installed exclude list ($(grep -cvE '^[[:space:]]*(#|$)' "$EXCLUDES" || true) patterns) -> ${EXCLUDES}"

  # Loaded from the copy just installed, so the guard below and the drift scan in
  # do_dumps measure the same set restic will.
  load_excludes

  # THE EXCLUDE LIST MUST NOT COVER $BASE ITSELF. This is asserted rather than
  # trusted, because the failure it causes is silent and total: restic drops an
  # explicitly named target that sits under an excluded ancestor, so a single
  # `/srv/.um790-backup` line voids `restic backup /srv "$STAGE"` and every phase
  # still reports success. That exact line was in this file's history and cost two
  # snapshots their entire database payload. Checking it here fails the run before
  # anything is staged, instead of after ~15 minutes of dumping.
  if grep -qxF "$BASE" "$EXCLUDES" 2>/dev/null; then
    die "exclude list excludes ${BASE} itself — that silently voids the explicit 'restic backup /srv \${STAGE}' target. Exclude ${BASE}'s children instead (state, cache, ssh, staging/.tmp)"
  fi

  # A lock from a crashed run must not block forever, but a lock that is hours old
  # is more likely a genuinely stuck run than a corpse.
  if [[ -f $STATE/run.lock ]]; then
    local lock_age
    lock_age=$(( $(stamp) - $(stat -c %Y "$STATE/run.lock") ))
    if (( lock_age < 43200 )); then
      die "run.lock present (${lock_age}s old) — another run is in flight, or a crashed one; inspect $STATE/run.lock"
    fi
    log "stale run.lock (${lock_age}s) — taking over"
  fi

  nas_ssh true || die "NAS ${NAS_HOST}:${NAS_PORT} unreachable as ${NAS_USER}"
  nas_ssh "sudo -n true" \
    || die "passwordless sudo on the NAS failed — the snapshot phase would fail later; failing now"

  restic_run cat config >/dev/null \
    || die "restic cannot open ${RESTIC_REPOSITORY} (wrong password, wrong path, or key not mounted)"

  # Measured the way do_backup will walk it: excluded subtrees pruned, not
  # subtracted after the fact. `du -sx /srv` answered a different question and made
  # a correct source look 19G too large.
  local src_gb
  src_gb=$(measure_source_gb) \
    || die "cannot measure the source size (see the ERROR line above for the raw find/awk total)"
  (( src_gb <= MAX_SOURCE_GB )) \
    || die "source is ${src_gb}G with excludes applied, above MAX_SOURCE_GB=${MAX_SOURCE_GB} — wrong mount, or raise the limit deliberately"

  # Staging is wiped every run: it must be a clean restore input, never a
  # carry-over. State lives beside it and is never wiped.
  rm -rf "$STAGE"
  install -d -m 0700 "$STAGE" "$STAGE/config" "$STAGE/sqlite" "$STAGE/pg" "$STAGE/.tmp"

  printf '%s\n' "${DAG_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}" > "$STATE/run.lock"
  stamp > "$STATE/backup_start.epoch"
  log "preflight ok (run $(cat "$STATE/run.lock"), source ${src_gb}G after excludes, repo ${RESTIC_REPOSITORY})"
}

# ---------------------------------------------------------------------------
# config — containers reconstructed from docker inspect
# ---------------------------------------------------------------------------
do_config() {
  local out=$STAGE/config

  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would 'docker ps -a' and 'docker inspect' every container into ${out}"
    log "dry-run: would scrub PASSWORD/SECRET/TOKEN/API_KEY values, keeping the keys"
    return 0
  fi

  require_cmds docker
  # Without the socket mounted this fails here rather than producing a backup that
  # silently contains no container configuration.
  docker ps >/dev/null 2>&1 \
    || die "docker daemon unreachable — mount /var/run/docker.sock into the container"

  [[ -d $out ]] || die "${out} missing — the preflight phase did not run in this cycle"

  docker ps -a --format '{{.Names}}' | sort > "$out/containers.txt"
  local n
  n=$(grep -c . "$out/containers.txt" || true)
  n=${n:-0}
  (( n >= EXPECTED_MIN_CONTAINERS )) \
    || die "only ${n} containers visible, expected >= ${EXPECTED_MIN_CONTAINERS} — wrong docker context?"

  local c
  while read -r c; do
    [[ -n $c ]] || continue
    docker inspect "$c" --format '{{json .}}' > "$out/${c}.json" \
      || die "docker inspect failed for $c"
  done < "$out/containers.txt"

  # The inspect output carries the whole environment, passwords included. Blank the
  # values but keep the keys, so the shape of a config stays recoverable from a
  # backup that may end up on a less-trusted disk.
  local f
  while read -r f; do
    sed -i -E 's/((PASSWORD|SECRET|TOKEN|APIKEY|API_KEY|PRIVATE_KEY)[A-Z_]*=)[^",\\]*/\1__REDACTED__/g' "$f"
  done < <(grep -rIlE '(PASSWORD|SECRET|TOKEN|APIKEY|API_KEY|PRIVATE_KEY)=' "$out" 2>/dev/null || true)

  log "config staged for ${n} containers"
}

# ---------------------------------------------------------------------------
# dumps — 4 Postgres, one entry per SQLITE_DBS
# ---------------------------------------------------------------------------
do_dumps() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would pg_dump ${#PG_CONTAINERS[@]} containers: ${PG_CONTAINERS[*]}"
    log "dry-run: would .backup + VACUUM INTO ${#SQLITE_DBS[@]} SQLite DBs, then integrity_check each copy"
    log "dry-run: on .backup failure would copy main+-wal into staging and dump the copy (read-only CANTOPEN case)"
    log "dry-run: would fail on any >10M *.db under /srv that is not on the list, not STATIC_SQLITE, and not excluded (drift hole)"
    return 0
  fi

  require_cmds docker sqlite3 find timeout
  [[ -d $STAGE/pg ]] || die "${STAGE} missing — the preflight phase did not run in this cycle"
  [[ $SQLITE_BACKUP_TIMEOUT =~ ^[0-9]+$ ]] \
    || die "SQLITE_BACKUP_TIMEOUT='${SQLITE_BACKUP_TIMEOUT}' is not a whole number of seconds"

  local c out sz user db
  for c in "${PG_CONTAINERS[@]}"; do
    # Dumping through the server's own binary guarantees the version matches
    # exactly. The password never leaves the container: pg_dump reads PGPASSWORD
    # from the container's own environment.
    user=$(docker exec "$c" sh -c 'printf %s "${POSTGRES_USER:-postgres}"' 2>/dev/null) \
      || die "pg container ${c} not running (or has no shell)"
    db=$(docker exec "$c" sh -c 'printf %s "${POSTGRES_DB:-postgres}"' 2>/dev/null) || db=""
    [[ -n $user && -n $db ]] || die "${c}: cannot read POSTGRES_USER/POSTGRES_DB"
    log "pg ${c}: dumping ${user}@${db}"

    out=$STAGE/pg/${c}.dump
    docker exec "$c" sh -c 'exec pg_dump -U "$1" -d "$2" -Fc' _ "$user" "$db" > "$out" \
      || die "pg_dump failed for ${c}"

    # An exit-0 empty dump is the classic "successful" backup that restores nothing.
    [[ $(head -c 5 "$out") == "PGDMP" ]] || die "${c}: dump is not custom-format (empty or truncated)"
    sz=$(stat -c %s "$out")
    (( sz > 4096 )) || die "${c}: dump implausibly small (${sz}B)"
    log "pg ${c} -> ${sz}B"
  done

  local entry name tmp dbpath started elapsed rc
  for entry in "${SQLITE_DBS[@]}"; do
    dbpath=${entry%%|*}
    name=${entry##*|}
    [[ -f $dbpath ]] || die "sqlite ${name} missing at ${dbpath} (moved, renamed, or wrong mount)"

    tmp=$STAGE/.tmp/${name}.db
    out=$STAGE/sqlite/${name}.db

    # IDEMPOTENT ACROSS RETRIES, and this is not tidiness. Dagu retries the failed
    # STEP, not the run, so preflight - the phase that wipes staging - does not run
    # again. A retry therefore starts with the previous attempt's partial output in
    # place, and `VACUUM INTO` refuses an existing destination:
    #     Error: stepping, output file already exists
    # On 2026-10-28 the drift guard correctly failed the first attempt, and both
    # automatic retries then died at msgvault with that error instead - a retry
    # that cannot succeed, reporting a fault unrelated to the real one and
    # burying it. These three files are this entry's own scratch and nothing
    # else's, so clearing them is safe: staging is disposable by contract and
    # preflight deletes all of it at the start of every cycle.
    rm -f "$tmp" "$out" "$STAGE/.tmp/${name}.err"

    # PRIMARY PATH: .backup against the live database, through the read-only mount.
    #
    # .backup is the online-backup API: it takes the copy under the right locking.
    # VACUUM INTO then compacts the COPY, never the live database.
    #
    # It is also the only path that captures a live writer's uncheckpointed
    # commits. With a -wal file present, SQLite builds the WAL index in heap and
    # .backup over a read-only mount returns the WAL content too - verified by
    # provoking a writer, not by reading documentation. Do NOT replace this with a
    # plain copy: that would be a regression, not a simplification.
    #
    # IT FAILS IN EXACTLY ONE REAL CASE, AND THE FAILURE IS NOT A LOCK.
    # If a database is WAL-mode AND has no -wal file at dump time, SQLite must
    # enter WAL mode properly, which means CREATE the -shm file. /srv is mounted
    # :ro, so that open gets EROFS and SQLite reports
    #     Error: unable to open database file     (SQLITE_CANTOPEN, 14)
    # instantly - nothing is locked and no writer is involved.
    #
    # The previous message here guessed "(database locked?)", which is what sent the
    # first investigation hunting for a concurrent writer. CANTOPEN is 14;
    # SQLITE_BUSY is 5. The hint was simply wrong, and a wrong hint is worse than
    # no hint because it is a confident one.
    #
    # mailroom is the database that lands in this state, and the reason is timing
    # rather than damage: its writers are short-lived, and SQLite deletes the -wal
    # on the last clean close, so at 03:00 there is nothing to read. The other five
    # keep a persistent connection, keep a live -wal, and never reach this branch -
    # which is why their success is not evidence that mailroom is fine.
    started=$(stamp)
    if timeout "$SQLITE_BACKUP_TIMEOUT" sqlite3 "$dbpath" ".backup '${tmp}'" 2>"$STAGE/.tmp/${name}.err"; then
      rm -f "$STAGE/.tmp/${name}.err"
    else
      rc=$?
      # 124 is `timeout`'s own status, not SQLite's: the copy was still making
      # progress (or still waiting on a lock) when the deadline hit. Named
      # separately because "failed" would read as a broken database when the
      # truth is "this database would not hold still long enough for the online
      # copy" - and the fallback below handles exactly that case.
      if (( rc == 124 )); then
        log "WARNING: ${name}: .backup hit the ${SQLITE_BACKUP_TIMEOUT}s deadline against the live database (locked or changing); using the staged copy"
      fi
      # FALLBACK: copy main + -wal into writable staging, then dump the copy.
      #
      # WHY THE -wal COMES TOO. Copying the main file alone would look like a fix
      # and be a regression: with a writer attached, recent commits live only in
      # the -wal, so a main-only copy is a view as of the last checkpoint -
      # arbitrarily stale. Copying main while a checkpoint is writing pages back
      # can also be a page-granularity torn read, and integrity_check may pass on a
      # torn-but-plausible copy. Copying the pair and letting SQLite replay the WAL
      # on the writable copy preserves the same fidelity as the primary path.
      #
      # The -shm is deliberately NOT copied: it is rebuildable and SQLite creates
      # its own on the writable copy.
      #
      # WHY NOT JUST MOUNT THOSE DIRECTORIES rw. Because opening a WAL database
      # writable is not passive: SQLite would create and later delete -wal/-shm,
      # may run WAL recovery, and closing the last connection can trigger a
      # checkpoint that writes into the LIVE main file. The failure mode would not
      # be "the backup is wrong", it would be "the backup perturbed the thing it
      # was backing up" - and it would contradict the wrapper's documented
      # `-v /srv:/srv:ro` contract.
      #
      # RESIDUAL RISK, stated rather than papered over: the copy is not atomic. In
      # the presence of a mid-copy checkpoint, copying main+wal can still be torn.
      # The mitigations are the integrity_check below and the fact that this branch
      # is only reached for a database that was unopenable read-only, which in
      # practice means no -wal, which means no checkpoint in flight.
      #
      # THAT MITIGATION IS WEAKER THAN IT WAS, and the deadline above is why. When
      # this branch was only reachable through CANTOPEN, "no -wal at dump time" was
      # the usual state and no checkpoint could be in flight. A timeout can also
      # land here WITH a live -wal - i.e. with a writer attached and a checkpoint
      # possible - so the torn-copy risk is now reachable too, not just theoretical.
      # It is still the better failure: integrity_check runs on the dumped copy
      # below, and a torn copy that passes it was indistinguishable from a good one
      # under the old code anyway. What the deadline buys is bounded time, and what
      # it costs is stated here rather than discovered later.
      local cpdir=$STAGE/.tmp/${name}.src
      rm -rf "$cpdir"
      install -d -m 0700 "$cpdir"
      cp -p "$dbpath" "$cpdir/${name}.db" \
        || die "${name}: .backup failed ($(tail -n1 "$STAGE/.tmp/${name}.err" 2>/dev/null)) and cp of the main file failed too"
      if [[ -f ${dbpath}-wal ]]; then
        cp -p "${dbpath}-wal" "$cpdir/${name}.db-wal" \
          || die "${name}: cp of ${dbpath}-wal failed"
        log "WARNING: ${name}: .backup failed; falling back to a staged copy INCLUDING -wal (uncheckpointed commits preserved)"
      else
        log "WARNING: ${name}: .backup failed and no -wal exists at dump time; falling back to a staged copy of the quiescent main file"
      fi
      timeout "$SQLITE_BACKUP_TIMEOUT" sqlite3 "$cpdir/${name}.db" ".backup '${tmp}'" \
        || { rc=$?; die "${name}: .backup failed on the staged copy as well (exit ${rc}: 124 = deadline, 14 = CANTOPEN, 5 = locked; check the mount and the -wal)"; }
      rm -rf "$cpdir"
      rm -f "$STAGE/.tmp/${name}.err"
      log "${name}: staged-copy fallback succeeded"
    fi

    sqlite3 "$tmp" "VACUUM INTO '${out}'" || die "${name}: VACUUM INTO failed"
    sqlite3 "$out" 'PRAGMA integrity_check;' | grep -qx ok \
      || die "${name}: dumped copy fails integrity_check"
    sz=$(stat -c %s "$out")
    (( sz > 4096 )) || die "${name}: dumped copy implausibly small (${sz}B)"
    elapsed=$(( $(stamp) - started ))
    # The duration is APPENDED to the line, not substituted for anything: a dump
    # that took 2h17m and one that took 1s used to look identical in this log,
    # which is why a 2h stall had to be reconstructed from timestamps on two
    # neighbouring lines instead of read off the line that reports the work.
    log "sqlite ${name} -> ${sz}B ($(human_duration "$elapsed"))"
    rm -f "$tmp"
  done

  # A new database nobody added to the list is a silent hole in coverage. Fail on
  # it - but only when the database is actually IN the backup. Scanning raw /srv
  # reported files under excluded paths, which restic never copies and which are
  # therefore not a coverage gap at all: the failure was unfixable except by
  # exempting the path or by adding a database to SQLITE_DBS that would then be
  # dumped and backed up twice.
  #
  # Without the exclude list this check is worse than useless, because every
  # excluded database would be reported, so a missing list is its own error rather
  # than a blind scan.
  #
  # THE SIZE THRESHOLD IS A BLIND SPOT, BY CONSTRUCTION. Only *.db > 10M is
  # scanned, so a small live database is copied raw by restic and never reported.
  # That is why potato/n8n/vikunja had to be found by hand rather than by this
  # guard. The threshold exists to avoid failing on every trivial SQLite file in
  # the tree; it is not a statement that small databases are safe to copy live.
  #
  # "$BASE" is pruned explicitly, so the dumps this phase just staged are not
  # scanned as undiscovered live databases - they are over 10M and would every one
  # of them trip this guard otherwise.
  load_excludes
  (( ${#EXCLUDE_OR[@]} )) \
    || die "exclude list ${EXCLUDES} is missing or has no patterns — the SQLite drift scan would be exclude-blind, so it cannot tell a coverage hole from an excluded file; did preflight complete?"

  # NOTE: written as `if`, not `[[ ]] && known=1` - under `set -e` a failing
  # AND-list as the last command in a loop body exits the shell silently, which
  # would kill this phase with no message on the first non-matching entry.
  local f known e static_hit
  while read -r f; do
    [[ -n $f ]] || continue
    known=0
    for e in "${SQLITE_DBS[@]}"; do
      if [[ ${e%%|*} == "$f" ]]; then
        known=1
      fi
    done
    if (( ! known )); then
      # A frozen pre-migration copy satisfies the check by being categorically
      # different from a live database, not by being excused from coverage: it is
      # still backed up, verbatim, by the restic run in do_backup.
      static_hit=0
      for e in "${STATIC_SQLITE[@]}"; do
        # The DIRECTORY is compared literally and only the BASENAME is a pattern,
        # which keeps the exemption anchored to one directory. `[[ $f == $e ]]` on
        # the whole path would let the pattern's `*` cross a `/` - bash's [[ ]]
        # globbing has no FNM_PATHNAME - so .../backups/mailroom_pre_*.db would
        # also match .../backups/mailroom_pre_x/live.db, exempting a live database
        # in a suffixed subdirectory from the drift scan while restic copied it
        # mid-write. (Verified: the old form does match that path.)
        #
        # The basename side MUST stay unquoted. Quoting a pattern in [[ ]] makes it
        # a literal string compare, so `mailroom_pre_*.db` would match only a name
        # containing a real asterisk - which shipped once and left static_hit 0 for
        # the genuine files, turning into a hard die on every run. Neither bash -n
        # nor the retention suite would catch that; the harness in the commit
        # message is what asserts this line. SC2053 is disabled for the same
        # reason: the glob is the point of the expression.
        # shellcheck disable=SC2053
        if [[ ${f%/*} == "${e%/*}" && ${f##*/} == ${e##*/} ]]; then
          static_hit=1
        fi
      done
      if (( ! static_hit )); then
        die "undiscovered SQLite >10M in the backup set: ${f} — add it to SQLITE_DBS if it is live, or to STATIC_SQLITE if it is a frozen copy that needs no dump, or exclude it in deploy/exclude.txt if it need not be backed up at all"
      fi
    fi
  done < <(find /srv -xdev \
             \( "${EXCLUDE_OR[@]}" -o -path "$STAGE" -o -path "$BASE" \) -prune -o \
             -type f -name '*.db' -size +10M -print 2>/dev/null || true)

  # The STATIC_SQLITE exemption rests entirely on "nothing writes to this file", and
  # that premise can quietly stop holding - at which point the entry keeps its
  # exemption and restic starts copying a live database mid-write while the scan
  # above says there is nothing to see. mtime is the only evidence available from
  # inside the container: /proc here shows container processes only, so "is a host
  # process holding the fd open" is not answerable, but a recently written file is.
  #
  # WARNING, not fatal: a freshly taken pre-migration copy is complete rather than
  # torn, and failing the run for the legitimate case would train people to widen
  # the exemption. The operator reading this line is the check.
  local m mt age
  for e in "${STATIC_SQLITE[@]}"; do
    for m in $e; do
      [[ -f $m ]] || continue
      mt=$(stat -c %Y "$m" 2>/dev/null) || continue
      age=$(( $(stamp) - mt ))
      if (( age < STATIC_SQLITE_MAX_AGE_DAYS * 86400 )); then
        log "WARNING: ${m} matches a STATIC_SQLITE exemption but was written ${age}s ago (limit $(( STATIC_SQLITE_MAX_AGE_DAYS * 86400 ))s) — if something now maintains it, move it to SQLITE_DBS so it gets dumped"
      fi
    done
  done

  log "dumps ok"
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
do_backup() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would 'restic backup /srv ${STAGE}' with --exclude-file=${EXCLUDES}"
    log "dry-run: tags um790,run:<id>, --host um790, --retry-lock 5m"
    log "dry-run: then would read the snapshot back and assert the staged payload is IN it"
    return 0
  fi

  require_cmds restic jq

  # Refuse to record a snapshot that is missing the phase outputs. restic would
  # happily back up /srv alone and report success.
  #
  # THESE CHECKS READ STAGING ON DISK, and that is exactly why they could not
  # detect the exclude defect that voided staging for two full runs: the files were
  # present, correct and complete here, and absent from the snapshot. They are kept
  # because they catch a different failure (a phase that did not run at all) early,
  # but the claim they support is only "the phase ran", not "the data is backed up".
  # assert_snapshot_contents below is what supports the latter.
  [[ -f $STATE/run.lock ]] || die "no run.lock — preflight did not run in this cycle"
  [[ -f $STAGE/config/containers.txt ]] || die "no container config staged — the config phase did not run"
  local pg sqlite
  pg=$(find "$STAGE/pg" -name '*.dump' -type f 2>/dev/null | grep -c . || true)
  sqlite=$(find "$STAGE/sqlite" -name '*.db' -type f 2>/dev/null | grep -c . || true)
  (( ${pg:-0} >= ${#PG_CONTAINERS[@]} )) \
    || die "only ${pg:-0}/${#PG_CONTAINERS[@]} Postgres dumps staged — refusing to back up an incomplete set"
  (( ${sqlite:-0} >= ${#SQLITE_DBS[@]} )) \
    || die "only ${sqlite:-0}/${#SQLITE_DBS[@]} SQLite dumps staged — refusing to back up an incomplete set"

  local run_id
  run_id=$(cat "$STATE/run.lock")

  # preflight installs the exclude list into $BASE, and $BASE is the mount this
  # container shares with it - so this failing means preflight did not complete,
  # not that the list needs fetching. Without excludes the backup silently swallows
  # Postgres data directories and caches, so this stays a hard stop.
  [[ -f $EXCLUDES ]] \
    || die "exclude file ${EXCLUDES} missing — preflight installs it from ${EXCLUDES_SRC}; did preflight complete?"

  restic_run backup /srv "$STAGE" \
    --exclude-file="$EXCLUDES" \
    --tag um790 --tag "run:${run_id}" \
    --host um790 \
    --retry-lock 5m \
    || die "restic backup failed"

  # PROVE IT LANDED. `restic backup` exiting 0 means it wrote a snapshot, not that
  # the snapshot contains what the run was for. The tag is the handle: it is set on
  # this snapshot only, so a stale snapshot from an earlier run can never satisfy
  # the check.
  local snap
  snap=$(restic_run snapshots --tag "run:${run_id}" --json 2>/dev/null \
           | jq -r 'if length > 0 then .[0].id else empty end' || true)
  [[ -n $snap ]] \
    || die "restic reported success but no snapshot carries tag run:${run_id} — cannot verify what was written"
  assert_snapshot_contents "$snap"

  stamp > "$STATE/backup_done.epoch"
  log "backup ok (run ${run_id})"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
do_check() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would 'restic unlock' to retire locks left by a restic that died before releasing them"
    log "dry-run: would 'restic check' with --read-data-subset=${CHECK_READ_SUBSET} --retry-lock ${CHECK_RETRY_LOCK}"
    return 0
  fi
  require_cmds restic

  # RETIRE THE STALE LOCK BEFORE ASKING FOR AN EXCLUSIVE ONE. See CHECK_RETRY_LOCK
  # for the run this comes from. Plain `unlock` — never `--remove-all`: without
  # that flag restic removes a lock only when its timestamp is past the 30m stale
  # window, or when it was written by this host and the PID is gone. A LIVE restic
  # refreshes its lock every 5m, so a lock that is still in use is never past that
  # window — that refresh is what makes this safe to run against a repository
  # another process is legitimately using. `--remove-all` skips both checks and
  # would evict a running backup, which is exactly why it must not appear here.
  #
  # The count is logged because 0 is the boring, expected number. Anything else
  # means some restic invocation outlived its process and left the repository
  # blocked for everyone who needs an exclusive lock, and that is worth seeing in
  # the run log instead of being discovered as a mystery failure next month.
  # `-v` is load-bearing: restic 0.18 (the pinned version) only reports how many
  # locks it removed at verbose level, so without it a removal is silent.
  local unlock_out lock_count
  if unlock_out=$(restic_run unlock -v 2>&1); then
    lock_count=$(printf '%s\n' "$unlock_out" \
      | sed -n 's/.*successfully removed \([0-9][0-9]*\) lock.*/\1/p' | head -n 1)
    lock_count=${lock_count:-0}
    log "unlock: removed ${lock_count} stale lock(s)"
    if (( lock_count > 0 )); then
      log "unlock: ${lock_count} lock(s) were held by processes that no longer exist — some restic run died mid-flight; the lock's own PID/time is in 'restic list locks' if it recurs"
    fi
  else
    # NOT fatal: `check` below needs the same repository and fails with the real
    # error if it is genuinely unreachable. Dying here would replace a specific
    # restic message with a vaguer one and skip the phase's own diagnostics.
    log "WARNING: restic unlock failed; continuing to check, which reports the underlying error"
  fi

  restic_run check --read-data-subset="$CHECK_READ_SUBSET" --retry-lock "$CHECK_RETRY_LOCK" \
    || die "restic check failed"
  log "check ok (read-data-subset=${CHECK_READ_SUBSET})"
}

# ---------------------------------------------------------------------------
# snapshot — must exist BEFORE prune, in this same run
# ---------------------------------------------------------------------------
do_snapshot() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would create a '${SNAPSHOT_MODE}' snapshot of ${SHARE} on ${NAS_HOST}"
    log "dry-run: would assert the snapshot count increased, then write snapshot.epoch"
    return 0
  fi
  require_cmds ssh
  nas_ssh "sudo -n /usr/syno/sbin/synosharesnapshot list '${SHARE}' >/dev/null" \
    || die "cannot read the snapshot list for ${SHARE} — synosharesnapshot is root-only, so this is the sudo path"

  local before after ts
  before=$(snapshot_count)

  case $SNAPSHOT_MODE in
    share)
      nas_ssh "sudo -n /usr/syno/sbin/synosharesnapshot create '${SHARE}'" \
        || die "snapshot create failed"
      ;;
    subvol)
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      nas_ssh "sudo -n btrfs subvolume snapshot -r /volume1/${SHARE} /volume1/${SHARE}-snap-${ts}" \
        || die "subvolume snapshot failed"
      ;;
    *) die "unknown SNAPSHOT_MODE=${SNAPSHOT_MODE}" ;;
  esac

  after=$(snapshot_count)
  (( after > before )) \
    || die "snapshot count did not increase (${before} -> ${after}) — treating a silent no-op as failure"

  stamp > "$STATE/snapshot.epoch"
  log "snapshot created (${before} -> ${after} snapshots)"
}

# ---------------------------------------------------------------------------
# prune — the one phase that can destroy history
# ---------------------------------------------------------------------------
do_prune() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would require snapshot.epoch >= backup_start.epoch and < ${SNAPSHOT_MAX_AGE}s old"
    log "dry-run: would 'restic forget ${RESTIC_KEEP_ARGS[*]}' (dry-run first)"
    log "dry-run: would delete ${SHARE} snapshots older than ${SNAPSHOT_RETENTION_DAYS}d, never the newest"
    return 0
  fi
  require_cmds restic ssh jq

  # Guard 1: a fresh snapshot from THIS run. A snapshot from a previous cycle is
  # at least one full interval stale and protects nothing that matters.
  [[ -f $STATE/snapshot.epoch ]] \
    || die "no snapshot.epoch — the snapshot phase did not succeed; refusing to prune"
  local snap start age
  snap=$(cat "$STATE/snapshot.epoch")
  [[ -f $STATE/backup_start.epoch ]] \
    || die "no backup_start.epoch — cannot prove the snapshot postdates this run"
  start=$(cat "$STATE/backup_start.epoch")

  (( snap >= start )) \
    || die "snapshot (${snap}) predates this run's backup start (${start}) — refusing to prune"
  age=$(( $(stamp) - snap ))
  (( age <= SNAPSHOT_MAX_AGE )) \
    || die "snapshot is ${age}s old, limit ${SNAPSHOT_MAX_AGE}s — refusing to prune"

  # Guard 2: the repo actually holds a snapshot from this run.
  local latest latest_epoch
  latest=$(restic_run snapshots --latest 1 --json | jq -r '.[0].time // empty')
  [[ -n $latest ]] || die "cannot read the newest restic snapshot — refusing to prune"
  latest_epoch=$(date -u -d "$latest" +%s 2>/dev/null || true)
  [[ -n $latest_epoch ]] || die "cannot parse newest snapshot time '${latest}' — refusing to prune"
  (( latest_epoch >= start )) \
    || die "newest restic snapshot (${latest}) predates this run — refusing to prune"

  # Show what dies, then kill it.
  restic_run forget "${RESTIC_KEEP_ARGS[@]}" --dry-run \
    || die "forget --dry-run failed — not proceeding to a real forget"
  restic_run forget "${RESTIC_KEEP_ARGS[@]}" --prune \
    || die "restic forget --prune failed"

  # Snapshot sweep, age-based rather than positional: DSM's list order is not
  # documented, and a positional rule here deletes the wrong point in time. The
  # selection itself lives in select_sweep_candidates so scripts/test-retention.sh
  # can drive it offline.
  local names total
  names=$(snapshot_names | grep . || true)
  total=$(printf '%s\n' "$names" | grep -c . || true)
  total=${total:-0}
  log "snapshots before sweep: ${total} (retention ${SNAPSHOT_RETENTION_DAYS}d = ${SNAPSHOT_RETENTION_WEEKS} weeks)"

  local doomed=()
  if (( total > 0 )); then
    # The selector logs unparseable names and never returns the newest snapshot,
    # so there is always a point in time left to restore to.
    mapfile -t doomed < <(printf '%s\n' "$names" \
      | select_sweep_candidates "$(stamp)" "$SNAPSHOT_RETENTION_DAYS")
  fi

  # A sweep that parsed NOTHING while there were names to parse is a parser
  # failure, not a no-op, and it fails silently in the direction of "safety"
  # (nothing deleted) while snapshots accumulate forever. The count is the only
  # place that is visible, so it is asserted here.
  if (( total > 0 )) && (( ${#doomed[@]} == 0 )); then
    local parsed
    parsed=$(printf '%s\n' "$names" | while read -r n; do
      [[ -n $n ]] || continue
      [[ -n $(snapshot_epoch "$n") ]] && printf 'x'
    done | grep -c x || true)
    if (( ${parsed:-0} == 0 )); then
      die "parsed 0 of ${total} snapshot names — the sweep would delete nothing; check the name format against synosharesnapshot list output"
    fi
  fi

  if (( ${#doomed[@]} == 0 )); then
    log "no snapshots older than ${SNAPSHOT_RETENTION_DAYS}d; sweep is a no-op"
  else
    log "deleting ${#doomed[@]} snapshot(s) older than ${SNAPSHOT_RETENTION_DAYS}d: $(join_space "${doomed[@]}")"

    # THE ARGV IS BUILT BY A PURE FUNCTION, and the failure is FATAL.
    #
    # Both halves of this were wrong and only showed up when the sweep finally had
    # more than one name to delete (2026-10-22, forced with SNAPSHOT_RETENTION_DAYS=0):
    #
    #   1. The command was assembled with "${quoted[*]}", which joins on the FIRST
    #      character of IFS - a newline in this file. Two names therefore became one
    #      argument containing a newline; the remote shell deleted the first and
    #      tried to EXECUTE the second ("command not found", exit 127). One of two
    #      snapshots died. See snapshot_delete_cmd for the quoting rationale.
    #
    #   2. The call was `nas_ssh ... || log "WARNING: snapshot delete failed"`, so
    #      that exit 127 left the phase reporting `prune ok`. A partial delete was
    #      indistinguishable from a clean one, and the only trace was a WARNING in a
    #      log nobody reads on success.
    #
    # A delete that does not happen must fail the step: the snapshots are the undo
    # that does not need the repository to be readable, and silently failing to
    # maintain them is how the retention window quietly collapses. It stops SHORT of
    # the restic work already done above - there is nothing to roll back - but the
    # phase exits non-zero so the run is not reported healthy.
    local cmd
    if ! cmd=$(snapshot_delete_cmd "$SHARE" "${doomed[@]}"); then
      die "refusing to build a delete command: a snapshot name contains a single quote, which cannot be safely wrapped for the remote shell"
    fi
    log "delete command: ${cmd}"

    if nas_ssh "$cmd"; then
      log "deleted ${#doomed[@]} snapshot(s)"
    else
      die "snapshot delete FAILED for ${#doomed[@]} name(s) — snapshots will accumulate and the retention window will silently shrink; the repository was already pruned, so re-run this phase once the cause is fixed"
    fi

    # Deleted names are only claimed if the count actually moved. A delete that
    # exits 0 without removing anything is a different failure from one that exits
    # non-zero, and it is the more dangerous of the two because it looks like
    # success.
    local after_count
    after_count=$(snapshot_count)
    local expected=$(( total - ${#doomed[@]} ))
    if (( after_count != expected )); then
      die "snapshot count is ${after_count} after deleting ${#doomed[@]} of ${total} (expected ${expected}) — the delete did not remove what it selected"
    fi
    log "snapshot count ${total} -> ${after_count}"
  fi

  log "prune ok"
}

# ---------------------------------------------------------------------------
# status — heartbeat written only when every phase succeeded
# ---------------------------------------------------------------------------
do_status() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would write $STATE/last_success.json, release the lock, notify on success"
    return 0
  fi
  require_cmds restic jq

  local snapshots bytes duration tmp run_id started
  local containers pg sqlite
  snapshots=$(restic_run snapshots --json | jq 'length')
  bytes=$(restic_run stats --mode raw-data --json | jq -r '.total_size // 0')
  run_id=$(cat "$STATE/run.lock" 2>/dev/null || echo unknown)
  started=$(cat "$STATE/backup_start.epoch" 2>/dev/null || stamp)
  duration=$(( $(stamp) - started ))

  # COVERAGE, read back off staging: this run wrote it, the next preflight wipes
  # it, so these describe THIS backup rather than a leftover.
  #
  # The container count is the config phase's `docker ps -a` roster, so it counts
  # every container the daemon knows about - EXITED ONE-SHOTS INCLUDED - and not
  # "containers whose data was backed up". What the backup captures per container
  # is its inspect/config JSON; the writable layer and anonymous volumes are never
  # in it. That is why the body says "N containers" and must never be reworded to
  # "N containers backed up": the number is evidence the daemon was reachable and
  # its roster reached the snapshot, i.e. a wrong-docker-context tripwire, not a
  # per-container data guarantee.
  #
  # The dump counts are the same quantities assert_snapshot_contents proved are IN
  # the snapshot, so they are a claim about the backup and not about staging. A
  # failed dump makes do_dumps die, so status is unreachable with a short set -
  # they are COUNTED anyway rather than read from ${#PG_CONTAINERS[@]}, so that if
  # that ever stops being true the message shows reality instead of restating an
  # expectation.
  #
  # `|| true` is load-bearing under `set -Eeuo pipefail`: `grep -c .` prints 0 and
  # exits 1 on an empty file, and without it the assignment would abort the shell
  # here - AFTER the heartbeat is written and the lock released, so the run would
  # look broken and the message would be lost.
  containers=$(grep -c . "$STAGE/config/containers.txt" 2>/dev/null || true)
  containers=${containers:-0}
  pg=$(find "$STAGE/pg" -name '*.dump' -type f 2>/dev/null | grep -c . || true)
  pg=${pg:-0}
  sqlite=$(find "$STAGE/sqlite" -name '*.db' -type f 2>/dev/null | grep -c . || true)
  sqlite=${sqlite:-0}

  # Written to a temp file and renamed, so a reader never sees half a heartbeat.
  tmp=$STATE/.last_success.$$
  cat > "$tmp" <<EOF
{
  "last_success": "$(date -u +%FT%TZ)",
  "last_success_epoch": $(stamp),
  "run_id": "${run_id}",
  "repo": "${RESTIC_REPOSITORY}",
  "snapshots": ${snapshots},
  "containers": ${containers},
  "pg_dumps": ${pg},
  "sqlite_dumps": ${sqlite},
  "repo_bytes": ${bytes},
  "duration_sec": ${duration},
  "snapshot_retention_days": ${SNAPSHOT_RETENTION_DAYS}
}
EOF
  mv -f "$tmp" "$STATE/last_success.json"
  rm -f "$STATE/run.lock"

  # THE NOTIFICATION BODY IS FOR A LOCK SCREEN, NOT A LOG.
  #
  # It used to read: run 034kNVOwLxtqLRbN8aCu67 — 1 snapshots, 12G, 889s
  #
  # Both halves of that were wrong for the medium, in ways that are only obvious
  # when you are the one glancing at a phone at 07:00:
  #
  #   1. THE RUN ID. `run_id` is Dagu's internal ULID (26 chars, base32). On a
  #      notification it sits between the reader and the numbers they
  #      actually wanted, and it answers a question nobody asks at that moment:
  #      which run was this. It is NOT lost by dropping it - it is in
  #      last_success.json (written two lines above), in the restic snapshot's
  #      `run:<id>` tag set by do_backup, and in the Dagu UI, which is the
  #      authoritative place to look up a specific run. The body's job is "did
  #      last night's backup work", answered at a glance.
  #
  #      do_fail KEEPS the run ID on purpose. A failure is precisely when you need
  #      the pointer to the run in order to investigate, and a FAILED message is
  #      read rather than glanced at.
  #
  #   2. THE SNAPSHOT COUNT, which was worse than uninteresting. It is
  #      `restic snapshots | length`, i.e. what retention has left, so it drifts
  #      with the keep policy and can read 1 on a perfectly healthy week - a
  #      number that answers a retention question for the dashboard, not "did
  #      last night's backup work", which is what the body is for. Worse, it
  #      understates a healthy backup, so the failure it invites is a reader
  #      learning to ignore the one line that tells them the backup is fine.
  #      What replaces it describes COVERAGE, which is what a glance is actually
  #      checking. The count is not lost: it stays in last_success.json and in
  #      the log line below.
  #
  # Deliberately NOT changed: `numfmt --to=iec` renders 12263703410 as "12G". That
  # is coarse (the true value is 11.42), but it is a proven call on an uncovered
  # path, and a format change here would be a behaviour change to the only line
  # that tells a human the backup is healthy. NOTHING in CI asserts this text:
  # grep for notify/num_fmt/NTFY across scripts/test-retention.sh and
  # .buildkite/pipeline.yml returns no matches, and the smoke gate's --dry-run
  # returns from this function before any of it is built.
  #
  # The DURATION got the same treatment: it used to end "..., 9180s", and 9180 is
  # not a number anyone converts to 2h33m while half-awake. It now renders through
  # human_duration as "2h33m" (or "35m", or "42s" for a run under a minute). This
  # is the one field whose value is LOST in the swap, so it is worth stating where
  # it survives: `duration_sec` in last_success.json and the log line below both
  # still carry exact seconds - the log line is unchanged on purpose, because a log
  # is read for precision and a notification is read for shape.
  #
  # Order matters and is unchanged: last_success.json is renamed into place and the
  # lock released BEFORE the notification is attempted, so a notifier outage can
  # only cost the message - it can never withhold the heartbeat or block the next
  # run on a stale lock.
  notify default "um790 backup OK" "${containers} containers, ${pg} pg + ${sqlite} sqlite dumps, $(numfmt --to=iec "$bytes"), $(human_duration "$duration")"
  log "status written (${snapshots} snapshots, ${containers} containers, ${pg} pg + ${sqlite} sqlite dumps, ${bytes}B, ${duration}s)"
}

# ---------------------------------------------------------------------------
# THE FAILURE MESSAGE. Four facts, in this order, and nothing else.
# ---------------------------------------------------------------------------
# The message that reached the operator for run 034pwBQBikAhf43qxfM06p, in full:
#
#   title: um790 backup FAILED
#   body:  run 034pwBQBikAhf43qxfM06p failed at: check
#
# It was unactionable at 03:31, and each of the four things below is one of the
# reasons why:
#
#   1. it did not name the job. "backup" is one of several jobs on this host;
#   2. "check" is a phase name, and it reads like a health check rather than the
#      restic verification that runs after the backup;
#   3. it carried no reason at all, while the phase's stderr held the single line
#      that made the incident diagnosable in seconds: `unable to create lock in
#      backend: repository is already locked by PID ...`;
#   4. "backup FAILED" does not distinguish a failed backup from a backup that
#      succeeded and whose verification then failed — which is what happened
#      (snapshot f35a24c4 was written; check, snapshot, prune and status were
#      skipped). Read from a phone, that message says there is no snapshot
#      tonight, and that was false.
#
# The counters that keep this honest: /srv on ryzen is named in the body, the
# phase is in the TITLE so it is visible without opening anything, the phase name
# is translated, the reason is the failing tool's own words, and the snapshot
# claim is DERIVED FROM THE PHASE ORDER rather than guessed (see
# failure_snapshot_state — wrong in either direction is worse than silent).

# The phase vocabulary is the script's, not the operator's. A phase missing from
# this table prints nothing and the caller falls back to the raw name: inventing
# a description for a phase we do not recognise is how a message starts lying.
phase_description() { # phase
  case ${1:-} in
    preflight) printf 'preflight checks' ;;
    config)    printf 'container config capture' ;;
    dumps)     printf 'database dumps' ;;
    backup)    printf 'restic backup' ;;
    check)     printf 'restic repository check' ;;
    snapshot)  printf 'NAS snapshot' ;;
    prune)     printf 'snapshot prune' ;;
    status)    printf 'status heartbeat' ;;
    *)         printf '' ;;
  esac
}

# WHETHER THIS RUN'S SNAPSHOT EXISTS, read off the phase order and nothing else:
#
#   preflight -> config -> dumps -> backup -> check -> snapshot -> prune -> status
#
# `backup` is the phase that writes the snapshot, so every phase after it can only
# fail on work that runs against a repository which already holds tonight's
# snapshot. A failure in check/snapshot/prune/status therefore means the DATA IS
# BACKED UP and only the verification or the bookkeeping did not finish — and a
# failure in preflight/config/dumps/backup means it is not. Unknown (including
# the wrapper's `unknown step` placeholder) gets `unknown` and the caller says
# nothing, because a confident wrong answer here is worse than no answer.
#
# Deliberately not derived from $STATE/backup_done.epoch: the phase order is a
# property of the DAG, the epoch file is a property of a mount that may be the
# very thing that failed.
failure_snapshot_state() { # phase -> after | before | unknown
  case ${1:-} in
    check|snapshot|prune|status)   printf 'after\n' ;;
    preflight|config|dumps|backup) printf 'before\n' ;;
    *)                             printf 'unknown\n' ;;
  esac
}

# A reason must never carry a credential into a notification body, into the state
# file it waits in, or into a log. Phase stderr can hold anything a tool chose to
# print, so a line shaped like a credential ASSIGNMENT is dropped outright rather
# than redacted in place: the value's length and shape are themselves information,
# and a dropped reason simply degrades to the static message, which is what the
# notifier sent before this existed.
reason_is_secret_shaped() { # text
  local t=${1:-}
  t=${t,,}
  [[ $t =~ (password|passwd|passphrase|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|authorization|bearer)[[:space:]]*[=:] ]]
}

# The failing tool's own words, out of a phase's captured stderr.
#
# Deliberately NOT "the last line". restic 0.18.1's lock failure, verbatim from
# this image against a throwaway repository:
#
#   repo already locked, waiting up to 1s for the lock
#   unable to create lock in backend: repository is already locked by PID 995832
#     on ... by nick (UID 1001, GID 100)
#   lock was created at 2026-10-31 16:01:21 (2.05136208s ago)
#   storage ID b67aeb07
#   the `unlock` command can be used to remove stale locks
#
# The LAST line there is advice, and taking it would have produced a reason that
# says nothing about the cause. So: the trailing block of non-runner lines is
# trimmed from its last error-shaped line, trailing advice is dropped, the rest
# is joined, whitespace-collapsed and capped. When the phase printed no tool line
# at all, the runner's own die message is the reason — it is usually the
# informative one ("snapshot count did not increase (8 -> 8) — ...").
#
# Every way this can come back empty (no capture, nothing usable, secret-shaped)
# means "send the static message", never "send nothing".
phase_failure_reason() { # capture-file
  local cap=${1:-}
  local -a lines=() block=()
  local i start=-1 end reason='' fallback='' line t
  # 160 chars keeps the whole body near 300 with the other three lines, which is
  # what a lock screen shows. The untruncated text is in the Dagu log either way.
  local max=160

  [[ -n $cap && -r $cap ]] || return 0
  mapfile -t lines < "$cap" || return 0
  (( ${#lines[@]} )) || return 0

  # Every line the runner writes is timestamped and bracketed; a tool's output is
  # not. `die` logs LAST, so the shape of a failure is
  #
  #   <runner line> <tool output...> <runner FATAL line>
  #
  # i.e. the tool's words are the contiguous block of non-runner lines BEFORE the
  # trailing runner lines. Earlier bad blocks elsewhere in the phase (a warning,
  # another command's chatter) are separated from this one by a runner line and
  # are therefore not considered.
  local log_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z \[[^]]*\] '
  local blank=0
  i=$(( ${#lines[@]} - 1 ))
  while (( i >= 0 )); do
    blank=0
    [[ -n ${lines[i]//[[:space:]]/} ]] || blank=1
    if (( blank )); then i=$(( i - 1 )); continue; fi
    if [[ ${lines[i]} =~ $log_re ]]; then
      # Keep the LAST runner line seen (we are walking backwards, so the first one
      # we meet is the last in the file): it is the fallback reason when the tool
      # printed nothing of its own.
      [[ -n $fallback ]] || fallback=${lines[i]}
      i=$(( i - 1 ))
      continue
    fi
    break
  done

  if (( i >= 0 )); then
    # Walk the tool's block backwards, then keep it in order.
    end=$(( i + 1 ))
    while (( i >= 0 )) && [[ -n ${lines[i]//[[:space:]]/} ]] && ! [[ ${lines[i]} =~ $log_re ]]; do
      i=$(( i - 1 ))
    done
    start=$(( i + 1 ))
    for (( i = start; i < end; i++ )); do
      block+=("${lines[i]}")
    done
  fi

  if (( ${#block[@]} )); then
    local err_re='^(unable to|fatal|error|failed|cannot|could not|no such|permission denied|panic|repository is already locked|wrong password|invalid|ssh:|signal:)'
    # Trailing advice, not cause: restic ends a lock failure with "storage ID
    # b67aeb07" then "the `unlock` command can be used to remove stale locks".
    local advice_re='^(storage id |the .*command can be used|please |try |note: )'
    for (( i = ${#block[@]} - 1; i >= 0; i-- )); do
      if [[ ${block[i],,} =~ $err_re ]]; then start=$i; break; fi
    done
    (( start >= 0 )) || start=0
    end=${#block[@]}
    while (( end > start + 1 )) && [[ ${block[end-1],,} =~ $advice_re ]]; do
      end=$(( end - 1 ))
    done
    for (( i = start; i < end; i++ )); do reason+="${block[i]} "; done
  fi

  if [[ -z $reason && -n $fallback ]]; then
    t=$fallback
    if [[ $t =~ $log_re ]]; then t=${t:${#BASH_REMATCH[0]}}; fi
    reason=$t
  fi
  reason=${reason#FATAL: }
  reason=${reason#WARNING: }
  # One line, whatever the tool printed.
  reason=$(printf '%s' "$reason" | tr -s '[:space:]' ' ')
  reason=${reason# }
  reason=${reason% }

  if (( ${#reason} > max )); then
    # Cut on a word boundary: half a number ("(2.05…") reads like corruption, and
    # the whole of it is in the log.
    reason=${reason:0:$(( max - 1 ))}
    reason="${reason% *}…"
  fi
  if reason_is_secret_shaped "$reason"; then
    return 0
  fi
  printf '%s\n' "$reason"
}

# Persist the reason for `fail` — a DIFFERENT container — to pick up.
#
# Why a file and not `-e FAIL_REASON=...`: the value would go through the
# wrapper's `docker run` argv, i.e. into the process list, which is exactly where
# the wrapper is careful not to put secrets (`-e RESTIC_PASSWORD` with no value).
# $BASE/state is the one path the failing phase and the fail container already
# share, it is excluded from the backup (deploy/exclude.txt), and the file holds
# an already-scrubbed, length-capped single line. It is consumed by do_fail and
# cleared by preflight, so a reason can never attach to a later run.
#
# Called from main AFTER the phase has exited, so it cannot change the phase's
# exit code: there is no phase left to affect.
record_failure_reason() { # phase rc capture-file
  local phase=${1:-} rc=${2:-0} cap=${3:-} reason tmp
  (( rc != 0 )) || return 0
  reason=$(phase_failure_reason "$cap" 2>/dev/null || true)
  [[ -n $reason ]] || return 0

  install -d -m 0700 "$STATE" 2>/dev/null || return 0
  tmp=$(mktemp "$STATE/.last_failure.XXXXXX" 2>/dev/null) || return 0
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! printf 'run=%s\nreason=%s\n' "${DAG_RUN_ID:-}" "$reason" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  mv -f "$tmp" "$STATE/last_failure" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  log "recorded failure reason for ${phase}: ${reason}"
}

# The reason recorded for THIS run, if any. Consumed either way: it describes one
# failure, and leaving it behind would attach this run's cause to a later message.
recorded_failure_reason() {
  local f=$STATE/last_failure run='' reason='' line
  local -a l=()
  [[ -r $f ]] || return 0
  # mapfile, not `sed | head`: IFS is $'\n\t' here and a pipeline under pipefail
  # can hand back 141 (SIGPIPE) from a `head` that quit early, which under `set -e`
  # would abort do_fail — a notifier failure changing a run's result.
  mapfile -t l < "$f" 2>/dev/null || true
  for line in "${l[@]}"; do
    case $line in
      run=*)    run=${line#run=} ;;
      reason=*) reason=${line#reason=} ;;
    esac
  done
  rm -f "$f" 2>/dev/null || true
  [[ $run == "${DAG_RUN_ID:-}" ]] || return 0
  if reason_is_secret_shaped "$reason"; then return 0; fi
  printf '%s\n' "$reason"
}

# The wrapper's placeholder for "there was no phase to name" (a hand-started
# `fail`, or a handler that could not know). It is not a phase name and must
# never be printed as one; any OTHER unrecognised name is still worth showing,
# because a future phase is a fact and "unknown step" is an absence.
phase_named() { # phase
  [[ -n ${1:-} && ${1:-} != 'unknown step' ]]
}

failure_title() { # phase
  if phase_named "${1:-}"; then
    printf 'um790 backup FAILED: %s\n' "$1"
  else
    printf 'um790 backup FAILED\n'
  fi
}

# The body. Plain text, no markdown (ntfy renders it as-is), four facts in
# priority order, ~300 characters so it is readable on a lock screen.
failure_body() { # phase reason run-id
  local where=${1:-} reason=${2:-} run_id=${3:-} desc state
  desc=$(phase_description "$where")
  state=$(failure_snapshot_state "$where")

  # 1. WHAT JOB — named as the restic backup of /srv on ryzen, because "um790
  #    backup" alone is one of several jobs on this host.
  if [[ -n $desc ]]; then
    printf 'restic backup of /srv on ryzen — %s failed' "$desc"
  elif phase_named "$where"; then
    printf 'restic backup of /srv on ryzen — %s failed' "$where"
  else
    printf 'restic backup of /srv on ryzen — failed'
  fi
  # 2. WHY — the failing tool's own words. The highest-value line, and the one
  #    the 2026-10-31 message did not carry.
  if [[ -n $reason ]]; then
    printf '\nwhy: %s' "$reason"
  fi
  # 3. WHAT STILL HOLDS — omitted entirely when the phase is unknown.
  case $state in
    after)  printf '\nsafe: this run'"'"'s snapshot is in the repository' ;;
    before) printf '\nsafe: no snapshot from this run — the backup did not finish' ;;
  esac
  # 4. WHICH RUN — the pointer into the log and the Dagu history, not buried.
  printf '\nrun %s\n' "${run_id:-?}"
}

# ---------------------------------------------------------------------------
do_fail() {
  local where="${DAG_STATUS:-unknown step}" reason title body
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would release the run lock and notify FAILED (step=${where})"
    return 0
  fi
  rm -f "$STATE/run.lock"
  # Read before anything is sent, and consumed on the way: the reason belongs to
  # this failure only. Absent, empty, unreadable or scrubbed-away all mean the
  # same thing here - the message goes out with the three static facts.
  reason=$(recorded_failure_reason || true)
  title=$(failure_title "$where")
  body=$(failure_body "$where" "$reason" "${DAG_RUN_ID:-}")
  notify high "$title" "$body"
  log "failure recorded at ${where}"
}

# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # Bare --dry-run is a validation run, not a phase: it must pass with no env.
  if [[ $DRY_RUN == 1 && -z $PHASE ]]; then
    log "validate-only: argv contract ok; phases = preflight config dumps backup check snapshot prune status fail"
    log "validate-only: repository=${RESTIC_REPOSITORY}"
    log "validate-only: staging=${STAGE} state=${STATE}"
    log "validate-only: excludes=${EXCLUDES} (from ${EXCLUDES_SRC})"
    log "validate-only: retention=${SNAPSHOT_RETENTION_DAYS}d (${SNAPSHOT_RETENTION_WEEKS} weeks)"
    log "validate-only: keep policy=$(join_space "${RESTIC_KEEP_ARGS[@]}")"
    return 0
  fi

  require_phase
  if [[ $DRY_RUN == 1 ]]; then
    log "DRY RUN — no secrets read, no repo opened, no host modified"
  fi

  # `fail` is not a phase: it is the notifier, it runs after a phase already
  # failed, and it must exit 0 on every path.
  if [[ $PHASE == fail ]]; then
    do_fail
    return 0
  fi

  # A dry run stays the trivial path: nothing to capture, nothing to notify.
  if [[ $DRY_RUN == 1 ]]; then
    dispatch_phase
    return
  fi

  local rc=0 cap=''
  cap=$(mktemp 2>/dev/null || true)
  if [[ -z $cap ]]; then
    # No scratch space: run the phase exactly as before. The cost is the reason,
    # never the run or the message.
    dispatch_phase
    return
  fi
  # STDERR IS STREAMED AND CAPTURED AT ONCE, because the two things it is needed
  # for happen at different times: the Dagu log (and a human watching a 12-minute
  # dumps phase) needs it live, and the failure message needs the last thing the
  # tool said. `2>&1 1>&4` points fd 2 at the pipe while fd 1 keeps the real
  # stdout, so the phase's own stdout is untouched; tee forwards every line.
  #
  # The phase runs in a subshell of the pipeline, so `die`'s `exit 1` ends that
  # subshell and PIPESTATUS[0] carries the phase's status up unchanged - the
  # phase's exit code is still the step's exit code. record_failure_reason runs
  # AFTER it, in this shell, when there is no phase left to disturb.
  exec 4>&1
  { dispatch_phase; } 2>&1 1>&4 | tee "$cap" >&2 || rc=$?
  exec 4>&-
  record_failure_reason "$PHASE" "$rc" "$cap" || true
  rm -f "$cap" 2>/dev/null || true
  return "$rc"
}

# The one place the phase name becomes a function call. Split out of main so the
# stderr capture above wraps the WHOLE phase and nothing else.
dispatch_phase() {
  case $PHASE in
    preflight) do_preflight ;;
    config)    do_config ;;
    dumps)     do_dumps ;;
    backup)    do_backup ;;
    check)     do_check ;;
    snapshot)  do_snapshot ;;
    prune)     do_prune ;;
    status)    do_status ;;
    *)         die "no dispatcher for phase: ${PHASE}" ;;
  esac
}

# Guarded so scripts/test-retention.sh can source this file for the real
# snapshot_epoch/select_sweep_candidates/snapshot_delete_cmd: importing must not
# run a phase.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
