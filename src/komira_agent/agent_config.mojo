# =============================================================================
# komira_agent/agent_config.mojo — the supervisor agent's startup config.
# =============================================================================
#
# The pod-side supervisor's configuration. Built from env in
# production (`from_env`), or by hand in tests. MVP scope:
#
#   * the job to run is a LOCAL binary path + argv (NOT an S3 object key —
#     binary-download from S3 is DEFERRED). The trivial-child e2e runs
#     `/bin/sh -c '...'` via `ChildSpec.shell`, but the prod shape is
#     `job_binary_path` + `job_argv`.
#   * the job-manager is reached by HOST + PORT (not a parsed URL) — the
#     heartbeat POST goes to `http://{host}:{port}/internal/heartbeat`, mirroring
#     `k8s_https_request_authed`'s host+port surface (the HttpClient parses a
#     dotted-quad / hostname directly, no URL-parse step).
#
# ENV CONTRACT (KOMIRA_AGENT_*):
#   KOMIRA_AGENT_JOB_ID             hyphenated job UUID            (REQUIRED)
#   KOMIRA_AGENT_POD_NAME           this pod's name                (REQUIRED)
#   KOMIRA_AGENT_JOB_BINARY         local path to the job binary   (REQUIRED)
#   KOMIRA_AGENT_JM_HOST            job-manager host               (default 127.0.0.1)
#   KOMIRA_AGENT_JM_PORT            job-manager port               (default 8081)
#   KOMIRA_AGENT_JM_SCHEME          `http` | `https`               (default http)
#   KOMIRA_AGENT_HEARTBEAT_SECS     heartbeat interval seconds     (default 5)
#   KOMIRA_AGENT_MAX_STDERR_LINES   stderr ring capacity           (default 100)
#   KOMIRA_AGENT_LOG_CHUNK_BYTES    streaming-log chunk threshold  (default 64 KiB)
#   KOMIRA_AGENT_LOG_FLUSH_SECS     streaming-log flush interval   (default 10s)
#
# DEPLOYMENT-REAL S3 surface (all OPTIONAL — when BINARY_S3_URI is unset the
# agent runs the LOCAL JOB_BINARY and skips the S3 download/upload entirely, so
# the in-process e2e keeps working):
#   KOMIRA_AGENT_BINARY_S3_URI      s3://bucket/<sha>/binary       (optional)
#   KOMIRA_AGENT_BINARY_SHA256      expected SHA-256 hex override  (optional)
#   KOMIRA_AGENT_LOG_BUCKET         bucket for crash-report+logs   (optional)
#   KOMIRA_AGENT_S3_ENDPOINT        S3 endpoint override (MinIO)   (optional)
#                                   ⚠ UNSET MEANS **REAL AWS S3**, which is
#                                   HTTPS-ONLY -- so absence selects TLS here,
#                                   it does not select plaintext.
#   KOMIRA_AGENT_S3_REGION          AWS region                     (default us-east-1)
#   (+ the AWS cred env the default chain reads: AWS_ACCESS_KEY_ID /
#    AWS_SECRET_ACCESS_KEY / AWS_WEB_IDENTITY_TOKEN_FILE / AWS_ROLE_ARN / ...)
#
# ENCAPSULATION + gap6: plain owned String / POD scalar fields; no UnsafePointer,
# no wildcard origin. The single getenv FFI cast is bounded inside komira_core
# posix's `_read_env`. Mojo 1.0.0b1.
# =============================================================================

from komira_core_ffi.posix import _read_env

# ★ THE JM AUTH POSTURE. Declared, not derived from the scheme --
# see `jm_auth.mojo`'s banner for why deriving breaks the AWS arm.
from komira_agent.jm_auth import (
    JmAuthMode,
    jm_audience,
    jm_credential_rides_in_clear,
    parse_jm_auth_mode,
)

# The two names the (scheme, posture) refusal in `from_env` has to cite. Each
# is ALSO the name `from_env` reads, so the refusal cannot name a variable the
# reader does not.
comptime _ENV_JM_SCHEME: StaticString = "KOMIRA_AGENT_JM_SCHEME"
comptime _ENV_JM_AUTH: StaticString = "KOMIRA_AGENT_JM_AUTH"


# =============================================================================
# §1 — env helpers (mirror job_manager_main's _env_or / _require_env).
# =============================================================================
def _agent_env_or(name: StaticString, default: String) -> String:
    """Return env `name`'s value, or `default` when unset/empty."""
    var v = _read_env(name)
    return v if v.byte_length() > 0 else default


