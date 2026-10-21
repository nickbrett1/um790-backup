#!/usr/bin/env bash
# um790-backup bootstrap - the one-time host setup that must exist before the
# first scheduled run. Run this ON THE UM790 HOST, not inside the container:
# it creates the identities the container mounts, and it may prompt for an SSH
# password once, neither of which a `docker run --rm` phase can do.
#
#   scripts/bootstrap.sh              # every step, in order
#   scripts/bootstrap.sh keys repo    # named steps only
#   scripts/bootstrap.sh --check      # verify only; change nothing
#
# Steps, in this order. The order is load-bearing: known-hosts comes before any
# strict ssh because every later step refuses to connect otherwise, and
# nas-keys comes before repo because restic init needs the sftp transport first.
# See deploy/bootstrap.md for why each one exists.
#
#   dirs         create $BASE and its ssh/state/cache subdirectories, mode 0700
#   restore-md   render /srv/RESTORE.md, which preflight refuses to run without
#   keys         generate the two ed25519 identities (never printed, never moved)
#   known-hosts  pin the NAS host key on the NON-DEFAULT port 2222
#   nas-keys     install the ryzen public key for nick@nas (prompts once)
#   repo         assert share + sftp user, then restic init if uninitialised
#   verify       re-assert every preflight gate for real, then clear the lock
#
# Exit 0 only when the machine is actually ready to back up.
set -Eeuo pipefail
IFS=$'\n\t'

# --- configuration ---------------------------------------------------------
# Same defaults and the same names as scripts/um790-backup.sh, so an override
# on the host applies to both. These are NAS facts, not guesses.
NAS_HOST="${NAS_HOST:-192.168.1.2}"
NAS_PORT="${NAS_PORT:-2222}"
NAS_USER="${NAS_USER:-nick}"         # shell user, NOPASSWD sudo, snapshot phase
RESTIC_USER="${RESTIC_USER:-restic}" # sftp-only user that owns the repo
SHARE="${SHARE:-restic-target}"      # DSM share holding the repo, not the data
BASE="${BASE:-/srv/.um790-backup}"   # writable mount shared with the container
IMAGE="${IMAGE:-ghcr.io/nickbrett1/um790-backup:latest}"
RESTORE_MD="${RESTORE_MD:-/srv/RESTORE.md}"

# The repo path is SHARE-ROOTED, not /volume1-rooted: Synology's patched
# internal-sftp exposes a virtual namespace of share names, so a /volume1 path
# fails server-side with `not found share [volume1]`.
REPOSITORY="sftp:${RESTIC_USER}@${NAS_HOST}:/${SHARE}/um790"

SSH_DIR="$BASE/ssh"
STATE_DIR="$BASE/state"
CACHE_DIR="$BASE/cache"
NAS_SSH_KEY="$SSH_DIR/id_ed25519_ryzen"
RESTIC_SSH_KEY="$SSH_DIR/id_ed25519_restic"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

STEPS=(dirs restore-md keys known-hosts nas-keys repo verify)
MODE=RUN      # RUN | CHECK
CHECK=0

