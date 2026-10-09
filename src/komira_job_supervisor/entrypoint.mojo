# =============================================================================
# komira_job_supervisor/entrypoint.mojo: the supervisor as a container
# entrypoint (the `job_supervisor_main` binary).
# =============================================================================
#
# A container whose entrypoint is this binary runs one job and beats its state
# to a configured endpoint over https, authenticated by a bearer credential,
# with the job's logs written to a Google Cloud Storage prefix. It takes
# exactly these flags, all `--name=value`, and nothing else (an unknown flag,
# a repeated one, a bare word before `--` are refused before anything runs):
#
#   --job-name=NAME                   sent in every heartbeat (REQUIRED)
#   --instance-name=NAME              sent in every heartbeat (default empty)
#   --heartbeat-url=URL               where heartbeats are POSTed (REQUIRED);
#                                     https only, because every beat carries
#                                     the credential (an http URL is refused)
#   --heartbeat-credential-file=PATH  the bearer token is this file, re-read
#                                     for every beat (bearer_auth.mojo)
#   --heartbeat-credential-env=NAME   the bearer token is this environment
#                                     variable, read once at start and then
#                                     removed from the environment, so the
#                                     job does not inherit it
#                                     (exactly one of the two is REQUIRED)
#   --heartbeat-interval-secs=N       seconds between RUNNING beats (default 5)
#   --max-runtime-secs=N              the job is stopped after N seconds and
#                                     reported FAILED with a timeout message
#                                     (REQUIRED, at least 1)
#   --log-prefix=gs://BUCKET/PREFIX   logs.txt, crash_report.json and the live
#                                     stdout chunks go under PREFIX in BUCKET
#                                     (REQUIRED; gs:// only)
#   --job-binary=PATH|NAME            the job (REQUIRED). A name without a `/`
#                                     is looked up on PATH, as a shell or
#                                     execvp(3) does (an empty PATH entry is
#                                     skipped, never read as the current
#                                     directory); a path with a `/` is used as
#                                     given. Either must name an executable
#                                     file, checked before the first beat.
#   -- ARG...                         the job's arguments, verbatim: anything
#                                     after the first bare `--`, a word that
#                                     begins with `--` included, is the job's.
#
# The credential is the one value that is not a flag: it is secret material,
# and argv is world-readable. The provider-standard variables the log store's
# credential search reads (GOOGLE_APPLICATION_CREDENTIALS and the metadata
# server's) are left in the environment, and the job inherits them.
#
# ORDER AT START: parse and check every flag; resolve the job binary; build
# the credential (the env form is read and removed here, before any spawn);
# build the heartbeat reporter (refuses a credential over plaintext); build
# the log store (resolves the storage credential, so a host with none refuses
# to start); then `run_job_supervisor`. Each refusal raises naming the flag,
# never a credential, and nothing has been beaten or spawned.
#
# EXIT STATUS (`run_entrypoint`): 0 when the job COMPLETED, 1 when it FAILED
# or was CANCELLED, 2 when the start was refused.
#
# No pointer type crosses this file's surface.
# =============================================================================

from komira_gcp_core import (
    AdcFetcher,
    AdcOptions,
    CachingTokenSource,
    GcpConnectorTransport,
    SystemWallClock,
    application_default_token_source,
)
from komira_http_client.client import HttpClientConfig
from komira_http_client.tls_connector import (
    TlsConnector,
    build_public_ca_tls_connector,
)
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_libc.posix import _path_is_executable, _read_env
from komira_objectstore_gcs import (
    GcsConditionalStore,
    GcsStorageBackend,
    GcsTlsConnector,
    StorageGrpcBackend,
    build_gcs_tls_connector,
)
from komira_retry import SystemClock

