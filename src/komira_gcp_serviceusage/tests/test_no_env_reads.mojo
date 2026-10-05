# The generated modules read no environment, and hold only the methods
# komira's callers use. The generated package is staged whole as this
# test's data, at gen/, and the test reads every file it finds there: no
# list of the generated files is kept here to fall behind the generator.
#
# No environment: no file names a way to read it or the FFI a read would go
# through. Configuration is a parameter (the HTTP client, the token source,
# the host); credentials come from the GcpTokenSource a caller passes.
#
# Scope: EnableService, DisableService and GetService (BUCK lists each with
# the use it serves). ListServices, BatchEnableServices and BatchGetServices
# are not generated, and neither is the long-running Operations service: a
# caller converges an enable by polling GetService. `Service.config` is left
# out of the generated message (`omit_fields`), so no ServiceConfig, and
# nothing it reaches, is generated.
from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = listdir(String(_DIR))
    var has_client = False
    var has_service = False
    for i in range(len(names)):
        if names[i] == "serviceusage.mojo":
            has_client = True
        if names[i] == "resources.mojo":
            has_service = True
    assert_true(len(names) > 0, "nothing is staged under gen/")
    assert_true(has_client and has_service, "gen/ is not the generated package")
    return names^


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
        "setenv",
        "_read_env",
        "std.os",
        "EnvSource",
        "komira_core_ffi",
        "external_call",
        "GOOGLE_APPLICATION_CREDENTIALS",
    ]
    var files = _files()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j] + "; the generated client"
                " takes every input as a parameter",
            )


def test_only_the_methods_callers_use_are_generated() raises:
    var absent: List[String] = [
        "ListServices",
        "BatchEnableServices",
        "BatchGetServices",
        "OperationsClient",
        "GetOperationRequest",
        "ServiceConfig",
        "var config",
        "def list_",
        "def batch_",
        "def get_operation",
        "def cancel_",
        "def wait_",
    ]
    var files = _files()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(absent)):
            assert_equal(
                _count(text, absent[j]),
                0,
                files[i] + " names " + absent[j] + "; the client is scoped to"
                " the methods its callers use",
            )


def test_the_scan_saw_the_client() raises:
    var text = _read("serviceusage.mojo")
    assert_equal(
        _count(text, "\nstruct ServiceUsageClient[C: Connector, T: GcpTokenSource]"), 1
    )
    var methods: List[String] = ["enable_service", "disable_service", "get_service"]
    for i in range(len(methods)):
        assert_equal(
            _count(text, String("    def ") + methods[i] + "[RT: Runtime]("),
            1,
            methods[i],
        )
    # And no other method: three in all.
    assert_equal(_count(text, "[RT: Runtime]("), 3)
    assert_equal(_count(_read("operations.mojo"), "\nstruct Operation("), 1)
    assert_equal(_count(_read("resources.mojo"), "\nstruct Service("), 1)


def main() raises:
    test_no_environment_read()
    test_only_the_methods_callers_use_are_generated()
    test_the_scan_saw_the_client()
    print("OK")
