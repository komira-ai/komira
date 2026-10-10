# =============================================================================
# test_no_product_vocabulary.mojo: the test issuer names no product concept
# and holds no early year-month (komira_test_vocabulary's words and date
# spellings).
# =============================================================================
#
# An issuer's account model is its operator's business, so no identifier,
# comment or docstring of this package may name one. The check reads every
# library source file (declared as test data in the BUCK file; the tests/
# directory is not among them) and fails naming the file and line of each
# hit.
# =============================================================================

from std.testing import assert_equal

from komira_test_vocabulary import scan_library


def test_library_names_no_product_vocabulary() raises:
    # All eight library files, so an empty staging cannot be a vacuous green.
    var report = scan_library(String("src/tests/helpers/komira_test_issuer"), 8)
    assert_equal(
        report,
        String(""),
        "product vocabulary or an early date in the test issuer:\n" + report,
    )


def main() raises:
    test_library_names_no_product_vocabulary()
    print("PASS komira_test_issuer test_no_product_vocabulary")
