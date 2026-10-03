#!/bin/sh
# release_version.sh -- the version, build number and build string a release of
# the conda packages carries.
#
# usage: tools/build/package/release_version.sh [<release commit>]   (default HEAD)
#
# Prints five lines:
#
#   version=<compiler version>
#   build_number=<N>
#   build=h<first 8 hex of C>_<N>
#   commit=<C>
#   buck_args=-c komira.package_stamp=<N> -c komira.package_commit=<C> -c komira.package_timestamp_ms=<ms>
#
# The VERSION of every package is the version of the Mojo compiler the
# repository pins (a compiler bump re-versions and rebuilds every
# package). It is read from the platform table's pin of the linux-64 compiler
# (tools/build/platforms/table.bzl) AT C, the one place it is stated; the pin
# names it in its asset name and in its URL, and a pin whose two disagree is
# refused. The release iteration is the conda BUILD NUMBER N, and the build
# string names N and the commit: `h<8 hex>_<N>`.
#
# N is `git rev-list --count --first-parent C`, where C is the newest
# first-parent commit at or below the release commit that touches anything but
# documentation (docs/, any *.md, .github/). A change to the published closure
# therefore always raises N, and a documentation-only commit never does, so two
# releases of the same bytes carry the same build number and string. The
# pathspec is "everything but documentation" on purpose: counting too much only
# skips a number, while counting too little would give different bytes the same
# name, version and build, which the registry refuses. The timestamp is C's
# commit time in milliseconds, so the packages' bytes depend on git and nothing
# else. C itself goes into every package's manifest metadata (`source_commit`),
# so a stamp is tied to a commit: the publish job runs this at a clean
# full-history checkout of main and compares its version=, build= and commit=
# with the packages' `version`, `build` and `source_commit` before any upload,
# and refuses a difference. The packages' own release check only proves a stamp
# is positive, carries a full commit id, a build string that names it, and a
# positive commit time; it cannot read git, and a stamp typed by hand passes it.
#
# It needs a full history: in a shallow clone N would be wrong, so it refuses.
# Run it where git is (a release job), never inside a build action: the build
# receives its output through `buck2 build -c ...` and reads no git.
set -eu

root=$(cd "$(dirname "$0")/../../.." && pwd)
rev=${1:-HEAD}
git() { command git -C "$root" "$@"; }

[ "$(git rev-parse --is-shallow-repository)" = false ] ||
    { echo "release_version.sh: shallow clone: the commit count would be wrong; fetch the full history" >&2; exit 1; }
commit=$(git rev-parse --verify --quiet "$rev^{commit}") ||
    { echo "release_version.sh: $rev is not a commit" >&2; exit 1; }
closure=$(git log -1 --first-parent --format=%H "$commit" -- . ':(exclude)docs' ':(exclude)*.md' ':(exclude).github')
[ -n "$closure" ] || { echo "release_version.sh: no commit touches the published closure" >&2; exit 1; }
table=$(git show "$closure:tools/build/platforms/table.bzl") ||
    { echo "release_version.sh: $closure has no tools/build/platforms/table.bzl" >&2; exit 1; }
by_name=$(printf '%s\n' "$table" | sed -n 's/.*"mojo_compiler_\(.*\)_linux-64\.conda".*/\1/p')
by_url=$(printf '%s\n' "$table" | sed -n 's#.*/linux-64/mojo-compiler-\(.*\)-release\.conda".*#\1#p')
case "$by_name" in
    [0-9]*) ;;
    *) echo "release_version.sh: cannot read the pinned compiler version from the linux-64 row of table.bzl at $closure" >&2; exit 1 ;;
esac
[ "$(printf '%s\n' "$by_name" | wc -l)" = 1 ] && [ "$by_name" = "$by_url" ] ||
    { echo "release_version.sh: the pinned compiler disagrees with itself at $closure: asset name says '$by_name', URL says '$by_url'" >&2; exit 1; }
n=$(git rev-list --count --first-parent "$closure")
ts=$(git log -1 --format=%ct "$closure")
echo "version=$by_name"
echo "build_number=$n"
echo "build=h$(printf %s "$closure" | cut -c1-8)_$n"
echo "commit=$closure"
echo "buck_args=-c komira.package_stamp=$n -c komira.package_commit=$closure -c komira.package_timestamp_ms=${ts}000"
