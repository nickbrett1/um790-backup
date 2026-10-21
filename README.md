# um790-backup

A um790-backup project generated with genproj

## Capabilities

This project includes the following capabilities:

- **Doppler Secrets Management**: Integrates Doppler for secure secrets management. Enables the various MCP servers that rely on privileged tokens to access their services (e.g. Buildkite, GitHub, SonarQube).
- **AI Coding Agents**: Sets up the AI coding agents in the devcontainer: goose (config, MCP servers and spec-first recipes) plus the Antigravity CLI.
- **Container Agent**: Every generated devcontainer brings up and registers its own a2a-goose agent (`<repo>-dev`), reached over the tailnet by the LiteLLM proxy; reuses the a2a-goose GitHub release channel, so the container has the same self-update path as a host.
- **Secret Scanning (gitleaks)**: Required on every project: gitleaks scans staged changes in a pre-commit hook and the full history in CI. Free, offline, no account and no quota.
- **Docker**: Adds Docker support for containerised builds and tooling.
- **Docker Container**: Containerize the project and publish to the GitHub Container Registry (GHCR) for deployment to a NAS or self-hosted host via Docker Compose. Mutually exclusive with other deployment systems. Set `workload: batch` for a scheduled job image (runs and exits; no port, no healthcheck, no Watchtower) instead of a long-running service.
- **Buildkite Integration**: Runs CI on a self-hosted Buildkite agent (Apple silicon) instead of a metered cloud fleet. The pipeline and its GitHub webhook are created during generation, so there is no manual "set up project" step. It can coexist with an existing CI provider, so a repository can migrate without a flag day.
- **ShellCheck (shell code quality)**: Adds ShellCheck to the generated CI for a shell project: `shellcheck -x scripts/*.sh`. Opt-in rather than always-on, because an unconditional gate fails repos that use deliberate eval or dynamic sourcing. Lint locally with `shellcheck -x scripts/*.sh`.

## Setup

1. Clone the repository
2. Install dependencies:

   ```bash
   npm install
   ```

3. Run the dev server:

   ```bash
   npm run dev
   ```

## Secret scanning

Every commit is scanned for credentials by `gitleaks`, and CI scans the
**full history**. The local hook is convenience; CI is the gate you cannot skip
with `git commit --no-verify`.

```bash
scripts/setup-git-hooks.sh   # installs gitleaks and sets core.hooksPath
```

If a commit is blocked, **rotate the credential first** — a finding means it may
already be exposed. Then remove it from the staged changes and commit again.

Only for a verified false positive, add its fingerprint to `.gitleaksignore`,
which is a committed and reviewable diff. Never bypass the hook with
`--no-verify`: it leaves no record and the next commit is unscanned too.

This is detection, not storage (Doppler holds secrets) and not rotation (that is
a human step). Allowlist edits in `.gitleaks.toml` are reviewable changes on
purpose.

## Doppler

This project uses Doppler for secrets from the shared `common` project
(config `dev`) — no per-repo Doppler project is created. First use (links
the shared project and `dev` config):

```bash
doppler setup --project common --config dev
```

If your repo needs app-specific secrets that shouldn't live in the shared
`common` project, regenerate it with the doppler capability set to
`projectStrategy: "new"` to get a dedicated project.

The Doppler CLI is installed in the devcontainer — it must be on PATH for the
VS Code extension and `doppler run` to work. Auth is persisted via the host
`~/.doppler` bind-mount.

### Env-var precedence (read this if `doppler run` hits the wrong project)

Doppler resolves its target as **environment variables > `doppler.yaml` >
`~/.doppler` scoped config**. If your shell — or the session that launched
the devcontainer (e.g. an agent runtime) — exports `DOPPLER_PROJECT` /
`DOPPLER_CONFIG` / `DOPPLER_ENVIRONMENT`, those silently override this
repo's `doppler.yaml` and every `doppler` command targets the wrong
project. The devcontainer's post-create setup pins this repo's context
(`common`/`dev`) in `~/.bashrc` and `~/.zshrc` and warns at
setup if resolution still mismatches. To force the correct context manually:

```bash
unset DOPPLER_PROJECT DOPPLER_CONFIG DOPPLER_ENVIRONMENT
doppler setup --no-interactive --project common --config dev
```

## Deployment

See `deploy/README.md` for the deployment runbook (Buildkite -> GHCR ->
Watchtower -> Docker host). Deploy with:

```bash
docker compose up -d
```

## The container's agent

This devcontainer brings up its own `a2a-goose` agent, registered in the hub as
`um790-backup-dev` - one agent per repo, so a restart reclaims the same entry
instead of adding a second one. Turns are billed through the LiteLLM proxy
configured in Doppler (`LITELLM_BASE_URL`).

```bash
scripts/agent-dev.sh start    # write secrets + config, fetch the launcher, run it
scripts/agent-dev.sh status   # running or not, the card URL, the log tail
scripts/agent-dev.sh stop     # SIGTERM, wait for a clean deregister, confirm gone
```

`start` runs from the devcontainer's post-start hook, so the agent is normally
already up when you arrive. It fails open: with no network on a first start it
prints why it did not start and leaves the project usable. Secrets come from
Doppler into `~/.config/a2a-goose/env` (mode 0600) and never into the image or
`containerEnv`.

## Generated by genproj

This project was generated using the genproj tool.
