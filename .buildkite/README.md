# Buildkite

`pipeline.yml` in this directory is the source of truth for this project's CI.
The pipeline object in Buildkite carries a one-line wrapper that uploads this
file, so edits take effect on the next push — there is nothing to change in the
Buildkite UI. That wrapper is dispatched to `mac-studio-linux` as well: it runs
_before_ this file is read, so it cannot inherit the queue from the steps below,
and it is pinned explicitly so a build never lands on a shared cloud agent.

## How a build runs

- **Queue:** `mac-studio-linux` — the pipeline is dispatched to that
  self-hosted agent, not to a cloud fleet.
- **Image:** `debian:bookworm-slim` for the build, lint and test steps (public;
  pick an arm64 image, the fleet is Apple silicon).
- **Steps:** install, then build, lint and test — in a **single job on purpose**.
  The install is the dominant fixed cost, so it is paid once rather than once
  per step.

The step set is _capability-driven_: a deployment capability adds its deploy
step, `gitguardian` adds the secret scan, `lighthouse-ci` adds the performance
gate. A project that selects none of them gets build and test and nothing else.

A `github-release` project with a target ending in `-apple-darwin` also gets a
**smoke gate**: a native macOS step that runs the built payload
(`scripts/smoke-launch.sh`, which is yours) and that the release depends on. A
payload is built on the Mac host because that is where it can be linked, but
_linking_ is not _running_ — this step is what stops a payload that cannot start
from being published. It fails closed: a payload missing its `bin/` entry point,
built for the wrong architecture, or that does not answer within the timeout
blocks the release rather than shipping.

## What the agent has to provide

None of this lives in the repository, and the pipeline fails in confusing ways
without it:

1. **`plugins-path`** in `buildkite-agent.cfg`. Agent v4 has no usable default,
   and _every_ step here uses a plugin — omitting it fails the checkout.
2. **A unique agent `name`** when a machine runs more than one agent
   (`name="<machine>-%spawn"`). Otherwise agents race over the plugin directory.
3. **Docker.** Almost every step runs in a container. The exception is a
   `github-release` release target ending in `-apple-darwin`: a macOS binary
   cannot be linked inside a Linux container, so that step is dispatched with no
   docker plugin and runs **on the host**. Its toolchain therefore has to be on
   the machine and not only in the image — for a rust target that means `rustup`,
   `cargo` and the Xcode command line tools, reachable from the agent's own
   `PATH` (a job inherits the agent process's environment, not your shell's).
   That step also ignores `buildkite.queue`: it is dispatched to the macOS queue
   (`mac-studio-linux`, which names the queue's containers rather than its
   hosts), because moving `buildkite.queue` to a Linux queue must not move a
   build that cannot run there. The **smoke gate** below runs the same way —
   native, on the macOS queue — so whatever executes the payload (`bin/` in
   `scripts/smoke-launch.sh`) has to be on that host too, and the step fetches
   the build's artifacts with `buildkite-agent`, which a native step can do and a
   containerised one cannot.
4. **The secret scan runs natively.** `gitleaks git` walks the repository's
   full history, which only the agent's checkout has, so that step is
   deliberately not containerised. It needs `curl` (or `wget`) and a writable
   `$HOME`; `scripts/install-gitleaks.sh` fetches the pinned, sha256-verified
   binary into `$HOME/.local/bin` on first run.
5. **Secrets, delivered to the job environment** by the agent's `environment`
   hook. A step-level `env:` value does **not** reach the container — only names
   listed in the docker plugin's `environment:` list do. This is the most common
   way a working step mysteriously loses its credentials.

## Secrets each contributed step needs

Provided by the agent's `environment` hook, by name:

- **Secret scan** (`gitguardian`) — `GITGUARDIAN_API_KEY`. Scans a path, so it
  needs no git history.
- **Deploy** (`cloudflare-wrangler`) — `CLOUDFLARE_API_TOKEN` and
  `CLOUDFLARE_ACCOUNT_ID`, plus `DOPPLER_TOKEN` when the `doppler` capability is
  selected (for `scripts/setup-wrangler-config.sh` and the secret sync).
- **Image publish** (`docker-container`) — one of two credential channels,
  decided by whether the `doppler` capability is selected. With it,
  `DOPPLER_TOKEN` lets the step read `GHCR_UPDATE_TOKEN` from Doppler
  (`common`/`prd`) at run time; the registry token is then never in the agent's
  `environment` hook, where every job on the fleet could read it. Without it,
  provide `GHCR_USERNAME` and `GHCR_TOKEN` in the agent's `environment` hook.
  Runs on the agent, which has the Docker daemon it needs.
- **DAG pin bump** (this project's own step) — `DOPPLER_TOKEN` only; the step
  resolves `DAGU_DAGS_TOKEN` from Doppler (`common`/`prd`) at run time. It is a
  fine-grained PAT for `nickbrett1/dagu-dags` with `Contents: read & write` and
  `Pull requests: read & write`, so it can push one branch and open one PR and
  cannot touch any other repository. `BUILDKITE_COMMIT` and
  `BUILDKITE_BUILD_URL` reach the container too, but are Buildkite's own
  variables rather than secrets.

This list is a bullet list rather than a table on purpose: a generated file has
to survive `prettier --check` in this project's own lint step, and prettier
re-pads markdown tables to its own column widths.

## Worth knowing

- If a build is queued but never starts, the queue name is wrong (above).
- A pipeline can exist, look correctly connected, and receive **nothing** on
  push. That is a missing GitHub webhook, and it is worth checking before
  debugging anything else.
- The Lighthouse step runs on `main` only by default, and passes its config
  explicitly (`--config .lighthouse.cjs`) because that filename is not one lhci
  discovers on its own.
- A rust target builds and tests with `--locked`, so the repository has to carry
  a `Cargo.lock` that matches `Cargo.toml`. A missing or stale lockfile fails
  those commands rather than silently resolving new versions — which is the
  point of the flag, and the reason to commit the lockfile with the manifest.
- **Cleanup traps must survive cancellation**, and they cost one character to get
  wrong. A shell killed by `SIGTERM` does not run its `EXIT` trap, so every step
  that creates a builder, container or image installs `trap 'exit 143' TERM INT`
  first; otherwise the cleanup is skipped exactly when it is needed.
- **Buildkite interpolates whole command blocks, comments included, and `$$` is
  its escape for one literal `$`.** A variable assigned *inside* the script must
  therefore be written with two dollars before it: two dollars reach the shell as
  one, and the shell expands the value the script set. Three dollars is a real
  bug that this pipeline shipped once — it silently deleted a volume that never
  existed, which looks like cleanup and is a no-op. Describe such sequences in
  words in a comment, because an example written with the dollar signs is
  rewritten before anyone reads it in the job log.
- The `retention_tests` step here is the pattern worth copying for any job whose
  "test" is a `--dry-run`: a dry run proves the code path is reached, not that
  the decision at the end of it is right. Where a decision is computable from
  plain inputs, extract it into a function and drive it in the image.
