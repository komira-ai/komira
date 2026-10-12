# =============================================================================
# src/kci_release_set/glibc_floor.mojo -- the one `__glibc` requirement a
#   library shipping native files carries: `__glibc >=<floor>`, the floor
#   the platform table's `os_floor` names for the package's subdir.
# =============================================================================
#
# The packer (tools/build/package/pack/conda_lib.zig) writes
# `__glibc >=<floor>` into the run requirements of a library whose package
# ships native files (metadata.json `lib_files`), and only of such a
# library, the floor read from the platform table's `os_floor`
# (tools/build/platforms/table.bzl, `glibc-2.34`), the floor zig links
# against and the build's check 5 holds each shared library's GLIBC_
# symbol versions to (docs/design/native_packaging.md, "glibc floor").
#
# `glibc_requirement_refusals` is the rule kci holds a library to: when it
# ships native files it requires exactly `glibc_requirement(subdir)`, once;
# when it ships none it requires no `__glibc` at all. Any other value
# (`__glibc >=2.38`, `__glibc >=2.17`, `__glibc`, `__glibc 2.34`) is refused:
# a higher floor would refuse hosts the build supports, a lower one would
# install a `.so` on a host whose glibc lacks a symbol version it needs. One
# floor per subdir also makes the requirement equal on every package of a
# set.
#
# Why a copy and not data the release carries: as system_libs.mojo, the
# PUBLISH step reads only the release directory the build under check
# wrote, so a floor carried there would let a package choose its own.
# tests/test_glibc_floor.mojo holds `glibc_floors()` equal to the table, by
# reading `//tools/build/package:glibc_floor` (one `<subdir> <floor>` line
# per subdir the packer writes, from `os_floor_version`): changing the
# table's floor without this file fails kci_release_set's build.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

comptime GLIBC_PACKAGE: String = "__glibc"
"""The virtual package of the host's glibc version."""


@fieldwise_init
struct GlibcFloor(Copyable, Movable):
    """One subdir the packer writes and the glibc floor of its platform row."""

    var subdir: String
    var floor: String


def glibc_floors() -> List[GlibcFloor]:
    """THE copy of the platform table's glibc floors, one row per conda
    subdir the packer writes (file header)."""
    var out = List[GlibcFloor]()
    out.append(GlibcFloor(String("linux-64"), String("2.34")))
    return out^


def glibc_floor_of(subdir: String) -> String:
    """The glibc floor of `subdir`; EMPTY for a subdir with no row."""
    var rows = glibc_floors()
    for i in range(len(rows)):
        if rows[i].subdir == subdir:
            return rows[i].floor.copy()
    return String("")


def glibc_requirement(subdir: String) -> String:
    """`__glibc >=<floor>` for `subdir`; EMPTY for a subdir with no row."""
    var floor = glibc_floor_of(subdir)
    if floor.byte_length() == 0:
        return String("")
    return String(GLIBC_PACKAGE) + String(" >=") + floor


def is_glibc_requirement(requirement: String) -> Bool:
    """Whether `requirement` names `__glibc` (with or without a version)."""
    return requirement == GLIBC_PACKAGE or requirement.startswith(String(GLIBC_PACKAGE) + String(" "))


def glibc_requirement_refusals(depends: List[String], ships_native: Bool, subdir: String) -> List[String]:
    """Why `depends` breaks the floor rule (file header); EMPTY when it
    holds. `ships_native`: the package's metadata.json has `lib_files`."""
    var out = List[String]()
    var want = glibc_requirement(subdir)
    var seen = 0
    for i in range(len(depends)):
        ref d = depends[i]
        if not is_glibc_requirement(d):
            continue
        seen += 1
        if not ships_native:
            out.append(
                String("requires '") + d + String("', but ships no native file (no lib_files): only a package")
                + String(" shipping native files carries the glibc floor")
            )
        elif want.byte_length() == 0:
            out.append(String("requires '") + d + String("', and subdir '") + subdir + String("' has no glibc floor"))
        elif d != want:
            out.append(
                String("requires '") + d + String("', not the platform floor '") + want
                + String("' (tools/build/platforms/table.bzl os_floor)")
            )
    if ships_native and seen == 0:
        out.append(
            String("ships native files (lib_files) and does not require '")
            + (want if want.byte_length() > 0 else String(GLIBC_PACKAGE) + String(" >=<floor>"))
            + String("': its .so would install on a host whose glibc is older than the floor it was linked for")
        )
    if seen > 1 and ships_native:
        out.append(String("requires __glibc ") + String(seen) + String(" times; the floor is one requirement"))
    return out^
