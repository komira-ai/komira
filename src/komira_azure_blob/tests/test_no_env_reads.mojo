# The package reads no environment: the account, its key, the endpoint and
# the clock's instant for a SAS are each a parameter. The package's
# sources are staged as this test's data, at src/<file>; the test reads each
# one and fails if any names a way to read the environment or the FFI a read
# would go through, and checks that the files it read are every staged one.
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
    "azure.mojo",
    "azure_client.mojo",
    "azure_client_spec.mojo",
    "azure_fs.mojo",
    "azure_sas.mojo",
    "azure_sas_query.mojo",
    "azure_signing.mojo",
    "azure_url.mojo",
    "azure_xml.mojo",
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
        "AZURE_CLIENT_ID",
        "AZURE_CLIENT_SECRET",
        "AZURE_TENANT_ID",
        "IDENTITY_ENDPOINT",
        "MSI_ENDPOINT",
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
    assert_equal(_count(_read("azure.mojo"), "\nstruct AzureStore["), 1)
    assert_equal(_count(_read("azure_fs.mojo"), "\nstruct AzureFs["), 1)
    assert_equal(_count(_read("azure_sas.mojo"), "\nstruct AzureSasSigner["), 1)
    assert_equal(_count(_read("azure_signing.mojo"), "\nstruct SharedKeySigningLayer["), 1)
    assert_equal(_count(_read("azure_url.mojo"), "\ndef parse_azure_url("), 1)
    assert_true(_read("azure_fs.mojo").byte_length() > 10000)


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_package()
    print("OK")