def _agent_env_bool(name: StaticString) -> Bool:
    """Parse env `name` as a truthy boolean (DEFAULT FALSE). True iff the value
    (case-insensitive) is one of `1` / `true` / `yes` / `on`. Anything else —
    unset, empty, `0`, `false`, garbage — is False. Used for SUBLINEAGE_ENABLED
    (SUBLIN-KAFKA-FACE-ROLLOUT G1): the safe default is OFF, so only an explicit
    affirmative flips it on."""
    var v = _read_env(name)
    if v.byte_length() == 0:
        return False
    var lo = v.lower()
    return (
        lo == String("1")
        or lo == String("true")
        or lo == String("yes")
        or lo == String("on")
    )


def _agent_env_bool_default_true(name: StaticString) -> Bool:
    """Parse env `name` as a boolean whose DEFAULT (unset/empty) is TRUE.

    the SERVER-boundary
    sub-lineage flip. When `SUBLINEAGE_ENABLED` is UNSET (or empty) the server
    now defaults the sub-lineage path ON. The OFF-switch is PRESERVED: an
    explicit `0` / `false` / `no` / `off` (case-insensitive) disables it. Any
    explicit affirmative (`1` / `true` / `yes` / `on`) or unrecognized value
    leaves it ON (fail-safe to the new default).

    This is the SERVER boundary ONLY — the BrokerCore/KafkaDataBroker field
    initializers stay default-OFF, so code that constructs the data-plane
    structs DIRECTLY keeps the legacy OFF default. Only the env-derived
    `BrokerConfig.from_env()` server-construction path defaults ON."""
    var v = _read_env(name)
    if v.byte_length() == 0:
        return True  # unset/empty -> the new server default is ON
    var lo = v.lower()
    # Explicit OFF switch (preserved): only these disable.
    if (
        lo == String("0")
        or lo == String("false")
        or lo == String("no")
        or lo == String("off")
    ):
        return False
    # Any explicit affirmative OR unrecognized value -> ON (fail-safe default).
    return True


def _agent_require_env(name: StaticString, label: String) raises -> String:
    """Return env `name`'s value, or RAISE a clear "missing required config"
    error (fail-fast — a missing job_id must abort before spawn, not crash
    deep in the heartbeat path)."""
    var v = _read_env(name)
    if v.byte_length() == 0:
        raise Error(
            String("agent: missing required env var ")
            + String(name)
            + String(" (")
            + label
            + String(
                "). Set KOMIRA_AGENT_JOB_ID / KOMIRA_AGENT_POD_NAME /"
                " KOMIRA_AGENT_JOB_BINARY before starting the agent."
            )
        )
    return v^


