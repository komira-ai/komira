# =============================================================================
# src/kci_release_set/system_libs.mojo -- the conda-forge requirements a
#   LIBRARY's package may carry for a system library it opens at run time.
# =============================================================================
#
# A library that opens a system codec at run time (`OwnedDLHandle(
# "libzstd.so.1")`) needs the conda-forge package that ships the soname;
# tools/build/package/system_libs.bzl names it for each soname
# (`zstd >=1.5.2,<2`). Both closure checks accept such a requirement of a
# LIBRARY (never of the metapackage) only when it is BYTE-EQUAL to the
# requirement of one row of `system_libs()`: another version range, another
# package, no range, a `<channel>::` prefix, another case, a pattern, a tab
# or a second space are each another string, so each is refused.
#
# Why a copy and not data the release carries: the PUBLISH step reads only
# the release directory, which the build under check wrote; a list carried
# there would let a package widen its own allowance. Compiled into kci, the
# list is fixed by kci's source. tests/test_system_libs.mojo holds it equal
# to the table, both ways, by reading `//tools/build/package:system_libs`
# (the table as the build evaluates it, one `<soname> <requirement>` line
# per row), so the two cannot drift: changing system_libs.bzl without this
# file fails kci_release_set's build.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================


@fieldwise_init
struct SystemLib(Copyable, Movable):
    """One row of tools/build/package/system_libs.bzl: a soname and the
    conda-forge requirement of the package that ships it."""

    var soname: String
    var requirement: String


def system_libs() -> List[SystemLib]:
    """THE copy of tools/build/package/system_libs.bzl's `SYSTEM_LIBS`, in
    soname order (file header)."""
    var out = List[SystemLib]()
    out.append(SystemLib(String("libbz2.so.1.0"), String("bzip2 >=1.0.8,<2")))
    out.append(SystemLib(String("liblz4.so.1"), String("lz4-c >=1.9.3,<2")))
    out.append(SystemLib(String("liblzma.so.5"), String("xz >=5.2.5,<6")))
    out.append(SystemLib(String("libz.so.1"), String("libzlib >=1.2.13,<2")))
    out.append(SystemLib(String("libzstd.so.1"), String("zstd >=1.5.2,<2")))
    return out^


def is_system_lib_requirement(requirement: String) -> Bool:
    """Whether `requirement` is byte-equal to the requirement of a row of
    `system_libs()` (file header)."""
    var rows = system_libs()
    for i in range(len(rows)):
        if rows[i].requirement == requirement:
            return True
    return False
