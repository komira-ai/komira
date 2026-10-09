# =============================================================================
# test_no_product_vocabulary.mojo: the package names no product concept and
# holds no early year-month (2024 or 2025 with any month, or 2026 with month
# 01 to 08; earlier years are not matched).
# =============================================================================
#
# komira_http_auth is a generic, open-source bearer-JWT layer. It reads every
# library source file (declared as test data in the BUCK file; tests/ is not
# among them) and fails naming the file and line of each hit. The words and
# date spellings are komira_test_vocabulary's.
# =============================================================================

from std.testing import assert_equal

from komira_test_vocabulary import scan_library


def test_library_names_no_product_vocabulary() raises:
    # At least 10 files, so an empty staging cannot be a vacuous green.
    var report = scan_library(String("src/komira_http_auth"), 10)
    assert_equal(
        report,
        String(""),
        "product vocabulary or an early date in komira_http_auth:\n" + report,
    )


def main() raises:
    test_library_names_no_product_vocabulary()
    print("PASS test_no_product_vocabulary")