# =============================================================================
# §2 — AgentConfig.
# =============================================================================
struct AgentConfig(Movable):
    """The supervisor agent configuration. MVP: a local job binary path + argv,
    a job-manager host+port to heartbeat, and the heartbeat cadence + stderr
    ring capacity.

      job_id              — hyphenated job UUID (the DB row the heartbeats
                            transition).
      pod_name            — this pod's name (echoed in every heartbeat).
      job_binary_path     — absolute local path to the job binary to spawn.
      job_argv            — argv[1:] for the job (argv[0] is the path).
      jm_host / jm_port   — the job-manager's /internal/heartbeat endpoint.
      heartbeat_interval_secs — seconds between periodic RUNNING heartbeats.
      max_stderr_lines    — the stderr ring capacity (last N lines kept).

      binary_s3_uri       — Some -> download from `s3://bucket/key` before
                            spawn; None -> run the LOCAL job_binary_path (the
                            MVP / in-process e2e path).
      binary_sha256       — Some -> verify the download against this hex digest
                            (else the key-embedded `<sha>/binary` segment).
      binary_download_path — where a downloaded binary is written (defaults to
                            job_binary_path so the download lands at the spawn
                            path).
      log_bucket          — Some -> upload crash-report + logs to this bucket
                            on terminal; None -> skip the S3 upload.
      s3_endpoint         — Some -> a custom S3 endpoint (MinIO/LocalStack);
                            None -> the AWS regional default.
      s3_region           — AWS region for signing (default us-east-1)."""

    var job_id: String
    var pod_name: String
    var job_binary_path: String
    var job_argv: List[String]
    var jm_host: String
    var jm_port: UInt16
    var heartbeat_interval_secs: Int
    var max_stderr_lines: Int
    var max_stdout_bytes: Int

    var binary_s3_uri: Optional[String]
    var binary_sha256: Optional[String]
    var binary_download_path: String
    var log_bucket: Optional[String]
    var s3_endpoint: Optional[String]
    var s3_region: String
    # Streaming-log-upload tunables. Appended at
    # the END of the field list + the __init__ signature, keyword-defaulted, so
    # no positional caller is disturbed (the prior mid-list insertion that broke
    # a positional caller is the cautionary tale — append + default, never mid).
    var log_chunk_bytes: Int
    var log_flush_secs: Int
    # ★ THE JOB-MANAGER URL **SCHEME**. `http` or `https`.
    #
    # ⛔ IT IS A FIELD BECAUSE IT WAS BEING DISCARDED. `build_pod_spec` splits the
    # scheduler's `job_manager_url` into HOST and PORT and threw the scheme away
    # (`pod_spec._split_url_host_port` strips `scheme://` and never returns it),
    # and `heartbeat_client` hardcoded `Url.http`. So no value of
    # `KOMIRA_JM_URL` -- not `https://...` -- could make this agent speak TLS,
    # which is what a Lambda-backed job manager behind API Gateway requires.
    #
    # Appended at the END of the field list + the `__init__` signature, keyword
    # -defaulted, per this struct's own standing note: the prior mid-list
    # insertion that broke a positional caller is the cautionary tale.
    var jm_scheme: String

    # ★ HOW THIS SUPERVISOR AUTHENTICATES TO THE JOB MANAGER.
    #
    # ⛔ IT IS A DECLARED POSTURE, NOT A DERIVED ONE, AND THE DEFAULT IS `none`.
    # Deriving it from `jm_scheme == https` would fix GCP with no deploy-side
    # edit, but an ECS Fargate task has no GCP metadata server -- a fail-closed
    # derive would red every AWS heartbeat, and a fail-open one would silently
    # send the beat bearer-less, re-creating exactly the never-beat-at-all /
    # beat-then-stopped ambiguity the heartbeat contract exists to remove.
    #
    # ⚠ DEFAULTING TO `none` MEANS THIS FIELD ALONE CHANGES NOTHING. Nothing
    # authenticates until the placement STAMPS KOMIRA_AGENT_JM_AUTH, which is
    # `komira_job_manager/pod_spec.mojo`'s job, not this file's.
    var jm_auth_mode: JmAuthMode

    # An explicit `aud` override. EMPTY means derive it from scheme/host/port,
    # which is correct for every Cloud Run service URL; the override exists for
    # a JM reached through a name that is not the one the token must be minted
    # for (a proxy, a custom domain).
    var jm_audience_override: String

    def __init__(
        out self,
        var job_id: String,
        var pod_name: String,
        var job_binary_path: String,
        var job_argv: List[String],
        var jm_host: String,
        jm_port: UInt16,
        heartbeat_interval_secs: Int,
        max_stderr_lines: Int,
        max_stdout_bytes: Int = 8 * 1024 * 1024,
        var binary_s3_uri: Optional[String] = Optional[String](),
        var binary_sha256: Optional[String] = Optional[String](),
        var binary_download_path: String = String(""),
        var log_bucket: Optional[String] = Optional[String](),
        var s3_endpoint: Optional[String] = Optional[String](),
        var s3_region: String = String("us-east-1"),
        log_chunk_bytes: Int = 64 * 1024,
        log_flush_secs: Int = 10,
        var jm_scheme: String = String("http"),
        jm_auth_mode: JmAuthMode = JmAuthMode.none(),
        var jm_audience_override: String = String(""),
    ):
        self.job_id = job_id^
        self.pod_name = pod_name^
        self.job_binary_path = job_binary_path^
        self.job_argv = job_argv^
        self.jm_host = jm_host^
        self.jm_port = jm_port
        self.heartbeat_interval_secs = heartbeat_interval_secs
        self.max_stderr_lines = max_stderr_lines
        # Cap the in-memory stdout capture (the post-exit logs.txt source). A
        # chatty job could produce unbounded stdout; we bound it to avoid an OOM
        # and note truncation in the captured log. 0 / negative => default 8 MiB.
        # (Streaming-to-S3-during-run is the deferred follow-on.)
        self.max_stdout_bytes = (
            max_stdout_bytes if max_stdout_bytes > 0 else 8 * 1024 * 1024
        )
        self.binary_s3_uri = binary_s3_uri^
        self.binary_sha256 = binary_sha256^
        # Default the download path to the spawn path so a downloaded binary
        # lands where the supervisor will exec it.
        if binary_download_path.byte_length() > 0:
            self.binary_download_path = binary_download_path^
        else:
            self.binary_download_path = self.job_binary_path
        self.log_bucket = log_bucket^
        self.s3_endpoint = s3_endpoint^
        self.s3_region = s3_region^
        # Streaming-log tunables. 0/neg => the LogStreamSink defaults
        # (64 KiB / 10s). flush_secs is whole seconds (mapped to ms in the sink).
        self.log_chunk_bytes = (
            log_chunk_bytes if log_chunk_bytes > 0 else 64 * 1024
        )
        self.log_flush_secs = log_flush_secs if log_flush_secs > 0 else 10
        # An unrecognised scheme is NOT silently coerced to plaintext: `https`
        # exactly (case-insensitively) selects TLS and anything else is `http`.
        # Coercing the other way would make a typo'd `htps://` dial in the clear
        # against a TLS port and report a transport error, which is the failure
        # this field exists to prevent.
        self.jm_scheme = (
            String("https") if jm_scheme.lower() == String("https")
            else String("http")
        )
        self.jm_auth_mode = jm_auth_mode
        self.jm_audience_override = jm_audience_override^

    def jm_uses_tls(self) -> Bool:
        """True iff the heartbeat POST must go over TLS -- i.e. the scheduler's
        `job_manager_url` was an `https://` URL.

        ⛔ THE DEFAULT IS PLAINTEXT AND THAT IS DELIBERATE, unlike `s3_uses_tls`
        below. An ABSENT S3 endpoint means real AWS (HTTPS-only, so absence
        implies TLS); an absent JM scheme means the in-cluster / in-process
        heartbeat seam, which is plain HTTP by design and is what every
        functional test drives."""
        return self.jm_scheme == String("https")

    def jm_auth_audience(self) -> String:
        """The `aud` the JM credential must be minted for.

        ★ DERIVED BY DEFAULT, WHICH IS WHY THE ORDINARY CASE NEEDS NO NEW DEPLOY
        SURFACE. `jm_audience` renders the JM's own service base URL and OMITS a
        default port -- Google validates an ID token's `aud` against
        `https://job-manager-....run.app`, with no `:443`, and a token minted
        for `https://host:443` is REJECTED at the ingress edge in a way the
        agent cannot tell apart from having sent no token at all."""
        if self.jm_audience_override.byte_length() > 0:
            return self.jm_audience_override
        return jm_audience(self.jm_scheme, self.jm_host, self.jm_port)

    def s3_uses_tls(self) -> Bool:
        """True iff the S3 transport must be TLS.

        ★ ABSENCE MEANS TLS HERE, AND GETTING THAT BACKWARDS IS THE WHOLE BUG.
        `AgentS3Client` maps a None endpoint onto `S3Config.aws(region)`
        -- virtual-hosted, **HTTPS**, the AWS regional host. So an agent with no
        endpoint override is already building `https://` URLs; before this method
        existed it dialled them through a `KernelTcpConnector` on port 443 and
        sent a plaintext GET into a TLS listener. Defaulting to plaintext here
        would preserve exactly that.

        An explicit endpoint carries its own scheme (`http://minio:9000` ->
        plaintext, `https://...` -> TLS), which `AgentS3Client` already honours for
        the URL and now honours for the TRANSPORT too."""
        if not self.s3_endpoint.__bool__():
            return True  # real AWS S3: HTTPS-only.
        var ep = self.s3_endpoint.value()
        return ep.lower().startswith(String("https://"))

    def uses_s3_binary(self) -> Bool:
        """True iff an S3 binary URI is configured (download-then-spawn);
        False -> run the local job_binary_path (the MVP / in-process e2e
        path)."""
        return self.binary_s3_uri.__bool__()

    @staticmethod
    def from_env() raises -> AgentConfig:
        """Build the config from KOMIRA_AGENT_* env (the deploy surface).
        job_id / pod_name / job_binary are REQUIRED (fail-fast); host / port /
        cadence / ring-size are defaulted. argv is read as a single
        space-joined KOMIRA_AGENT_JOB_ARGV (MVP — no shell quoting; the prod
        job is a single binary path with simple positional args)."""
        var job_id = _agent_require_env(
            "KOMIRA_AGENT_JOB_ID", String("job uuid")
        )
        var pod_name = _agent_require_env(
            "KOMIRA_AGENT_POD_NAME", String("pod name")
        )
        var job_binary = _agent_require_env(
            "KOMIRA_AGENT_JOB_BINARY", String("job binary path")
        )
        var host = _agent_env_or(
            "KOMIRA_AGENT_JM_HOST", String("127.0.0.1")
        )
        # ★ THE SCHEME IS READ BEFORE THE PORT BECAUSE THE PORT'S DEFAULT
        # DEPENDS ON IT, AND GETTING THAT ORDER WRONG WAS A LIVE DEFECT.
        #
        # ⛔ THE BUG THIS REPLACES. The default was a flat `8081` regardless of
        # scheme. `pod_spec._split_url_host_port` returns an EMPTY port for a
        # URL that carries none -- and a Cloud Run URL
        # (`https://job-manager-....run.app`) carries none -- so a correctly
        # `https`-schemed agent dialled `https://host:8081` while Cloud Run
        # serves 443. TLS was threaded correctly and the port was still wrong,
        # which is the worst shape: the transport decision LOOKS right in every
        # log line and the connection goes nowhere.
        var jm_scheme = _agent_env_or(_ENV_JM_SCHEME, String("http"))
        var port_raw = _read_env("KOMIRA_AGENT_JM_PORT")
        var port_s = port_raw
        if port_raw.byte_length() == 0:
            # `http` keeps TODAY'S 8081 exactly, so every in-cluster manifest
            # renders byte-identically; only the https case changes.
            port_s = (
                String("443") if jm_scheme.lower() == String("https")
                else String("8081")
            )
        # ★ THE AUTH POSTURE. Absent => `none` => byte-identical to the
        # agent from before the auth seam. ⛔ `parse_jm_auth_mode` RAISES on a typo rather
        # than falling back to `none`: a misspelled posture that silently
        # degraded would beat bearer-less into a 403 forever while every log
        # line said the agent was healthy. Refusing here surfaces it at boot.
        var jm_auth_mode = parse_jm_auth_mode(_read_env(_ENV_JM_AUTH))
        # Absent => derive from scheme/host/port (the ordinary Cloud Run case).
        var jm_audience_override = _read_env("KOMIRA_AGENT_JM_AUDIENCE")

        var hb_s = _agent_env_or("KOMIRA_AGENT_HEARTBEAT_SECS", String("5"))
        var ring_s = _agent_env_or(
            "KOMIRA_AGENT_MAX_STDERR_LINES", String("100")
        )
        var stdout_bytes_s = _agent_env_or(
            "KOMIRA_AGENT_MAX_STDOUT_BYTES", String("8388608")  # 8 MiB
        )

        var port = atol(port_s)
        if port <= 0 or port > 65535:
            raise Error(
                String("agent: KOMIRA_AGENT_JM_PORT out of range: ") + port_s
            )
        var hb = atol(hb_s)
        if hb <= 0:
            hb = 5
        var ring = atol(ring_s)
        if ring <= 0:
            ring = 100
        var stdout_bytes = atol(stdout_bytes_s)
        if stdout_bytes <= 0:
            stdout_bytes = 8 * 1024 * 1024

        # MVP argv: a single space-split env (no shell quoting). Empty when
        # unset — most jobs are a bare binary path.
        var argv = List[String]()
        var argv_raw = _read_env("KOMIRA_AGENT_JOB_ARGV")
        if argv_raw.byte_length() > 0:
            var cur = String("")
            var bytes = argv_raw.as_bytes()
            for i in range(len(bytes)):
                var c = bytes[i]
                if c == UInt8(0x20):  # space
                    if cur.byte_length() > 0:
                        argv.append(cur)
                        cur = String("")
                else:
                    cur += chr(Int(c))
            if cur.byte_length() > 0:
                argv.append(cur)

        # ---- DEPLOYMENT-REAL S3 surface (all optional) ----
        var binary_s3_uri = Optional[String]()
        var s3_uri_raw = _read_env("KOMIRA_AGENT_BINARY_S3_URI")
        if s3_uri_raw.byte_length() > 0:
            binary_s3_uri = Optional[String](s3_uri_raw^)
        var binary_sha = Optional[String]()
        var sha_raw = _read_env("KOMIRA_AGENT_BINARY_SHA256")
        if sha_raw.byte_length() > 0:
            binary_sha = Optional[String](sha_raw^)
        var log_bucket = Optional[String]()
        var lb_raw = _read_env("KOMIRA_AGENT_LOG_BUCKET")
        if lb_raw.byte_length() > 0:
            log_bucket = Optional[String](lb_raw^)
        var s3_endpoint = Optional[String]()
        var ep_raw = _read_env("KOMIRA_AGENT_S3_ENDPOINT")
        if ep_raw.byte_length() > 0:
            s3_endpoint = Optional[String](ep_raw^)
        var s3_region = _agent_env_or(
            "KOMIRA_AGENT_S3_REGION", String("us-east-1")
        )

        # Streaming-log tunables (defaults: 64 KiB / 10s). 0/neg falls back
        # to the default inside __init__.
        var chunk_bytes_s = _agent_env_or(
            "KOMIRA_AGENT_LOG_CHUNK_BYTES", String("65536")  # 64 KiB
        )
        var flush_secs_s = _agent_env_or(
            "KOMIRA_AGENT_LOG_FLUSH_SECS", String("10")
        )
        var chunk_bytes = atol(chunk_bytes_s)
        if chunk_bytes <= 0:
            chunk_bytes = 64 * 1024
        var flush_secs = atol(flush_secs_s)
        if flush_secs <= 0:
            flush_secs = 10

        var cfg = AgentConfig(
            job_id^,
            pod_name^,
            job_binary^,
            argv^,
            host^,
            UInt16(port),
            Int(hb),
            Int(ring),
            Int(stdout_bytes),
            binary_s3_uri^,
            binary_sha^,
            String(""),  # binary_download_path defaults to job_binary_path
            log_bucket^,
            s3_endpoint^,
            s3_region^,
            log_chunk_bytes=Int(chunk_bytes),
            log_flush_secs=Int(flush_secs),
            jm_scheme=jm_scheme^,
            jm_auth_mode=jm_auth_mode,
            jm_audience_override=jm_audience_override^,
        )
        # ⛔ (plaintext, credential) IS REFUSED AT BOOT. Asked of
        # the BUILT config, through `jm_uses_tls()` -- the same predicate the
        # beat's transport is chosen by -- so this refusal and the send site
        # cannot read the scheme two ways. `send_heartbeat_blocking` also
        # refuses per beat; this says it once, at the cause.
        if jm_credential_rides_in_clear(cfg.jm_uses_tls(), cfg.jm_auth_mode):
            raise Error(
                String("agent: REFUSED ")
                + String(_ENV_JM_AUTH)
                + String("='")
                + cfg.jm_auth_mode.name()
                + String("' over a PLAINTEXT job manager (")
                + String(_ENV_JM_SCHEME)
                + String("='")
                + cfg.jm_scheme
                + String(
                    "'; absent means http). Every heartbeat would mint a"
                    " Google-signed ID token and send it in the clear, for an"
                    " http:// audience Cloud Run does not serve. Set "
                )
                + String(_ENV_JM_SCHEME)
                + String("=https for a Cloud Run job manager, or clear ")
                + String(_ENV_JM_AUTH)
                + String(" for a plaintext in-cluster one.")
            )
        return cfg^


