# =============================================================================
# komira_job_supervisor/tests/e2e/job_supervisor_minio_e2e.mojo -- what the
# supervisor's MinIO end-to-end tests share: the opening of the run's test
# bucket from the test's flags, and the supervisor's own S3 store on that
# bucket.
# =============================================================================
#
# The real process runner and object-store client are komira_test_s3_adapter's
# (`SpawnedProcessRunner`, `MinioObjectStore`); this file holds only what is
# the job supervisor's.
#
# `open_job_supervisor_test_bucket()` is komira_test_s3_adapter's
# `open_embedded_minio_test_bucket`: no flag is SKIP (exit 77), and anything
# but `--test-minio-binary` is CANNOT_TELL (exit 3), because these tests run
# the job supervisor against an embedded MinIO only. A test ends with
# `close()`, which deletes the run's prefix, lists it again to prove it
# empty, and stops the server; `require_clean()` turns a verdict that is not
# CLEAN into a failure.
#
# `point_job_supervisor_at()` makes the AWS default chain the supervisor's S3
# store builds find the embedded server's credential: AWS_SHARED_CREDENTIALS_FILE
# names its credentials file, AWS_CONFIG_FILE an empty file, and every
# variable that would win over the file (several hold credentials) is
# removed through komira_libc's `_unset_env`. The supervisor is the
# code under test, so its credential takes the path any other caller's takes.
# `supervisor_store()` is that store (s3_store.mojo's `make_s3_store`), and
# `SilentReporter` stands in for a heartbeat endpoint: these tests drive the
# supervisor's steps and send no heartbeat.
# =============================================================================

from std.ffi import external_call
from std.os import remove
from std.os.path import exists

from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_libc.posix import _unset_env
from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisor,
    SupervisorS3Store,
    SupervisorHeartbeat,
    make_s3_store,
)
from komira_test_s3_adapter import MinioTestBucket, open_embedded_minio_test_bucket


def sleep_ms(ms: Int):
    """usleep: this binary links komira_async, whose reactor declares its own
    nanosleep, so std's time.sleep would not legalize."""
    if ms <= 0:
        return
    # FFI-BOUNDARY: usleep takes a by-value microsecond count; there is no
    # pointer and nothing to own or free.
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def text_of(bytes: List[UInt8]) -> String:
    """The bytes as a String, byte for byte (no decoding)."""
    return String(unsafe_from_utf8=Span(bytes))


# =============================================================================
# §1 -- opening the run's bucket on the embedded MinIO.
# =============================================================================
comptime JobSupervisorTestBucket = MinioTestBucket


def open_job_supervisor_test_bucket(target_label: String) raises -> JobSupervisorTestBucket:
    """The run's bucket on the embedded MinIO the flags name; SKIP (77) with
    no flags, CANNOT_TELL (3) for any other store (module header)."""
    return open_embedded_minio_test_bucket(
        target_label, String("the job supervisor's MinIO end-to-end suite")
    )


# =============================================================================
# §2 -- pointing the job supervisor at the run's bucket.
# =============================================================================
def _setenv(name: String, value: String):
    """libc setenv (the test's own process)."""
    var n = name
    var v = value
    # FFI-BOUNDARY: setenv borrows the two NUL-terminated buffers `n` and `v`
    # own for the call and copies them; nothing is retained or freed. The
    # `_ = n` / `_ = v` below keep both alive until the call has returned.
    _ = external_call["setenv", Int32](
        n.as_c_string_slice().unsafe_ptr(), v.as_c_string_slice().unsafe_ptr(), Int32(1)
    )
    _ = n
    _ = v


def point_job_supervisor_at(bucket: JobSupervisorTestBucket) raises:
    """Make the AWS default chain the supervisor's store builds find the
    embedded server's credential, and nothing else (module header)."""
    var gone: List[String] = [
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_PROFILE",
        "AWS_DEFAULT_PROFILE",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "AWS_ROLE_ARN",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
    ]
    for i in range(len(gone)):
        _unset_env(gone[i])
    _setenv("AWS_SHARED_CREDENTIALS_FILE", bucket.credentials_file())
    _setenv("AWS_CONFIG_FILE", "/dev/null")
    _setenv("AWS_EC2_METADATA_DISABLED", "true")


def remove_if_present(path: String):
    if exists(path):
        try:
            remove(path)
        except:
            pass


# =============================================================================
# §3 -- the supervisor's side: its S3 store on the run's bucket, and a
# reporter that sends nothing.
# =============================================================================
struct SilentReporter(HeartbeatReporter):
    """Counts heartbeats and delivers none."""

    var beats: Int

    def __init__(out self):
        self.beats = 0

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        self.beats += 1
        return HeartbeatOutcome(True, False, 200)


def _mk_plain() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


comptime E2eStore = SupervisorS3Store[KernelTcpConnector]
comptime E2eSupervisor = JobSupervisor[SilentReporter, E2eStore]


def supervisor_store(bucket: JobSupervisorTestBucket) raises -> E2eStore:
    """The supervisor's own S3 store on the run's bucket, as
    `run_job_supervisor_on_s3` builds it."""
    return make_s3_store[KernelTcpConnector](
        _mk_plain, bucket.bucket(), bucket.region(), Optional[String](bucket.endpoint())
    )
