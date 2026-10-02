#!/bin/sh
# list_conda_targets.sh -- the conda package targets of the repository, one per line.
#
# usage: tools/build/package/list_conda_targets.sh [<target pattern>]   (default //src/...)
#        (BUCK2 overrides the buck2 binary)
#
# Every mojo_library declares a package target `<name>_conda`, unless it opted
# out with `conda = False`. This prints them: a development helper, so that a
# person or the release tool can enumerate what could be declared. It is NOT the
# list of what is published: that is the release tool's reviewed list of artifact
# declarations, and a target printed here is published only if one names it.
# A library that cannot be packaged is still printed (its target builds, as a
# refusal; see tools/build/package/conda.bzl).
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
buck2=${BUCK2:-$root/buck2}
pattern=${1:-//src/...}
cd "$root"
exec "$buck2" uquery "kind(conda_package, $pattern)"