from komira_job_supervisor.bearer_auth import BearerHeartbeatAuth
from komira_job_supervisor.heartbeat_client import HttpHeartbeatReporter
from komira_job_supervisor.job_supervisor import run_job_supervisor
from komira_job_supervisor.job_supervisor_config import (
    FLAG_HEARTBEAT_INTERVAL_SECS,
    FLAG_HEARTBEAT_URL,
    FLAG_INSTANCE_NAME,
    FLAG_JOB_BINARY,
    FLAG_JOB_NAME,
    FLAG_LOG_PREFIX,
    FLAG_MAX_RUNTIME_SECS,
    JobSupervisorConfig,
    scan_flags,
)
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase


comptime FLAG_HEARTBEAT_CREDENTIAL_FILE: StaticString = "--heartbeat-credential-file"
comptime FLAG_HEARTBEAT_CREDENTIAL_ENV: StaticString = "--heartbeat-credential-env"

comptime GCS_LOG_SCHEME: StaticString = "gs://"

comptime GCS_READ_WRITE_SCOPE: StaticString = (
    "https://www.googleapis.com/auth/devstorage.read_write"
)
"""The OAuth scope the log store's token is minted for."""

comptime EXIT_COMPLETED: Int = 0
comptime EXIT_JOB_FAILED: Int = 1
comptime EXIT_REFUSED: Int = 2


def entrypoint_flag_names() -> List[String]:
    """Every flag the entrypoint takes; any other is refused."""
    var out = List[String]()
    out.append(String(FLAG_JOB_NAME))
    out.append(String(FLAG_INSTANCE_NAME))
    out.append(String(FLAG_HEARTBEAT_URL))
    out.append(String(FLAG_HEARTBEAT_CREDENTIAL_FILE))
    out.append(String(FLAG_HEARTBEAT_CREDENTIAL_ENV))
    out.append(String(FLAG_HEARTBEAT_INTERVAL_SECS))
    out.append(String(FLAG_MAX_RUNTIME_SECS))
    out.append(String(FLAG_LOG_PREFIX))
    out.append(String(FLAG_JOB_BINARY))
    return out^


# =============================================================================
# §1: the log location.
# =============================================================================
struct LogLocation(Copyable, Movable):
    """Where the job's logs go: `bucket` and the object-key `key_prefix`
    under it, from a `gs://BUCKET/PREFIX` flag value."""

    var bucket: String
    var key_prefix: String

    def __init__(out self, var bucket: String, var key_prefix: String):
        self.bucket = bucket^
        self.key_prefix = key_prefix^


def parse_log_location(value: String) raises -> LogLocation:
    """`gs://BUCKET/PREFIX` -> (BUCKET, PREFIX). Refuses any other scheme,
    an empty bucket and an empty prefix; one trailing `/` is dropped."""
    var flag = String(FLAG_LOG_PREFIX)
    if not value.startswith(String(GCS_LOG_SCHEME)):
        raise Error(
            String("job supervisor: ")
            + flag
            + String(" must be gs://BUCKET/PREFIX (no other store is supported)")
        )
    var b = value.as_bytes()
    var start = String(GCS_LOG_SCHEME).byte_length()
    var slash = -1
    for i in range(start, len(b)):
        if b[i] == UInt8(0x2F):
            slash = i
            break
    if slash < 0 or slash == start:
        raise Error(
            String("job supervisor: ")
            + flag
            + String(" names no bucket and prefix (gs://BUCKET/PREFIX)")
        )
    var end = len(b)
    if end > slash + 1 and b[end - 1] == UInt8(0x2F):
        end -= 1
    if end <= slash + 1:
        raise Error(
            String("job supervisor: ") + flag + String(" has an empty object prefix")
        )
    return LogLocation(
        String(StringSlice(unsafe_from_utf8=b[start:slash])),
        String(StringSlice(unsafe_from_utf8=b[slash + 1 : end])),
    )


