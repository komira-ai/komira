# The generated modules read no environment, and hold only the read a
# metrics reader calls. The generated package is staged whole as this
# test's data, at gen/, and the test reads every file it finds there: no
# list of the generated files is kept here to fall behind the generator.
#
# No environment: no file names a way to read it or the FFI a read would
# go through. Configuration is a parameter (the HTTP client, the token
# source, the endpoint); credentials come from the GcpTokenSource a caller
# passes.
#
# Scope: the client is generated for `MetricService.ListTimeSeries` only.
# The service's writes (CreateTimeSeries, CreateMetricDescriptor, the
# deletes) are not in the generated code, so a caller of this package
# cannot write a metric or a descriptor through it.
from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = listdir(String(_DIR))
    var has_client = False
    for i in range(len(names)):
        if names[i] == "metric_service.mojo":
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


def test_only_the_read_is_generated() raises:
    var absent: List[String] = [
        "CreateTimeSeries",
        "CreateServiceTimeSeries",
        "CreateMetricDescriptor",
        "DeleteMetricDescriptor",
        "def create_",
        "def delete_",
        "def get_",
    ]
    var files = _files()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(absent)):
            assert_equal(
                _count(text, absent[j]),
                0,
                files[i] + " names " + absent[j] + "; the client is scoped to"
                " ListTimeSeries",
            )


def test_the_scan_saw_the_client() raises:
    # Not vacuous: the staged modules are the generated client, whole.
    var text = _read("metric_service.mojo")
    assert_equal(
        _count(
            text, "\nstruct MetricServiceClient[C: Connector, T: GcpTokenSource]"
        ),
        1,
    )
    assert_equal(_count(text, "    def list_time_series[RT: Runtime]("), 1)
    assert_equal(_count(text, "\nstruct ListTimeSeriesRequest("), 1)
    assert_equal(_count(text, "\nstruct ListTimeSeriesResponse("), 1)


def main() raises:
    test_no_environment_read()
    test_only_the_read_is_generated()
    test_the_scan_saw_the_client()
    print("OK")
