# The generated modules read no environment, and hold only the methods
# komira's callers use. The generated package is staged whole as this
# test's data, at gen/, and the test reads every file it finds there: no
# list of the generated files is kept here to fall behind the generator.
#
# No environment: no file names a way to read it or the FFI a read would go
# through. Configuration is a parameter (the HTTP client, the token source,
# the host); credentials come from the GcpTokenSource a caller passes.
#
# Scope: the client is generated for the service-account, role and
# service-account-policy methods its callers make (BUCK lists each with the
# use it serves). The rest of the IAM service is not generated, so a caller
# of this package cannot reach it: no service-account key is created,
# uploaded, listed or deleted, nothing is signed (SignBlob and SignJwt are
# deprecated here in favour of IAM Credentials), no account is patched,
# enabled, disabled or undeleted, and no role is listed, queried or
# undeleted. Of the workload
# identity pools, only a provider is read (GetWorkloadIdentityPoolProvider);
# no pool or provider is listed, created, changed, deleted or undeleted.
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
    var has_policy = False
    for i in range(len(names)):
        if names[i] == "iam.mojo":
            has_client = True
        if names[i] == "policy.mojo":
            has_policy = True
    assert_true(len(names) > 0, "nothing is staged under gen/")
    assert_true(has_client and has_policy, "gen/ is not the generated package")
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


def test_only_the_methods_callers_use_are_generated() raises:
    var absent: List[String] = [
        "ServiceAccountKey",
        "SignBlob",
        "SignJwt",
        "UndeleteServiceAccount",
        "PatchServiceAccount",
        "UpdateServiceAccount",
        "EnableServiceAccount",
        "DisableServiceAccount",
        "ListRoles",
        "UndeleteRole",
        "QueryGrantableRoles",
        "QueryTestablePermissions",
        "QueryAuditableServices",
        "LintPolicy",
        "TestIamPermissions",
        "IAMPolicyClient",
        "def sign_",
        "def undelete_",
        "def patch_",
        "def upload_",
        "def list_workload",
        "def create_workload",
        "def update_workload",
        "def delete_workload",
        "def get_workload_identity_pool[",
        "def enable_",
        "def disable_",
        "def query_",
    ]
    var files = _files()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(absent)):
            assert_equal(
                _count(text, absent[j]),
                0,
                files[i] + " names " + absent[j] + "; the client is scoped to"
                " the methods its callers use",
            )


def test_the_scan_saw_the_client() raises:
    # Not vacuous: the staged modules are the generated client, whole, with
    # each of its methods once.
    var text = _module("iam.mojo")
    assert_equal(
        _count(text, "\nstruct IAMClient[C: Connector, T: GcpTokenSource]"), 1
    )
    var methods: List[String] = [
        "list_service_accounts",
        "get_service_account",
        "create_service_account",
        "delete_service_account",
        "get_iam_policy",
        "set_iam_policy",
        "get_role",
        "create_role",
        "update_role",
        "delete_role",
    ]
    for i in range(len(methods)):
        assert_equal(
            _count(text, String("    def ") + methods[i] + "[RT: Runtime]("),
            1,
            methods[i],
        )
    # And no other method: ten in all.
    assert_equal(_count(text, "[RT: Runtime]("), 10)
    # The workload identity pools client holds the provider read alone.
    var wif = _module("workload_identity_pool.mojo")
    assert_equal(
        _count(
            wif,
            "\nstruct WorkloadIdentityPoolsClient[C: Connector, T: GcpTokenSource]",
        ),
        1,
    )
    assert_equal(
        _count(wif, "    def get_workload_identity_pool_provider[RT: Runtime]("), 1
    )
    assert_equal(_count(wif, "[RT: Runtime]("), 1)
    assert_equal(_count(_module("policy.mojo"), "\nstruct Policy("), 1)


def main() raises:
    test_no_environment_read()
    test_only_the_methods_callers_use_are_generated()
    test_the_scan_saw_the_client()
    print("OK")
