# The package reads no environment: every setting is an S3Config field or a
# type parameter (the credential source, the clock), where the earlier S3
# layer read environment variables for its signing clock, its in-flight
# bound and its MinIO endpoint (named below). The package's sources are staged as this test's
# data, at src/<file>; the test reads each one and fails if any names a way
# to read the environment or the FFI a read would go through.
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
    "presign.mojo",
    "ranges.mojo",
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
        "komira_core_ffi",
        "external_call",
        "S3_AMZ_DATE",
        "S3_SHORT_DATE",
        "PREFETCH_MAX_INFLIGHT",
        "MINIO_E2E_",
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
    # Not vacuous: each file is the package's, whole.
    assert_equal(_count(_read("config.mojo"), "\nstruct S3Config("), 1)
    assert_equal(_count(_read("store.mojo"), "\nstruct S3Store["), 1)
    assert_equal(_count(_read("conditional_store.mojo"), "\nstruct S3ConditionalStore["), 1)
    assert_equal(_count(_read("presign.mojo"), "\nstruct S3PresignSigner["), 1)
    assert_true(_read("store.mojo").byte_length() > 10000)


def main() raises:
    test_no_environment_read()
    test_the_scan_saw_the_package()
    print("OK")
