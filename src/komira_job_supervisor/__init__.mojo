"""`komira_job_supervisor`: the job supervisor, the process a job manager places
next to a job.

It downloads the job binary, spawns it, heartbeats the job manager (driving
its ASSIGNED -> RUNNING -> COMPLETED/FAILED/CANCELLED state machine), acts on
a cancel, and on child exit analyses the result and sends a terminal
heartbeat with failure forensics.

It composes existing libraries:
  * komira_supervisor (Supervisor / ChildSpec / ExitInfo): the process spawn,
    two-pipe capture, SIGTERM -> grace -> SIGKILL terminate and waitpid reap.
  * komira_http_client / komira_http_core: the heartbeat POST, over plain TCP
    or TLS as `JobSupervisorConfig.jm_uses_tls()` decides.
  * komira_supervisor_proto: the generated `komira.supervisor.v1`
    SupervisorHeartbeat / HeartbeatResponse / FailureReport messages, encoded
    to protobuf binary with komira_proto_codec.
  * komira_objectstore_s3 over the generated komira_aws_s3 client, with
    komira_aws_core's default credential chain: the S3 binary download, the
    live log stream and the terminal upload (s3_client.mojo).

PUBLIC SURFACE:
  JobSupervisorConfig         startup config (job_id / pod_name / job binary / jm host
                              + port / cadence), with `from_env()`.
  JobSupervisorState          the loop's working state (phase / progress / message /
                              failure / cancel_requested).
  JobSupervisorPhase          the four job-supervisor-reported phases (RUNNING / COMPLETED /
                              FAILED / CANCELLED).
  FailureReport               the FAILED-heartbeat forensics.
  SupervisorHeartbeat / HeartbeatOutcome: the heartbeat value + POST result.
  encode_heartbeat            encode the heartbeat to protobuf binary via the
                              generated SupervisorHeartbeat (the wire contract).
  send_heartbeat[RT] / send_heartbeat_blocking: the heartbeat transport.
  JobSupervisor[C]            the supervisor state machine, generic over the S3
                              transport (`PlainJobSupervisor` / `TlsJobSupervisor` are the two
                              instantiations), with stepping methods a same-process
                              test can interleave with a job manager.
  run_job_supervisor(config)  the continuous blocking run loop (the production path).
                              Picks the S3 transport from `config.s3_uses_tls()` and
                              calls `run_job_supervisor_over[C]`.
  JobSupervisorS3Client[C]    the job supervisor's S3 verbs (s3_client.mojo).
  download_binary / make_s3_client_from_chain / parse_s3_uri: the S3
                              job-binary fetch (GET + SHA verify + chmod 0o755).
  upload_crash_report / upload_logs / build_crash_report_json: the terminal
                              S3 forensics write (crash_report.json + logs.txt).
  LogStreamSink               stdout in 64 KiB / 10 s chunks, PUT to
                              `{log_bucket}/{job_id}/chunks/{n}.log` while the job
                              runs (best effort: one retry, then drop).
  amz_stamps_now              system clock -> SigV4 (amz_date, short_date) stamps.

Not done here: a reactor-driven stderr drain (stderr is the last-N forensics
ring, drained after exit), and a separate stderr stream.

ENCAPSULATION: the Supervisor encapsulates every fd/pipe/pid; the job supervisor
surface is typed scalars and Strings. No UnsafePointer crosses a boundary; no
wildcard-origin field.
"""

from .job_supervisor_config import JobSupervisorConfig

# the co-located broker NODE's startup config (read
# from KOMIRA_BROKER_* env). The broker process runs its OWN broker-heartbeat
# loop to the coordinator; this is the deploy surface for that process.
from .job_supervisor_config import BrokerConfig
from .job_supervisor_state import JobSupervisorPhase, JobSupervisorState, FailureReport
# ★ THE JM AUTH SEAM — how a supervisor in a customer container
# authenticates to an IAM-gated job manager. `jm_auth_headers` returns HEADERS
# (not a token) computed from the request, so the AWS SigV4 arm — which signs
# method+path+body and emits three headers — lands as one more match arm with
# no caller reshape.
from .jm_auth import (
    JmAuthMode,
    JmTokenMinter,
    GcpMetadataMinter,
    parse_jm_auth_mode,
    jm_audience,
    jm_auth_headers,
    # The one (transport, posture) pair that is never allowed: a credential
    # over plaintext. Every refusal of it asks this.
    jm_credential_rides_in_clear,
)
from .heartbeat_client import (
    SupervisorHeartbeat,
    HeartbeatOutcome,
    # The supervisor could not obtain a credential -- DISTINCT from status 0
    # ("never connected"), because a bad image and a network blip must never
    # share a code path.
    HEARTBEAT_STATUS_AUTH_UNAVAILABLE,
    # The declared posture would have sent a credential over PLAINTEXT, so the
    # beat was refused before the mint and before the dial.
    HEARTBEAT_STATUS_AUTH_REFUSED,
    encode_heartbeat,
    decode_cancel,
    build_job_supervisor_jm_tls_connector,
    send_heartbeat,
    send_heartbeat_blocking,
    send_heartbeat_blocking_with_minter,
    # the broker-node heartbeat: reports
    # node_id/load/owned_partitions + decodes the assignment reply.
    BrokerHeartbeatOutcome,
    send_broker_heartbeat_blocking,
    # BROKER-KEEPALIVE-REUSE — the heartbeat over a caller-held
    # long-lived client+reactor (per-tick connection reuse, no re-dial storm).
    send_broker_heartbeat_over,
    # the job-supervisor-facing cluster routing map projection.
    BrokerClusterView,
    BrokerEndpointView,
    PartitionLeaderView,
)
from .job_supervisor import JobSupervisor, PlainJobSupervisor, TlsJobSupervisor, run_job_supervisor, run_job_supervisor_over
from .boot import (
    download_binary,
    make_s3_client_from_chain,
    make_s3_client_over,
    make_tls_s3_client_from_chain,
    mk_job_supervisor_s3_plain_connector,
    mk_job_supervisor_s3_tls_connector,
    parse_s3_uri,
    expected_sha_from_key,
    S3Uri,
)
from .upload import (
    upload_crash_report,
    upload_logs,
    build_crash_report_json,
)
from .log_streamer import LogStreamSink
from .clock_helper import amz_stamps_now, amz_stamps_from_unix_ms, AmzStamps
