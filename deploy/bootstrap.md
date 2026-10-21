# Bootstrap: making the first run possible

`scripts/um790-backup.sh` has four preconditions that nothing creates for you,
and `preflight` refuses to run without every one of them. That refusal is
correct — a run that proceeds without them produces a green build and a backup
that restores nothing — but it means the script cannot be the first thing you
run. This is the thing you run first.

```bash
# on the UM790 host, not in the container
export RESTIC_PASSWORD='...'        # Doppler: um790-backup/prd
scripts/bootstrap.sh                # all steps, in order
scripts/bootstrap.sh --check        # verify only, changes nothing
```

Exit 0 means ready. Exit 1 means the machine is not, and the message names
the gap.

## Why the steps are in a fixed order

The steps are not independently runnable in any order, and the script enforces
the sequence rather than trusting you to remember it:

| # | Step | What it creates | Why it has to come here |
|---|------|-----------------|-------------------------|
| 1 | `dirs` | `$BASE` + `ssh/ state/ cache/`, mode 0700 | Docker auto-creates a missing bind source `root:root 0755`. The keys are only as private as the directory holding them, so create it first. |
| 2 | `restore-md` | `/srv/RESTORE.md` | The first preflight gate. Cheapest failure to fix, so surface it before any network work. |
| 3 | `keys` | `id_ed25519_ryzen`, `id_ed25519_restic` | Both transports need a key on disk before ssh will try. |
| 4 | `known-hosts` | pinned `[192.168.1.2]:2222` | Every later connection uses `StrictHostKeyChecking=yes`, so without the pin ssh fails before it authenticates. |
| 5 | `nas-keys` | ryzen pubkey in `nick`'s `authorized_keys` | Needs `known_hosts` (step 4) to connect strictly, and is what makes steps 6–7 possible. |
| 6 | `repo` | the restic repository | `restic init` needs the sftp transport working, i.e. steps 3–5. |
| 7 | `verify` | nothing; re-asserts everything | Runs the image's real `preflight`, which is the only check that the container can see `/srv`, the socket, the keys and the state mount at the right paths. |

Steps are idempotent: run the whole script again and each step reports what it
found. `--check` is read-only and exits at the first gap rather than listing
them all, because this is meant to be fixed once, not inspected repeatedly.

## The four preconditions, and what each one actually needs

### 1. SSH identities

Two keys, different jobs, both unmounted from `/srv/.um790-backup/ssh`:

- **`id_ed25519_ryzen`** — `ssh` as `nick@192.168.1.2:2222`. Used only by
  `snapshot`/`prune`, and only ever with `sudo -n`, because `synosharesnapshot`
  is root-only.
- **`id_ed25519_restic`** — `sftp` as `restic@192.168.1.2:2222`. Used as the
  restic repository transport.

Neither has a passphrase, and that is deliberate: there is no ssh-agent inside a
`docker run --rm` batch container, so a passphrase would make every scheduled
run an interactive prompt. Protection is file mode (0600 in a 0700 directory),
not key encryption.

Practical consequence: **losing the private key means reissuing it, not
recovering it.** To reissue, delete `<key>` and `<key>.pub`, rerun
`scripts/bootstrap.sh keys`, then reinstall the new `.pub` on the NAS. The
repository itself is unaffected — it is encrypted by `RESTIC_PASSWORD`, not by
this key.

NAS-side, the user needs a public key installed by hand. `ssh-copy-id` does that
for `nick` because it can authenticate with a password once. For `restic` there
is no password (it is an sftp-only account), so the key goes in through DSM:
**Control Panel → User → restic → Public key**. The script checks for the
account and tells you when it is missing; it never creates the account, because
`synouser` is undocumented and a half-made account that authenticates but cannot
see the share is worse than a clear error.

### 2. `known_hosts` on port 2222

`NAS_PORT` is 2222, so the entry must be keyed **`[192.168.1.2]:2222`** — a bare
hostname entry will not match, and ssh reports a scary "remote host
identification has changed" style failure or a plain "no host key". The script
fetches with `ssh-keyscan -p 2222` and writes the bracketed form.

