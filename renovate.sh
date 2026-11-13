#!/usr/bin/env bash
# Run Renovate, with my usual configuration, on the repos named as arguments.
#
# Configuration is by environment variable: anything set already wins over the
# defaults below (set one to the empty string to clear it), and everything
# Renovate reads from the environment is passed through to its container.
# Repos' own config files are ignored. It's a dry run unless you set
# RENOVATE_DRY_RUN=null. You need at least RENOVATE_TOKEN, e.g.:
#
#   RENOVATE_TOKEN=$(gh auth token) ./renovate.sh bmillwood/freecell
#
# composite-actions/renovate is a thin wrapper around this for GitHub Actions.
set -o errexit
set -o nounset
set -o pipefail

renovate_image=ghcr.io/renovatebot/renovate:44.239.1@sha256:7dba1a3b916a2cf302ba0df458ddcc8fcbac3c92d0fe9882ac13ba0363de656b # renovate: datasource=docker

default() {
  local name=$1 value=$2
  [[ -v $name ]] || export "$name=$value"
}

default RENOVATE_DRY_RUN full
default RENOVATE_REQUIRE_CONFIG optional
default RENOVATE_ONBOARDING false
default RENOVATE_EXTENDS config:recommended,helpers:pinGitHubActionDigests
# Noisy, but IME a lot of what you care about is at debug level.
default LOG_LEVEL debug

default RENOVATE_CUSTOM_MANAGERS "$(cat <<'EOF'
[
  {
    "customType": "regex",
    "description": "Update versions anywhere, using marker comments",
    "managerFilePatterns": [".github/workflows/*"],
    "matchStrings": [
      ":\\s*(?<currentValue>[0-9.]+)\\s*# renovate: datasource=(?<datasource>[a-z-]+) depName=(?<depName>\\S+)",
    ],
  },
  {
    "customType": "regex",
    "description": "Update git digests of branches anywhere, using marker comments",
    "managerFilePatterns": [".github/workflows/*"],
    "matchStrings": [
      ":\\s*(?<currentDigest>[a-f0-9]{40})\\s*# renovate: datasource=(?<datasource>[a-z-]+) depName=(?<depName>\\S+) packageName=(?<packageName>\\S+) currentValue=(?<currentValue>\\S+)",
    ],
    // when I'm trying to update a digest, I usually don't want to also
    // update the currentValue
    // "versioning" is the wrong parameter to configure this, it only
    // affects extracting versions, not deciding on new ones
    "versioningTemplate": "exact",
  },
  {
    "customType": "regex",
    "description": "Update digest-pinned docker image references anywhere, using marker comments",
    "managerFilePatterns": [".github/workflows/*", "**/*.sh"],
    "matchStrings": [
      "(?<depName>[a-z0-9.-]+(?:/[a-z0-9._-]+)+):(?<currentValue>[^@\\s]+)@(?<currentDigest>sha256:[a-f0-9]{64})\\s*# renovate: datasource=(?<datasource>docker)",
    ],
  },
]
EOF
)"

# I use this in Haskell packages to ensure CI actually uses the new verison.
default RENOVATE_COMMIT_BODY '{{#each upgrades}}New-{{{datasource}}}-version: {{{depName}}}{{#if newVersion}}=={{{newVersion}}}{{else if newDigest}}=={{{newDigest}}}{{/if}}\n{{/each}}'

default RENOVATE_PR_HOURLY_LIMIT 0

# Renovate's output in the container isn't a terminal, so it would otherwise
# turn colour off, but the GitHub Actions log viewer renders it fine.
if [[ -t 1 || -v GITHUB_ACTIONS ]]; then
  default FORCE_COLOR 3
fi

# Renovate exits nonzero when it logs errors, but not warnings, which we also
# want to fail on. This collects them separately from the human-readable log.
# The directory has to be writable by the container's (unprivileged) user.
log_dir=$(mktemp --directory --tmpdir renovate-log.XXXXXX)
trap 'rm -rf "$log_dir"' EXIT
chmod a+rwx "$log_dir"
export RENOVATE_LOG_FILE=/renovate-log/log.jsonl
export RENOVATE_LOG_FILE_LEVEL=warn

# Pass through the same variables that renovatebot/github-action does
# https://github.com/renovatebot/github-action/blob/1c0cf989c02653fba0efe7ca5772338860ca71dc/src/input.ts#L11-L12
# plus FORCE_COLOR, which it sets itself.
env_args=()
while read -r name; do
  env_args+=(--env "$name")
done < <(compgen -e | grep -E '^(RENOVATE_\w+|LOG_LEVEL|GITHUB_COM_TOKEN|NODE_OPTIONS|NO_COLOR|FORCE_COLOR|(HTTPS?|NO)_PROXY|(https?|no)_proxy)$')

docker run --rm \
  "${env_args[@]}" \
  --volume "$log_dir:/renovate-log" \
  "$renovate_image" \
  "$@"

if [ -s "$log_dir/log.jsonl" ]; then
  cat "$log_dir/log.jsonl"
  exit 1
fi
