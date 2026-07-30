#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install.sh

Installs or updates this repository's dist branch for a 1Panel server. The
worktree body lives at <INSTALL_DIR>/dist and the 1Panel local apps dir is
maintained as a symlink to it. First run clones the dist branch; later runs
fetch and hard-reset to the latest publish. A copy of this script is kept at
<INSTALL_DIR>/install.sh so a 1Panel scheduled task can call a stable path.

Configuration is passed via environment variables only; the only accepted
argument is -h/--help. Precedence: environment variable > install.conf
(written next to the script copy on every successful run) > built-in default.
A customized install therefore keeps working with a plain, argument-less
`bash <INSTALL_DIR>/install.sh`.

Environment variables:
  REPO_URL        Repository URL, passed to git as-is. Required on first
                  install unless an existing dist.git still records the
                  origin; later runs default to the stored origin.
  DIST_BRANCH     Dist branch name. Default: dist on first install; the
                  currently checked out branch on updates.
  INSTALL_DIR     Directory for the worktree body (dist/), git metadata
                  (dist.git/), the script copy, the lock file and
                  install.conf. Default: the script's own directory when an
                  install.conf or dist.git sits next to it, otherwise
                  /opt/1panel-local-appstore.
  LOCAL_APPS_DIR  1Panel local apps dir; maintained as a symlink to
                  <INSTALL_DIR>/dist and must not be inside INSTALL_DIR.
                  Default: the value recorded in install.conf, otherwise
                  /opt/1panel/resource/apps/local.
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
  echo "Unexpected arguments: $*" >&2
  echo "Configuration is passed via environment variables; run with --help for details." >&2
  exit 2
fi

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

repo_url="${REPO_URL:-}"
dist_branch="${DIST_BRANCH:-}"
install_dir="${INSTALL_DIR:-}"
local_apps_dir="${LOCAL_APPS_DIR:-}"

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock is required" >&2; exit 1; }
command -v realpath >/dev/null 2>&1 || { echo "realpath is required" >&2; exit 1; }
command -v find >/dev/null 2>&1 || { echo "find is required" >&2; exit 1; }
command -v sed >/dev/null 2>&1 || { echo "sed is required" >&2; exit 1; }

self_real=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  self_real="$(realpath "${BASH_SOURCE[0]}")"
fi

if [[ -z "$install_dir" ]]; then
  if [[ -n "$self_real" ]]; then
    self_dir="$(dirname "$self_real")"
    if [[ -f "$self_dir/install.conf" || -d "$self_dir/dist.git" ]]; then
      install_dir="$self_dir"
    fi
  fi
  install_dir="${install_dir:-/opt/1panel-local-appstore}"
fi
install_dir="${install_dir%/}"

conf_file="$install_dir/install.conf"
if [[ -z "$local_apps_dir" && -f "$conf_file" ]]; then
  while IFS= read -r conf_line; do
    case "$conf_line" in
      LOCAL_APPS_DIR=*) local_apps_dir="${conf_line#LOCAL_APPS_DIR=}" ;;
    esac
  done < "$conf_file"
fi
local_apps_dir="${local_apps_dir:-/opt/1panel/resource/apps/local}"
local_apps_dir="${local_apps_dir%/}"

redact_url() {
  printf '%s\n' "$1" | sed -E 's#//[^/@]+@#//***@#'
}

local_apps_parent="$(dirname "$local_apps_dir")"
if [[ ! -d "$local_apps_parent" ]]; then
  echo "LOCAL_APPS_DIR parent does not exist: $local_apps_parent" >&2
  echo "Set LOCAL_APPS_DIR to your 1Panel local apps dir, usually <1Panel install dir>/resource/apps/local" >&2
  exit 2
fi

if ! mkdir -p "$install_dir"; then
  echo "Cannot create $install_dir (try running as root, or set INSTALL_DIR)" >&2
  exit 1
fi
install_dir="$(cd "$install_dir" && pwd -P)"
local_apps_dir="$(cd "$local_apps_parent" && pwd -P)/$(basename "$local_apps_dir")"

chmod 700 "$install_dir"

