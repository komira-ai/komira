# Every generated module of this package reads no environment, and holds
# only the methods its BUCK target names: a scan of the generated files
# (staged under gen/ by the target's test_data), not of a list of them.
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


def test_only_the_named_methods_are_generated() raises:
    # Every method of google.firestore.v1.Firestore but the three named in
    # BUCK: the document reads and writes the package makes go through
    # them, as Google's own client libraries' do.
    var absent: List[String] = [
        "def get_document",
        "def list_documents",
        "def update_document",
        "def delete_document",
        "def create_document",
        "def begin_transaction",
        "def rollback",
        "def run_aggregation_query",
        "def partition_query",
        "def listen",
        "def write",
        "def list_collection_ids",
        "def batch_write",
        "def execute_pipeline",
    ]
    var files = _files()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(absent)):
            assert_equal(
                _count(text, absent[j]),
                0,
                files[i] + " names " + absent[j] + "; the client is scoped to"
                " BatchGetDocuments, Commit and RunQuery",
            )


def test_the_scan_saw_the_client() raises:
    var text = _module("firestore.mojo")
    assert_equal(
        _count(text, "\nstruct FirestoreClient[C: Connector, T: GcpTokenSource]"),
        1,
    )
    assert_equal(_count(text, "    def batch_get_documents[RT: Runtime]("), 1)
    assert_equal(_count(text, "    def commit[RT: Runtime]("), 1)
    assert_equal(_count(text, "    def run_query[RT: Runtime]("), 1)
    assert_equal(_count(text, "gcp_rest_stream_items(String("), 2)
    assert_equal(_count(_module("document.mojo"), "\nstruct Value("), 1)


def main() raises:
    test_no_environment_read()
    test_only_the_named_methods_are_generated()
    test_the_scan_saw_the_client()
    print("OK")