# --- output ----------------------------------------------------------------
log()  { printf '%s [bootstrap] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
ok()   { log "ok: $*"; }
warn() { log "WARNING: $*"; }
die()  { log "FATAL: $*"; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: bootstrap.sh [--check] [step...]

steps (default: all, in this order):
  dirs restore-md keys known-hosts nas-keys repo verify

  --check   verify only, change nothing (exits 1 at the first gap)

environment overrides: NAS_HOST NAS_PORT NAS_USER RESTIC_USER SHARE BASE IMAGE
                       RESTORE_MD RESTIC_PASSWORD
EOF
}

# --- helpers ---------------------------------------------------------------
# Both transports pin the host key and refuse to prompt. Identical flag set to
# scripts/um790-backup.sh, so "it works in bootstrap" means "it works in the
# scheduled phase" rather than "it works with my ~/.ssh/config".
nas_ssh() {
  ssh -p "$NAS_PORT" -i "$NAS_SSH_KEY" \
      -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
      "${NAS_USER}@${NAS_HOST}" "$@"
}
nas_ssh_works() { nas_ssh true >/dev/null 2>&1; }

# restic is invoked THROUGH THE IMAGE, not from the host, so bootstrap tests the
# exact binary and version the schedule will use. A host restic of a different
# minor version can open a repo the container cannot, or vice versa, and that
# difference is invisible until 02:00.
image_restic() {
  docker run --rm \
    --entrypoint restic \
    -e RESTIC_PASSWORD \
    -e RESTIC_REPOSITORY="$REPOSITORY" \
    -v "${SSH_DIR}:/run/ssh:ro" \
    "$IMAGE" \
    -o "sftp.args=-p ${NAS_PORT} -i /run/ssh/id_ed25519_restic -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/ssh/known_hosts" \
    "$@"
}

# Fingerprints only. The private half is never read, echoed, or copied - if it
# is lost the right response is to reissue it, not to recover it, so printing it
# here would only teach bad habits.
fingerprint() { ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'; }

ensure_key() { # path comment
  local path=$1 comment=$2
  if [[ -s ${path}.pub ]]; then
    if [[ $(stat -c '%a' "$path") != 600 ]]; then
      if (( CHECK )); then die "${path} is mode $(stat -c '%a' "$path"), expected 600"; fi
      chmod 0600 "$path"
      log "chmod 0600 ${path}"
    fi
    ok "identity present: ${path} (fingerprint $(fingerprint "${path}.pub"))"
    return 0
  fi
  if (( CHECK )); then die "missing identity ${path}"; fi
  # No passphrase on purpose: there is no agent inside the batch container, so a
  # passphrase would turn every scheduled run into an interactive prompt. The key
  # is protected by being 0600 inside a 0700 directory, not by encryption.
  ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$path"
  chmod 0600 "$path"
  ok "generated ${path} (fingerprint $(fingerprint "${path}.pub"))"
}

step_known_requested() { # name -> bool
  local s
  for s in "${STEPS[@]}"; do
    if [[ $s == "$1" ]]; then return 0; fi
  done
  return 1
}

# --- steps -----------------------------------------------------------------
step_dirs() {
  local d
  for d in "$BASE" "$SSH_DIR" "$STATE_DIR" "$CACHE_DIR"; do
    if [[ ! -d $d ]]; then
      if (( CHECK )); then die "missing directory ${d}"; fi
      install -d -m 0700 "$d"
      ok "created ${d}"
      continue
    fi
    if [[ $(stat -c '%a' "$d") != 700 ]]; then
      if (( CHECK )); then die "${d} is mode $(stat -c '%a' "$d"), expected 700"; fi
      chmod 0700 "$d"
      log "chmod 0700 ${d}"
    fi
  done
  # Created deliberately rather than left to Docker: a bind-mount source that
  # does not exist is auto-created root:root 0755, and the keys inside it are
  # only as private as the directory holding them.
  ok "${BASE} ready (mode 0700, holds ssh/ state/ cache/)"
}

step_restore_md() {
  if [[ -s $RESTORE_MD ]]; then
    # Drift check instead of templating: the doc is hand-maintainable, but if it
    # names a repository that is not the one configured, it describes a restore
    # that no longer exists.
    if ! grep -qF "$REPOSITORY" "$RESTORE_MD"; then
      die "${RESTORE_MD} exists but does not mention ${REPOSITORY} - it documents a restore path that is no longer this repository; update it or move it aside"
    fi
    ok "${RESTORE_MD} present and names the configured repository"
    return 0
  fi
  if (( CHECK )); then die "missing ${RESTORE_MD} (preflight refuses to back up without it)"; fi

  # Quoted heredoc: nothing below is interpolated, so backticks and $ in the
  # prose and code blocks stay literal. The doc uses $REPO/$KEY variables that
  # the reader sets, which keeps it correct even if the defaults change.
  cat > "$RESTORE_MD" <<'RESTORE_MD_EOF'
# Restore procedure - um790

This file exists because `preflight` refuses to back up without it. That is
deliberate: a backup whose restore path is undocumented is not a backup, it is
files on a NAS that happen to be copies.

Keep this next to a copy of the encryption password. A restic repository you
cannot decrypt is a very large random number.

## What is in the repository

Every snapshot contains:

- `/srv` from um790, minus the patterns in `deploy/exclude.txt`
- staged database copies under the backup's own staging directory:
  - `pg/*.dump` - custom-format `pg_dump` output, 4 Postgres databases
  - `sqlite/*.db` - `VACUUM INTO` copies, already integrity-checked
- `config/*.json` - `docker inspect` for every container, with secret VALUES
  replaced by `__REDACTED__`. The keys survive, the values do not. Container
  definitions are recoverable; container secrets come from Doppler.

Excluded on purpose (do not go looking for them): Postgres data directories,
caches, logs, Dagu run state, and `/srv/.um790-backup` itself. Every excluded
database is covered by a dump instead.

## Before you start

```bash
REPO='sftp:restic@192.168.1.2:/restic-target/um790'
PASSWORD='...'          # from Doppler, project um790-backup, config prd
SNAPSHOT='latest'       # or a short_id from `rb snapshots`
```

The sftp path is SHARE-ROOTED. `/restic-target/um790`, never
`/volume1/restic-target/um790`: Synology's patched internal-sftp serves a virtual
namespace of share names, and a `/volume1` path fails with
`not found share [volume1]`.

Use the image, not a host restic, so the version matches what wrote the data:

```bash
rb() {
  docker run --rm --entrypoint restic \
    -e RESTIC_PASSWORD="$PASSWORD" \
    -v /srv/.um790-backup/ssh:/run/ssh:ro \
    ghcr.io/nickbrett1/um790-backup:latest \
    -r "$REPO" \
    -o "sftp.args=-p 2222 -i /run/ssh/id_ed25519_restic -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/ssh/known_hosts" \
    "$@"
}
```

## 1. Find the snapshot you want

```bash
rb snapshots --host um790
rb snapshots --json | jq -r '.[] | [.short_id, .time, .tags[]] | @tsv'
```

Each run is tagged `run:<dag-run-id>`, so a snapshot is traceable to the run
that produced it.

## 2. Restore to a scratch directory first, never over /srv

```bash
install -d -m 0755 /srv/.um790-backup/restore
rb restore "$SNAPSHOT" --target /srv/.um790-backup/restore
```

`/srv/.um790-backup` is excluded from backups, so restoring there cannot
overwrite the recovery data with the thing being recovered.

Look before you copy:

```bash
ls /srv/.um790-backup/restore/srv
```

## 3. Restore one file or one directory

```bash
rb restore "$SNAPSHOT" --target /tmp/one --include /srv/msgvault/msgvault.db
```

## 4. SQLite databases

The staged copies have already passed `PRAGMA integrity_check` once, so restore
is a copy - but **stop the container first**, or its next write clobbers yours:

```bash
docker stop <container>
cp /srv/.um790-backup/restore/srv/.um790-backup/staging/sqlite/msgvault.db \
   /srv/msgvault/msgvault.db
sqlite3 /srv/msgvault/msgvault.db 'PRAGMA integrity_check;'   # expect: ok
docker start <container>
```

Check the file is owned by the uid/gid the container expects before restarting.

## 5. Postgres databases

Restore with the container's own `pg_restore`, so client and server versions
match. The dump is custom format (`-Fc`), which `psql` cannot read.

```bash
docker exec -i <container> pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --clean --if-exists --no-owner < \
  /srv/.um790-backup/restore/srv/.um790-backup/staging/pg/<container>.dump
```

`--clean --if-exists` makes this repeatable. Expect "does not exist, skipping"
noise on a first restore: that is the flag working, not an error.

## 6. Container configuration

`config/<name>.json` is a `docker inspect`. Read it for image tag, mounts,
networks, restart policy, and the env var NAMES. Every value that looked like a
secret is `__REDACTED__`, so the container must be recreated with real secrets
from Doppler, never from the backup. This is the intended failure mode: the
backup tells you how the container was wired, not what its tokens were.

## 7. Sanity checks that are not restore tests

- `restic check` proves the repository is internally consistent. It does **not**
  prove you can restore a working system.
- The real test is a restore to a scratch host with containers started from the
  restored config. Do that occasionally, not for the first time during an outage.

## What this does not cover

- Secrets. They live in Doppler and are backed up by Doppler; rotate them if a
  device holding them is lost.
- Data on other machines, and `/srv/backups`, `/srv/marketdata` (excluded as
  another machine's data).
- Anything outside `/srv` on um790, including `/etc` and the Docker daemon
  configuration. Container definitions are covered by `config/`; the host's own
  configuration is not.
- Rebuilding the boot disk. This restores data, not an operating system.
RESTORE_MD_EOF
  chmod 0644 "$RESTORE_MD"
  ok "wrote ${RESTORE_MD} ($(grep -c . "$RESTORE_MD") lines)"
}

step_keys() {
  ensure_key "$NAS_SSH_KEY" "um790-backup ryzen -> ${NAS_USER}@${NAS_HOST}"
  ensure_key "$RESTIC_SSH_KEY" "um790-backup restic -> ${RESTIC_USER}@${NAS_HOST}"
}

step_known_hosts() {
  local pinned live tmp
  pinned=$(ssh-keygen -F "[${NAS_HOST}]:${NAS_PORT}" -f "$KNOWN_HOSTS" -l 2>/dev/null | awk '{print $2}' | sort -u || true)
  live=$(ssh-keyscan -p "$NAS_PORT" -T 5 "$NAS_HOST" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | sort -u || true)

  if [[ -z $live ]]; then
    if (( CHECK )); then die "cannot reach ${NAS_HOST}:${NAS_PORT} to fetch its host key"; fi
    die "no host key from ${NAS_HOST}:${NAS_PORT} - is SSH enabled on the NAS on that port (Control Panel > Terminal & SNMP > SSH), and reachable from here?"
  fi

  if [[ -n $pinned ]]; then
    if [[ $pinned == "$live" ]]; then
      ok "host key for [${NAS_HOST}]:${NAS_PORT} pinned and still current (${live%% *})"
      return 0
    fi
    # A changed host key is either a rebuilt NAS or an interception. Both need a
    # human, so this never self-heals.
    die "host key for [${NAS_HOST}]:${NAS_PORT} has CHANGED (pinned ${pinned}, now ${live}). If you rebuilt the NAS deliberately, remove ${KNOWN_HOSTS} and rerun. Otherwise stop and investigate - something is answering as your NAS."
  fi

  if (( CHECK )); then die "${KNOWN_HOSTS} does not pin [${NAS_HOST}]:${NAS_PORT}"; fi
  tmp=$(mktemp)
  ssh-keyscan -p "$NAS_PORT" -T 5 "$NAS_HOST" 2>/dev/null > "$tmp"
  install -m 0600 "$tmp" "$KNOWN_HOSTS"
  rm -f "$tmp"
  ok "pinned [${NAS_HOST}]:${NAS_PORT} -> ${KNOWN_HOSTS} (${live%% *})"
  warn "that pin is trust-on-first-use: it records whatever answered first. Verify the fingerprint against DSM, or accept that StrictHostKeyChecking=yes only proves it has not changed SINCE TODAY."
}

step_nas_keys() {
  if nas_ssh_works; then
    ok "ssh as ${NAS_USER}@${NAS_HOST} works with ${NAS_SSH_KEY}"
  else
    if (( CHECK )); then die "cannot ssh to ${NAS_USER}@${NAS_HOST}:${NAS_PORT} with ${NAS_SSH_KEY} (public key not installed, or ssh/sudo disabled for that user)"; fi

    log "installing the ryzen public key for ${NAS_USER}@${NAS_HOST}. This prompts for the NAS password ONCE - that prompt is the root of trust, and the reason this step cannot be automated."
    ssh-copy-id -i "${NAS_SSH_KEY}.pub" -p "$NAS_PORT" \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
      "${NAS_USER}@${NAS_HOST}" \
      || die "ssh-copy-id failed. Manual fallback: append $(cat "${NAS_SSH_KEY}.pub") to /var/services/homes/${NAS_USER}/.ssh/authorized_keys on the NAS (directory 0700, file 0600)."
    nas_ssh_works || die "key installed but ssh still fails - check that the user may log in by key at all (DSM > Control Panel > User > ${NAS_USER} > Public key)"
    ok "ssh as ${NAS_USER}@${NAS_HOST} works"
  fi

  # preflight asserts this and fails the whole run on it, so catching it here
  # turns a 02:00 failure into a setup-time one.
  nas_ssh "sudo -n true" >/dev/null 2>&1 \
    || die "${NAS_USER} cannot sudo without a password on the NAS. The snapshot phase needs it (synosharesnapshot is root-only). Add ${NAS_USER} to the administrators group in DSM."
  ok "passwordless sudo on the NAS works"
}

step_repo() {
  : "${RESTIC_PASSWORD:?RESTIC_PASSWORD must be set (Doppler um790-backup/prd) - export it, do not pass it as an argument where it lands in ps}"

  # The two NAS-side preconditions restic cannot report clearly: a missing share
  # surfaces as an sftp error about the repository path, and a missing sftp user
  # as a bare connection failure.
  if nas_ssh_works; then
    nas_ssh "sudo -n test -d /volume1/${SHARE}" >/dev/null 2>&1 \
      || die "share ${SHARE} does not exist on the NAS. Create it in DSM (Control Panel > Shared Folder) - it holds the repository, not the source data."
    # Checked, never created: synouser is undocumented, and a half-made account
    # that authenticates but cannot see the share is worse than a clear error.
    nas_ssh "id -u ${RESTIC_USER} >/dev/null 2>&1" \
      || die "sftp user ${RESTIC_USER} does not exist on the NAS. Create it in DSM (Control Panel > User) with no shell, read/write on ${SHARE}, then install ${RESTIC_SSH_KEY}.pub as its public key (DSM > User > ${RESTIC_USER} > Public key)."
  else
    warn "skipping NAS-side share/user checks - ssh as ${NAS_USER} does not work yet (run the nas-keys step first)"
  fi

  if image_restic cat config >/dev/null 2>&1; then
    ok "repository opens: ${REPOSITORY}"
    return 0
  fi
  if (( CHECK )); then die "cannot open ${REPOSITORY} (not initialised, wrong password, or key/share problem)"; fi

  warn "repository does not open - initialising ${REPOSITORY}"
  warn "restic init only destroys anything if the path above is WRONG, so read it before continuing"
  image_restic init || die "restic init failed (does ${RESTIC_USER} have write access to ${SHARE}, and is ${RESTIC_SSH_KEY} installed for it?)"
  image_restic cat config >/dev/null 2>&1 \
    || die "init reported success but the repository still does not open - refusing to call that ready"
  ok "initialised ${REPOSITORY}"
}

step_verify() {
  local problems=0
  [[ -s $RESTORE_MD ]]      || { warn "missing ${RESTORE_MD}"; problems=$((problems + 1)); }
  [[ -s $NAS_SSH_KEY ]]     || { warn "missing ${NAS_SSH_KEY}"; problems=$((problems + 1)); }
  [[ -s $RESTIC_SSH_KEY ]]  || { warn "missing ${RESTIC_SSH_KEY}"; problems=$((problems + 1)); }
  [[ -s $KNOWN_HOSTS ]]     || { warn "missing ${KNOWN_HOSTS}"; problems=$((problems + 1)); }
  (( problems == 0 )) || die "${problems} prerequisite(s) still missing - the run would fail at the first preflight gate"

  nas_ssh "sudo -n true" >/dev/null 2>&1 || die "NAS sudo check failed"

  # In check mode a missing password is not fatal for a structural check, but it
  # must not be reported as a passed repository check either.
  if [[ -n ${RESTIC_PASSWORD:-} ]]; then
    image_restic cat config >/dev/null 2>&1 || die "repository does not open"
    ok "repository opens"
  elif (( CHECK )); then
    warn "RESTIC_PASSWORD is unset - skipping the repository open check (structure is verified, the repo is NOT)"
  else
    die "RESTIC_PASSWORD is unset"
  fi

  if (( CHECK )); then
    ok "all prerequisites present (check mode: not running the real preflight, so no lock is taken)"
    return 0
  fi

  # The real gate: the image's own preflight, with the compose mount set. This
  # is the only check that proves the container can see /srv, the socket, the
  # keys and the state mount at exactly the paths the script expects.
  log "running the real preflight through ${IMAGE}"
  docker run --rm \
    -v /srv:/srv:ro \
    -v "${BASE}:${BASE}" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v "${SSH_DIR}:/run/ssh:ro" \
    -e RESTIC_PASSWORD \
    -e RESTIC_REPOSITORY="$REPOSITORY" \
    -e NAS_HOST="$NAS_HOST" \
    -e NAS_PORT="$NAS_PORT" \
    -e NAS_USER="$NAS_USER" \
    -e "EXCLUDES=${BASE}/exclude.txt" \
    "$IMAGE" preflight \
    || die "preflight failed - the message above is the real reason, and this script cannot fix it for you"

  # preflight takes the run lock and the backup-start stamp to enforce ordering
  # between phases. Bootstrap deliberately stops after gate one, so those two
  # files are cleared here. Left in place, the next real run would see a
  # 12h-fresh lock and refuse - which looks exactly like a crashed run.
  rm -f "$STATE_DIR/run.lock" "$STATE_DIR/backup_start.epoch"
  ok "preflight passed; lock cleared (bootstrap stops before config/dumps)"
  log "next: enable the DAG, or run the remaining phases by hand with the same mounts"
}

# --- main ------------------------------------------------------------------
main() {
  local -a requested=()
  while (( $# )); do
    case $1 in
      --check) CHECK=1; MODE=CHECK ;;
      --help|-h) usage; exit 0 ;;
      -*) usage; die "unknown option: $1" ;;
      *) requested+=("$1") ;;
    esac
    shift
  done

  if (( ${#requested[@]} == 0 )); then
    requested=("${STEPS[@]}")
  else
    local s
    for s in "${requested[@]}"; do
      step_known_requested "$s" || { usage; die "unknown step: $s"; }
    done
  fi

  if [[ $MODE == CHECK ]]; then
    log "check mode: nothing will be created or modified"
  fi

  local name fn
  for name in "${requested[@]}"; do
    log "== ${name}"
    case $name in
      dirs)        fn=step_dirs ;;
      restore-md)  fn=step_restore_md ;;
      keys)        fn=step_keys ;;
      known-hosts) fn=step_known_hosts ;;
      nas-keys)    fn=step_nas_keys ;;
      repo)        fn=step_repo ;;
      verify)      fn=step_verify ;;
      *) die "internal: no dispatch for ${name}" ;;
    esac
    "$fn"
  done

  if [[ $MODE == CHECK ]]; then
    ok "all requested checks passed"
  else
    ok "bootstrap complete for: ${requested[*]}"
  fi
}

main "$@"
