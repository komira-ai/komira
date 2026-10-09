# =============================================================================
# test_no_product_vocabulary.mojo — the gate's sources name no product concept
# and hold no early year-month (komira_test_vocabulary says which words and
# date spellings).
# =============================================================================
#
# The check reads every library source file (declared as test data in the
# BUCK file; tests/ is not among them) and fails naming the file and line of
# each hit.
# =============================================================================

from std.testing import assert_equal

from komira_test_vocabulary import scan_library


def test_library_names_no_product_vocabulary() raises:
    # All four library files, so an empty staging cannot be a vacuous green.
    var report = scan_library(String("src/komira_resource_gate"), 4)
    assert_equal(
        report,
        String(""),
        "product vocabulary or an early date in the resource gate:\n" + report,
    )


def main() raises:
    test_library_names_no_product_vocabulary()
    print("PASS komira_resource_gate test_no_product_vocabulary")
