# =============================================================================
# komira_gcp_core/tests/test_env_source_only.mojo
# =============================================================================
#
# komira_gcp_core may read the environment only where Google's own auth chain
# does (GOOGLE_APPLICATION_CREDENTIALS, metadata-server detection), and only
# in a file named in _allowed() below with its reason. Every library source of
# the package is staged as test data (src/komira_gcp_core/*.mojo); the test
# reads each one and fails if a file not in _allowed() names getenv, setenv,
# `_read_env`, komira_core_ffi or an `external_call`.
#
# Today _allowed() is empty: the package holds no credential-chain code yet, so
# every source takes its configuration as parameters. When a chain source
# lands, add it to _allowed() by file name with a one-line reason. An allowed
# entry must exist and must actually read the environment, so a stale entry
# fails too. The scan is not vacuous: it must see the token contract, the V4
# signer and every other source the package has.
# =============================================================================

from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "src/komira_gcp_core"


# (file name, reason). A file here may read the environment; no other may.
def _allowed() -> List[Tuple[String, String]]:
    return []


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def test_scan() raises:
    var allowed = _allowed()
    var allowed_seen = List[Bool]()
    for _ in range(len(allowed)):
        allowed_seen.append(False)
    var names = listdir(String(_DIR))
    var scanned = 0
    var saw_token = False
    var saw_v4 = False
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
        if name == "token.mojo":
            saw_token = True
            assert_true(
                _count(text, "trait GcpTokenSource") == 1,
                "token.mojo holds no GcpTokenSource?",
            )
        if name == "v4_sign.mojo":
            saw_v4 = True
            assert_true(
                _count(text, "struct GcsV4CanonicalRequest") == 1,
                "v4_sign.mojo holds no GcsV4CanonicalRequest?",
            )
        var hits = 0
        for j in range(len(banned)):
            hits += _count(text, banned[j])
        var exempt = False
        for k in range(len(allowed)):
            if allowed[k][0] == name:
                exempt = True
                allowed_seen[k] = True
                assert_true(
                    hits > 0,
                    name + " is allowed to read the environment but does"
                    " not; drop it from _allowed()",
                )
        if exempt:
            continue
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                name + " names " + banned[j] + "; komira_gcp_core reads the"
                " environment only in Google auth-chain files named in"
                " _allowed()",
            )
    for k in range(len(allowed)):
        assert_true(
            allowed_seen[k],
            allowed[k][0] + " is in _allowed() but was not staged",
        )
    assert_true(saw_token, "token.mojo was not staged")
    assert_true(saw_v4, "v4_sign.mojo was not staged")
    assert_true(scanned >= 7, "only " + String(scanned) + " sources staged")


def main() raises:
    test_scan()
    print("OK")
