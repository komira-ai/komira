# =============================================================================
# src/kci_release_set/tests/test_glibc_floor.mojo -- kci's copy of the glibc
#   floor equals the platform table's, and the one `__glibc` requirement kci
#   accepts.
# =============================================================================
#
# Test data (BUCK): `glibc_floor.txt` (//tools/build/package:glibc_floor, the
# platform table as the build evaluates it: one `<subdir> <floor>` line per
# subdir the packer writes).
#
# ROWS
#   (0) the drift check, both ways: line i is exactly row i of
#       `glibc_floors()`; the same number of rows. A floor changed in
#       tools/build/platforms/table.bzl without glibc_floor.mojo fails here;
#   (1) a library shipping native files requiring exactly
#       `__glibc >=2.34` once is accepted (what #1363's packer writes);
#   (2) refused, each by its message: `__glibc >=2.38` (a higher floor),
#       `__glibc >=2.17`, a bare `__glibc`, `__glibc 2.34`, the floor given
#       twice, no floor on a library with lib_files, a floor on a library
#       with none, a subdir with no floor row;
#   (3) a package with no native file and no `__glibc` passes, and another
#       virtual package (`__linux`) is not a glibc requirement.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_set import (
    glibc_floor_of,
    glibc_floors,
    glibc_requirement,
    glibc_requirement_refusals,
    is_glibc_requirement,
)


def _lines() raises -> List[String]:
    var out = List[String]()
    var parts = Path(String("glibc_floor.txt")).read_text().split(String("\n"))
    for i in range(len(parts)):
        var line = String(parts[i])
        if line.byte_length() > 0:
            out.append(line^)
    return out^


def _deps(a: String, b: String = String(""), c: String = String("")) -> List[String]:
    var out = List[String]()
    out.append(String("__linux"))
    if a.byte_length() > 0:
        out.append(a.copy())
    if b.byte_length() > 0:
        out.append(b.copy())
    if c.byte_length() > 0:
        out.append(c.copy())
    out.append(String("mojo-compiler ==1.0.0"))
    return out^


def _one(deps: List[String], native: Bool, subdir: String = String("linux-64")) raises -> String:
    var r = glibc_requirement_refusals(deps, native, subdir)
    assert_equal(len(r), 1, String("refusals: ") + String(" | ").join(r))
    return r[0].copy()


def test_the_copy_equals_the_platform_table() raises:
    var lines = _lines()
    var rows = glibc_floors()
    assert_true(len(lines) > 0, "glibc_floor.txt names no row: the drift check would be vacuous")
    assert_equal(len(rows), len(lines), "src/kci_release_set/glibc_floor.mojo and the platform table differ in rows")
    for i in range(len(lines)):
        assert_equal(
            rows[i].subdir + String(" ") + rows[i].floor,
            lines[i],
            String("src/kci_release_set/glibc_floor.mojo row ") + String(i)
            + String(" differs from tools/build/platforms/table.bzl os_floor"),
        )
    assert_equal(glibc_requirement(String("linux-64")), String("__glibc >=2.34"))
    assert_equal(glibc_floor_of(String("osx-arm64")), String(""))
    assert_equal(glibc_requirement(String("osx-arm64")), String(""))


def test_the_floor_is_accepted_on_a_library_with_native_files() raises:
    var r = glibc_requirement_refusals(_deps(String("__glibc >=2.34")), True, String("linux-64"))
    assert_equal(len(r), 0, String(" | ").join(r))


def test_no_floor_and_no_native_files_is_accepted() raises:
    var r = glibc_requirement_refusals(_deps(String("")), False, String("linux-64"))
    assert_equal(len(r), 0, String(" | ").join(r))
    assert_false(is_glibc_requirement(String("__linux")))
    assert_false(is_glibc_requirement(String("__glibcx >=2.34")))
    assert_true(is_glibc_requirement(String("__glibc")))
    assert_true(is_glibc_requirement(String("__glibc >=2.38")))


def test_another_floor_is_refused() raises:
    assert_equal(
        _one(_deps(String("__glibc >=2.38")), True),
        String("requires '__glibc >=2.38', not the platform floor '__glibc >=2.34' (tools/build/platforms/table.bzl os_floor)"),
    )
    assert_equal(
        _one(_deps(String("__glibc >=2.17")), True),
        String("requires '__glibc >=2.17', not the platform floor '__glibc >=2.34' (tools/build/platforms/table.bzl os_floor)"),
    )
    assert_equal(
        _one(_deps(String("__glibc")), True),
        String("requires '__glibc', not the platform floor '__glibc >=2.34' (tools/build/platforms/table.bzl os_floor)"),
    )
    assert_equal(
        _one(_deps(String("__glibc 2.34")), True),
        String("requires '__glibc 2.34', not the platform floor '__glibc >=2.34' (tools/build/platforms/table.bzl os_floor)"),
    )


def test_the_floor_twice_is_refused() raises:
    assert_equal(
        _one(_deps(String("__glibc >=2.34"), String("__glibc >=2.34")), True),
        String("requires __glibc 2 times; the floor is one requirement"),
    )


def test_a_library_with_native_files_and_no_floor_is_refused() raises:
    assert_equal(
        _one(_deps(String("")), True),
        String(
            "ships native files (lib_files) and does not require '__glibc >=2.34': its .so would install on a"
            " host whose glibc is older than the floor it was linked for"
        ),
    )


def test_a_floor_without_native_files_is_refused() raises:
    assert_equal(
        _one(_deps(String("__glibc >=2.34")), False),
        String(
            "requires '__glibc >=2.34', but ships no native file (no lib_files): only a package shipping native"
            " files carries the glibc floor"
        ),
    )


def test_a_subdir_with_no_floor_is_refused() raises:
    var r = glibc_requirement_refusals(_deps(String("__glibc >=2.34")), True, String("osx-arm64"))
    assert_equal(len(r), 1, String(" | ").join(r))
    assert_equal(r[0], String("requires '__glibc >=2.34', and subdir 'osx-arm64' has no glibc floor"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
