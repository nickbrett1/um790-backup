#!/usr/bin/env bash
# Bump the pinned um790-backup image in nickbrett1/dagu-dags and merge it.
#
# This is the "automate the promotion" half of the deploy design. A green main
# build never pulls itself onto the NAS: it lands as a one-line diff on a branch,
# opens a PR for the audit trail, and then merges that PR itself.
#
# Why a PR at all, if CI merges it:
#   - the diff is the record. `git log --grep 'pin image to'` on dagu-dags is the
#     deployment history of the NAS, with a build URL on each commit;
#   - `prune` is the one phase that can destroy snapshot history, so the pin can
#     be reverted with a one-line commit rather than by re-publishing an image;
#   - a human who reads the log sees what changed and when, which a force-push
#     straight to main would not give.
#
# Why not a channel pull: the phases run as separate `docker run --rm`
# invocations, so an image that moves between them makes a failure
# unreproducible and a retry not identical.
#
# WHAT THIS SCRIPT DOES NOT DO: schedule anything. The DAG it edits has no cron
# key and no `name:` key, and this script adds neither. A merged bump changes the
# image tag and nothing else, so it cannot put an unattended `restic forget
# --prune` on a timer. Enabling stays a deliberate edit by a human.
#
# A merged bump IS live within about a minute, without anyone pulling on the host:
# dagu-dags-autocommit runs every minute and does fetch + rebase + push, which
# means it pulls too. That is why the backwards-pin guard below matters more than
# it looks - there is no window in which a human notices a bad pin before it is on
# the box.
#
# Inputs (all optional):
#   DOPPLER_TOKEN              required unless DAGU_DAGS_TOKEN is already set;
#                              used to read DAGU_DAGS_TOKEN from common/prd
#   DAGU_DAGS_TOKEN            overrides the Doppler lookup (local use)
#   UM790_BACKUP_IMAGE_SHA     tag to pin (default: $BUILDKITE_COMMIT)
#   UM790_BACKUP_REPO_SLUG     default nickbrett1/dagu-dags
#   UM790_BACKUP_SRC_REPO_SLUG default nickbrett1/um790-backup (the repo whose
#                              history the backwards-pin guard asks about)
#   UM790_BACKUP_DAG_PATH      default dags/ryzen/um790-backup.yaml
#   UM790_BACKUP_BRANCH        default auto/um790-backup-pin
#   UM790_BACKUP_IMAGE_NAME    default ghcr.io/nickbrett1/um790-backup
#   DRY_RUN=1                  clone and rewrite, print the diff, do not push
#   UM790_BACKUP_NO_MERGE=1    open/refresh the PR but leave it for a human
#
# HISTORY:
#  1. The first version could not perform the first bump. The DAG ships the pin
#     as `UM790_BACKUP_IMAGE: \"\"` on purpose (the wrapper is
#     ${UM790_BACKUP_IMAGE:?}, so an unvalidated default cannot run), but the
#     reading guard was `[[ -n $current ]]` - which treats "line present, value
#     empty" as "line missing". It died on the only state the file has ever been
#     in. Presence and emptiness are separate questions; now asked separately.
#  2. Merging moved from a human to this script. A human used to be able to see a
#     stale build re-pinning an older image; that eye is gone, so the ancestry
#     guard took its place.
#  3. The first cut of that guard could never fire. It resolved the source
#     checkout as ${BUILDKITE_BUILD_CHECKOUT_PATH:-$PWD} AFTER `cd` into the
#     throwaway dagu-dags clone, so it looked for .git in the wrong repo, failed
#     the check, and stood aside - logging a reassuring "cannot verify ancestry"
#     on every run. Build 41 is the proof: it merged while claiming the guard was
#     skipped. It now asks the GitHub compare API instead of local git, which has
#     no cwd to get wrong and no dependency on how deep the checkout was cloned.
#  4. DAG_PATH was the `.disabled` filename, and that filename was deliberately
#     retired when the DAG became a managed definition (dagu-dags 5084ec82 and
#     before it 5c03178). Nothing in this repo referenced it, so build 54 - the
#     first build after the rename, and the one carrying the mailroom sqlite fix -
#     published its image successfully and then failed here with
#     "um790-backup.yaml.disabled does not exist". The image was published and
#     unpinned, i.e. the fix was built and could not reach the host.
#
#     The rename was not wrong; carrying the coupling was. This default is now the
#     real path, and the lookup below no longer rests on one spelling: it will
#     accept either form if BOTH ever exist, and if the path is missing it says
#     what it found instead of only what it wanted. A hardcoded filename in a repo
#     that cannot see the other repo is a coupling nobody validates, and the cost
#     is a green-image, red-pipeline stall that looks like a backup problem.
set -Eeuo pipefail
IFS=$'\n\t'

