# =============================================================================
# komira_objectstore_gcs/tests/test_env_source_only.mojo
# =============================================================================
#
# Nothing in komira_objectstore_gcs reads the environment: the bucket, the
# service account and the clock are all parameters. Every library source of
# the package is staged as test data (src/komira_objectstore_gcs/*.mojo); the
# test reads each one and fails if any names getenv, setenv, `_read_env`,
# komira_core_ffi or an `external_call`. There is no exempt file. The scan is
# not vacuous: it must see the signer and every other source the package has.
# =============================================================================

from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "src/komira_objectstore_gcs"


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def test_scan() raises:
    var names = listdir(String(_DIR))
    var scanned = 0
    var saw_signer = False
    var banned: List[String] = [
        "getenv",
        "setenv",
        "_read_env",
        "komira_core_ffi",
        "external_call",
    ]
    for i in range(len(names)):
        var name = String(names[i])
        if not name.endswith(".mojo"):
            continue
        var text: String
        with open(String(_DIR) + "/" + name, "r") as f:
            text = f.read()
        scanned += 1
        if name == "signer.mojo":
            saw_signer = True
            assert_true(
                _count(text, "struct GcsV4Signer") == 1,
                "signer.mojo holds no GcsV4Signer?",
            )
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                name + " names " + banned[j] + "; komira_objectstore_gcs"
                " takes its configuration as parameters",
            )
    assert_true(saw_signer, "signer.mojo was not staged")
    assert_true(scanned >= 7, "only " + String(scanned) + " sources staged")


def main() raises:
    test_scan()
    print("OK")