# =============================================================================
# §2: the job binary.
# =============================================================================
def resolve_job_binary(binary: String, search_path: String) raises -> String:
    """The file the job is spawned from. A `binary` holding a `/` is used as
    given; a bare name is looked up in each non-empty `:`-separated entry of
    `search_path` in order (the first executable regular file wins). Raises,
    naming --job-binary, when nothing executable is found."""
    var flag = String(FLAG_JOB_BINARY)
    if binary.byte_length() == 0:
        raise Error(String("job supervisor: ") + flag + String(" is empty"))
    if binary.find(String("/")) >= 0:
        if not _path_is_executable(binary):
            raise Error(
                String("job supervisor: ")
                + flag
                + String(" ")
                + binary
                + String(" is not an executable file")
            )
        return binary
    var b = search_path.as_bytes()
    var dir_start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == UInt8(0x3A):
            if i > dir_start:
                var dir = String(StringSlice(unsafe_from_utf8=b[dir_start:i]))
                var candidate = dir + String("/") + binary
                if _path_is_executable(candidate):
                    return candidate
            dir_start = i + 1
    raise Error(
        String("job supervisor: ")
        + flag
        + String(" ")
        + binary
        + String(" was not found as an executable on PATH")
    )


# =============================================================================
# §3: the configuration.
# =============================================================================
struct EntrypointConfig(Movable):
    """The entrypoint's parsed flags (module header): the supervisor's
    config (its log prefix is the key prefix of `log`), where the credential
    comes from, and where the logs go."""

    var job: JobSupervisorConfig
    var credential_file: Optional[String]
    var credential_env: Optional[String]
    var log: LogLocation

    def __init__(
        out self,
        var job: JobSupervisorConfig,
        var credential_file: Optional[String],
        var credential_env: Optional[String],
        var log: LogLocation,
    ):
        self.job = job^
        self.credential_file = credential_file^
        self.credential_env = credential_env^
        self.log = log^

    @staticmethod
    def from_args(args: List[String]) raises -> EntrypointConfig:
        """Parse `args` (without the program name). Refuses any flag the
        entrypoint does not take, a missing credential, both credentials, a
        missing maximum runtime and a log prefix that is not gs://."""
        var f = scan_flags(args, entrypoint_flag_names())
        var cred_file = f.get(String(FLAG_HEARTBEAT_CREDENTIAL_FILE))
        var cred_env = f.get(String(FLAG_HEARTBEAT_CREDENTIAL_ENV))
        if cred_file and cred_env:
            raise Error(
                String("job supervisor: give one of ")
                + String(FLAG_HEARTBEAT_CREDENTIAL_FILE)
                + String(" and ")
                + String(FLAG_HEARTBEAT_CREDENTIAL_ENV)
                + String(", not both")
            )
        if not cred_file and not cred_env:
            raise Error(
                String("job supervisor: the heartbeat needs a credential: give ")
                + String(FLAG_HEARTBEAT_CREDENTIAL_FILE)
                + String("= or ")
                + String(FLAG_HEARTBEAT_CREDENTIAL_ENV)
                + String("=")
            )
        if cred_file and cred_file.value().byte_length() == 0:
            raise Error(
                String("job supervisor: ")
                + String(FLAG_HEARTBEAT_CREDENTIAL_FILE)
                + String(" is empty")
            )
        if cred_env and cred_env.value().byte_length() == 0:
            raise Error(
                String("job supervisor: ")
                + String(FLAG_HEARTBEAT_CREDENTIAL_ENV)
                + String(" is empty")
            )
        _ = f.require(String(FLAG_MAX_RUNTIME_SECS))
        var log = parse_log_location(f.require(String(FLAG_LOG_PREFIX)))

        var others = List[String]()
        others.append(String(FLAG_HEARTBEAT_CREDENTIAL_FILE))
        others.append(String(FLAG_HEARTBEAT_CREDENTIAL_ENV))
        var job = JobSupervisorConfig.from_args(args, others)
        job.log_prefix = log.key_prefix.copy()
        return EntrypointConfig(job^, cred_file^, cred_env^, log^)

    def into_job(deinit self) -> JobSupervisorConfig:
        """The supervisor's config, consuming this one."""
        return self.job^

    def heartbeat_auth(self) raises -> BearerHeartbeatAuth:
        """The bearer conformer the flags name. The env form reads the
        variable and removes it from the environment, here."""
        if self.credential_file:
            return BearerHeartbeatAuth.from_file(self.credential_file.value())
        return BearerHeartbeatAuth.from_env(self.credential_env.value())


