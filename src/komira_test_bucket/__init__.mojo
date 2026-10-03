"""`komira_test_bucket` -- a run-scoped prefix in an S3-compatible store that
cleans up after itself and proves it.

A test opens a `TestBucket`: a private prefix `runs/<run_id>/` in an object
store, with a lease object written first. The test (or the program it runs,
through `as_flags()`) works under that prefix, then calls `close()`, which
deletes everything, lists again to prove it, and returns a `Verdict`: CLEAN
(0), CANNOT_TELL (3) or LEAK (6). `leak_check` asks the same question of a
run id from outside the run.

Two stores, both opt-in by flag (flags.mojo; configuration is flags, there
is no configuration file):
  * an external S3-compatible store (`--test-s3-endpoint`, `-region`,
    `-bucket`, `-credentials-file`, all or none), whose bucket must already
    exist and is never created or deleted; this package holds none of its
    values;
  * an embedded MinIO, pinned by sha256, that the test itself starts on
    127.0.0.1 (`--test-minio-binary`, komira_test_minio). The bucket handle
    owns it and stops it in `close()`, after the final re-list.
With no flags (the default, on any machine with no infrastructure) the test
ends with SKIP and a reason (exit 77), never a pass and never a guess at an
endpoint.

The object store is a seam (`ObjectStoreClient`) with an in-memory fake; a
real client lives in an adapter package. See each module's header.
"""

from .bucket import (
    BACKEND_EMBEDDED_MINIO,
    BACKEND_EXTERNAL_S3,
    EMBEDDED_BUCKET,
    LEASE_OBJECT,
    UNCLOSED_HANDLE_MARKER,
    TestBucket,
    lease_text,
    open_embedded_minio_bucket,
    open_test_bucket,
)
from .flags import (
    BACKEND_CHOICE_CANNOT_TELL,
    BACKEND_CHOICE_EMBEDDED_MINIO,
    BACKEND_CHOICE_EXTERNAL_S3,
    BACKEND_CHOICE_SKIP,
    DEFAULT_MAX_LEASE_SECONDS,
    DEFAULT_TEARDOWN_BUDGET_SECONDS,
    FLAG_MAX_LEASE_SECONDS,
    FLAG_MINIO_BINARY,
    FLAG_S3_BUCKET,
    FLAG_S3_CREDENTIALS_FILE,
    FLAG_S3_ENDPOINT,
    FLAG_S3_REGION,
    FLAG_TARGET,
    FLAG_TEARDOWN_BUDGET_SECONDS,
    BackendChoice,
    TestStoreFlags,
    open_test_bucket_from_flags,
    select_backend,
)
from .leak_check import leak_check
from .store import RUN_PREFIX, FakeObjectStore, ObjectStoreClient, StoreScope, StoreTarget