git_dir="$install_dir/dist.git"
worktree_dir="$install_dir/dist"
lock_file="$install_dir/.lock"
self_target="$install_dir/install.sh"
conf_file="$install_dir/install.conf"

if [[ "$local_apps_dir/" == "$install_dir/"* ]]; then
  echo "LOCAL_APPS_DIR must not be inside INSTALL_DIR ($local_apps_dir is under $install_dir)" >&2
  exit 2
fi
if [[ "$install_dir/" == "$local_apps_dir/"* ]]; then
  echo "INSTALL_DIR must not be inside LOCAL_APPS_DIR ($install_dir is under $local_apps_dir)" >&2
  exit 2
fi

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another install/update is already running (lock: $lock_file)" >&2
  exit 1
fi

backup_ts="$(date -u '+%Y%m%d%H%M%S')"

if [[ -n "$self_real" ]]; then
  if [[ ! -e "$self_target" || "$self_real" != "$(realpath "$self_target")" ]]; then
    tmp_copy="$install_dir/.install.sh.tmp"
    rm -f "$tmp_copy"
    cp "$self_real" "$tmp_copy"
    chmod 755 "$tmp_copy"
    mv -f "$tmp_copy" "$self_target"
    echo "Installed script copy: $self_target"
  fi
else
  echo "Warning: script source is not a regular file (running from stdin?); skipping self-install." >&2
  echo "The 1Panel scheduled task needs a copy at $self_target" >&2
fi

make_link() {
  if [[ -L "$local_apps_dir" ]]; then
    tmp_link="$local_apps_dir.tmp.$$"
    rm -f "$tmp_link"
    ln -s "$worktree_dir" "$tmp_link"
    mv -T "$tmp_link" "$local_apps_dir"
  else
    ln -s "$worktree_dir" "$local_apps_dir"
  fi
}

mode=install
if [[ -f "$worktree_dir/.git" ]]; then
  if git -C "$worktree_dir" rev-parse --absolute-git-dir >/dev/null 2>&1; then
    mode=update
  else
    echo "Warning: $worktree_dir/.git points to a missing or broken git dir; reinstalling." >&2
  fi
fi

if [[ -z "$dist_branch" ]]; then
  if [[ "$mode" == update ]]; then
    dist_branch="$(git -C "$worktree_dir" symbolic-ref --short HEAD 2>/dev/null || echo dist)"
  else
    dist_branch=dist
  fi
fi

if [[ "$mode" == update ]]; then
  if [[ -n "$repo_url" ]]; then
    git -C "$worktree_dir" remote set-url -- origin "$repo_url"
  fi
  old_sha="$(git -C "$worktree_dir" rev-parse --short HEAD)"
  echo "Updating $worktree_dir (branch $dist_branch)"
  if ! git -C "$worktree_dir" fetch --depth=1 origin "+$dist_branch:refs/remotes/origin/$dist_branch"; then
    echo "Fetch failed; local apps left unchanged at $old_sha" >&2
    exit 1
  fi
  git -C "$worktree_dir" checkout -B "$dist_branch" "refs/remotes/origin/$dist_branch"
  git -C "$worktree_dir" reset --hard "refs/remotes/origin/$dist_branch"
else
  if [[ -z "$repo_url" && -f "$git_dir/config" ]]; then
    repo_url="$(git config --file "$git_dir/config" --get remote.origin.url 2>/dev/null || true)"
    if [[ -n "$repo_url" ]]; then
      echo "Reusing origin recorded in $git_dir: $(redact_url "$repo_url")"
    fi
  fi
  if [[ -z "$repo_url" ]]; then
    echo "REPO_URL is required for first install" >&2
    exit 2
  fi

  if [[ -e "$worktree_dir" || -L "$worktree_dir" ]]; then
    echo "Removing leftover $worktree_dir"
    rm -rf "$worktree_dir"
  fi
  if [[ -e "$git_dir" || -L "$git_dir" ]]; then
    echo "Removing leftover $git_dir"
    rm -rf "$git_dir"
  fi

  echo "Cloning branch $dist_branch to $worktree_dir from $(redact_url "$repo_url")"
  if ! git clone --depth=1 --branch "$dist_branch" --separate-git-dir "$git_dir" -- "$repo_url" "$worktree_dir"; then
    echo "Clone failed" >&2
    exit 1
  fi
