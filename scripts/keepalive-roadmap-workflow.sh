#!/usr/bin/env bash
set -euo pipefail

readonly base_branch="main"
readonly keepalive_branch="automation/roadmap-keepalive"
readonly keepalive_file=".github/last-keepalive"
readonly commit_title="chore: keep roadmap workflow active"
readonly bot_email="41898282+github-actions[bot]@users.noreply.github.com"

fail() {
  echo "Keepalive error: $*" >&2
  exit 1
}

command -v git >/dev/null || fail "git is unavailable."
command -v gh >/dev/null || fail "GitHub CLI (gh) is unavailable."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  fail "the repository checkout is unavailable; inspect the checkout step."
[ -n "${GH_TOKEN:-}" ] || fail "GH_TOKEN is not set."
[ -n "${KEEPALIVE_AFTER_DAYS:-}" ] || fail "KEEPALIVE_AFTER_DAYS is not set."
case "${KEEPALIVE_AFTER_DAYS}" in
  *[!0-9]*|'') fail "KEEPALIVE_AFTER_DAYS must be a non-negative integer." ;;
esac

echo "Fetching the latest origin/${base_branch}."
git fetch --no-tags origin \
  "+refs/heads/${base_branch}:refs/remotes/origin/${base_branch}" || \
  fail "could not fetch origin/${base_branch}; check checkout and contents permissions."

last_commit_ts="$(git show -s --format=%ct "origin/${base_branch}")"
now_ts="$(date -u +%s)"
if [ "${now_ts}" -lt "${last_commit_ts}" ]; then
  fail "origin/${base_branch} has a commit timestamp in the future."
fi
age_days=$(( (now_ts - last_commit_ts) / 86400 ))
echo "Last commit on ${base_branch}: ${age_days} day(s) ago (keepalive threshold: ${KEEPALIVE_AFTER_DAYS}, GitHub disables scheduled workflows at 60)."

if [ "${age_days}" -lt "${KEEPALIVE_AFTER_DAYS}" ]; then
  echo "Repository active recently enough; no keepalive pull request is needed."
  exit 0
fi

open_pr="$(gh pr list \
  --base "${base_branch}" \
  --head "${keepalive_branch}" \
  --state open \
  --json number \
  --jq '.[0].number // empty')" || \
  fail "could not query existing pull requests; check GH_TOKEN and pull-requests permissions."

remote_branch_sha="$(git ls-remote --heads origin "refs/heads/${keepalive_branch}" | awk 'NR == 1 { print $1 }')" || \
  fail "could not inspect origin/${keepalive_branch}."

if [ -n "${remote_branch_sha}" ]; then
  git fetch --no-tags origin \
    "+refs/heads/${keepalive_branch}:refs/remotes/origin/${keepalive_branch}" || \
    fail "could not fetch origin/${keepalive_branch}."

  # We refresh this automation branch from current main. Refuse to rewrite it
  # if anybody has placed unrelated work on it.
  while IFS= read -r commit; do
    [ -n "${commit}" ] || continue
    author_email="$(git show -s --format=%ae "${commit}")"
    [ "${author_email}" = "${bot_email}" ] || \
      fail "origin/${keepalive_branch} contains a non-automation commit (${commit}); refusing to rewrite it."
    unexpected_files="$(git diff-tree --no-commit-id --name-only -r "${commit}" -- | grep -Fvx "${keepalive_file}" || true)"
    [ -z "${unexpected_files}" ] || \
      fail "origin/${keepalive_branch} contains changes outside ${keepalive_file}; refusing to rewrite it."
  done < <(git rev-list "origin/${base_branch}..origin/${keepalive_branch}")
fi

git switch --detach "origin/${base_branch}"
timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '%s\n' "${timestamp}" > "${keepalive_file}"
git config user.name "github-actions[bot]"
git config user.email "${bot_email}"
git add -- "${keepalive_file}"
git diff --cached --quiet && fail "the keepalive timestamp did not change; refusing to create an empty commit."
git commit -m "${commit_title}"

if [ -n "${remote_branch_sha}" ]; then
  git push --force-with-lease="refs/heads/${keepalive_branch}:${remote_branch_sha}" \
    origin "HEAD:refs/heads/${keepalive_branch}" || \
    fail "could not safely update origin/${keepalive_branch}; it may have changed concurrently or contents write permission is missing."
else
  git push origin "HEAD:refs/heads/${keepalive_branch}" || \
    fail "could not create origin/${keepalive_branch}; check contents write permission and repository rules."
fi

if [ -n "${open_pr}" ]; then
  echo "Updated keepalive pull request #${open_pr}. It must be merged before the 60-day inactivity cutoff."
  exit 0
fi

pr_body="$(cat <<'EOF'
GitHub automatically disables scheduled workflows after 60 days without repository activity.

Please merge this pull request before that inactivity cutoff. Merging it adds a commit to `main` and resets the repository inactivity clock.
EOF
)"

if ! gh pr create \
  --base "${base_branch}" \
  --head "${keepalive_branch}" \
  --title "${commit_title}" \
  --body "${pr_body}" >/dev/null; then
  # Another run may have created the PR after our initial lookup.
  open_pr="$(gh pr list \
    --base "${base_branch}" \
    --head "${keepalive_branch}" \
    --state open \
    --json number \
    --jq '.[0].number // empty')" || true
  [ -n "${open_pr}" ] || \
    fail "the branch was pushed, but the pull request could not be created; check GH_TOKEN, pull-requests write permission, and repository policy."
  echo "Keepalive pull request #${open_pr} was created by another run."
fi

echo "Created a keepalive pull request. It must be merged before the 60-day inactivity cutoff."