# =============================================================================
# §3 — BrokerConfig — the co-located broker NODE's startup config (M6F-1).
# =============================================================================
struct BrokerConfig(Movable):
    """The BROKER-NODE process configuration (BROKER-M6-FOLLOWON M6F-1). The
    broker is a never-exiting Kafka-over-S3 server that ALSO runs its OWN
    broker-heartbeat loop to the job-manager coordinator: each tick it reports
    (node_id / load / owned_partitions) and applies the coordinator's
    `assigned_partitions[]` reply in-process (D1, the relay) — REPLACING the M6
    `--assignment=` CLI-arg channel. The container/k8s supervisor handles process
    restart; this is NOT launched by the generic agent.mojo child-supervisor (an
    impedance mismatch — that supervises jobs-that-EXIT).

      node_id            — this node's stable broker id (the heartbeat key + the
                           Kafka broker node id). Reported on every heartbeat.
      listen_port        — the Kafka listen port (0 => kernel-ephemeral).
      topic              — the topic this cluster serves (M6: a single topic).
      num_partitions     — P (total partition count).
      cluster            — the cluster id (the S3 prefix + the assignment key).
      bucket             — the S3 bucket the segment store + manifests live in.
      s3_endpoint        — the S3 endpoint (MinIO/LocalStack) — REQUIRED in the
                           container stack (no AWS regional default there).
      s3_region          — AWS region for SigV4 signing (default us-east-1).
      jm_host / jm_port  — the coordinator's broker-heartbeat endpoint
                           (http://{host}:{port}/internal/heartbeat).
      heartbeat_interval_secs — seconds between broker heartbeats.
      advertised_host    — the host this broker advertises in its Kafka Metadata
                           response (what a client + peers route back to). In a
                           CONTAINER stack this MUST be the broker's reachable
                           service-DNS / container hostname (e.g. `broker-1`),
                           NOT 127.0.0.1 (the container's own loopback,
                           unreachable from peers). Default 127.0.0.1 (the
                           same-host / single-node back-compat shape). When set,
                           the broker binds 0.0.0.0 (all interfaces) instead of
                           loopback so cross-container connections are accepted."""

    var node_id: Int
    var listen_port: UInt16
    var topic: String
    var num_partitions: Int
    var cluster: String
    var bucket: String
    var s3_endpoint: String
    var s3_region: String
    var jm_host: String
    var jm_port: UInt16
    var heartbeat_interval_secs: Int
    var advertised_host: String
    # BROKER-PERF-CORE-SCALING: the number of share-nothing serve workers
    # (per-core pthreads) the broker spawns. Each worker accepts on the SHARED
    # listening fd (POSIX prefork on macOS; SO_REUSEPORT would be the Linux
    # path) and runs its OWN serve_multiplexed_step loop over its OWN
    # connections + its OWN server clone — so a slow S3 op on one worker no
    # longer head-of-line-blocks the whole node, and throughput scales with
    # cores by overlapping N independent S3 round-trips. Default 1 (the
    # single-threaded back-compat shape — byte-identical to the prior serial
    # serve loop).
    var serve_workers: Int
    # the server-boundary
    # sub-lineage flag. The SERVER default is now TRUE via from_env() (which
    # reads SUBLINEAGE_ENABLED through _agent_env_bool_default_true): unset/empty
    # => ON; the OFF-switch is PRESERVED — an explicit SUBLINEAGE_ENABLED=
    # 0/false/no/off disables it. The struct FIELD/ctor default stays FALSE (and
    # every bind_* default stays FALSE): only from_env() defaults ON, so code
    # that constructs the data-plane structs DIRECTLY keeps the legacy OFF
    # default. When False the live Kafka server's topic-registration path makes
    # ZERO enable_sublineage_* calls and behavior is byte-identical to the
    # legacy path.
    var sublineage_default: Bool

    def __init__(
        out self,
        node_id: Int,
        listen_port: UInt16,
        var topic: String,
        num_partitions: Int,
        var cluster: String,
        var bucket: String,
        var s3_endpoint: String,
        var s3_region: String,
        var jm_host: String,
        jm_port: UInt16,
        heartbeat_interval_secs: Int,
        var advertised_host: String = String("127.0.0.1"),
        serve_workers: Int = 1,
        sublineage_default: Bool = False,
    ):
        self.node_id = node_id
        self.listen_port = listen_port
        self.topic = topic^
        self.num_partitions = num_partitions
        self.cluster = cluster^
        self.bucket = bucket^
        self.s3_endpoint = s3_endpoint^
        self.s3_region = s3_region^
        self.jm_host = jm_host^
        self.jm_port = jm_port
        self.heartbeat_interval_secs = heartbeat_interval_secs
        self.advertised_host = advertised_host^
        self.serve_workers = serve_workers
        self.sublineage_default = sublineage_default

    @staticmethod
    def from_env() raises -> BrokerConfig:
        """Build the broker-node config from KOMIRA_BROKER_* env (the deploy
        surface — the container stack's ENV contract). node_id / bucket / cluster
        / s3_endpoint are REQUIRED (fail-fast); listen-port / topic / partitions
        / jm-host / jm-port / heartbeat-cadence are defaulted.

        ENV CONTRACT (KOMIRA_BROKER_*):
          KOMIRA_BROKER_NODE_ID         broker node id (int)           (REQUIRED)
          KOMIRA_BROKER_S3_BUCKET       S3 bucket                      (REQUIRED)
          KOMIRA_BROKER_CLUSTER         cluster id (S3 prefix + key)   (REQUIRED)
          KOMIRA_BROKER_S3_ENDPOINT     S3 endpoint (MinIO)            (REQUIRED)
          KOMIRA_BROKER_LISTEN_PORT     Kafka listen port              (default 0 / ephemeral)
          KOMIRA_BROKER_TOPIC           topic name                     (default komira-data)
          KOMIRA_BROKER_PARTITIONS      P                              (default 6)
          KOMIRA_BROKER_S3_REGION       AWS region                     (default us-east-1)
          KOMIRA_BROKER_JM_HOST         coordinator host               (default 127.0.0.1)
          KOMIRA_BROKER_JM_PORT         coordinator port               (default 8082)
          KOMIRA_BROKER_HEARTBEAT_SECS  heartbeat interval seconds     (default 5)
          KOMIRA_BROKER_ADVERTISED_HOST Metadata-advertised host       (default 127.0.0.1;
                                        set to the container service name in the
                                        multi-node stack so peers/clients route
                                        back correctly + the broker binds 0.0.0.0)
          KOMIRA_BROKER_SERVE_WORKERS   # of share-nothing serve workers  (default 1;
                                        BROKER-PERF-CORE-SCALING — N per-core
                                        pthreads accepting on the shared
                                        listener fd, each its own serve loop +
                                        server clone; throughput scales with
                                        cores by overlapping N S3 round-trips.
                                        1..64; out-of-range -> 1)
        """
        var node_id_s = _agent_require_env(
            "KOMIRA_BROKER_NODE_ID", String("broker node id")
        )
        var bucket = _agent_require_env(
            "KOMIRA_BROKER_S3_BUCKET", String("S3 bucket")
        )
        var cluster = _agent_require_env(
            "KOMIRA_BROKER_CLUSTER", String("cluster id")
        )
        var s3_endpoint = _agent_require_env(
            "KOMIRA_BROKER_S3_ENDPOINT", String("S3 endpoint")
        )

        var node_id = atol(node_id_s)
        if node_id < 0:
            raise Error(
                String("broker: KOMIRA_BROKER_NODE_ID must be >= 0 (got ")
                + node_id_s
                + String(")")
            )

        var listen_port_s = _agent_env_or(
            "KOMIRA_BROKER_LISTEN_PORT", String("0")
        )
        var listen_port = atol(listen_port_s)
        if listen_port < 0 or listen_port > 65535:
            raise Error(
                String("broker: KOMIRA_BROKER_LISTEN_PORT out of range: ")
                + listen_port_s
            )

        var topic = _agent_env_or(
            "KOMIRA_BROKER_TOPIC", String("komira-data")
        )
        var parts_s = _agent_env_or("KOMIRA_BROKER_PARTITIONS", String("6"))
        var parts = atol(parts_s)
        if parts <= 0:
            raise Error(
                String("broker: KOMIRA_BROKER_PARTITIONS must be >= 1 (got ")
                + parts_s
                + String(")")
            )

        var s3_region = _agent_env_or(
            "KOMIRA_BROKER_S3_REGION", String("us-east-1")
        )
        var jm_host = _agent_env_or(
            "KOMIRA_BROKER_JM_HOST", String("127.0.0.1")
        )
        var jm_port_s = _agent_env_or("KOMIRA_BROKER_JM_PORT", String("8082"))
        var jm_port = atol(jm_port_s)
        if jm_port <= 0 or jm_port > 65535:
            raise Error(
                String("broker: KOMIRA_BROKER_JM_PORT out of range: ")
                + jm_port_s
            )
        var hb_s = _agent_env_or("KOMIRA_BROKER_HEARTBEAT_SECS", String("5"))
        var hb = atol(hb_s)
        if hb <= 0:
            hb = 5

        var advertised_host = _agent_env_or(
            "KOMIRA_BROKER_ADVERTISED_HOST", String("127.0.0.1")
        )

        # BROKER-PERF-CORE-SCALING: the number of share-nothing serve workers
        # (per-core pthreads). Default 1 (single-threaded back-compat). A garbage
        # / out-of-range value falls back to 1 rather than failing the boot.
        var workers_s = _agent_env_or("KOMIRA_BROKER_SERVE_WORKERS", String("1"))
        var workers = atol(workers_s)
        if workers < 1 or workers > 64:
            print(
                String("broker: KOMIRA_BROKER_SERVE_WORKERS '")
                + workers_s
                + String("' out of range [1, 64]; using default 1")
            )
            workers = 1

        # the server-boundary
        # sub-lineage flag — now DEFAULT TRUE at the SERVER boundary. When
        # SUBLINEAGE_ENABLED is unset/empty the live Kafka server runs the
        # sub-lineage (disjoint-shard) path; the OFF-switch is PRESERVED —
        # SUBLINEAGE_ENABLED=0/false/no/off still disables it. This inversion is
        # PURELY at the server config boundary: the BrokerCore/KafkaDataBroker
        # field initializers + every bind_* default stay OFF, so tests/code that
        # construct the data-plane structs DIRECTLY keep the legacy OFF default.
        var sublineage_default = _agent_env_bool_default_true("SUBLINEAGE_ENABLED")

        return BrokerConfig(
            node_id=Int(node_id),
            listen_port=UInt16(listen_port),
            topic=topic^,
            num_partitions=Int(parts),
            cluster=cluster^,
            bucket=bucket^,
            s3_endpoint=s3_endpoint^,
            s3_region=s3_region^,
            jm_host=jm_host^,
            jm_port=UInt16(jm_port),
            heartbeat_interval_secs=Int(hb),
            advertised_host=advertised_host^,
            serve_workers=Int(workers),
            sublineage_default=sublineage_default,
        )
