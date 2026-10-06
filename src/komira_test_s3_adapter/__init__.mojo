"""`komira_test_s3_adapter` -- the real adapters behind komira_test_bucket's
and komira_test_minio's seams.

`MinioObjectStore` is komira_test_bucket's `ObjectStoreClient` over
komira_objectstore_s3's `S3Store` (path-style, plaintext, credential from
the target's shared-credentials file). `SpawnedProcessRunner` is
komira_test_minio's `ProcessRunner` over komira_supervisor's
`spawn_detached` (Linux, PR_SET_PDEATHSIG through setpriv, readiness from
MinIO's health endpoint). `open_embedded_minio_test_bucket` opens a run's
bucket on an embedded MinIO from the test binary's flags with both.
"""

from .object_store import (
    KernelMinioObjectStore,
    MinioObjectStore,
    create_bucket_status_ok,
    minio_object_store,
    read_credential_file,
)
from .open import MinioTestBucket, open_embedded_minio_test_bucket, scratch_root
from .runner import (
    EMPTY_ENV_MARKER,
    MINIO_HEALTH_PATH,
    SETPRIV,
    SpawnedProcessRunner,
    child_env_for,
    exit_status_of,
    readiness_exit_code,
    minio_health_live,
    minio_health_request,
    shell_argv_for,
)
