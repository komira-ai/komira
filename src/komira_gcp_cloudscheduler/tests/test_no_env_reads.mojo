# The generated modules read no environment, and hold only the methods
# komira's callers use. The generated package is staged whole as this
# test's data, at gen/, and the test reads every file it finds there: no
# list of the generated files is kept here to fall behind the generator.
#
# No environment: no file names a way to read it or the FFI a read would
# go through. Configuration is a parameter (the HTTP client, the token
# source, the host); credentials come from the GcpTokenSource a caller
# passes.
#
# Scope: CreateJob, GetJob, ListJobs, UpdateJob and DeleteJob. The
# service's other methods (PauseJob, ResumeJob, RunJob) are not in the
# generated code.
from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = listdir(String(_DIR))
    var has_client = False
    var has_job = False
    for i in range(len(names)):
        if names[i] == "cloudscheduler.mojo":
            has_client = True
        if names[i] == "job.mojo":
            has_job = True
    assert_true(len(names) > 0, "nothing is staged under gen/")
    assert_true(has_client and has_job, "gen/ is not the generated package")
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


def test_only_the_used_methods_are_generated() raises:
    var absent: List[String] = [
        "def pause_job[",
        "def resume_job[",
        "def run_job[",
        "struct PauseJobRequest(",
        "struct ResumeJobRequest(",
        "struct RunJobRequest(",
    ]
    var files = _files()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(absent)):
            assert_equal(
                _count(text, absent[j]),
                0,
                files[i] + " holds " + absent[j] + "; the client is scoped to"
                " the methods its callers use",
            )


def test_the_scan_saw_the_client() raises:
    # Not vacuous: the staged modules are the generated client, whole.
    var text = _read("cloudscheduler.mojo")
    assert_equal(
        _count(text, "\nstruct CloudSchedulerClient[C: Connector, T: GcpTokenSource]"),
        1,
    )
    var present: List[String] = [
        "    def create_job[RT: Runtime](",
        "    def get_job[RT: Runtime](",
        "    def list_jobs[RT: Runtime](",
        "    def update_job[RT: Runtime](",
        "    def delete_job[RT: Runtime](",
    ]
    for j in range(len(present)):
        assert_equal(_count(text, present[j]), 1, present[j])
    # Exactly these: no other method of the service is generated.
    assert_equal(_count(text, "[RT: Runtime]("), len(present))
    assert_true(_count(_read("job.mojo"), "\nstruct Job(") == 1)


def main() raises:
    test_no_environment_read()
    test_only_the_used_methods_are_generated()
    test_the_scan_saw_the_client()
    print("OK")
