"""`komira_test_infra` -- tests that use a real object store and clean up
after themselves.

A test opens a `TestBucket`: a private prefix `<run_prefix><run_id>/` in an
object store, with a lease object written first. The test (or the program it
runs, through `as_flags()`) works under that prefix, then calls `close()`,
which deletes everything, lists again to prove it, and returns a `Verdict`:
CLEAN (0), CANNOT_TELL (3) or LEAK (6). `leak_check` asks the same question
of a run id from outside the run.

Two backends:
  * the shared store a deployment describes in a `TestInfraConfig` file
    (`--testinfra-config=<path>`); this library holds none of its values;
  * a local MinIO, pinned by sha256, started inside the test on 127.0.0.1
    (`--testinfra-local-minio=<path>`), for machines without the shared store.
With neither, the test ends with SKIP and a reason (`exit_skip`, which
exits 77 itself), never a pass.

The object store and the process launcher are seams (`ObjectStoreClient`,
`ProcessRunner`), with in-memory fakes; real clients live in adapter
packages. See each module's header.
"""

from .bucket import (
    BACKEND_FARM,
    BACKEND_LOCAL,
    LEASE_OBJECT,
    UNCLOSED_HANDLE_MARKER,
    TestBucket,
    lease_text,
    open_test_bucket,
)
from .config import TestInfraConfig, load_test_infra_config, parse_test_infra_config
from .flags import (
    BACKEND_CHOICE_CANNOT_TELL,
    BACKEND_CHOICE_FARM,
    BACKEND_CHOICE_LOCAL,
    BACKEND_CHOICE_SKIP,
    BackendChoice,
    TestInfraFlags,
    select_backend,
)
from .leak_check import leak_check
from .local_backend import (
    LOCAL_BUCKET,
    LOCAL_HOST,
    LOCAL_REGION,
    LOCAL_RUN_PREFIX,
    credentials_file_text,
    open_local_test_bucket,
)
from .local_minio_pins import MinioPin, current_minio_platform, local_minio_pins, pinned_sha256_for
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
