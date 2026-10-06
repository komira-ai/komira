# =============================================================================
# komira_test_s3_adapter/open.mojo -- opening a run's test bucket on an
# embedded MinIO from the test binary's own flags, with the real adapters.
# =============================================================================
#
# `open_embedded_minio_test_bucket(target_label, suite)` reads the process's
# flags (komira_test_bucket's `TestStoreFlags`) and acts on the choice: no
# flag is SKIP (exit 77), and anything but `--test-minio-binary` is
# CANNOT_TELL (exit 3), because a suite that uses it runs on an embedded
# MinIO only; `suite`, a singular noun phrase ("the job supervisor's MinIO
# end-to-end suite"), names that suite in the CANNOT_TELL reason. It mints
# the run id, starts the pinned server under `scratch_root()` with a
# `SpawnedProcessRunner`, and opens the bucket with a `MinioObjectStore`.
#
# This reads argv, may end the process and starts a server, so the welded
# tests do not call it; the opt-in MinIO end-to-end binaries that use it do.
# =============================================================================

from komira_libc.posix import _read_env
from komira_test_bucket import (
    BACKEND_CHOICE_EMBEDDED_MINIO,
    FLAG_MINIO_BINARY,
    TestBucket,
    TestStoreFlags,
    open_test_bucket_from_flags,
    select_backend,
)
from komira_test_run_id import SystemClock, UrandomEntropy, mint_run_id
from komira_test_verdict import exit_cannot_tell

from .object_store import KernelMinioObjectStore, minio_object_store
from .runner import SpawnedProcessRunner


comptime MinioTestBucket = TestBucket[KernelMinioObjectStore, SpawnedProcessRunner]
"""A run's test bucket on an embedded MinIO this process started."""


def scratch_root() -> String:
    """TEST_TMPDIR under a test runner, else TMPDIR, else /tmp."""
    var t = _read_env("TEST_TMPDIR")
    if t.byte_length() == 0:
        t = _read_env("TMPDIR")
    if t.byte_length() == 0:
        t = String("/tmp")
    return t^


def open_embedded_minio_test_bucket(target_label: String, suite: String) raises -> MinioTestBucket:
    """The run's bucket on the embedded MinIO the flags name; SKIP (77) with
    no flags, CANNOT_TELL (3) for any other store (module header)."""
    var flags = TestStoreFlags.from_process_args()
    if flags.target.byte_length() == 0:
        flags.target = target_label
    var choice = select_backend(flags)
    choice.exit_unless_runnable()
    if choice.kind != BACKEND_CHOICE_EMBEDDED_MINIO:
        exit_cannot_tell(
            suite
            + " runs on an embedded MinIO only; give "
            + FLAG_MINIO_BINARY
            + " and no --test-s3-* flag"
        )
    var clock = SystemClock()
    var entropy = UrandomEntropy()
    var run_id = mint_run_id(clock, entropy)
    return open_test_bucket_from_flags(
        choice,
        run_id,
        scratch_root(),
        minio_object_store(),
        SpawnedProcessRunner(),
        entropy,
        clock,
    )
