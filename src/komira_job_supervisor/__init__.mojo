"""`komira_job_supervisor`: a generic job supervisor.

It runs one job (a local binary, or one fetched from an object store and
SHA-256 verified), heartbeats its state while it runs, stops it on a cancel,
and when it exits classifies the result (COMPLETED / FAILED / CANCELLED),
reports it with failure forensics, and writes the job's logs and crash
report to an object store.

WHAT THE EMBEDDING BINARY SUPPLIES:
  * the configuration: `JobSupervisorConfig.from_args` (command-line flags;
    no environment variables);
  * a `HeartbeatReporter`: where heartbeats go. `HttpHeartbeatReporter[A]`
    ships: one HTTP(S) POST per beat to `--heartbeat-url`, authenticated by
    a `HeartbeatAuth` conformer `A`; `NoHeartbeatAuth` ships. A credential
    scheme is the embedding binary's own `HeartbeatAuth` conformer;
  * optionally, the binary store and the log store: any komira_objectstore
    `ConditionalWriteStore`. `s3_store` builds S3 / S3-compatible ones from
    flags (`S3StoreFlags`, `run_job_supervisor_on_s3`).

THE ENTRYPOINT: `run_entrypoint` (entrypoint.mojo) is the whole of the
`job_supervisor_main` binary: exactly the flags its header lists, a bearer
credential from a file re-read per beat or from an environment variable read
once and removed (`BearerHeartbeatAuth`), a maximum runtime, and the logs
under a `gs://` prefix (komira_objectstore_gcs).

The heartbeat wire is the generated `komira.job_report.v1` `JobHeartbeat` /
`JobHeartbeatReply` messages (komira_job_report_proto) in protobuf binary.

PUBLIC SURFACE:
  JobSupervisorConfig, scan_flags, FlagValues, job_supervisor_flag_names
  JobSupervisorPhase, JobSupervisorState, FailureReport
  SupervisorHeartbeat, HeartbeatOutcome, HeartbeatReporter,
    HttpHeartbeatReporter, encode_heartbeat, decode_cancel,
    build_heartbeat_request, parse_heartbeat_url,
    HEARTBEAT_STATUS_AUTH_UNAVAILABLE, HEARTBEAT_STATUS_AUTH_REFUSED
  HeartbeatAuth, NoHeartbeatAuth, credential_rides_in_clear
  BearerHeartbeatAuth, bearer_token_length
  EntrypointConfig, LogLocation, parse_log_location, resolve_job_binary,
    gcs_log_store, entrypoint_flag_names, start_and_run, run_entrypoint,
    exit_status_of, EntrypointGcsBackend
  JobSupervisor[R, S], run_job_supervisor
  download_binary, expected_sha_from_key
  upload_logs, upload_crash_report, build_crash_report_json
  LogStreamSink
  S3StoreFlags, SupervisorS3Store, make_s3_store, run_job_supervisor_on_s3,
    s3_store_flag_names

The Supervisor (komira_supervisor) encapsulates every fd, pipe and pid; this
package's surface is typed values. No pointer type crosses a boundary.
"""

from .job_supervisor_config import (
    JobSupervisorConfig,
    FlagValues,
    scan_flags,
    job_supervisor_flag_names,
    is_sha256_hex,
)
from .job_supervisor_state import (
    JobSupervisorPhase,
    JobSupervisorState,
    FailureReport,
)
from .heartbeat_auth import (
    HeartbeatAuth,
    NoHeartbeatAuth,
    credential_rides_in_clear,
)
from .heartbeat_client import (
    SupervisorHeartbeat,
    HeartbeatOutcome,
    HeartbeatReporter,
    HttpHeartbeatReporter,
    HEARTBEAT_STATUS_AUTH_UNAVAILABLE,
    HEARTBEAT_STATUS_AUTH_REFUSED,
    encode_heartbeat,
    decode_cancel,
    build_heartbeat_request,
    parse_heartbeat_url,
)
from .job_supervisor import JobSupervisor, run_job_supervisor
from .bearer_auth import BearerHeartbeatAuth, bearer_token_length
from .entrypoint import (
    EntrypointConfig,
    EntrypointGcsBackend,
    LogLocation,
    entrypoint_flag_names,
    exit_status_of,
    gcs_log_store,
    parse_log_location,
    resolve_job_binary,
    run_entrypoint,
    start_and_run,
)
from .boot import download_binary, expected_sha_from_key
from .upload import (
    upload_crash_report,
    upload_logs,
    build_crash_report_json,
)
from .log_streamer import LogStreamSink
from .s3_store import (
    S3StoreFlags,
    SupervisorS3Store,
    make_s3_store,
    run_job_supervisor_on_s3,
    s3_store_flag_names,
)
