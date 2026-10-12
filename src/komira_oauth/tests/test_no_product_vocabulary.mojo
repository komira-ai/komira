# =============================================================================
# test_no_product_vocabulary.mojo — komira_oauth names no product concept and
# holds no early year-month (2024 or 2025 with any month, or 2026 with month
# 01 to 08; earlier years are not matched).
# =============================================================================
#
# The package is a generic OAuth client: which issuer it talks to and what a
# token means are the deployment's business, so no identifier, comment or
# docstring of this package may name one. The check reads every library
# source file (declared as test data in the BUCK file; the tests/ directory is
# not among them) and fails naming the file and line of each hit. The words
# and date spellings are komira_test_vocabulary's, with one word taken out:
# the OAuth term for what a client asks a token endpoint for (RFC 6749
# section 1.3, the `client_credentials` one and the `grant_type` parameter
# that names it) is this package's subject, not a product concept. The test
# checks that exactly that one word is taken out, so a word added to the
# shared list still applies here.
# =============================================================================

from std.os import listdir
from std.testing import assert_equal

from komira_test_vocabulary import banned_words, scan_text


comptime ROOT = "src/komira_oauth"
# Every library file, so an empty staging cannot be a vacuous green.
comptime LIBRARY_FILES = 7


def _oauth_term() -> String:
    # Built from parts, as komira_test_vocabulary builds its words.
    return String("gra") + "nt"


def test_library_names_no_product_vocabulary() raises:
    var all_words = banned_words()
    var banned = List[String]()
    for i in range(len(all_words)):
        if all_words[i] != _oauth_term():
            banned.append(all_words[i])
    assert_equal(len(banned), len(all_words) - 1, "the one OAuth term is taken out")
    var files = List[String]()
    for name in listdir(ROOT):
        var n = String(name)
        if n.endswith(".mojo"):
            files.append(String(ROOT) + "/" + n)
    assert_equal(len(files), LIBRARY_FILES, "library sources staged")
    var hits = List[String]()
    for i in range(len(files)):
        var text: String
        with open(files[i], "r") as f:
            text = f.read()
        scan_text(files[i], text, banned, hits)
    var report = String("")
    for i in range(len(hits)):
        report += hits[i] + "\n"
    assert_equal(
        report,
        String(""),
        "product vocabulary or an early date in komira_oauth:\n" + report,
    )


def main() raises:
    test_library_names_no_product_vocabulary()
    print("PASS komira_oauth test_no_product_vocabulary")
