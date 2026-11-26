"""The two Mojo compilers the tree builds with, and the one setting that chooses between them.

The platform table pins two compilers on every row: `mojo_compiler` (the default) and
`mojo_compiler_next` (tools/build/platforms/table.bzl). A target platform carrying buildrules'
constraint value for the second one's version (`buildrules//platforms:mojo_1_2_0`) builds
everything with it: komira's own Mojo rules through `toolchains//:mojo` (defs.bzl,
darwin/BUCK), and every `mojo_package` through buildrules' own select on the same constraint
(rules/mojo/versions.bzl of buildrules). A platform without it builds with the default. The
platforms are `<row>-mojo-<version>` in tools/build/platforms/BUCK.

The versions are read from the pins' asset names (`mojo_compiler_<version>_<subdir>.conda`), so the
table stays the one place a compiler version is written.
"""

load("@buildrules//rules/mojo:version_names.bzl", "mojo_setting")
load("@komira//tools/build/platforms:table.bzl", "asset")

def _version(role):
    return asset("linux-x86_64", role)["name"].split("_")[2]

# The default compiler's version, and the second one's.
MOJO_DEFAULT = _version("mojo_compiler")
MOJO_NEXT = _version("mojo_compiler_next")

# The buildrules constraint value a target platform carries to build with MOJO_NEXT.
MOJO_NEXT_CONSTRAINT = "buildrules//platforms:mojo_" + MOJO_NEXT.replace(".", "_")

def by_mojo(default, next):
    """`default` on a platform without MOJO_NEXT_CONSTRAINT, `next` on one with it."""
    return select({
        mojo_setting(MOJO_NEXT): next,
        "DEFAULT": default,
    })

def mojo_version():
    """The version of the compiler the target platform builds with: what a `mojo_conda` packs for."""
    return by_mojo(MOJO_DEFAULT, MOJO_NEXT)
