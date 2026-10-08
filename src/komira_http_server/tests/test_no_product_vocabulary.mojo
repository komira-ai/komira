# =============================================================================
# test_no_product_vocabulary.mojo — the generic HTTP server names no product
# concept and holds no early year-month (2024 or 2025 with any month, or 2026
# with month 01 to 08; earlier years are not matched).
# =============================================================================
#
# This package is general-purpose and open source. Whatever identity, tenancy or
# authorization model an embedder has is the embedder's own middleware's
# business (see `middleware/middleware.mojo`: `Principal`, `Claims`,
# `RequestContext.attributes`). So no identifier, comment or docstring of the
# library may name one. The check reads every library source file (declared as
# test data in the BUCK file; the tests/ directory is not among them) and fails
# naming the file and line of each hit. The words and date spellings are
# komira_test_vocabulary's.
# =============================================================================

from std.testing import assert_equal

from komira_test_vocabulary import scan_library


def test_library_names_no_product_vocabulary() raises:
    # At least 10 files, so an empty staging cannot be a vacuous green.
    var report = scan_library(String("src/komira_http_server"), 10)
    assert_equal(
        report,
        String(""),
        "product vocabulary or an early date in the generic server:\n" + report,
    )


def main() raises:
    test_library_names_no_product_vocabulary()
    print("PASS test_no_product_vocabulary")
