# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_non_ascii_names.mojo — a byte at or
#   above 0x80 in a distribution name is neither rewritten nor sent.
# =============================================================================
#
#   * `normalize_distribution_name` keeps every byte of a non-ASCII name
#     exactly (it only lowercases A-Z and collapses `-` `_` `.` runs);
#   * `pypi_json_api_path` refuses a distribution that is not letters, digits,
#     `.`, `-` or `_` (the packaging spec's name alphabet), and an empty one,
#     before any request is built; a valid name still yields the path.
#
# Hermetic: no file, no network.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    normalize_distribution_name,
)
from kci_pkg_upload.pypi_registry import pypi_json_api_path


def _coord(distribution: String) -> PackageCoordinate:
    return PackageCoordinate(
        SUBSTRATE_PUBLIC_PYPI,
        String("pypi.org"),
        distribution.copy(),
        String("1.0"),
        String("linux-64"),
        String("x.whl"),
    )


def test_normalize_keeps_non_ascii_bytes() raises:
    var got = normalize_distribution_name(String("Café_Lib"))
    var want = String("café-lib")
    assert_equal(got.byte_length(), want.byte_length())
    assert_equal(got, want)


def test_normalize_still_lowercases_and_collapses() raises:
    assert_equal(
        normalize_distribution_name(String("Kci.Pkg__Upload")),
        String("kci-pkg-upload"),
    )


def test_json_path_refuses_a_non_ascii_name() raises:
    with assert_raises(contains="distribution"):
        _ = pypi_json_api_path(_coord(String("café")))


def test_json_path_refuses_other_bytes_and_empty() raises:
    with assert_raises(contains="distribution"):
        _ = pypi_json_api_path(_coord(String("a/b")))
    with assert_raises(contains="distribution"):
        _ = pypi_json_api_path(_coord(String("a b")))
    with assert_raises(contains="distribution"):
        _ = pypi_json_api_path(_coord(String("")))


def test_json_path_for_a_valid_name() raises:
    assert_equal(
        pypi_json_api_path(_coord(String("Kci_Pkg.Upload"))),
        String("/pypi/kci-pkg-upload/1.0/json"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
