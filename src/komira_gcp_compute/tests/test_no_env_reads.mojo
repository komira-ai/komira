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
# Scope: 39 methods on 17 clients (BUCK `methods`). Every other method of
# the Compute Engine API is absent: no list, aggregated list, start, stop,
# reset, setLabels/setMetadata/setMachineType/setTags or instance-group
# method, and not RegionNetworkEndpointGroups.InsertBeta, which is not a v1
# method. The operation is compute's own (`status`), never
# google.longrunning's (`done`).
from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = listdir(String(_DIR))
    var has_client = False
    for i in range(len(names)):
        if names[i] == "compute.mojo":
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
        "komira_core_ffi",
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
    var text = _read("compute.mojo")
    # Every generated method, by verb: 39 in all.
    assert_equal(_count(text, "[RT: Runtime](mut self, req: "), 39)
    assert_equal(_count(text, "    def get[RT: Runtime]("), 15)
    assert_equal(_count(text, "    def insert[RT: Runtime]("), 13)
    assert_equal(_count(text, "    def delete[RT: Runtime]("), 4)
    assert_equal(_count(text, "    def wait[RT: Runtime]("), 3)
    assert_equal(_count(text, "    def patch[RT: Runtime]("), 3)
    assert_equal(_count(text, "    def invalidate_cache[RT: Runtime]("), 1)
    assert_equal(_count(text, "Client[C: Connector, T: GcpTokenSource]"), 17)

    var absent: List[String] = [
        "def list",
        "def aggregated_list",
        "def start",
        "def stop",
        "def reset",
        "def set_labels",
        "def set_metadata",
        "def set_machine_type",
        "def set_tags",
        "def insert_beta",
        "InsertBeta",
        "ListInstancesRequest",
        "AggregatedList",
        "InstanceGroup",
        "GetRegionOperationRequest",
        "GetGlobalOperationRequest",
        "google.longrunning",
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


def test_the_operation_is_computes_own() raises:
    var text = _read("compute.mojo")
    var at = text.find("\nstruct Operation(")
    assert_true(at >= 0, "no Operation struct")
    var end = text.find("\n    def __deinit__", at)
    var fields = String(text[byte=at:end])
    assert_equal(_count(fields, "    var status: Optional[Operation_Status]\n"), 1)
    assert_equal(_count(fields, "    var error: Optional[Error_]\n"), 1)
    assert_equal(_count(fields, "    var done"), 0)
    assert_equal(_count(fields, "    var response"), 0)
    assert_equal(_count(fields, "    var metadata"), 0)


def test_the_scan_saw_the_client() raises:
    # Not vacuous: the staged module is the generated client.
    var text = _read("compute.mojo")
    assert_equal(
        _count(
            text, "\nstruct InstancesClient[C: Connector, T: GcpTokenSource]"
        ),
        1,
    )
    assert_equal(
        _count(
            text,
            '"""POST `/compute/v1/projects/{project}/zones/{zone}/instances`',
        ),
        1,
    )


def main() raises:
    test_no_environment_read()
    test_only_the_called_methods_are_generated()
    test_the_operation_is_computes_own()
    test_the_scan_saw_the_client()
    print("OK")
