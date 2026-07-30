#!/usr/bin/env bash
set -euo pipefail

manifest="${MANIFEST:-apps.json}"
dist_branch="${DIST_BRANCH:-dist}"
output_dir="${OUTPUT_DIR:-dist}"
workdir="${WORKDIR:-${RUNNER_TEMP:-/tmp}/1panel-local-appstore-build}"
clean_build="${CLEAN_BUILD:-false}"

if [[ $# -gt 0 ]]; then
  echo "Unexpected arguments: $*" >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

json_escape() {
  jq -Rn --arg value "$1" '$value'
}

validate_manifest() {
  local invalid repo_count repo_index repo_name upstream_ref ref_target

  if [[ ! -r "$manifest" ]]; then
    echo "Manifest file not found: $manifest" >&2
    exit 1
  fi

  jq -e '
    type == "object"
    and (.repo | type == "array" and length > 0)
    and all(.repo[]; (
      (.name | type == "string" and length > 0)
      and (.upstream_repo | type == "string" and length > 0)
      and (.upstream_ref | type == "string" and length > 0)
      and (.apps | type == "array" and length > 0)
      and all(.apps[]; type == "string" and length > 0)
    ))
  ' "$manifest" >/dev/null || {
    echo "Invalid manifest schema: $manifest" >&2
    exit 1
  }

  invalid="$(jq -r '[.repo[].name | select((test("^[A-Za-z0-9._-]+$") and . != "." and . != "..") | not)] | unique | join(", ")' "$manifest")"
  if [[ -n "$invalid" ]]; then
    echo "Invalid repo name (allowed characters: A-Za-z0-9._-, \".\" and \"..\" rejected): $invalid" >&2
    exit 1
  fi

  invalid="$(jq -r '[.repo[].apps[] | select((test("^[A-Za-z0-9._-]+$") and . != "." and . != "..") | not)] | unique | join(", ")' "$manifest")"
  if [[ -n "$invalid" ]]; then
    echo "Invalid app name (allowed characters: A-Za-z0-9._-, \".\" and \"..\" rejected): $invalid" >&2
    exit 1
  fi

  repo_count="$(jq '.repo | length' "$manifest")"
  for (( repo_index = 0; repo_index < repo_count; repo_index++ )); do
    repo_name="$(jq -r ".repo[$repo_index].name" "$manifest")"
    upstream_ref="$(jq -r ".repo[$repo_index].upstream_ref" "$manifest")"
    if [[ "$upstream_ref" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
      continue
    fi
    ref_target="$upstream_ref"
    if [[ "$upstream_ref" != refs/* ]]; then
      ref_target="refs/heads/$upstream_ref"
    fi
    if ! git check-ref-format "$ref_target"; then
      echo "Invalid upstream_ref (must be a full lowercase commit SHA, or a ref name accepted by git check-ref-format): $repo_name: $upstream_ref" >&2
      exit 1
    fi
  done

  invalid="$(jq -r '
    [.repo[].name]
    | group_by(.)
    | map(select(length > 1) | "\(.[0]) (declared \(length) times)")
    | join("; ")
  ' "$manifest")"
  if [[ -n "$invalid" ]]; then
    echo "Duplicate repo name: $invalid" >&2
    exit 1
  fi

  invalid="$(jq -r '
    [.repo[] | .name as $repo_name | .apps[] | {app: ., repo: $repo_name}]
    | group_by(.app)
    | map(select(length > 1) | "\(.[0].app) (declared by \([.[].repo] | join(", ")))")
    | join("; ")
  ' "$manifest")"
  if [[ -n "$invalid" ]]; then
    echo "Duplicate app name: $invalid" >&2
    exit 1
  fi
}

resolve_upstream_ref() {
  local repo_name="$1"
  local upstream_url="$2"
  local upstream_ref="$3"
  local refs commit="" matched_ref=""
  local patterns=()

  if [[ "$upstream_ref" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    printf '%s' "$upstream_ref"
    return 0
  fi

  if [[ "$upstream_ref" == refs/* ]]; then
    patterns=("$upstream_ref" "${upstream_ref}^{}")
  else
    patterns=("refs/heads/$upstream_ref" "refs/tags/$upstream_ref" "refs/tags/$upstream_ref^{}")
  fi

  if ! refs="$(git ls-remote -- "$upstream_url" "${patterns[@]}")"; then
    echo "Unable to query upstream refs for $repo_name ($upstream_url $upstream_ref)" >&2
    return 1
  fi

  if [[ "$upstream_ref" == refs/* ]]; then
    matched_ref="$upstream_ref"
    commit="$(awk -v ref="${upstream_ref}^{}" '$2 == ref { print $1; exit }' <<<"$refs")"
    [[ -n "$commit" ]] || commit="$(awk -v ref="$upstream_ref" '$2 == ref { print $1; exit }' <<<"$refs")"
  else
    commit="$(awk -v ref="refs/heads/$upstream_ref" '$2 == ref { print $1; exit }' <<<"$refs")"
    if [[ -n "$commit" ]]; then
      matched_ref="refs/heads/$upstream_ref"
    else
      commit="$(awk -v ref="refs/tags/$upstream_ref^{}" '$2 == ref { print $1; exit }' <<<"$refs")"
      [[ -n "$commit" ]] || commit="$(awk -v ref="refs/tags/$upstream_ref" '$2 == ref { print $1; exit }' <<<"$refs")"
      [[ -n "$commit" ]] && matched_ref="refs/tags/$upstream_ref"
    fi
  fi

  if [[ -z "$commit" ]]; then
    echo "Unable to resolve upstream ref for $repo_name ($upstream_url $upstream_ref)" >&2
    return 1
  fi

  printf '%s %s' "$commit" "$matched_ref"
}

set_should_skip() {
  local value="$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "should_skip=$value" >> "$GITHUB_OUTPUT"
  else
    echo "should_skip=$value"
  fi
}

current_dist_json=""

load_current_dist_json() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is not available; dist will be built." >&2
    return 1
  fi

  if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    echo "GITHUB_REPOSITORY is not set; dist will be built." >&2
    return 1
  fi

  if current_dist_json="$(gh api \
    -H "Accept: application/vnd.github.raw+json" \
    "repos/${GITHUB_REPOSITORY}/contents/dist.json?ref=${dist_branch}" 2>/dev/null)"; then
    echo "Loaded current dist.json from $dist_branch branch." >&2
    return 0
  fi

  echo "dist.json was not found on $dist_branch branch; dist will be built." >&2
  current_dist_json=""
  return 1
}

should_skip_build() {
  local expected_json current_normalized expected_normalized
  local expected_upstream_items=() repo_count repo_index repo_name upstream_repo

  if [[ "$clean_build" == "true" ]]; then
    echo "CLEAN_BUILD is enabled; dist will be built."
    return 1
  fi

  if [[ -z "$source_sha" ]]; then
    echo "Warning: source SHA is missing; dist will be built." >&2
    return 1
  fi

  repo_count="$(jq '.repo | length' "$manifest")"
  for (( repo_index = 0; repo_index < repo_count; repo_index++ )); do
    repo_name="$(jq -r ".repo[$repo_index].name" "$manifest")"
    upstream_repo="$(jq -r ".repo[$repo_index].upstream_repo" "$manifest")"
    expected_upstream_items+=("$(printf '{"name":%s,"upstream_repo":%s,"upstream_sha":%s}' \
      "$(json_escape "$repo_name")" \
      "$(json_escape "$upstream_repo")" \
      "$(json_escape "${resolved_shas[$repo_index]}")")")
  done
  expected_json="$(printf '%s\n' "${expected_upstream_items[@]}" | jq -s --arg source_sha "$source_sha" \
    '{source_sha: $source_sha, upstream: .}')"

  if ! load_current_dist_json; then
    return 1
  fi

  if [[ -z "$current_dist_json" ]]; then
    echo "Current dist.json was not found; dist will be built."
    return 1
  fi

  if ! jq -e 'type == "object" and (.upstream | type == "array")' <<<"$current_dist_json" >/dev/null; then
    echo "Warning: current dist.json is invalid; dist will be built." >&2
    return 1
  fi

  if ! jq -e '
    (.source_sha | type == "string")
    and all(.upstream[]?; (.upstream_sha | type == "string"))
  ' <<<"$current_dist_json" >/dev/null; then
    echo "Warning: current dist.json has missing or invalid source/upstream metadata; dist will be built." >&2
    return 1
  fi

  current_normalized="$(jq -S '{source_sha, upstream}' <<<"$current_dist_json")"
  expected_normalized="$(jq -S '.' <<<"$expected_json")"

  if [[ "$current_normalized" == "$expected_normalized" ]]; then
    echo "Current dist.json already matches the source SHA and pinned upstream SHAs."
    return 0
  fi

  echo "Current dist.json is stale; dist will be built."
  return 1
}

build_dist() {
  if [[ -z "$source_sha" ]]; then
    echo "Warning: source SHA is unavailable; dist.json will omit source_sha." >&2
  fi

  rm -rf "$workdir" "$output_dir"
  mkdir -p "$workdir" "$output_dir"

  local dist_app_json_items=()
  local dist_upstream_json_items=()
  local repo_count repo_index repo_name upstream_repo upstream_ref upstream_dir upstream_commit
  local resolved_sha resolved_ref fetch_target object_format
  local apps app sparse_paths sparse_path source_app target_app

  repo_count="$(jq '.repo | length' "$manifest")"
  for (( repo_index = 0; repo_index < repo_count; repo_index++ )); do
    repo_name="$(jq -r ".repo[$repo_index].name" "$manifest")"
    upstream_repo="$(jq -r ".repo[$repo_index].upstream_repo" "$manifest")"
    upstream_ref="$(jq -r ".repo[$repo_index].upstream_ref" "$manifest")"
    resolved_sha="${resolved_shas[$repo_index]}"
    resolved_ref="${resolved_refs[$repo_index]}"
    fetch_target="${resolved_ref:-$resolved_sha}"

    upstream_dir="$workdir/$repo_name"
    mapfile -t apps < <(jq -r ".repo[$repo_index].apps[]" "$manifest")
    sparse_paths=()
    declare -A seen_sparse_paths=()

    for app in "${apps[@]}"; do
      sparse_path="apps/$app"
      if [[ -z "${seen_sparse_paths[$sparse_path]+x}" ]]; then
        sparse_paths+=("$sparse_path")
        seen_sparse_paths[$sparse_path]=1
      fi
    done

    object_format=sha1
    [[ "${#resolved_sha}" -eq 64 ]] && object_format=sha256

    echo "Fetching $repo_name ($upstream_repo $fetch_target, $object_format)"
    git init -q --object-format="$object_format" "$upstream_dir"
    git -C "$upstream_dir" remote add -- origin "$upstream_repo"
    git -C "$upstream_dir" sparse-checkout set --cone "${sparse_paths[@]}"
    git -C "$upstream_dir" fetch -q --depth=1 --filter=blob:none origin "$fetch_target"
    git -C "$upstream_dir" checkout -q --detach FETCH_HEAD
    upstream_commit="$(git -C "$upstream_dir" rev-parse HEAD)"

    if [[ "$upstream_commit" != "$resolved_sha" ]]; then
      if [[ -n "$resolved_ref" ]]; then
        echo "Warning: $resolved_ref for $repo_name moved from $resolved_sha to $upstream_commit between resolve and fetch; recording the fetched commit." >&2
      else
        echo "Fetched commit $upstream_commit does not match pinned upstream commit $resolved_sha ($repo_name)" >&2
        exit 1
      fi
    fi

    dist_upstream_json_items+=("$(printf '{"name":%s,"upstream_repo":%s,"upstream_sha":%s}' \
      "$(json_escape "$repo_name")" \
      "$(json_escape "$upstream_repo")" \
      "$(json_escape "$upstream_commit")")")

    for app in "${apps[@]}"; do
      source_app="$upstream_dir/apps/$app"
      target_app="$output_dir/$app"

      if [[ ! -d "$source_app" ]]; then
        echo "App not found in upstream: $app ($repo_name)" >&2
        exit 1
      fi

      rm -rf "$target_app"
      cp -a "$source_app" "$target_app"

      dist_app_json_items+=("$(printf '{"name":%s,"upstream":%s}' \
        "$(json_escape "$app")" \
        "$(json_escape "$repo_name")")")
    done
  done

  if [[ "${#dist_app_json_items[@]}" -eq 0 ]]; then
    echo "No apps were copied" >&2
    exit 1
  fi

  local upstream_json apps_json
  upstream_json="$(printf '%s\n' "${dist_upstream_json_items[@]}" | jq -s '.')"
  apps_json="$(printf '%s\n' "${dist_app_json_items[@]}" | jq -s '.')"
  jq -n \
    --arg build_time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg source_sha "$source_sha" \
    --argjson upstream "$upstream_json" \
    --argjson apps "$apps_json" \
    '({build_time: $build_time}
      + (if $source_sha == "" then {} else {source_sha: $source_sha} end)
      + {upstream: $upstream, apps: $apps})' \
    > "$output_dir/dist.json"

  echo "Dist content built at $output_dir"
}

validate_manifest
echo "Manifest is valid: $manifest"

source_sha="${SOURCE_SHA:-${GITHUB_SHA:-}}"
if [[ -z "$source_sha" ]]; then
  source_sha="$(git rev-parse --verify HEAD 2>/dev/null || true)"
fi

resolved_shas=()
resolved_refs=()
repo_count="$(jq '.repo | length' "$manifest")"
for (( repo_index = 0; repo_index < repo_count; repo_index++ )); do
  repo_name="$(jq -r ".repo[$repo_index].name" "$manifest")"
  upstream_repo="$(jq -r ".repo[$repo_index].upstream_repo" "$manifest")"
  upstream_ref="$(jq -r ".repo[$repo_index].upstream_ref" "$manifest")"
  if ! resolved="$(resolve_upstream_ref "$repo_name" "$upstream_repo" "$upstream_ref")"; then
    exit 1
  fi
  read -r resolved_commit resolved_fullref <<<"$resolved"
  if [[ -n "$resolved_fullref" ]]; then
    echo "Resolved $repo_name: $upstream_ref -> $resolved_commit ($resolved_fullref)"
  else
    echo "Resolved $repo_name: pinned commit $resolved_commit"
  fi
  resolved_shas+=("$resolved_commit")
  resolved_refs+=("$resolved_fullref")
done

if should_skip_build; then
  set_should_skip true
  exit 0
fi

build_dist
set_should_skip false
