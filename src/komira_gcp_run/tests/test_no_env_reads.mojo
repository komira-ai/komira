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
# Scope: the methods in BUCK's `methods`. The services' other methods
# (TestIamPermissions, a worker pool's IAM policy, executions listing and
# deletion, revisions read, instances, tasks, builds, operations listing,
# deletion and cancellation) are not in the generated code.
from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = listdir(String(_DIR))
    var has_service = False
    var has_operations = False
    for i in range(len(names)):
        if names[i] == "service.mojo":
            has_service = True
        if names[i] == "operations.mojo":
            has_operations = True
    assert_true(len(names) > 0, "nothing is staged under gen/")
    assert_true(has_service and has_operations, "gen/ is not the generated package")
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


def _methods_of(file: String, var names: List[String]) raises -> Int:
    """Hold `file` to exactly the client methods `names`; their count."""
    var text = _read(file)
    for j in range(len(names)):
        assert_equal(
            _count(text, String("    def ") + names[j] + "[RT: Runtime]("),
            1,
            file + ": " + names[j],
        )
    assert_equal(_count(text, "[RT: Runtime]("), len(names), file)
    return len(names)


def test_only_the_used_methods_are_generated() raises:
    var total = 0
    total += _methods_of(
        "service.mojo",
        [
            "create_service",
            "get_service",
            "list_services",
            "update_service",
            "delete_service",
            "get_iam_policy",
            "set_iam_policy",
        ],
    )
    total += _methods_of("revision.mojo", ["list_revisions", "delete_revision"])
    total += _methods_of(
        "job.mojo",
        [
            "create_job",
            "get_job",
            "list_jobs",
            "update_job",
            "delete_job",
            "run_job",
            "get_iam_policy",
            "set_iam_policy",
        ],
    )
    total += _methods_of(
        "worker_pool.mojo",
        [
            "create_worker_pool",
            "get_worker_pool",
            "list_worker_pools",
            "update_worker_pool",
            "delete_worker_pool",
        ],
    )
    total += _methods_of("execution.mojo", ["get_execution", "cancel_execution"])
    total += _methods_of("operations.mojo", ["get_operation", "wait_operation"])
    assert_equal(total, 26)
    var files = _files()
    var methods = 0
    for i in range(len(files)):
        methods += _count(_read(files[i]), "[RT: Runtime](")
    assert_equal(methods, total, "a method outside the list was generated")
    # One operations client: google.longrunning.Operations, generated into
    # operations.mojo with run_v2.yaml's bindings.
    assert_equal(_count(_read("operations.mojo"), "struct OperationsClient["), 1)


def main() raises:
    test_no_environment_read()
    test_only_the_used_methods_are_generated()
    print("OK")
