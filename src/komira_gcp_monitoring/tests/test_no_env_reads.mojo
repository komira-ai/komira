# The package reads no environment: the project, the host, the token
# source and the connector are the caller's. The package's sources are staged
# whole as this test's data, at src/; the test reads every file it finds
# there (no list of them to fall behind) and fails if one names a way to read
# the environment or the FFI a read would go through.
from std.os import listdir
from std.testing import assert_equal, assert_true


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _read(name: String) raises -> String:
    with open(String("src/") + name, "r") as f:
        return f.read()


def test_no_environment_read() raises:
    var banned: List[String] = [
        "getenv",
        "setenv",
        "_read_env",
        "std.os",
        "EnvSource",
        "ProcessEnv",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "CLOUDSDK_",
        "application_default",
        "komira_core_ffi",
        "komira_libc",
        "external_call",
    ]
    var files = listdir(String("src"))
    assert_true(len(files) >= 3, "the package's sources are not staged at src/")
    var saw_reader = False
    for i in range(len(files)):
        var text = _read(files[i])
        if _count(text, "\nstruct CloudMonitoringMetricsReader[") == 1:
            saw_reader = True
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j] + "; every setting is a parameter",
            )
    assert_true(saw_reader, "the scan did not read reader.mojo")


def main() raises:
    test_no_environment_read()
    print("OK")
