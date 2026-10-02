#!/bin/sh
# release_version.sh -- the version a release of the conda packages carries.
#
# usage: tools/build/package/release_version.sh [<release commit>]   (default HEAD)
#
# Prints three lines:
#
#   version=<prefix>.<N>
#   commit=<C>
#   buck_args=-c komira.package_stamp=<N> -c komira.package_commit=<C> -c komira.package_timestamp_ms=<ms>
#
# <prefix> is the one line of packaging/conda/VERSION_PREFIX at the release
# commit. N is `git rev-list --count --first-parent C`, where C is the newest
# first-parent commit at or below the release commit that touches anything but
# documentation (docs/, any *.md, .github/). A change to the published closure
# therefore always raises N, and a documentation-only commit never does, so two
# releases of the same bytes carry the same version. The pathspec is "everything
# but documentation" on purpose: counting too much only skips a number, while
# counting too little would give different bytes the same version, which the
# registry refuses. The timestamp is C's commit time in milliseconds, so
# the packages' bytes depend on git and nothing else. C itself goes into every
# package's manifest (`source_commit`), so a stamp is tied to a commit: the
# publish job runs this at a clean full-history checkout of main and compares
# its version= and commit= with the manifest's `version` and `source_commit`
# before any upload, and refuses a difference. The packages' own release check
# only proves a stamp is positive, carries a full commit id, and a positive
# commit time; it cannot read git, and a stamp typed by hand passes it.
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
prefix=$(git show "$commit:packaging/conda/VERSION_PREFIX" | tr -d ' \t\r\n') ||
    { echo "release_version.sh: $commit has no packaging/conda/VERSION_PREFIX" >&2; exit 1; }
case "$prefix" in
    [0-9]*.[0-9]*) ;;
    *) echo "release_version.sh: VERSION_PREFIX '$prefix' is not MAJOR.MINOR" >&2; exit 1 ;;
esac
closure=$(git log -1 --first-parent --format=%H "$commit" -- . ':(exclude)docs' ':(exclude)*.md' ':(exclude).github')
[ -n "$closure" ] || { echo "release_version.sh: no commit touches the published closure" >&2; exit 1; }
n=$(git rev-list --count --first-parent "$closure")
ts=$(git log -1 --format=%ct "$closure")
echo "version=$prefix.$n"
echo "commit=$closure"
echo "buck_args=-c komira.package_stamp=$n -c komira.package_commit=$closure -c komira.package_timestamp_ms=${ts}000"
