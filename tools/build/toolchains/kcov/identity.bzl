"""What identifies the built kcov: the two constants the package guard refuses a file by.

kcov is GPL-2.0 and build-only (README.md, "Licences"). Every package format
runs the guard (tools/build/package/kcov_guard.bzl) over what it packs, and the
guard refuses a file whose sha256 is KCOV_BIN_SHA256 or whose bytes contain
KCOV_USAGE_LINE. The guard reads these constants, not a kcov target, so no
package build builds kcov or waits on it.

`:kcov_identity` gates `:kcov`: it fails when the built `bin/kcov` has
another sha256 or does not hold the line, and its message says which constant
to update. A change of a kcov pin, of kcov_build.sh or of the pinned zig that
changes kcov's bytes therefore fails the kcov build until KCOV_BIN_SHA256 is
updated here.

The constants live here, not in the platform table: the table holds the
sha256 of each download by role, with a schema its cases check, and this
sha256 is of a build output, which moves with kcov_build.sh and the compiler
as well as with the pins. This file loads nothing, so the package rules load
it without loading kcov's rules.
"""

# sha256 of `bin/kcov` of `:kcov_dist` (one build: it hard-codes the
# linux-x86_64 row, and `:kcov_reproducible` requires two builds to be the
# same bytes).
KCOV_BIN_SHA256 = "4468362dc51f234df19825338794cbb1d642182ccb1ec12a4a8dc8db81b897b7"

# kcov's usage line, the start of one string literal of its
# src/configuration.cc (the C++ compiler joins the adjacent literals), so the
# bytes are contiguous in `bin/kcov`. Not the version: kcov prints `kcov %s`
# with the string `v42` of version.c, and no `kcov v42` is in the binary. A
# file holds this line only if it is kcov, embeds it, or quotes its help text
# verbatim.
KCOV_USAGE_LINE = "Usage: kcov [OPTIONS] out-dir in-file [args...]"
