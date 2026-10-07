# The generated modules read no environment, and hold only the methods the
# BUCK file's `methods` names. The generated package is staged whole as
# this test's data, at gen/, and the test reads every file it finds there:
# no list of the generated files is kept here to fall behind what the
# generator writes.
#
# No environment: no file names a way to read it or the FFI a read would go
# through. Configuration is a parameter (the HTTP client, the token source,
# the host); credentials come from the GcpTokenSource a caller passes.
#
# Scope: Create, Get and Delete of Api, ApiConfig and Gateway (BUCK
# `methods`). The service's other methods are absent: the listings and the
# three updates. google.longrunning's Operations service is not generated
# either (its operation poll is not a method of these protos' REST surface;
# BUCK states why).
from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = listdir(String(_DIR))
    var has_client = False
    for i in range(len(names)):
        if names[i] == "apigateway_service.mojo":
            has_client = True
    assert_true(len(names) > 0, "nothing is staged under gen/")
    assert_true(has_client, "gen/ is not the generated package")
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
        "komira_libc",
        "external_call",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "CLOUDSDK_",
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


def test_only_the_called_methods_are_generated() raises:
    var text = _read("apigateway_service.mojo")
    assert_equal(_count(text, "[RT: Runtime](mut self, req: "), 9)
    var kept: List[String] = [
        "create_api",
        "get_api",
        "delete_api",
        "create_api_config",
        "get_api_config",
        "delete_api_config",
        "create_gateway",
        "get_gateway",
        "delete_gateway",
    ]
    for i in range(len(kept)):
        assert_equal(
            _count(text, "    def " + kept[i] + "[RT: Runtime]("), 1, kept[i]
        )
    var absent: List[String] = [
        "def update_",
        "UpdateGateway",
        "UpdateApi",
        "def list_",
        "ListGateways",
        "ListApis",
        "def get_operation",
        "def wait_operation",
        "def cancel_operation",
    ]
    var files = _files()
    for i in range(len(files)):
        var body = _read(files[i])
        for j in range(len(absent)):
            assert_equal(
                _count(body, absent[j]),
                0,
                files[i] + " names " + absent[j] + "; the client is scoped to"
                " the methods its BUCK file names",
            )


def test_the_scan_saw_the_client() raises:
    var text = _read("apigateway_service.mojo")
    assert_equal(
        _count(
            text,
            "\nstruct ApiGatewayServiceClient[C: Connector, T: GcpTokenSource]",
        ),
        1,
    )
    assert_true(_count(_read("apigateway.mojo"), "\nstruct Gateway(") == 1)
    assert_true(_count(_read("operations.mojo"), "\nstruct Operation(") == 1)


def main() raises:
    test_no_environment_read()
    test_only_the_called_methods_are_generated()
    test_the_scan_saw_the_client()
    print("OK")
