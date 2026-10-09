# The package reads no environment: every setting is an S3Config field or a
# type parameter (the credential source, the clock). The package's sources
# are staged as this test's data, at src/<file>; the test reads each one and
# fails if any names a way to read the environment or the FFI a read would
# go through, and checks that the files it read are every staged one.
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
    "conditional_store.mojo",
    "config.mojo",
    "errors.mojo",
    "inflight.mojo",
    "presign.mojo",
    "ranges.mojo",
    "s3_endpoint.mojo",
    "s3_fs.mojo",
    "s3_fs_jobs.mojo",
    "s3_fs_options.mojo",
    "store.mojo",
]


def test_no_environment_read() raises:
    var banned: List[String] = [
        "getenv",
        "_read_env",
        "std.os",
        "EnvSource",
        "ProcessEnv",
        "DefaultChainCredsSource",
        "aws_endpoint_config",
        "komira_libc",
        "external_call",
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
    assert_equal(_count(_read("config.mojo"), "\nstruct S3Config("), 1)
    assert_equal(_count(_read("store.mojo"), "\nstruct S3Store["), 1)
    assert_equal(_count(_read("conditional_store.mojo"), "\nstruct S3ConditionalStore["), 1)
    assert_equal(_count(_read("presign.mojo"), "\nstruct S3PresignSigner["), 1)
    assert_equal(_count(_read("s3_fs.mojo"), "\nstruct S3Fs["), 1)
    assert_equal(_count(_read("s3_endpoint.mojo"), "\ndef s3_prod_fs["), 1)
    assert_true(_read("store.mojo").byte_length() > 10000)


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_package()
    print("OK")
