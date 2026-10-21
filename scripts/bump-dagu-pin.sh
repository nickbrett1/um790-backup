#!/usr/bin/env bash
# Bump the pinned um790-backup image in nickbrett1/dagu-dags and open (or
# refresh) the PR that carries it.
#
# This is the "automate the promotion, not the pull" half of the deploy design.
# A green main build never reaches the NAS by itself: it lands as a one-line
# diff, on a branch, for a human to merge.
#
# Why a PR and not a channel pull:
#   - the phases run as separate `docker run --rm` invocations, so an image that
#     changes between them makes a failure unreproducible and a retry not
#     identical;
#   - `prune` is the one phase that can destroy snapshot history, and a bad one
#     on a pin costs a one-line revert while a bad one on a channel costs a new
#     publish;
#   - so the pin stays, and only the hand-editing of the SHA goes away.
#
# The file it edits is `um790-backup.yaml.disabled`: even a merged bump cannot
# put an unattended `restic forget --prune` on a timer. Enabling stays a separate
# rename, by a human, after the phases have been run by hand once.
#
# Inputs (all optional):
#   DOPPLER_TOKEN              required unless DAGU_DAGS_TOKEN is already set;
#                              used to read DAGU_DAGS_TOKEN from common/prd
#   DAGU_DAGS_TOKEN            overrides the Doppler lookup (local use)
#   UM790_BACKUP_IMAGE_SHA     tag to pin (default: $BUILDKITE_COMMIT)
#   UM790_BACKUP_REPO_SLUG     default nickbrett1/dagu-dags
#   UM790_BACKUP_DAG_PATH      default dags/ryzen/um790-backup.yaml.disabled
#   UM790_BACKUP_BRANCH        default auto/um790-backup-pin
#   UM790_BACKUP_IMAGE_NAME    default ghcr.io/nickbrett1/um790-backup
#   DRY_RUN=1                  clone and rewrite, print the diff, do not push
set -Eeuo pipefail
IFS=$'\n\t'

API=https://api.github.com
REPO=${UM790_BACKUP_REPO_SLUG:-nickbrett1/dagu-dags}
DAG_PATH=${UM790_BACKUP_DAG_PATH:-dags/ryzen/um790-backup.yaml.disabled}
BRANCH=${UM790_BACKUP_BRANCH:-auto/um790-backup-pin}
IMAGE=${UM790_BACKUP_IMAGE_NAME:-ghcr.io/nickbrett1/um790-backup}
SHA=${UM790_BACKUP_IMAGE_SHA:-${BUILDKITE_COMMIT:-}}
DRY_RUN=${DRY_RUN:-0}

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
# rewrite the pin
# ---------------------------------------------------------------------------
[[ -f $DAG_PATH ]] || die "${DAG_PATH} does not exist in ${REPO} - wrong path, or the DAG was renamed"

current=$(sed -n -E 's/^[[:space:]]*UM790_BACKUP_IMAGE:[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "$DAG_PATH")
[[ -n $current ]] \
  || die "no UM790_BACKUP_IMAGE: \"...\" line in ${DAG_PATH} - refusing to guess at the shape"
log "currently pinned: ${current}"

if [[ $current == "$TAG" ]]; then
  log "already pinned to ${TAG:0:0}${TAG} - nothing to do"
  exit 0
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

if [[ $DRY_RUN == 1 ]]; then
  git diff -- "$DAG_PATH" >&2
  log "dry-run: would push ${BRANCH} and open/refresh the PR; stopping here"
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
  -m "The DAG file stays .disabled: merging this sets the pin, it does not start the schedule. Run the phases by hand once, then rename it." \
  || die "git commit failed"
git push --quiet --force origin "HEAD:refs/heads/${BRANCH}" \
  || die "git push failed - does DAGU_DAGS_TOKEN have Contents: write on ${REPO}?"
log "pushed ${BRANCH} at ${SHORT}"

# ---------------------------------------------------------------------------
# open the PR, or report the one that is already there
# ---------------------------------------------------------------------------
OWNER=${REPO%%/*}
ENCODED_BRANCH=${BRANCH//\//%2F}

existing=$(curl -fsS \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "${API}/repos/${REPO}/pulls?head=${OWNER}:${ENCODED_BRANCH}&state=open") \
  || die "cannot list open PRs for ${REPO}"

open_count=$(jq 'length' <<<"$existing")
if [[ $open_count != 0 ]]; then
  log "PR #$(jq -r '.[0].number' <<<"$existing") is already open; branch refreshed to ${SHORT}"
  exit 0
fi

PR_BODY=$(cat <<EOF
Automated pin bump from a green build of \`nickbrett1/um790-backup\`.

- image: \`${TAG}\`
- build: ${BUILDKITE_BUILD_URL:-not a Buildkite run}

This changes one line in \`${DAG_PATH}\` and nothing else. The file stays
\`.disabled\`, so merging this **sets the pin but does not start the schedule**.

Before renaming it to \`um790-backup.yaml\`, run the phases by hand once each:

\`\`\`
um790-backup.sh preflight config dumps backup check snapshot prune status
\`\`\`

\`snapshot\` and \`prune\` are the two that have never run against DSM. Check that
prune's sweep line selected the snapshot you expected before enabling the cron.

Rollback: revert this PR's commit, or set \`UM790_BACKUP_IMAGE\` back to the
previous SHA. Nothing was pushed to a channel, so there is nothing to unpublish.
EOF
)

payload=$(jq -n \
  --arg title "chore(um790-backup): pin image to ${SHORT}" \
  --arg head "$BRANCH" \
  --arg body "$PR_BODY" \
  '{title: $title, head: $head, base: "main", body: $body}')

code=$(curl -sS -o "$WORK/pr.json" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -d "$payload" \
  "${API}/repos/${REPO}/pulls")

case $code in
  201) log "opened PR #$(jq -r '.number' "$WORK/pr.json") for ${SHORT}" ;;
  # Racing a second build that created it first is not a failure.
  422) log "a PR for ${BRANCH} already exists; left it alone" ;;
  *)
    cat "$WORK/pr.json" >&2
    die "GitHub returned HTTP ${code} opening the PR"
    ;;
esac
