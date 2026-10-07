#!/bin/sh
# list_conda_targets.sh -- the conda package targets of the repository, one per line.
#
# usage: tools/build/package/list_conda_targets.sh [<target pattern>...]   (default //src/...)
#        (BUCK2 overrides the buck2 binary)
#
# Every mojo_library declares a package target `<name>_conda`, unless it opted
# out with `conda = False`. This prints them: a development helper, so that a
# person or the release tool can enumerate what could be declared. It is NOT the
# list of what is published: that is the release tool's reviewed list of artifact
# declarations, and a target printed here is published only if one names it.
# A library that cannot be packaged is still printed (its target builds, as a
# refusal; see tools/build/package/conda.bzl). The native package
# (//tools/build/native:komira_native_conda, libkomira_native.so.1) is printed
# when the patterns cover it.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
buck2=${BUCK2:-$root/buck2}
[ "$#" -gt 0 ] || set -- //src/...
set_expr=$1
shift
for p in "$@"; do set_expr="$set_expr + $p"; done
cd "$root"
exec "$buck2" uquery "kind('conda_package|conda_native_package', $set_expr)"
