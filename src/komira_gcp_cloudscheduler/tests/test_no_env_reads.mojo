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


def _gen_files() raises -> List[String]:
    """Every file staged under gen/, the parts of a module the generator split
    (the files of gen/_parts/) as `_parts/<file>`."""
    var names = List[String]()
    for entry in listdir(String(_DIR)):
        if entry == "_parts":
            for part in listdir(String(_DIR) + "_parts"):
                names.append("_parts/" + part)
        else:
            names.append(entry)
    return names^


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = _gen_files()
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


def _is_part_of(file: String, stem: String) -> Bool:
    """Whether `file` is `<stem>_pNN.mojo`: a part of module `stem`."""
    var head = stem + "_p"
    if not file.startswith(head) or not file.endswith(".mojo"):
        return False
    var digits = String(file[byte=head.byte_length():file.byte_length() - 5])
    if digits.byte_length() == 0:
        return False
    var b = digits.as_bytes()
    for i in range(len(b)):
        if Int(b[i]) < 48 or Int(b[i]) > 57:
            return False
    return True


def _module(name: String) raises -> String:
    """The text of generated module `name`: its file and, when the generator
    split it (the file is then a facade importing its parts from
    gen/_parts/), each of its parts."""
    var text = _read(name)
    var stem = String(name[byte=0:name.byte_length() - 5])
    for part in listdir(String(_DIR) + "_parts"):
        if _is_part_of(part, stem):
            text += _read("_parts/" + part)
    return text^


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
    var text = _module("cloudscheduler.mojo")
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
    assert_true(_count(_module("job.mojo"), "\nstruct Job(") == 1)


def main() raises:
    test_no_environment_read()
    test_only_the_used_methods_are_generated()
    test_the_scan_saw_the_client()
    print("OK")
