#!/usr/bin/env bash
set -euo pipefail

current_origin() {
  git config --get remote.origin.url 2>/dev/null || true
}

dist_dir="${DIST_DIR:-dist}"
dist_branch="${DIST_BRANCH:-dist}"
publish_dir="${PUBLISH_DIR:-${RUNNER_TEMP:-/tmp}/1panel-local-appstore-publish}"

if [[ ! -d "$dist_dir" ]]; then
  echo "Dist directory not found: $dist_dir" >&2
  exit 1
fi
dist_dir="$(cd "$dist_dir" && pwd)"

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }

repo_url="${REPO_URL:-}"
if [[ -z "$repo_url" && -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  repo_url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi
repo_url="${repo_url:-$(current_origin)}"

if [[ -z "$repo_url" ]]; then
  echo "Unable to determine publish repository URL" >&2
  exit 1
fi

rm -rf "$publish_dir"
git init --initial-branch="$dist_branch" "$publish_dir"
publish_dir="$(cd "$publish_dir" && pwd)"
cd "$publish_dir"
git remote add -- origin "$repo_url"
cp -a "$dist_dir/." "$publish_dir/"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -Af

git commit -m "Publish selected apps"
git push origin "HEAD:$dist_branch" --force