The pin is **trust-on-first-use**: it records whatever answered first. That is
weaker than it looks, so the script says so at the point it does it. If you want
it to mean something, check the fingerprint against DSM once.

After a deliberate NAS rebuild the host key changes, and the script refuses to
overwrite the pin. Delete `$BASE/ssh/known_hosts` and rerun. It never
autoheals, because "the NAS host key changed" is also what an interception looks
like.

### 3. `RESTORE.md`

`preflight` hard-fails without `/srv/RESTORE.md`. This is not a formality: the
whole point of the system is a documented recovery path, so the doc is a gate
rather than an afterthought.

The script renders a working procedure from a template (restic via the image,
`/volume1` warning, SQLite container-stop ordering, `pg_restore --clean
--if-exists`, redacted config caveat, and what is *not* covered). It will not
overwrite an existing file, and it refuses one that does not mention the
configured repository — a restore doc pointing at a path that no longer exists
is worse than none.

Two things the template cannot do for you:

- It names the repository but not the password. Keep a copy of
  `RESTIC_PASSWORD` somewhere that is neither this host nor that NAS.
- It is a procedure, not a rehearsal. `restic check` proves the repository is
  consistent; it does not prove you can restore a running system.

### 4. `restic init`

`preflight` runs `restic cat config` and fails if the repo does not open, so the
repository must exist before the first run. `bootstrap.sh repo` initialises it
if `cat config` fails, and then re-checks — an `init` that reports success but
leaves an unopenable repo is not treated as ready.

It asserts the two NAS-side preconditions restic reports badly:

- share `restic-target` exists (a missing share surfaces as a confusing sftp
  error about the repository path);
- user `restic` exists (a missing account surfaces as a bare connection failure).

The repository path is **share-rooted**: `sftp:restic@192.168.1.2:/restic-target/um790`.
Never `/volume1/restic-target/um790` — Synology's patched `internal-sftp` serves
a virtual namespace of share names, so a `/volume1` path fails server-side with
`not found share [volume1]`.

## What `verify` does that nothing else does

It runs the image's own `preflight` with the same four mounts `docker-compose.yml`
declares. That is the only step that proves the *container* can see what the
script expects, rather than proving the host can. A missing `-v` for the socket
or the keys fails here, before it fails at 02:00.

It then **clears `state/run.lock` and `state/backup_start.epoch`**. `preflight`
takes both, and bootstrap deliberately stops after `preflight` — it does not run
`config`/`dumps`. Left behind, the next real run sees a fresh lock and refuses,
which looks exactly like a crashed run and is a confusing hour to lose. Bootstrap
removes its own footprint.

## What bootstrap does not do

- **Enable the schedule.** See `../dags/ryzen/um790-backup.yaml.disabled` in
  `nickbrett1/dagu-dags`. The phases have to be run by hand once, in order,
  before that file is renamed and cron is pointed at it.
- **Define secrets in Doppler.** `RESTIC_PASSWORD` must exist in
  `um790-backup/prd`; `NTFY_URL` is optional (notifications are best-effort by
  design — a broken notifier never changes a phase result).
- **Create the NAS share or the `restic` user.** Both are DSM clicks, and both
  are checked rather than guessed at.
- **Prove the backup works.** That is `backup` + `check` + a restore rehearsal.

## Verifying a bootstrap

```bash
scripts/bootstrap.sh --check                 # structure, no changes
docker run --rm --entrypoint um790-backup.sh \
  -v /srv:/srv:ro -v /srv/.um790-backup:/srv/.um790-backup \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /srv/.um790-backup/ssh:/run/ssh:ro \
  -e RESTIC_PASSWORD ghcr.io/nickbrett1/um790-backup:latest --dry-run
```

`--dry-run` needs no secrets and touches nothing, so it is safe to run any time;
it is also the CI smoke gate, which is why it must keep passing with the
environment empty.
