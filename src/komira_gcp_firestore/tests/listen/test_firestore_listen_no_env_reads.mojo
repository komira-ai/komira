# Every generated module of this package reads no environment, and holds
# only the methods its BUCK target names: a scan of the generated files
# (staged under gen/ by the target's test_data), not of a list of them.
from std.os import listdir
from std.testing import assert_equal, assert_true


comptime _DIR = "gen/"


def _files() raises -> List[String]:
    """Every file staged under gen/. Refuses an empty staging, which would
    make each scan below pass over nothing."""
    var names = listdir(String(_DIR))
    var has_client = False
    var has_document = False
    for i in range(len(names)):
        if names[i] == "firestore.mojo":
            has_client = True
        if names[i] == "document.mojo":
            has_document = True
    assert_true(len(names) > 0, "nothing is staged under gen/")
    assert_true(has_client and has_document, "gen/ is not the generated package")
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
        "FIRESTORE_EMULATOR_HOST",
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


def test_only_listen_is_generated() raises:
    var absent: List[String] = [
        "def get_document",
        "def batch_get_documents",
        "def commit",
        "def run_query",
        "def write",
        "def rollback",
        "def begin_transaction",
    ]
    var files = _files()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(absent)):
            assert_equal(
                _count(text, absent[j]),
                0,
                files[i] + " names " + absent[j] + "; the client is scoped to"
                " Listen",
            )


def test_the_scan_saw_the_client() raises:
    var text = _read("firestore.mojo")
    assert_equal(
        _count(text, "\nstruct FirestoreClient[C: Connector, T: GcpTokenSource]"),
        1,
    )
    assert_equal(_count(text, "    def listen[RT: Runtime]("), 1)
    assert_equal(_count(text, "\nstruct ListenRequest("), 1)
    assert_equal(_count(text, "\nstruct ListenResponse("), 1)


def main() raises:
    test_no_environment_read()
    test_only_listen_is_generated()
    test_the_scan_saw_the_client()
    print("OK")
