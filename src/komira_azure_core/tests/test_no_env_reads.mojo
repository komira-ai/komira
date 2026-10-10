# The package reads no environment today: an account key, a SAS, a tenant, a
# client id and secret, and an endpoint are each a parameter. The package's
# sources are staged as this test's data, at src/<file>; the test reads each
# one and fails if any names a way to read the environment or the FFI a read
# would go through, or the storage-account variables of the dropped
# environment provider, and checks that the files it read are every staged
# one.
#
# Policy: configuration is parameters; the environment is read only the way
# the official SDK credential chains read it. So a future default credential
# chain that reads the variables the official Azure chain reads
# (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, IDENTITY_ENDPOINT,
# MSI_ENDPOINT) is allowed; the change that adds it narrows the generic bans
# below for that one file, deliberately. Those names are therefore not banned
# by name here.
from std.os import listdir
from std.testing import assert_equal, assert_true


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _read(name: String) raises -> String:
    with open(String("src/") + name, "r") as f:
        return f.read()


comptime _FILES: List[String] = [
    "__init__.mojo",
    "azure_token.mojo",
    "credentials.mojo",
    "creds_managed_identity.mojo",
    "creds_service_principal.mojo",
]


def test_no_environment_read() raises:
    var banned: List[String] = [
        "getenv",
        "_read_env",
        "std.os",
        "from_environ",
        "komira_libc",
        "komira_libc",
        "external_call",
        "AZURE_STORAGE_ACCOUNT",
        "AZURE_STORAGE_KEY",
        "AZURE_STORAGE_SAS_TOKEN",
    ]
    var files = materialize[_FILES]()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j] + "; every setting is a parameter",
            )


def test_the_scan_saw_the_package() raises:
    # Every staged source is one the scan reads: a new file joins _FILES.
    var files = materialize[_FILES]()
    var staged = listdir(String("src"))
    assert_equal(len(staged), len(files), "src/ holds a file the scan does not read")
    for i in range(len(staged)):
        var known = False
        for j in range(len(files)):
            if staged[i] == files[j]:
                known = True
        assert_true(known, "src/" + staged[i] + " is staged but not scanned")
    # Not vacuous: each file is the package's, whole.
    assert_equal(_count(_read("credentials.mojo"), "\nstruct AzureSharedKey("), 1)
    assert_equal(_count(_read("creds_managed_identity.mojo"), "\nstruct AzureImdsProvider["), 1)
    assert_equal(_count(_read("creds_service_principal.mojo"), "\nstruct ServicePrincipalProvider["), 1)
    assert_true(_read("creds_managed_identity.mojo").byte_length() > 5000)


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_package()
    print("OK")
