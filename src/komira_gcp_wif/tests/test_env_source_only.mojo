# =============================================================================
# komira_gcp_wif/tests/test_env_source_only.mojo
# =============================================================================
#
# komira_gcp_wif reads no environment: the AWS credential comes through a
# komira_aws_core `AwsCredsSource` (whose default chain reads the AWS SDK's
# standard variables in komira_aws_core, not here), and every other input is
# a parameter. Every library source of the package is staged as test data
# (src/komira_gcp_wif/*.mojo); the test fails if one names getenv, setenv,
# `_read_env`, komira_libc, an `external_call`, or a compile-time define
# read (`env_get_*`, `is_defined`). The library's sources are the same
# top-level glob (BUCK), so no module can compile in without being scanned.
#
# The scan is not vacuous: it must see each of the package's modules.
# =============================================================================

from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "src/komira_gcp_wif"


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def test_scan() raises:
    var names = listdir(String(_DIR))
    var banned: List[String] = [
        "getenv",
        "setenv",
        "_read_env",
        "komira_libc",
        "external_call",
        "env_get_",
        "is_defined",
    ]
    var expected: List[String] = [
        "__init__.mojo",
        "_post.mojo",
        "aws_subject.mojo",
        "external_account.mojo",
        "sign_jwt.mojo",
        "sts.mojo",
    ]
    var seen = List[Bool]()
    for _ in range(len(expected)):
        seen.append(False)
    var scanned = 0
    for i in range(len(names)):
        var name = String(names[i])
        if not name.endswith(".mojo"):
            continue
        var text: String
        with open(String(_DIR) + "/" + name, "r") as f:
            text = f.read()
        scanned += 1
        assert_true(text.byte_length() > 0, name + " is empty")
        for k in range(len(expected)):
            if expected[k] == name:
                seen[k] = True
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                name + " names " + banned[j] + "; komira_gcp_wif reads no"
                " environment",
            )
    for k in range(len(expected)):
        assert_true(seen[k], expected[k] + " was not staged")
    assert_equal(scanned, len(expected))


def main() raises:
    test_scan()
    print("OK")
