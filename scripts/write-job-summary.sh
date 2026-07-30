#!/usr/bin/env bash
set -euo pipefail

dist_json="${DIST_JSON:-dist/dist.json}"
skipped="${SKIPPED:-false}"
status=""

case "$skipped" in
  true)
    status="Already up to date; build skipped"
    ;;
  false)
    status="Build succeeded"
    ;;
  *)
    echo "SKIPPED must be true or false" >&2
    exit 2
    ;;
esac

escape_md() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

write_summary() {
  local app_count
  local build_time
  local source_sha
  local upstream_count

  echo "## Dist publishing summary"
  echo
  echo "- Status: $status"

  if [[ "$skipped" == "true" ]]; then
    return 0
  fi

  if [[ ! -r "$dist_json" ]]; then
    echo "- dist.json: not found"
    return 0
  fi

  command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

  build_time="$(jq -r '.build_time // ""' "$dist_json")"
  source_sha="$(jq -r '.source_sha // ""' "$dist_json")"
  app_count="$(jq '.apps | length' "$dist_json")"
  upstream_count="$(jq '.upstream | length' "$dist_json")"

  if [[ -n "$build_time" ]]; then
    echo "- Build time: \`$build_time\`"
  fi
  if [[ -n "$source_sha" ]]; then
    echo "- Source SHA: \`$source_sha\`"
  fi
  echo "- Upstreams: $upstream_count"
  echo "- Apps: $app_count"
  echo

  echo "### Upstreams"
  echo
  if [[ "$upstream_count" -eq 0 ]]; then
    echo "_No upstreams recorded_"
  else
    echo "| Name | Repository | SHA |"
    echo "| --- | --- | --- |"
    while IFS=$'\t' read -r name repo sha; do
      echo "| $(escape_md "$name") | $(escape_md "$repo") | \`$sha\` |"
    done < <(jq -r '.upstream[] | [.name, .upstream_repo, .upstream_sha] | @tsv' "$dist_json")
  fi
  echo

  echo "### Apps"
  echo
  if [[ "$app_count" -eq 0 ]]; then
    echo "_No apps recorded_"
  else
    echo "| App | Upstream |"
    echo "| --- | --- |"
    while IFS=$'\t' read -r name upstream; do
      echo "| $(escape_md "$name") | $(escape_md "$upstream") |"
    done < <(jq -r '.apps[] | [.name, .upstream] | @tsv' "$dist_json")
  fi
}

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  write_summary >> "$GITHUB_STEP_SUMMARY"
else
  write_summary
fi
