# =============================================================================
# test_no_product_vocabulary.mojo — the authorization interface names no
# product concept and holds no early year-month (2024 or 2025 with any month,
# or 2026 with month 01 to 08; earlier years are not matched).
# =============================================================================
#
# A host's identity, tenancy and permission model is the host's own conformer's
# business, so no identifier, comment or docstring of this package may name
# one. The check reads every library source file (declared as test data in the
# BUCK file; the tests/ directory is not among them) and fails naming the file
# and line of each hit. The words and date spellings are komira_test_vocabulary's.
# =============================================================================

from std.testing import assert_equal

from komira_test_vocabulary import scan_library


def test_library_names_no_product_vocabulary() raises:
    # Both library files, so an empty staging cannot be a vacuous green.
    var report = scan_library(String("src/komira_authz_api"), 2)
    assert_equal(
        report,
        String(""),
        "product vocabulary or an early date in the authorization interface:\n"
        + report,
    )


def main() raises:
    test_library_names_no_product_vocabulary()
    print("PASS komira_authz_api test_no_product_vocabulary")
