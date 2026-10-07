# The generated client reads no environment: the token comes from the
# caller's GcpTokenSource and the endpoint from the caller's GrpcClient. The
# generated files are staged as this test's data, at gen/<file>; the test
# reads each one and fails if any names a way to read the environment or
# reaches the FFI a read would go through, or imports komira_serde (generated
# code encodes with komira_proto_codec) or komira_obs.
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _read(name: String) raises -> String:
    with open(String(_DIR) + name, "r") as f:
        return f.read()


def test_no_environment_read() raises:
    var banned: List[String] = [
        "getenv",
        "_read_env",
        "std.os",
        "EnvSource",
        "ProcessEnv",
        "GOOGLE_",
        "komira_libc",
        "external_call",
        # Generated code encodes with komira_proto_codec and logs nothing.
        "komira_serde",
        "komira_obs",
    ]
    var files: List[String] = [
        "__init__.mojo",
        "_layout_probe.mojo",
        "date.mojo",
        "expr.mojo",
        "iam_policy.mojo",
        "options.mojo",
        "policy.mojo",
        "storage.mojo",
    ]
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j] + "; the generated client"
                " takes every input as a parameter",
            )


def test_the_scan_saw_the_client() raises:
    # Not vacuous: the module staged is the generated client, whole.
    var text = _read("storage.mojo")
    assert_true(text.byte_length() > 100000, "the staged module is too small")
    assert_equal(
        _count(text, "\nstruct StorageClient[C: Connector, T: GcpTokenSource]"), 1
    )
    assert_equal(_count(text, "    def write_object[RT: Runtime]("), 1)


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_client()
    print("OK")
