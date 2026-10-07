# =============================================================================
# komira_aws_core/tests/test_env_source_only.mojo
# =============================================================================
#
# No environment read in komira_aws_core happens through anything but the
# EnvSource. Every library source of the package is staged as test data
# (src/komira_aws_core/*.mojo); the test reads each one and fails if any file
# other than sources.mojo -- the one home of `ProcessEnv` -- names getenv,
# `_read_env`, komira_libc or an `external_call`. sources.mojo itself must
# reach getenv exactly once, through `_read_env`, so the scan is not vacuous.
#
# The behavioural half lives in test_credential_chain.mojo: every read the
# chain makes is recorded by MapEnv and must be a standard AWS SDK variable.
# =============================================================================

from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "src/komira_aws_core"


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
    var saw_sources = False
    var saw_chain = False
    var banned: List[String] = [
        "getenv",
        "_read_env",
        "komira_libc",
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
        if name == "sources.mojo":
            saw_sources = True
            assert_equal(_count(text, "external_call"), 0, name)
            assert_equal(
                _count(text, "from komira_libc.posix import _read_env"), 1, name
            )
            assert_equal(_count(text, "return _read_env(name)"), 1, name)
            continue
        if name == "credential_chain.mojo":
            saw_chain = True
            assert_true(_count(text, "env.get(") > 10, "the chain reads no env?")
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                name + " names " + banned[j] + "; read the environment only"
                " through the EnvSource in sources.mojo",
            )
    assert_true(saw_sources, "sources.mojo was not staged")
    assert_true(saw_chain, "credential_chain.mojo was not staged")
    assert_true(scanned >= 12, "only " + String(scanned) + " sources staged")


def main() raises:
    test_scan()
    print("OK")
