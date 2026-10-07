# =============================================================================
# test_no_product_vocabulary.mojo: the JWK library names no product concept and
# carries no date before the open-source cut.
# =============================================================================
#
# This package is general-purpose and open source: the authorization model of
# whoever mints tokens is the minter's business. So no identifier, comment or
# docstring of the library may name one, and no line may carry a date in the
# first eight months of the year the repository opened (an internal timeline
# has no place in it). The check reads every library source file (declared as
# test data in the BUCK file; the tests/ directory is not among them) and
# fails naming the file and line of each hit.
#
# Matching is case-insensitive substring, deliberately blunt: a false positive
# is a rename, a false negative is the product model creeping back in. The word
# list is the one `komira_http_server`'s test of the same name uses.
# =============================================================================

from std.os import listdir
from std.os.path import isdir
from std.testing import assert_equal, assert_true

comptime _ROOT = "src/komira_jwks"


# Spelled in parts so that no line of this file contains a banned word whole:
# a search of the repository for one of them then finds only real uses.
def _banned() -> List[String]:
    var out = List[String]()
    out.append(String("org") + "_id")
    out.append(String("workspace") + "_id")
    out.append(String("app") + "_id")
    out.append(String("env") + "_id")
    out.append(String("gra") + "nt")
    out.append(String("ten") + "ant")
    out.append(String("cust") + "omer")
    out.append(String("job") + " manager")
    # Year, separator, month 01 to 08, in the spellings dates take.
    var seps = List[String]()
    seps.append("-")
    seps.append("_")
    seps.append("/")
    seps.append(".")
    for s in range(len(seps)):
        for m in range(1, 9):
            out.append(String("20") + "26" + seps[s] + "0" + String(m))
    return out^


def _collect(dir: String, mut files: List[String]) raises:
    for name in listdir(dir):
        var path = dir + "/" + String(name)
        if isdir(path):
            _collect(path, files)
        elif path.endswith(".mojo"):
            files.append(path)


def _scan(path: String, banned: List[String], mut hits: List[String]) raises:
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var low = String(lines[i]).lower()
        for j in range(len(banned)):
            if banned[j] in low:
                hits.append(path + ":" + String(i + 1) + ": " + banned[j])


def test_library_names_no_product_vocabulary() raises:
    var files = List[String]()
    _collect(String(_ROOT), files)
    # Refuse to pass over nothing: an empty staging would be a vacuous green.
    assert_true(
        len(files) >= 5,
        "expected the library sources staged as test data, found "
        + String(len(files)),
    )
    var banned = _banned()
    var hits = List[String]()
    for i in range(len(files)):
        _scan(files[i], banned, hits)
    var report = String("")
    for i in range(len(hits)):
        report += hits[i] + "\n"
    assert_equal(len(hits), 0, "product vocabulary or dates in komira_jwks:\n" + report)


def main() raises:
    test_library_names_no_product_vocabulary()