fi

if [[ -L "$local_apps_dir" ]]; then
  link_target="$(readlink "$local_apps_dir")"
  if [[ "$link_target" != "$worktree_dir" ]]; then
    echo "Warning: $local_apps_dir pointed to $link_target; retargeting to $worktree_dir" >&2
    make_link
    echo "Linked $local_apps_dir -> $worktree_dir"
  fi
elif [[ -d "$local_apps_dir" ]]; then
  if ! rmdir "$local_apps_dir" 2>/dev/null; then
    backup="$local_apps_dir.backup.$backup_ts"
    echo "Moving existing $local_apps_dir to $backup"
    mv "$local_apps_dir" "$backup"
  fi
  make_link
  echo "Linked $local_apps_dir -> $worktree_dir"
elif [[ -e "$local_apps_dir" ]]; then
  backup="$local_apps_dir.backup.$backup_ts"
  echo "Moving existing $local_apps_dir to $backup"
  mv "$local_apps_dir" "$backup"
  make_link
  echo "Linked $local_apps_dir -> $worktree_dir"
else
  make_link
  echo "Linked $local_apps_dir -> $worktree_dir"
fi

if [[ ! -f "$worktree_dir/dist.json" ]]; then
  echo "Expected dist metadata not found: $worktree_dir/dist.json" >&2
  exit 1
fi

first_app_data="$(find "$worktree_dir" -mindepth 2 -maxdepth 2 -type f -name data.yml -print -quit)"
if [[ -z "$first_app_data" ]]; then
  echo "No app data.yml found under $worktree_dir/<app-name>/data.yml" >&2
  echo "Make sure the dist branch contains app directories at its root." >&2
  exit 1
fi

if [[ "$(readlink "$local_apps_dir" 2>/dev/null)" != "$worktree_dir" ]]; then
  echo "Link verification failed: $local_apps_dir does not point to $worktree_dir" >&2
  exit 1
fi

conf_tmp="$install_dir/.install.conf.tmp"
printf 'LOCAL_APPS_DIR=%s\n' "$local_apps_dir" > "$conf_tmp"
mv -f "$conf_tmp" "$conf_file"

new_sha="$(git -C "$worktree_dir" rev-parse --short HEAD)"
if [[ "$mode" == update ]]; then
  if [[ "$old_sha" == "$new_sha" ]]; then
    echo "Already up to date: $new_sha"
  else
    echo "Updated: $old_sha -> $new_sha"
  fi
else
  echo "Installed: $new_sha"
  echo
  echo "1Panel local apps dir (symlink): $local_apps_dir"
  echo "Worktree body: $worktree_dir"
  echo "Git metadata: $git_dir"
  echo "Script copy: $self_target"
  echo "Config file: $conf_file"
  echo
  echo "Next steps:"
  echo "1. In the 1Panel app store, run \"Sync local apps\"."
  echo "2. Create a Shell-script scheduled task in 1Panel for periodic updates:"
  echo "     bash $self_target"
  echo "   Best scheduled daily after the dist publish (20:00 UTC); mind the server's timezone."
  echo "   The directories, branch and repo URL from this run are saved; the task needs no arguments."
fi

origin_url="$(git -C "$worktree_dir" remote get-url origin)"
if [[ "$origin_url" == https://* && "$origin_url" != *@* ]] \
  && ! git -C "$worktree_dir" config --get credential.helper >/dev/null 2>&1; then
  echo
  echo "Reminder: origin is an https URL without credentials and no credential.helper is detected."
  echo "Scheduled tasks run without a terminal, git cannot prompt for credentials, and updates will fail. Pick one:"
  echo "  - Run git config --global credential.helper store, then run this script once manually and enter the credentials;"
  echo "  - Re-run with REPO_URL set to a URL with an embedded token (saved to $git_dir/config);"
  echo "  - Switch to an SSH URL and set up a deploy key."
  echo "If credentials are already provided some other way, ignore this reminder."
fi
