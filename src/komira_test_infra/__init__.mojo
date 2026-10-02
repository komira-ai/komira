"""`komira_test_infra` -- tests that use a real object store and clean up
after themselves.

A test opens a `TestBucket`: a private prefix `<run_prefix><run_id>/` in an
object store, with a lease object written first. The test (or the program it
runs, through `as_flags()`) works under that prefix, then calls `close()`,
which deletes everything, lists again to prove it, and returns a `Verdict`:
CLEAN (0), CANNOT_TELL (3) or LEAK (6). `leak_check` asks the same question
of a run id from outside the run.

Two backends, both opt-in by flag:
  * EXTERNAL_S3: an S3-compatible endpoint described by a `TestInfraConfig`
    file (`--testinfra-s3-config=<path>`); this library holds none of its
    values;
  * EMBEDDED_MINIO: a MinIO server, pinned by sha256, that the test itself
    starts on 127.0.0.1 (`--testinfra-minio-binary=<path>`).
With no flags (the default, on any machine with no infrastructure) the test
ends with SKIP and a reason (`exit_skip`, which exits 77 itself), never a
pass and never a guess at an endpoint.

The object store and the process launcher are seams (`ObjectStoreClient`,
`ProcessRunner`), with in-memory fakes; real clients live in adapter
packages. See each module's header.
"""

from .bucket import (
    BACKEND_EXTERNAL_S3,
    BACKEND_EMBEDDED_MINIO,
    LEASE_OBJECT,
    UNCLOSED_HANDLE_MARKER,
    TestBucket,
    lease_text,
    open_test_bucket,
)
from .config import TestInfraConfig, load_test_infra_config, parse_test_infra_config
from .flags import (
    BACKEND_CHOICE_CANNOT_TELL,
    BACKEND_CHOICE_EXTERNAL_S3,
    BACKEND_CHOICE_EMBEDDED_MINIO,
    BACKEND_CHOICE_SKIP,
    BackendChoice,
    TestInfraFlags,
    select_backend,
)
from .leak_check import leak_check
from .embedded_minio import (
    MINIO_BUCKET,
    MINIO_HOST,
    MINIO_REGION,
    MINIO_RUN_PREFIX,
    credentials_file_text,
    open_embedded_minio_test_bucket,
)
from .minio_pins import MinioPin, current_minio_platform, minio_server_pins, pinned_sha256_for
from .process import (
    READINESS_EXITED,
    READINESS_READY,
    READINESS_TIMEOUT,
    EnvEntry,
    NoProcess,
    ProcessRunner,
    ProcessSpec,
    Readiness,
    ScriptedProcessRunner,
)
from .run_id import RunId, mint_run_id
from .seams import (
    Entropy,
    FileSource,
    FixedWallClock,
    MapFiles,
    ProcessFiles,
    ScriptedEntropy,
    SystemClock,
    UrandomEntropy,
    WallClock,
)
from .skip import SKIP_EXIT_CODE, SKIP_MARKER, exit_skip, skip_line
from .store import FakeObjectStore, ObjectStoreClient, StoreTarget
from .verdict import (
    VERDICT_CANNOT_TELL,
    VERDICT_CLEAN,
    VERDICT_LEAK,
    Verdict,
    verdict_kind_name,
)