API=https://api.github.com
REPO=${UM790_BACKUP_REPO_SLUG:-nickbrett1/dagu-dags}
SRC_REPO=${UM790_BACKUP_SRC_REPO_SLUG:-nickbrett1/um790-backup}
DAG_PATH=${UM790_BACKUP_DAG_PATH:-dags/ryzen/um790-backup.yaml}
BRANCH=${UM790_BACKUP_BRANCH:-auto/um790-backup-pin}
IMAGE=${UM790_BACKUP_IMAGE_NAME:-ghcr.io/nickbrett1/um790-backup}
SHA=${UM790_BACKUP_IMAGE_SHA:-${BUILDKITE_COMMIT:-}}
DRY_RUN=${DRY_RUN:-0}
NO_MERGE=${UM790_BACKUP_NO_MERGE:-0}

log() { printf '%s [bump] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# A partial or branch-name SHA would pin something that cannot be pulled, and the
# failure would land at 03:00 on the host rather than here.
[[ $SHA =~ ^[0-9a-f]{40}$ ]] \
  || die "UM790_BACKUP_IMAGE_SHA/BUILDKITE_COMMIT is not a 40-character commit SHA (got '${SHA}')"
TAG="${IMAGE}:${SHA}"
SHORT=${SHA:0:12}

# ---------------------------------------------------------------------------
# credential
# ---------------------------------------------------------------------------
TOKEN=${DAGU_DAGS_TOKEN:-}
if [[ -z $TOKEN ]]; then
  [[ -n ${DOPPLER_TOKEN:-} ]] || die "neither DAGU_DAGS_TOKEN nor DOPPLER_TOKEN is set - cannot authenticate"
  log "reading DAGU_DAGS_TOKEN from Doppler (common/prd)"
  TOKEN=$(curl -fsS -H "Authorization: Bearer ${DOPPLER_TOKEN}" \
    'https://api.doppler.com/v3/configs/config/secret?project=common&config=prd&name=DAGU_DAGS_TOKEN' \
    | jq -r '.value.raw // empty') \
    || die "Doppler request failed - is DOPPLER_TOKEN valid for common/prd?"
fi
[[ -n $TOKEN ]] \
  || die "DAGU_DAGS_TOKEN resolved empty - create it in Doppler (common/prd) with access to ${REPO}"

# One caller for every GitHub call below. -sS so a transport error is still
# visible on stderr; no -f, so the caller decides what a 4xx means.
ghapi() {
  curl -sS \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$@"
}

# ---------------------------------------------------------------------------
# clone
# ---------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'exit 143' TERM INT
trap 'rm -rf "$WORK"' EXIT

log "cloning ${REPO}"
git clone --quiet --depth 1 \
  "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "$WORK/repo" \
  || die "git clone failed - is DAGU_DAGS_TOKEN valid and scoped to ${REPO}?"
cd "$WORK/repo"
git config user.name "um790-backup CI"
git config user.email "ci@nickbrett1.invalid"

# ---------------------------------------------------------------------------
# resolve the DAG
#
# The configured path is tried first. If it is absent, the one other spelling
# this file has ever had is tried, and then the directory is LISTED in the
# failure message. "does not exist - wrong path, or the DAG was renamed" made the
# reader go and look; printing the siblings answers the question immediately, and
# a rename is exactly the event that reaches this branch.
# ---------------------------------------------------------------------------
if [[ ! -f $DAG_PATH ]]; then
  ALT="${DAG_PATH}.disabled"
  if [[ -f $ALT ]]; then
    log "WARNING: ${DAG_PATH} not found but ${ALT} is - using the legacy spelling; update UM790_BACKUP_DAG_PATH"
    DAG_PATH=$ALT
  else
    # A DAG that cannot be found after a rename is a deployment stall, not a
    # code error: the image is published and nothing points at it. Say so, and
    # show what IS there so the fix is a one-line edit rather than a hunt.
    found=$(find dags -maxdepth 3 -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.disabled' \) 2>/dev/null | sort | sed 's/^/  /' || true)
    die "${DAG_PATH} does not exist in ${REPO}, and neither does ${ALT}. The image ${SHORT} is published but unpinned. DAG files present:
${found:-  (none found under dags/)}"
  fi
fi

# ---------------------------------------------------------------------------
# rewrite the pin
# ---------------------------------------------------------------------------
# Presence first, as its own question. The shipped value is intentionally empty,
# so an empty `current` below is a normal starting point and must not be read as
# a missing line. Exactly one match, because a second pin line would mean this
# regex is rewriting something it does not understand.
pin_lines=$(grep -cE '^[[:space:]]*UM790_BACKUP_IMAGE:[[:space:]]*"' "$DAG_PATH" || true)
[[ $pin_lines == 1 ]] \
  || die "expected exactly one UM790_BACKUP_IMAGE: \"...\" line in ${DAG_PATH}, found ${pin_lines} - refusing to guess at the shape"

current=$(sed -n -E 's/^[[:space:]]*UM790_BACKUP_IMAGE:[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "$DAG_PATH")
log "currently pinned: ${current:-<none>}"

if [[ $current == "$TAG" ]]; then
  log "already pinned to ${TAG} - nothing to do"
  exit 0
fi

# ---------------------------------------------------------------------------
# refuse to move the pin backwards
#
# Auto-merge removed the person who would have read the PR title and noticed that
# a *retried* or out-of-order build was about to re-pin an older image. Retrying
# an old build is normal here - build 40 was itself a retry - so this is not
# hypothetical: build 41 proves it, because without a working guard a retry of
# build 40 would have re-pinned 2a936dc over 2e151fe.
#
# The comparison is a question for GitHub about the SOURCE repo's history, not a
# local `merge-base`. Local git was the first attempt and it could not work: the
# script has already `cd`ed into the dagu-dags clone, and a --depth 1 checkout has
# no history to walk anyway. Both failure modes ended in `|| true`-shaped silence.
#
# compare/{base}...{head} reports head relative to base:
#   ahead     -> SHA descends from the pin; a normal forward bump
#   behind    -> the pin is newer; this build is stale, refuse
#   diverged  -> not a fast-forward; refuse
# An unreachable API is NOT treated as a rollback: the guard warns and steps
# aside, because it must not become a new way for a green build to fail.
# A deliberate rollback is a hand edit, which is the right place for it.
# ---------------------------------------------------------------------------
CURRENT_SHA=${current##*:}
if [[ $CURRENT_SHA =~ ^[0-9a-f]{40}$ && $CURRENT_SHA != "$SHA" ]]; then
  compare=$(ghapi "${API}/repos/${SRC_REPO}/compare/${CURRENT_SHA}...${SHA}" 2>/dev/null || true)
  status=$(jq -r '.status // empty' <<<"$compare" 2>/dev/null || true)
  case $status in
    ahead)
      log "${SHORT} is ahead of the pinned ${CURRENT_SHA:0:12} in ${SRC_REPO}" ;;
    behind|diverged)
      die "refusing to pin ${SHORT}: ${SRC_REPO} reports it is '${status}' relative to the pinned ${CURRENT_SHA:0:12}, so this would roll the pin backwards. If that is intended, edit ${DAG_PATH} by hand." ;;
    *)
      log "WARNING: could not confirm ${SHORT} descends from the pinned ${CURRENT_SHA:0:12} (compare API gave '${status:-no answer}'); pinning anyway" ;;
  esac
elif [[ -n $CURRENT_SHA && ! $CURRENT_SHA =~ ^[0-9a-f]{40}$ ]]; then
  log "WARNING: pinned value '${CURRENT_SHA}' is not a full commit SHA - skipping the backwards-pin guard"
fi

sed -i -E "s|^([[:space:]]*UM790_BACKUP_IMAGE:[[:space:]]*)\"[^\"]*\"[[:space:]]*\$|\1\"${TAG}\"|" "$DAG_PATH"

# A regex that matched more than the one pin line would rewrite the DAG, and a
# DAG is not something to discover a problem with at 03:00. Exactly one line
# changed, in each direction, or nothing is pushed.
changed=$(git diff --numstat -- "$DAG_PATH" | awk '{print $1 + $2}')
[[ $changed == 2 ]] \
  || die "expected exactly two changed lines in ${DAG_PATH}, got '${changed}' - refusing to push"
grep -qF "UM790_BACKUP_IMAGE: \"${TAG}\"" "$DAG_PATH" \
  || die "the new pin is not present in ${DAG_PATH} after editing"

# Belt and braces for the property this whole pipeline exists to protect: a
# published image must never be the thing that puts a cron on the host. If a
# future edit to the DAG arrives with a schedule key already in it, this script
# is not the place to quietly re-pin and merge. Reads the same shape the DAG's
# own governance record documents, so `# schedule:` counts as suspicious too.
if grep -qE '^[[:space:]]*#?[[:space:]]*schedule:' "$DAG_PATH"; then
  log "NOTE: ${DAG_PATH} carries a schedule key - re-pinning only; this script does not enable or alter scheduling"
fi

if [[ $DRY_RUN == 1 ]]; then
  git diff -- "$DAG_PATH" >&2
  log "dry-run: would push ${BRANCH}, open/refresh the PR, and merge it; stopping here"
  exit 0
fi

# ---------------------------------------------------------------------------
# commit and push (one branch, force-updated, so successive green builds refresh
# one PR instead of leaving a branch per build)
# ---------------------------------------------------------------------------
git checkout --quiet -B "$BRANCH"
git add -- "$DAG_PATH"
git commit --quiet \
  -m "chore(um790-backup): pin image to ${SHORT}" \
  -m "Published by ${BUILDKITE_BUILD_URL:-the um790-backup pipeline}." \
  -m "This sets the image tag and nothing else. ${DAG_PATH} has no schedule key, so this does not start a timer." \
  || die "git commit failed"
git push --quiet --force origin "HEAD:refs/heads/${BRANCH}" \
  || die "git push failed - does DAGU_DAGS_TOKEN have Contents: write on ${REPO}?"
log "pushed ${BRANCH} at ${SHORT}"

HEAD_SHA=$(git rev-parse HEAD)

# ---------------------------------------------------------------------------
# open the PR, or reuse the open one
# ---------------------------------------------------------------------------
OWNER=${REPO%%/*}
ENCODED_BRANCH=${BRANCH//\//%2F}

existing=$(ghapi "${API}/repos/${REPO}/pulls?head=${OWNER}:${ENCODED_BRANCH}&state=open") \
  || die "cannot list open PRs for ${REPO}"

PR_NUMBER=$(jq -r '.[0].number // empty' <<<"$existing")
if [[ -n $PR_NUMBER ]]; then
  log "PR #${PR_NUMBER} is already open; branch refreshed to ${SHORT}"
else
  PR_BODY=$(cat <<EOF
Automated pin bump from a green build of \`${SRC_REPO}\`, merged by CI.

- image: \`${TAG}\`
- build: ${BUILDKITE_BUILD_URL:-not a Buildkite run}

This changes one line in \`${DAG_PATH}\` and nothing else. The DAG has no
schedule key, so this **sets the pin but does not start a timer**.

This PR is a record, not a decision: it merges itself. The commit it produces is
the NAS deployment history, and reverting it is the rollback.

Naming the image, though, is not the same as proving it. Before any schedule is
added, run the phases by hand once each, as one run:

\`\`\`
um790-backup.sh preflight config dumps backup check snapshot prune status
\`\`\`

\`snapshot\` and \`prune\` are the two that have never run against DSM. Check that
prune's sweep line selected the snapshot you expected before enabling anything.
Prefer a whole-run invocation to \`dagu retry --step\`: a single step runs in a
fresh run and does not honour \`depends:\`, so it can pass over a dependency that
never ran.

Rollback: revert this PR's commit, or set \`UM790_BACKUP_IMAGE\` back to the
previous SHA. Nothing was pushed to a channel, so there is nothing to unpublish.
EOF
)

  payload=$(jq -n \
    --arg title "chore(um790-backup): pin image to ${SHORT}" \
    --arg head "$BRANCH" \
    --arg body "$PR_BODY" \
    '{title: $title, head: $head, base: "main", body: $body}')

  code=$(ghapi -o "$WORK/pr.json" -w '%{http_code}' -X POST -d "$payload" \
    "${API}/repos/${REPO}/pulls")

  case $code in
    201) PR_NUMBER=$(jq -r '.number' "$WORK/pr.json")
         log "opened PR #${PR_NUMBER} for ${SHORT}" ;;
    # Racing a second build that created it first is not a failure.
    422) log "a PR for ${BRANCH} already exists; leaving it to the next run" ; exit 0 ;;
    *)   cat "$WORK/pr.json" >&2
         die "GitHub returned HTTP ${code} opening the PR" ;;
  esac
fi

# ---------------------------------------------------------------------------
# merge it
# ---------------------------------------------------------------------------
if [[ $NO_MERGE == 1 ]]; then
  log "UM790_BACKUP_NO_MERGE=1: PR #${PR_NUMBER} left open for a human"
  exit 0
fi

# `sha` is the guard: it tells GitHub "merge only if the head is still the commit
# I just pushed". Without it, a branch refreshed between our push and this call
# could be merged at a commit that was never checked.
merge_payload=$(jq -n \
  --arg sha "$HEAD_SHA" \
  --arg title "chore(um790-backup): pin image to ${SHORT} (#${PR_NUMBER})" \
  '{merge_method: "squash", sha: $sha, commit_title: $title}')

code=$(ghapi -o "$WORK/merge.json" -w '%{http_code}' -X PUT -d "$merge_payload" \
  "${API}/repos/${REPO}/pulls/${PR_NUMBER}/merge")

case $code in
  200)
    log "merged PR #${PR_NUMBER} at $(jq -r '.sha[0:12]' "$WORK/merge.json")"
    # Best effort: the branch is force-updated on the next bump anyway, so a
    # failure to delete it is cosmetic and must not fail a green build.
    ghapi -o /dev/null -X DELETE "${API}/repos/${REPO}/git/refs/heads/${ENCODED_BRANCH}" \
      || log "could not delete ${BRANCH} (harmless; it is reused next run)"
    ;;
  405|409)
    # Mergeable came back false, usually because the hosts autocommit to this
    # repo and moved `main` while we were working.
    cat "$WORK/merge.json" >&2
    die "PR #${PR_NUMBER} is not mergeable right now (HTTP ${code}). It is open and holds ${SHORT}; merge it by hand or re-run this build."
    ;;
  403|404)
    cat "$WORK/merge.json" >&2
    die "cannot merge PR #${PR_NUMBER} (HTTP ${code}) - does DAGU_DAGS_TOKEN have write access to ${REPO}, and is main unprotected? The PR is open and holds ${SHORT}."
    ;;
  *)
    cat "$WORK/merge.json" >&2
    die "GitHub returned HTTP ${code} merging PR #${PR_NUMBER}; the PR is open and holds ${SHORT}"
    ;;
esac
