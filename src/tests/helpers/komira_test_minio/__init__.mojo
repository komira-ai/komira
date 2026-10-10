"""`komira_test_minio` -- an embedded MinIO server the test starts itself.

`start_embedded_minio` checks the binary against a sha256 pin, makes a
private (0700) temporary directory with a random root credential in 0600
files, starts the server on random loopback-only ports with
`die_with_parent`, and hands back an `EmbeddedMinio`: its endpoint, region
and the PATH of an AWS shared-credentials file, and a `stop()` that stops
the server, removes the directory and returns a `Verdict`.

This package creates no bucket and knows no object-store client;
komira_test_bucket builds a run-scoped bucket on top of it. The process
launcher is a seam (`ProcessRunner`) with a scripted fake; a real runner
lives in an adapter package.
"""

from .minio_pins import (
    MinioPin,
    binary_sha256,
    current_minio_platform,
    minio_server_pins,
    pinned_sha256_for,
)
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
from .server import (
    MINIO_HOST,
    MINIO_REGION,
    UNSTOPPED_SERVER_MARKER,
    EmbeddedMinio,
    credentials_file_text,
    start_embedded_minio,
    start_embedded_minio_with_pins,
)
