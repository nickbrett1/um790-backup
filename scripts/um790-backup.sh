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
EXCLUDES="${EXCLUDES:-$BASE/exclude.txt}"

# Snapshot retention is COUNT-based against a WEEKLY prune: 8 snapshots ~= 8 weeks
# of "undo a bad prune". This is a different axis from restic's own forget policy.
KEEP_SNAPSHOTS="${KEEP_SNAPSHOTS:-8}"
SNAPSHOT_RETENTION_DAYS="${SNAPSHOT_RETENTION_DAYS:-$((KEEP_SNAPSHOTS * 7))}"
SNAPSHOT_MAX_AGE="${SNAPSHOT_MAX_AGE:-$((6 * 3600))}"

MAX_SOURCE_GB="${MAX_SOURCE_GB:-45}"
EXPECTED_MIN_CONTAINERS="${EXPECTED_MIN_CONTAINERS:-60}"
CHECK_READ_SUBSET="${CHECK_READ_SUBSET:-10%}"    # weekly cadence, so 10% each run

PG_CONTAINERS=(litellm-db mcphub-postgres miniflux-db miniflux-explore-db)
SQLITE_DBS=(
  "/srv/msgvault/msgvault.db|msgvault"
  "/srv/docker/phoenix/data/phoenix.db|phoenix"
  "/srv/docker/open-webui/data/webui.db|open-webui"
  "/srv/docker/pihole/config/pihole-FTL.db|pihole-ftl"
  "/srv/docker/mailroom/data/mailroom.db|mailroom"
  "/srv/reader/vg-books/reader.db|vg-books"
)

DRY_RUN=0
PHASE=""

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${PHASE:-validate}" "$*" >&2; }
die()  { log "FATAL: $*"; exit 1; }
stamp() { date -u +%s; }

