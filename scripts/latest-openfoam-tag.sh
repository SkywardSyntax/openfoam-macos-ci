#!/bin/bash
set -euo pipefail
# Print the newest OpenFOAM release published upstream, as the value
# build.yml wants for its `openfoam_version` input (e.g. "v2606").
#
# Upstream tags the release watcher cares about:
#   OpenFOAM-v2606          main release (two per year: vYYMM, 06 and 12)
#   OpenFOAM-v1912.200312   patch release on top of one
# Anything else in the tag history is ignored — there are stray forms
# (OpenFOAM-v2012_210414) and dev branches that are not releases.
#
# Exits non-zero if nothing matches, so a bad fetch can never be mistaken
# for "no new release".

REPO_URL="${OPENFOAM_GIT_URL:-https://gitlab.com/openfoam/core/openfoam.git}"

git ls-remote --tags --refs "$REPO_URL" \
  | awk '{print $2}' \
  | sed 's#^refs/tags/##' \
  | grep -E '^OpenFOAM-v[0-9]{4}(\.[0-9]+)?$' \
  | sed 's/^OpenFOAM-//' \
  | sort -V \
  | tail -1
