# The generated modules read no environment, and hold only what a log
# reader calls. Every generated file is staged as this test's data, at
# gen/<file>; the test reads each one.
#
# No environment: no file names a way to read it or the FFI a read would
# go through. Configuration is a parameter (the HTTP client, the token
# source, the host); credentials come from the GcpTokenSource a caller
# passes, and where that source looks is komira_gcp_core's business.
#
# Scope: the client is generated for `LoggingServiceV2.ListLogEntries`
# only. The service's other methods, every write among them, are not in
# the generated code, so a caller of this package cannot write, delete or
# tail a log through it.
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() -> List[String]:
    return [
        "__init__.mojo",
        "_layout_probe.mojo",
        "http_request.mojo",
        "log_entry.mojo",
        "log_severity.mojo",
        "logging.mojo",
        "monitored_resource.mojo",
    ]


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


def test_only_the_read_is_generated() raises:
    var absent: List[String] = [
        "WriteLogEntries",
        "DeleteLog",
        "TailLogEntries",
        "ListLogs",
        "ListMonitoredResourceDescriptors",
        "MonitoredResourceDescriptor",
        "def write_",
        "def delete_",
        "def tail_",
    ]
    var files = _files()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(absent)):
            assert_equal(
                _count(text, absent[j]),
                0,
                files[i] + " names " + absent[j] + "; the client is scoped to"
                " ListLogEntries",
            )


def test_the_scan_saw_the_client() raises:
    # Not vacuous: the staged modules are the generated client, whole.
    var text = _read("logging.mojo")
    assert_equal(
        _count(
            text,
            "\nstruct LoggingServiceV2Client[C: Connector, T: GcpTokenSource]",
        ),
        1,
    )
    assert_equal(_count(text, "    def list_log_entries[RT: Runtime]("), 1)
    assert_equal(_count(text, "\nstruct ListLogEntriesRequest("), 1)
    assert_equal(_count(text, "\nstruct ListLogEntriesResponse("), 1)
    assert_equal(_count(text, '"""POST `/v2/entries:list`'), 1)
    assert_true(_count(_read("log_entry.mojo"), "\nstruct LogEntry(") == 1)


def main() raises:
    test_no_environment_read()
    test_only_the_read_is_generated()
    test_the_scan_saw_the_client()
    print("OK")
