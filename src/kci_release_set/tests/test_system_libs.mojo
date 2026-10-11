# =============================================================================
# src/kci_release_set/tests/test_system_libs.mojo -- kci's copy of the
#   system-library table equals tools/build/package/system_libs.bzl's.
# =============================================================================
#
# Test data (BUCK): `system_libs.txt` (//tools/build/package:system_libs, the
# table as the build evaluates SYSTEM_LIBS: one `<soname> <requirement>` line
# per row, soname order).
#
# ROWS
#   (0) the drift check, both ways: the file is not empty; line i is exactly
#       row i of `system_libs()` (soname, one space, requirement); the two
#       have the same number of rows. A row added, removed or changed on
#       either side fails here, naming it;
#   (1) `is_system_lib_requirement` accepts every requirement of the file,
#       byte-equal, and nothing near one: another range, no range, a
#       channel prefix, another case, a second space, a trailing space, a
#       tab, a pattern, the soname itself, the empty string.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from kci_release_set import is_system_lib_requirement, system_libs


def _lines() raises -> List[String]:
    var out = List[String]()
    var parts = Path(String("system_libs.txt")).read_text().split(String("\n"))
    for i in range(len(parts)):
        var line = String(parts[i])
        if line.byte_length() > 0:
            out.append(line^)
    return out^


def test_the_copy_equals_the_build_table() raises:
    var lines = _lines()
    var rows = system_libs()
    assert_true(len(lines) > 0, "system_libs.txt names no row: the drift check would be vacuous")
    for i in range(len(lines)):
        assert_true(
            i < len(rows),
            String("system_libs.bzl row '") + lines[i]
            + String("' is not in src/kci_release_set/system_libs.mojo"),
        )
        assert_equal(
            rows[i].soname + String(" ") + rows[i].requirement,
            lines[i],
            String("src/kci_release_set/system_libs.mojo row ") + String(i)
            + String(" differs from tools/build/package/system_libs.bzl"),
        )
    for i in range(len(lines), len(rows)):
        assert_true(
            False,
            String("src/kci_release_set/system_libs.mojo row '") + rows[i].soname + String(" ")
            + rows[i].requirement + String("' is not in tools/build/package/system_libs.bzl"),
        )
    assert_equal(len(rows), len(lines))
    print("  test_the_copy_equals_the_build_table: PASS")


def test_only_a_requirement_of_the_table_byte_for_byte() raises:
    var lines = _lines()
    for i in range(len(lines)):
        var sp = lines[i].find(String(" "))
        assert_true(sp > 0, lines[i])
        var req = String(lines[i][byte = sp + 1 :])
        assert_true(is_system_lib_requirement(req), req)
    assert_true(is_system_lib_requirement(String("zstd >=1.5.2,<2")))
    for bad in [
        String("zstd >=1.0"),
        String("zstd"),
        String("conda-forge::zstd >=1.5.2,<2"),
        String("ZSTD >=1.5.2,<2"),
        String("zstd  >=1.5.2,<2"),
        String("zstd >=1.5.2,<2 "),
        String(" zstd >=1.5.2,<2"),
        String("zstd\t>=1.5.2,<2"),
        String("zst* >=1.5.2,<2"),
        String("libzstd.so.1"),
        String("notalib >=1"),
        String(""),
    ]:
        assert_false(is_system_lib_requirement(bad), String("accepted '") + bad + String("'"))
    print("  test_only_a_requirement_of_the_table_byte_for_byte: PASS")


def main() raises:
    test_the_copy_equals_the_build_table()
    test_only_a_requirement_of_the_table_byte_for_byte()
    print("test_system_libs: ALL PASS")
