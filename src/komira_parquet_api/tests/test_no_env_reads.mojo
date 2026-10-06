# The package reads no environment, imports no first-party package and holds
# no raw pointer: it is plain values over the standard library. Every source
# the library compiles is staged as this test's data, at src/<path>; the test
# reads each one and fails if any names a way to read the environment, the FFI
# a read would go through, a first-party import or an unsafe pointer, and
# checks that the files it read are every staged one (a staged subdirectory is
# a name it does not read, so it fails too).
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
    "hll_footer.mojo",
    "metadata.mojo",
    "types.mojo",
]


def test_no_environment_read() raises:
    var banned: List[String] = [
        "getenv",
        "_read_env",
        "std.os",
        "external_call",
        "komira_core_ffi",
        "from komira",
        "import komira",
        "UnsafePointer",
        "unsafe_from_address",
    ]
    var files = materialize[_FILES]()
    for i in range(len(files)):
        var text = _read(files[i])
        for j in range(len(banned)):
            assert_equal(
                _count(text, banned[j]),
                0,
                files[i] + " names " + banned[j] + "; the package is plain values",
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
    assert_equal(_count(_read("types.mojo"), "\nstruct CompressionCodec("), 1)
    assert_equal(_count(_read("metadata.mojo"), "\nstruct FileMetaData("), 1)
    assert_true(_read("metadata.mojo").byte_length() > 10000)


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_package()
    print("OK")
