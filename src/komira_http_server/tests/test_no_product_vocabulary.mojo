# =============================================================================
# test_no_product_vocabulary.mojo — the generic HTTP server names no product
# concept.
# =============================================================================
#
# This package is general-purpose and open source. Whatever identity, tenancy or
# authorization model an embedder has is the embedder's own middleware's
# business (see `middleware/middleware.mojo`: `Principal`, `Claims`,
# `RequestContext.attributes`). So no identifier, comment or docstring of the
# library may name one. The check reads every library source file (declared as
# test data in the BUCK file; the tests/ directory is not among them) and fails
# naming the file and line of each hit.
#
# Matching is case-insensitive substring, deliberately blunt: a false positive
# is a rename, a false negative is the product model creeping back in.
# =============================================================================

from std.os import listdir
from std.os.path import isdir
from std.testing import assert_equal, assert_true

comptime _ROOT = "src/komira_http_server"

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
        len(files) >= 10,
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
    assert_equal(len(hits), 0, "product vocabulary in the generic server:\n" + report)


def main() raises:
    test_library_names_no_product_vocabulary()
    print("PASS test_no_product_vocabulary")