# =============================================================================
# §4: the log store.
# =============================================================================
comptime EntrypointAdcTokenSource = CachingTokenSource[
    AdcFetcher[
        GcpConnectorTransport[KernelTcpConnector],
        GcpConnectorTransport[TlsConnector[KernelTcpConnector]],
        SystemWallClock,
    ],
    SystemClock,
]
"""The storage credential: Application Default Credentials."""

comptime EntrypointGcsBackend = StorageGrpcBackend[
    GcsTlsConnector, EntrypointAdcTokenSource, SystemClock
]
"""The production log-store backend: google.storage.v2 over gRPC."""


def _mk_plain() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


def _mk_token_tls() raises -> TlsConnector[KernelTcpConnector]:
    return build_public_ca_tls_connector(String("oauth2.googleapis.com"))


def _make_gcs_backend() raises -> EntrypointGcsBackend:
    """A backend over public-CA TLS whose token comes from Application
    Default Credentials, searched now."""
    var scopes = List[String]()
    scopes.append(String(GCS_READ_WRITE_SCOPE))
    var http = HttpClientConfig.defaults()
    var tokens = application_default_token_source[
        KernelTcpConnector, TlsConnector[KernelTcpConnector]
    ](http, _mk_plain, _mk_token_tls, AdcOptions(scopes^))
    return EntrypointGcsBackend(
        build_gcs_tls_connector(), tokens^, SystemClock(), http
    )


def gcs_log_store[
    B: GcsStorageBackend,
](
    log: LogLocation, var backend: B, make_backend: def () raises thin -> B
) -> GcsConditionalStore[B]:
    """The log store for `log`: its bucket over `backend` (a clone builds its
    own with `make_backend`)."""
    return GcsConditionalStore[B](log.bucket.copy(), backend^, make_backend)


# =============================================================================
# §5: the run.
# =============================================================================
def start_and_run(args: List[String]) raises -> JobSupervisorPhase:
    """Parse, check and build everything in the order the module header
    states, then run the job to its end. Raises only before the job is
    spawned."""
    var cfg = EntrypointConfig.from_args(args)
    # PATH is on komira_libc.posix's allow-list for exactly this: exec-path
    # lookup of a bare --job-binary.
    cfg.job.job_binary_path = resolve_job_binary(
        cfg.job.job_binary_path, _read_env("PATH")
    )
    cfg.job.binary_download_path = cfg.job.job_binary_path.copy()
    var auth = cfg.heartbeat_auth()
    var reporter = HttpHeartbeatReporter[BearerHeartbeatAuth](
        cfg.job.heartbeat_url, auth^
    )
    var store = gcs_log_store[EntrypointGcsBackend](
        cfg.log, _make_gcs_backend(), _make_gcs_backend
    )
    return run_job_supervisor[
        HttpHeartbeatReporter[BearerHeartbeatAuth],
        GcsConditionalStore[EntrypointGcsBackend],
    ](
        cfg^.into_job(),
        reporter^,
        None,
        Optional[GcsConditionalStore[EntrypointGcsBackend]](store^),
    )


def exit_status_of(phase: JobSupervisorPhase) -> Int:
    """0 for COMPLETED, 1 for FAILED or CANCELLED."""
    if phase == JobSupervisorPhase.completed():
        return EXIT_COMPLETED
    return EXIT_JOB_FAILED


def run_entrypoint(args: List[String]) -> Int:
    """The binary's whole life: the exit status (module header). A refusal
    is printed on stderr."""
    try:
        return exit_status_of(start_and_run(args))
    except e:
        print(String(e), file=FileDescriptor(2))
        return EXIT_REFUSED