usage() {
  cat >&2 <<'EOF'
usage: um790-backup.sh <phase> [--dry-run]
       um790-backup.sh --dry-run

phases:
  preflight  assert NAS reachable, repo openable, source sane; take the run lock
  config     reconstruct container configs from docker inspect, secrets redacted
  dumps      pg_dump the 4 Postgres DBs, VACUUM INTO the 6 SQLite DBs
  backup     restic backup /srv + staging
  check      restic check (10% data read by default)
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
snapshot_epoch() { # name -> epoch, empty on parse failure
  local name=$1 ts
  ts=$(sed -E 's/^GMT[+-][0-9]{2}-//' <<<"$name")
  date -u -d "${ts//./-}" +%s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# preflight — fail before touching anything
# ---------------------------------------------------------------------------
do_preflight() {
  require_cmds restic ssh jq docker sqlite3 curl numfmt du stat

  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would assert RESTORE.md, NAS reachability, passwordless sudo,"
    log "dry-run: repo openable, source <= ${MAX_SOURCE_GB}G, then take the run lock"
    log "dry-run: repository=${RESTIC_REPOSITORY}"
    log "dry-run: staging=${STAGE} state=${STATE}"
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

  local src_gb
  src_gb=$(du -sx --block-size=1G /srv 2>/dev/null | cut -f1)
  [[ $src_gb =~ ^[0-9]+$ ]] || die "cannot measure /srv size (du returned '${src_gb:-}')"
  (( src_gb <= MAX_SOURCE_GB )) \
    || die "source is ${src_gb}G, above MAX_SOURCE_GB=${MAX_SOURCE_GB} — wrong mount, or raise the limit deliberately"

  # Staging is wiped every run: it must be a clean restore input, never a
  # carry-over. State lives beside it and is never wiped.
  rm -rf "$STAGE"
  install -d -m 0700 "$STAGE" "$STAGE/config" "$STAGE/sqlite" "$STAGE/pg" "$STAGE/.tmp"

  [[ -f $EXCLUDES ]] || log "WARNING: $EXCLUDES missing — the backup will run WITHOUT excludes"

  printf '%s\n' "${DAG_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}" > "$STATE/run.lock"
  stamp > "$STATE/backup_start.epoch"
  log "preflight ok (run $(cat "$STATE/run.lock"), source ${src_gb}G, repo ${RESTIC_REPOSITORY})"
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
# dumps — 4 Postgres, 6 SQLite
# ---------------------------------------------------------------------------
do_dumps() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would pg_dump ${#PG_CONTAINERS[@]} containers: ${PG_CONTAINERS[*]}"
    log "dry-run: would .backup + VACUUM INTO ${#SQLITE_DBS[@]} SQLite DBs, then integrity_check each copy"
    log "dry-run: would fail on any >10M *.db under /srv that is not on the list (drift hole)"
    return 0
  fi

  require_cmds docker sqlite3
  [[ -d $STAGE/pg ]] || die "${STAGE} missing — the preflight phase did not run in this cycle"

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

  local entry name tmp dbpath
  for entry in "${SQLITE_DBS[@]}"; do
    dbpath=${entry%%|*}
    name=${entry##*|}
    [[ -f $dbpath ]] || die "sqlite ${name} missing at ${dbpath} (moved, renamed, or wrong mount)"

    tmp=$STAGE/.tmp/${name}.db
    out=$STAGE/sqlite/${name}.db

    # .backup is the online-backup API: it takes the copy under the right locking.
    # VACUUM INTO then compacts the COPY, never the live database.
    sqlite3 "$dbpath" ".backup '${tmp}'" || die "${name}: .backup failed (database locked?)"
    sqlite3 "$tmp" "VACUUM INTO '${out}'" || die "${name}: VACUUM INTO failed"
    sqlite3 "$out" 'PRAGMA integrity_check;' | grep -qx ok \
      || die "${name}: dumped copy fails integrity_check"
    log "sqlite ${name} -> $(stat -c %s "$out")B"
    rm -f "$tmp"
  done

  # A new database nobody added to the list is a silent hole in coverage. Fail on
  # it. NOTE: written as `if`, not `[[ ]] && known=1` - under `set -e` a failing
  # AND-list as the last command in a loop body exits the shell silently, which
  # would kill this phase with no message on the first non-matching entry.
  local f known e
  while read -r f; do
    [[ -n $f ]] || continue
    known=0
    for e in "${SQLITE_DBS[@]}"; do
      if [[ ${e%%|*} == "$f" ]]; then
        known=1
      fi
    done
    if (( ! known )); then
      die "undiscovered SQLite >10M: ${f} — add it to SQLITE_DBS"
    fi
  done < <(find /srv -xdev -type f -name '*.db' -size +10M \
             -not -path "$STAGE/*" -not -path "$BASE/*" 2>/dev/null || true)

  log "dumps ok"
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
do_backup() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would 'restic backup /srv ${STAGE}' with --exclude-file=${EXCLUDES}"
    log "dry-run: tags um790,run:<id>, --host um790, --retry-lock 5m"
    return 0
  fi

  require_cmds restic

  # Refuse to record a snapshot that is missing the phase outputs. restic would
  # happily back up /srv alone and report success.
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

  # An exclude file that has gone missing turns this into a much larger backup
  # (pg data dirs, caches) without failing. Check, don't assume.
  [[ -f $EXCLUDES ]] || die "exclude file ${EXCLUDES} missing — refusing to back up without excludes"

  restic_run backup /srv "$STAGE" \
    --exclude-file="$EXCLUDES" \
    --tag um790 --tag "run:${run_id}" \
    --host um790 \
    --retry-lock 5m \
    || die "restic backup failed"

  stamp > "$STATE/backup_done.epoch"
  log "backup ok (run ${run_id})"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
do_check() {
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would 'restic check' with --read-data-subset=${CHECK_READ_SUBSET}"
    return 0
  fi
  require_cmds restic
  restic_run check --read-data-subset="$CHECK_READ_SUBSET" \
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
    log "dry-run: would 'restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6' (dry-run first)"
    log "dry-run: would delete ${SHARE} snapshots older than ${SNAPSHOT_RETENTION_DAYS}d, keeping at least 1"
    return 0
  fi
  require_cmds restic ssh jq

  # Guard 1: a fresh snapshot from THIS run. Prune is weekly, so a snapshot from a
  # previous cycle is a full week stale and protects nothing that matters.
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
  restic_run forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --dry-run \
    || die "forget --dry-run failed — not proceeding to a real forget"
  restic_run forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune \
    || die "restic forget --prune failed"

  # Snapshot sweep, age-based rather than positional: DSM's list order is not
  # documented, and an off-by-one here deletes the wrong point in time.
  local names total
  names=$(snapshot_names | grep . || true)
  total=$(printf '%s\n' "$names" | grep -c . || true)
  total=${total:-0}
  log "snapshots before sweep: ${total}"

  local doomed=() name ep
  while read -r name; do
    [[ -n $name ]] || continue
    ep=$(snapshot_epoch "$name")
    if [[ -z $ep ]]; then
      log "WARNING: cannot parse snapshot name '${name}' — leaving it alone"
      continue
    fi
    if (( $(stamp) - ep > SNAPSHOT_RETENTION_DAYS * 86400 )); then
      doomed+=("$name")
    fi
  done <<< "$names"

  # Never delete the last snapshot, however old: it is the only undo left.
  if (( ${#doomed[@]} >= total && total > 0 )); then
    log "WARNING: sweep would delete every snapshot; keeping the newest and skipping the rest"
    doomed=("${doomed[@]:0:$((total - 1))}")
  fi

  if (( ${#doomed[@]} == 0 )); then
    log "no snapshots older than ${SNAPSHOT_RETENTION_DAYS}d; sweep is a no-op"
  else
    log "deleting ${#doomed[@]} snapshot(s) older than ${SNAPSHOT_RETENTION_DAYS}d: ${doomed[*]}"
    # delete takes several snapshot names in one call
    local quoted=() s
    for s in "${doomed[@]}"; do quoted+=("'${s}'"); done
    nas_ssh "sudo -n /usr/syno/sbin/synosharesnapshot delete '${SHARE}' ${quoted[*]}" \
      || log "WARNING: snapshot delete failed — snapshots will accumulate; the repo is still pruned safely"
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
  snapshots=$(restic_run snapshots --json | jq 'length')
  bytes=$(restic_run stats --mode raw-data --json | jq -r '.total_size // 0')
  run_id=$(cat "$STATE/run.lock" 2>/dev/null || echo unknown)
  started=$(cat "$STATE/backup_start.epoch" 2>/dev/null || stamp)
  duration=$(( $(stamp) - started ))

  # Written to a temp file and renamed, so a reader never sees half a heartbeat.
  tmp=$STATE/.last_success.$$
  cat > "$tmp" <<EOF
{
  "last_success": "$(date -u +%FT%TZ)",
  "last_success_epoch": $(stamp),
  "run_id": "${run_id}",
  "repo": "${RESTIC_REPOSITORY}",
  "snapshots": ${snapshots},
  "repo_bytes": ${bytes},
  "duration_sec": ${duration}
}
EOF
  mv -f "$tmp" "$STATE/last_success.json"
  rm -f "$STATE/run.lock"

  notify default "um790 backup OK" "run ${run_id} — ${snapshots} snapshots, $(numfmt --to=iec "$bytes"), ${duration}s"
  log "status written (${snapshots} snapshots, ${bytes}B, ${duration}s)"
}

# ---------------------------------------------------------------------------
do_fail() {
  local where="${DAG_STATUS:-unknown step}"
  if [[ $DRY_RUN == 1 ]]; then
    log "dry-run: would release the run lock and notify FAILED (step=${where})"
    return 0
  fi
  rm -f "$STATE/run.lock"
  notify high "um790 backup FAILED" "run ${DAG_RUN_ID:-?} failed at: ${where}"
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
    return 0
  fi

  require_phase
  if [[ $DRY_RUN == 1 ]]; then
    log "DRY RUN — no secrets read, no repo opened, no host modified"
  fi

  case $PHASE in
    preflight) do_preflight ;;
    config)    do_config ;;
    dumps)     do_dumps ;;
    backup)    do_backup ;;
    check)     do_check ;;
    snapshot)  do_snapshot ;;
    prune)     do_prune ;;
    status)    do_status ;;
    fail)      do_fail ;;
  esac
}

main "$@"
