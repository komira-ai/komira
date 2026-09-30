#!/bin/sh
# merge_from_live.sh -- open a pull request bumping every pin to its live
# release. NOT IMPLEMENTED: this stub says what it will do and exits 1, so a
# run of .github/workflows/merge_from_live.yml fails visibly.
#
# The design:
#   1. For each pin -- tools/buck2 (both platforms), the pinned_file
#      downloads in tools/build/**/BUCK (zig, the Mojo compiler, the conda
#      runtime libraries, busybox, shellcheck, actionlint), third_party's
#      source archives, and the submodule this repository mounts -- ask its
#      source for the newest release. A small Mojo tool reads and rewrites
#      the pins (url, size, sha256); this script only drives it and git.
#   2. Download each new artifact once and write its size and sha256.
#   3. Commit on a branch and open one pull request with the GITHUB_TOKEN
#      (contents: write, pull-requests: write on the job).
#   4. The pull request's own ci run is the gate: it merges only if green.
echo "merge_from_live.sh: not implemented yet; see the design in $0" >&2
exit 1
