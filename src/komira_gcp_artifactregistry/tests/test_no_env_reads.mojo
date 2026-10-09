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
# Scope: CreateRepository, GetRepository, DeleteRepository,
# ListRepositories, GetFile, GetIamPolicy and SetIamPolicy (BUCK `methods`).
# The service's other methods are absent, among them TestIamPermissions,
# the docker image, package, version, tag and file listings, and
# UpdateRepository.
from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = listdir(String(_DIR))
    var has_client = False
    for i in range(len(names)):
        if names[i] == "service.mojo":
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
    var text = _read("service.mojo")
    assert_equal(_count(text, "[RT: Runtime](mut self, req: "), 7)
    assert_equal(_count(text, "    def create_repository[RT: Runtime]("), 1)
    assert_equal(_count(text, "    def get_repository[RT: Runtime]("), 1)
    assert_equal(_count(text, "    def delete_repository[RT: Runtime]("), 1)
    assert_equal(_count(text, "    def list_repositories[RT: Runtime]("), 1)
    assert_equal(_count(text, "    def get_file[RT: Runtime]("), 1)
    assert_equal(_count(text, "    def get_iam_policy[RT: Runtime]("), 1)
    assert_equal(_count(text, "    def set_iam_policy[RT: Runtime]("), 1)
    var absent: List[String] = [
        "TestIamPermissions",
        "def test_iam_permissions",
        "DockerImage",
        "docker_image",
        "def list_files",
        "def list_packages",
        "def list_versions",
        "def list_tags",
        "def delete_package",
        "def update_repository",
        "def get_operation",
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
    var text = _read("service.mojo")
    assert_equal(
        _count(
            text,
            "\nstruct ArtifactRegistryClient[C: Connector, T: GcpTokenSource]",
        ),
        1,
    )
    assert_true(_count(_read("repository.mojo"), "\nstruct Repository(") == 1)
    assert_true(_count(_read("operations.mojo"), "\nstruct Operation(") == 1)


def main() raises:
    test_no_environment_read()
    test_only_the_called_methods_are_generated()
    test_the_scan_saw_the_client()
    print("OK")
