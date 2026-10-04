# =============================================================================
# komira_agent/heartbeat_client.mojo — the agent -> job-manager heartbeat POST.
# =============================================================================
#
# The supervisor agent's heartbeat transport: builds the proto3-JSON
# `SupervisorHeartbeat` body the job-manager's `heartbeat_handler`
# (`parse_heartbeat_body` / `_failure_from_json`) parses, POSTs it to
# `http://{host}:{port}/internal/heartbeat` over the shared `komira_http_client`
# `HttpClient`, and parses the `{cancel}` JSON response.
#
# ★ THE TRANSPORT IS A PARAMETER, NOT A CONSTANT. This file used to
# say "plain TCP via `KernelTcpConnector` — the control plane is in-cluster
# HTTP, NOT TLS in the MVP", and it hardcoded BOTH halves: the connector type in
# the signature AND `Url.http` in the body. That is a deploy-topology assumption
# baked into a transport, and it is false the moment the job manager is a Lambda
# behind API Gateway. No job-manager URL could reach such an endpoint.
#
# `send_heartbeat` is now `[RT, C: Connector]`-parametric and takes the URL
# scheme as an argument; `send_heartbeat_blocking` is the ONE place that decides
# both, so the connector and the scheme cannot disagree — a `TlsConnector`
# dialling an `http://` URL, or a `KernelTcpConnector` dialling `https://`, are
# each unrepresentable rather than merely discouraged.
#
# WIRE SHAPE: the body is the
# GENERATED `komira.supervisor.v1.SupervisorHeartbeat` message (`komira_supervisor_proto`)
# encoded to PROTOBUF-BINARY via `komira_proto_codec.encode_proto`, POSTed with
# `Content-Type: application/protobuf`. The job-manager's handler `decode_proto`s
# it back, and the `{cancel}` reply is the generated `HeartbeatResponse` message
# encoded to protobuf-binary, which the agent `decode_proto`s for the cancel bit.
#
# WHY protobuf-binary (was proto3-JSON): the SAME `.proto` (supervisor.proto) that
# defines the messages defines the wire, and BOTH sides drive the generated
# Mojo structs through the one `komira_proto_codec` codec (no hand-rolled JSON
# projection / hand-written parser to drift). The agent's own `AgentPhase` /
# `FailureReport` value types are mapped onto the generated message here.
#
# DRIVE MODEL (mirrors k8s_tls.k8s_https_request_authed): `send_heartbeat[RT]`
# is `[RT]`-parametric over the runtime/reactor (so a future production agent
# can park the POST on a shared reactor); `send_heartbeat_blocking` is the SYNC
# ESCAPE — it stands up a `BlockingRuntime[NoopSink]` on the calling thread and
# drives the `[RT]` path, exactly the reactor-free single-shot control-plane
# shape the k8s pod client + job-manager service use. The agent run loop calls
# the `_blocking` entry (single-threaded MVP loop).
#
# RESILIENCE: a network failure (connect refused, EOF) is caught and surfaced as
# a `HeartbeatOutcome` with `ok=False` — the loop LOGS + backs off and NEVER
# interrupts the child. A heartbeat is best-effort; losing one must not kill the
# job.
#
# ENCAPSULATION + gap6: value-typed surface — a SupervisorHeartbeat value struct
# in, a HeartbeatOutcome (ok + cancel + status) out. No UnsafePointer crosses any
# boundary; the HttpClient owns all body accumulation on its reactor-park path
# (no borrow held across the park). Mojo 1.0.0b1.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import BytesBody
from komira_http_client.client import (
    HttpClient,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderEntry, HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_POST, HttpMethod
from komira_http_client.tls_connector import (
    TlsConnector,
    build_unpinned_public_ca_tls_connector,
)
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_proto_codec import encode_proto, decode_proto

# The GENERATED supervisor/broker proto messages. Aliased so the
# agent-facing `SupervisorHeartbeat` value struct below does not collide with
# the generated wire message — the agent builds the value struct, then projects
# it onto `PbSupervisorHeartbeat` for the wire.
from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
    FailureReport as PbFailureReport,
    JobPhase as PbJobPhase,
)
from komira_broker_proto.broker import (
    NodeLoad as PbNodeLoad,
    ClusterConfig as PbClusterConfig,
    BrokerClusterMap as PbBrokerClusterMap,
)

from komira_agent.agent_state import AgentPhase, FailureReport

# ★ THE JM AUTH SEAM. `jm_auth_headers` returns the headers one
# job-manager request must carry under the DECLARED posture -- an EMPTY list
# under `none` (byte-identical to this file's request before the auth seam), a
# `Bearer <oidc-id-token>` under `gcp_metadata`. It RAISES rather than
# degrading, which is why `send_heartbeat_blocking` below has an explicit
# AUTH_UNAVAILABLE outcome instead of falling back to a bearer-less POST.
from komira_agent.jm_auth import (
    GcpMetadataMinter,
    JmAuthMode,
    JmTokenMinter,
    jm_auth_headers,
    jm_credential_rides_in_clear,
)

import komira_log as log
from komira_log import ArgStr


# =============================================================================
# §1 — SupervisorHeartbeat — the value the agent sends.
# =============================================================================
struct SupervisorHeartbeat(Movable):
    """One supervisor heartbeat. The agent builds this from its AgentState +
    config each cycle; the JSON builder below projects it onto the wire shape
    the handler parses.

      job_id    — hyphenated job UUID.
      phase     — the agent-reported phase.
      pod_name  — this pod's name.
      progress  — Optional progress percent.
      message   — Optional status line.
      failure   — Some only on a FAILED report (forensics)."""

    var job_id: String
    var phase: AgentPhase
    var pod_name: String
    var progress: Optional[Int32]
    var message: Optional[String]
    var failure: Optional[FailureReport]

    def __init__(
        out self,
        var job_id: String,
        phase: AgentPhase,
        var pod_name: String,
        progress: Optional[Int32],
        var message: Optional[String],
        var failure: Optional[FailureReport],
    ):
        self.job_id = job_id^
        self.phase = phase
        self.pod_name = pod_name^
        self.progress = progress
        self.message = message^
        self.failure = failure^


# =============================================================================
# §2 — HeartbeatOutcome — the result of one POST.
# =============================================================================
# ★ A STATUS THAT IS NOT AN HTTP STATUS, BECAUSE THE POST NEVER HAPPENED.
#
# `status = 0` already means "the POST never completed" -- a refused connect, an
# EOF, a decode error. Reusing it for "this supervisor could not obtain a
# credential" would collapse the two failures the heartbeat contract exists to
# separate: an image that can NEVER beat, and a healthy job whose network
# blipped. The first is a non-restartable terminal; the second is a back-off.
# They cannot be told apart downstream if they arrive with the same status.
#
# Negative so it can never collide with a real HTTP status.
comptime HEARTBEAT_STATUS_AUTH_UNAVAILABLE: Int = -1

# ★ THE THIRD ONE: THE CREDENTIAL WAS NEVER ASKED FOR, BECAUSE IT WOULD HAVE
# TRAVELLED IN THE CLEAR. A declared posture that attaches a
# credential (`gcp-metadata`: a Google-signed OIDC ID token) over a PLAINTEXT
# dial is refused by `send_heartbeat_blocking` BEFORE the mint and BEFORE the
# dial -- nothing is minted, nothing is sent. It is distinct from
# AUTH_UNAVAILABLE (-1) because the cause is different and so is the fix: -1 is
# "this image cannot obtain a credential" (the metadata server said no); -2 is
# "this CONFIGURATION would leak one" (the scheme and the posture disagree).
# Neither is a network blip, and neither may share status 0 with one.
comptime HEARTBEAT_STATUS_AUTH_REFUSED: Int = -2


struct HeartbeatOutcome(Copyable, Movable, ImplicitlyCopyable):
    """The result of one heartbeat POST.

      ok      — True iff the POST completed and returned a parseable response
                (a network failure / non-2xx is ok=False; the loop backs off).
      cancel  — the job-manager's {cancel} signal (only meaningful when ok).
      status  — the HTTP status (0 when the POST never completed)."""

    var ok: Bool
    var cancel: Bool
    var status: Int

    def __init__(out self, ok: Bool, cancel: Bool, status: Int):
        self.ok = ok
        self.cancel = cancel
        self.status = status


# =============================================================================
# §3 — proto projection: AgentState value struct -> generated wire message.
# =============================================================================
def _json_escape(s: String) -> String:
    """Escape a String for embedding inside a JSON string literal: backslash,
    double-quote, and the control chars a parser would choke on. The heartbeat
    wire is now protobuf-binary, but this small utility is still used by the
    crash-report JSON upload (`upload.mojo` — the S3 forensics write), so it is
    kept here as a shared helper."""
    var out = String("")
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(0x22):  # "
            out += String('\\"')
        elif c == UInt8(0x5C):  # backslash
            out += String("\\\\")
        elif c == UInt8(0x0A):  # newline
            out += String("\\n")
        elif c == UInt8(0x0D):  # carriage return
            out += String("\\r")
        elif c == UInt8(0x09):  # tab
            out += String("\\t")
        else:
            out += chr(Int(c))
    return out^


def _phase_to_proto(phase: AgentPhase) -> PbJobPhase:
    """Map the agent-reported `AgentPhase` onto the generated supervisor.proto
    `JobPhase` enum. Agents only ever report the four terminal-ish phases
    (RUNNING / COMPLETED / FAILED / CANCELLED)."""
    if phase == AgentPhase.completed():
        return PbJobPhase(PbJobPhase.JOB_PHASE_COMPLETED)
    if phase == AgentPhase.failed():
        return PbJobPhase(PbJobPhase.JOB_PHASE_FAILED)
    if phase == AgentPhase.cancelled():
        return PbJobPhase(PbJobPhase.JOB_PHASE_CANCELLED)
    return PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING)


def _failure_to_proto(f: FailureReport) -> PbFailureReport:
    """Project the agent's `FailureReport` value struct onto the generated
    supervisor.proto `FailureReport` message. The agent does not populate the
    proto `reason` field (it carries exit_code / signal / stderr_tail /
    panic_message / last_record_offset); `reason` is left absent."""
    var tail = List[String]()
    for ref l in f.stderr_tail:
        tail.append(l)

    var pm = Optional[String]()
    if f.panic_message:
        pm = Optional[String](f.panic_message.value())

    var lro = Optional[UInt64]()
    if f.last_record_offset:
        # The agent stores the offset as Int64; the proto field is uint64.
        lro = Optional[UInt64](UInt64(Int(f.last_record_offset.value())))

    return PbFailureReport(
        f.exit_code,  # exit_code (Optional[Int32])
        f.signal,  # signal (Optional[Int32])
        tail^,  # stderr_tail (repeated string)
        pm^,  # panic_message (Optional[String])
        Optional[String](),  # reason (agent leaves absent)
        lro^,  # last_record_offset (Optional[UInt64])
    )


def _to_proto(hb: SupervisorHeartbeat) -> PbSupervisorHeartbeat:
    """Project the agent-facing `SupervisorHeartbeat` value struct onto the
    GENERATED supervisor.proto `SupervisorHeartbeat` wire message."""
    var progress = Optional[UInt32]()
    if hb.progress:
        # Agent stores progress as Int32; the proto field is uint32.
        progress = Optional[UInt32](UInt32(Int(hb.progress.value())))

    var message = Optional[String]()
    if hb.message:
        message = Optional[String](hb.message.value())

    var failure = Optional[PbFailureReport]()
    if hb.failure:
        failure = Optional[PbFailureReport](_failure_to_proto(hb.failure.value()))

    return PbSupervisorHeartbeat(
        String(hb.job_id),  # job_id
        _phase_to_proto(hb.phase),  # phase
        String(hb.pod_name),  # pod_name
        progress^,  # progress
        message^,  # message
        failure^,  # failure
        # M6 fields (field #7/8/9). A plain job supervisor owns no broker
        # partitions, so node_id/load are absent + owned_partitions is empty.
        # The broker-node agent path populates these via _to_proto_node below.
        Optional[String](),  # node_id
        Optional[PbNodeLoad](),  # load
        List[UInt32](),  # owned_partitions
        # BROKER-PEER-ROUTING fields (#10/#11): a plain job supervisor reports
        # no Kafka endpoint (the broker-node path populates them).
        Optional[String](),  # advertised_host
        Optional[UInt32](),  # advertised_port
    )


def encode_heartbeat(hb: SupervisorHeartbeat) raises -> List[UInt8]:
    """Encode an agent heartbeat to protobuf-binary wire bytes via the generated
    supervisor.proto `SupervisorHeartbeat` message + the `komira_proto_codec` codec."""
    return encode_proto[PbSupervisorHeartbeat](_to_proto(hb))


# =============================================================================
# §4 — {cancel} response decode (the generated HeartbeatResponse message).
# =============================================================================
def decode_cancel(var body: List[UInt8]) raises -> Bool:
    """Decode the job-manager's protobuf-binary `HeartbeatResponse` reply and
    return the `cancel` bit. An empty body (proto3 default: all-fields-default)
    decodes to `cancel=false`."""
    var resp = decode_proto[PbHeartbeatResponse](body^)
    return resp.cancel


# =============================================================================
# §5 — send_heartbeat[RT] — one POST over an existing HttpClient + reactor.
# =============================================================================
def send_heartbeat[
    RT: Runtime,
    C: Connector,
](
    mut client: HttpClient[C],
    mut reactor: Reactor[RT.Sink],
    host: String,
    port: UInt16,
    hb: SupervisorHeartbeat,
    use_tls: Bool = False,
    auth_headers: List[HeaderEntry] = List[HeaderEntry](),
) -> HeartbeatOutcome:
    """POST one heartbeat to `{scheme}://{host}:{port}/internal/heartbeat` over
    the caller's HttpClient, whose transport `C` the caller chose.

    `auth_headers` are appended AFTER `Content-Type` and are whatever the
    caller's DECLARED posture produced (`komira_agent.jm_auth.jm_auth_headers`).
    An EMPTY list -- the default -- serializes byte-identically to this
    function's request before the auth seam, so every existing caller is unchanged.

    ⛔ THIS FUNCTION DOES NOT MINT, DELIBERATELY. Minting can fail, and a
    function whose contract is NEVER RAISES must not be the place that decides
    what a mint failure means -- the only thing it could do here is swallow it,
    which is a bearer-less POST into a 403. That decision belongs to
    `send_heartbeat_blocking`, and it is AUTH_UNAVAILABLE.

    ⚠ `use_tls` SELECTS THE URL SCHEME ONLY -- it does NOT and cannot select the
    transport, because the transport is `C` and `C` was fixed when the client was
    built. Passing `use_tls=True` with a `KernelTcpConnector` client sends a
    plaintext request to a TLS port. `send_heartbeat_blocking` exists so that
    ordinary callers never make the two choices separately; a caller holding its
    own long-lived client is responsible for keeping them in step.

    Mirrors `k8s_https_request_authed`'s POST branch: encode the GENERATED supervisor.proto `SupervisorHeartbeat` to
    PROTOBUF-BINARY (`encode_heartbeat`), POST it as a BytesBody with
    `Content-Type: application/protobuf` via `HttpClient.send_buffered[RT]`
    (which owns ALL body accumulation on its reactor-park path — no borrow
    across the park here), then `decode_cancel` the protobuf-binary
    `HeartbeatResponse` reply.

    NEVER raises: a network failure (connect refused / EOF / decode error) is
    caught and returned as `HeartbeatOutcome(ok=False, ...)` so the agent loop
    logs + backs off WITHOUT interrupting the child (a lost heartbeat must not
    kill the job)."""
    try:
        var body_bytes = encode_heartbeat(hb)
        var url = (
            Url.https(host, port, String("/internal/heartbeat"))
            if use_tls
            else Url.http(host, port, String("/internal/heartbeat"))
        )

        var headers = HeaderMap()
        headers.append(
            String("Content-Type"), String("application/protobuf")
        )
        for i in range(len(auth_headers)):
            headers.append(auth_headers[i].name, auth_headers[i].value)

        var req = build_request_with_body[BytesBody](
            HttpMethod(code=HTTP_METHOD_POST),
            url^,
            headers^,
            BytesBody.from_bytes(body_bytes^),
        )
        var cr = client.send_buffered[RT, BytesBody](req^, reactor)
        var status = Int(cr.status)

        # Decode the protobuf-binary HeartbeatResponse body -> {cancel} flag.
        # Only a 2xx carries a meaningful response message; a 4xx body is an
        # error envelope (not a HeartbeatResponse), so we only decode on 2xx.
        var ok = status >= 200 and status < 300
        var cancel = False
        var resp_bytes = cr.body.take_bytes()
        if ok:
            cancel = decode_cancel(resp_bytes^)
        return HeartbeatOutcome(ok, cancel, status)
    except e:
        # Network / decode failure — best-effort, never crash the loop.
        log.warn[
            "agent: heartbeat POST failed: {}", "komira_agent.heartbeat"
        ](ArgStr(String(e)))
        return HeartbeatOutcome(False, False, 0)


# =============================================================================
# §5b — the agent's job-manager TLS connector.
# =============================================================================
def build_agent_jm_tls_connector() raises -> TlsConnector[KernelTcpConnector]:
    """The `TlsConnector` the agent dials an `https://` job manager through:
    the EXISTING unpinned public-CA connector, verbatim.

    ⛔ THIS FUNCTION DELIBERATELY ADDS NOTHING. It exists to give the choice a
    NAME and one place to change, not to configure anything -- writing a second
    TLS setup for the agent is exactly the duplication to avoid, and
    `komira_http_client`'s factory already carries the four decisions that matter
    (TLS 1.3 cipher preferences, the system public-CA trust store, verification
    ON, `verify_mode=VERIFY_PEER` so the session cache buckets correctly).

    ⛔ NO `disable_verify()` ARM, AND NONE MAY BE ADDED. An agent that skips peer
    verification reports its job's terminal phase -- and takes its cancel
    signal -- from whatever answered the dial. The MVP-plaintext posture this
    replaces was at least honestly plaintext; a verify-skipping TLS arm would
    look secure in every log line."""
    return build_unpinned_public_ca_tls_connector()


# =============================================================================
# §6 — send_heartbeat_blocking — the SYNC ESCAPE (BlockingRuntime).
# =============================================================================
def send_heartbeat_blocking(
    host: String,
    port: UInt16,
    hb: SupervisorHeartbeat,
    use_tls: Bool,
    auth_mode: JmAuthMode,
    audience: String,
) -> HeartbeatOutcome:
    """Synchronous one-shot heartbeat POST. Stands up a
    `BlockingRuntime[NoopSink]` (current-thread, single-task) on the CALLING
    thread, builds a fresh HttpClient, and drives
    `send_heartbeat[BlockingRuntime[NoopSink], C]` with the runtime's reactor —
    the `k8s_https_request_authed_blocking` model. The agent run loop calls this
    (single-threaded MVP loop).

    ⛔⛔ THE TRANSPORT ARGUMENTS HAVE **NO DEFAULTS**, AND THEY MAY NOT GROW
    THEM BACK. They had `use_tls=False` / `auth_mode=none()` /
    `audience=""`, and the on-VM pod-loader supervisor's two call sites simply
    omitted them — so every VM beat went out plaintext and bearer-less against
    an https, IAM-gated Cloud Run job manager, and NOTHING reached the wire for
    30 days. A defaulted parameter is a decision the compiler cannot make a
    caller state; without the defaults, a call site that does not say how it
    reaches the job manager does not compile. A caller that genuinely wants
    plaintext with no credential writes `False, JmAuthMode.none(), String("")`
    — visibly.

    ★ THIS IS THE ONE PLACE THE TRANSPORT AND THE SCHEME ARE CHOSEN, AND THEY
    ARE CHOSEN TOGETHER. `use_tls=True` builds an
    `HttpClient[TlsConnector[KernelTcpConnector]]` over the UNPINNED public-CA
    connector AND passes `use_tls` through to the URL builder; `use_tls=False`
    is byte-identical to this function's plaintext-only behaviour. There is no
    argument that lets a caller select one without the other.

    ⚠ UNPINNED, NOT PINNED, AND THAT IS DELIBERATE.
    `build_unpinned_public_ca_tls_connector` takes no host and lets `HttpClient`
    push the URL host as SNI per request. Pinning here would bake ONE server
    name into the connector, which is wrong the moment a job manager is reached
    through more than one hostname — and `build_public_ca_tls_connector`'s own
    docstring names that as the trap. ⛔ The consequence, stated: a JM addressed
    by IP LITERAL cannot use the TLS arm, because RFC 6066 §3 forbids an IP as
    SNI. That is correct for an API-Gateway-fronted JM (always a DNS name) and
    is a REFUSAL rather than a silent downgrade -- the dial fails and the
    heartbeat reports ok=False rather than quietly going plaintext.

    ⛔⛔ A CREDENTIAL NEVER RIDES A PLAINTEXT DIAL. `use_tls=False`
    with a posture that attaches a credential (`gcp-metadata`) returns
    `HEARTBEAT_STATUS_AUTH_REFUSED` having minted NOTHING and dialled NOTHING.
    Until then this function minted whenever the posture was not `none`,
    whatever `use_tls` said, so an ID token could go out in the clear -- the
    on-VM loader could reach that pair after a transient failure of the startup
    script's optional scheme fetch, where no placement check can see it. Both
    config readers (`AgentConfig.from_env`, `PodLoaderSupervisorConfig
    .from_env`) now refuse the pair at boot; this is the per-beat backstop for
    every caller, including one that builds its config by hand.

    NEVER raises: the inner send_heartbeat catches network errors; the runtime
    AND connector construction (both of which CAN raise — Reactor's ctor
    enforces the per-OS backend, and the s2n config can fail) are wrapped here so
    a construction failure degrades to an ok=False outcome rather than crashing
    the loop.

    The body is `send_heartbeat_blocking_with_minter`, driven with the
    PRODUCTION minter; see that function for why the seam exists."""
    var minter = GcpMetadataMinter()
    return send_heartbeat_blocking_with_minter[GcpMetadataMinter](
        host, port, hb, use_tls, auth_mode, audience, minter
    )


def send_heartbeat_blocking_with_minter[
    M: JmTokenMinter
](
    host: String,
    port: UInt16,
    hb: SupervisorHeartbeat,
    use_tls: Bool,
    auth_mode: JmAuthMode,
    audience: String,
    mut minter: M,
) -> HeartbeatOutcome:
    """`send_heartbeat_blocking`'s body, with the credential minter as a
    parameter. Production reaches it ONLY through `send_heartbeat_blocking`,
    which passes `GcpMetadataMinter`.

    ⚠ THE MINTER IS A PARAMETER SO "NOTHING WAS MINTED" IS OBSERVABLE. The
    production minter dials `metadata.google.internal`, which does not resolve
    on a build box: a test driving it could not tell "the guard refused before
    the mint" from "the mint failed", because both send nothing. A scripted
    `JmTokenMinter` counts its calls and hands back a real-looking token, so a
    test can assert the mint count AND read what went on the wire -- the same
    reason `jm_auth.JmTokenMinter` is a trait at all."""
    # ---- ⛔ NO CREDENTIAL IN THE CLEAR -- BEFORE THE MINT, BEFORE THE DIAL ----
    # The order is the property: refusing after the mint would already have
    # put a live token in this process for nothing, and refusing after the dial
    # would already have sent it. Neither the token nor any part of it exists
    # yet, so the WARN can carry the posture and the target and nothing else.
    if jm_credential_rides_in_clear(use_tls, auth_mode):
        log.warn[
            (
                "agent: heartbeat REFUSED: posture {} would send a credential"
                " over PLAINTEXT to {}:{} -- nothing minted, nothing dialled"
            ),
            "komira_agent.heartbeat",
        ](ArgStr(auth_mode.name()), ArgStr(host), ArgStr(String(port)))
        return HeartbeatOutcome(False, False, HEARTBEAT_STATUS_AUTH_REFUSED)

    # ---- AUTH FIRST, AND FAIL CLOSED -------------------------------------
    # ⛔ A MINT FAILURE RETURNS AUTH_UNAVAILABLE AND NEVER FALLS THROUGH TO A
    # BEARER-LESS POST. Sending the beat without the credential the posture
    # declared would 403 at the ingress edge and arrive back here as an
    # ordinary transport failure -- making "this image cannot authenticate"
    # indistinguishable from "the network blipped", which is precisely the
    # collapse the heartbeat contract exists to remove.
    var auth_headers = List[HeaderEntry]()
    if not auth_mode.is_none():
        try:
            auth_headers = jm_auth_headers[M](
                auth_mode,
                minter,
                audience,
                String("POST"),
                String("/internal/heartbeat"),
                List[UInt8](),
            )
        except e:
            # ⛔ THE MODE AND THE AUDIENCE, NEVER THE TOKEN. The audience is a
            # public service URL; the credential is not, and an exception
            # string is the most-copied text in an incident.
            log.warn[
                (
                    "agent: heartbeat auth unavailable (mode={}, aud={}): {}"
                ),
                "komira_agent.heartbeat",
            ](ArgStr(auth_mode.name()), ArgStr(audience), ArgStr(String(e)))
            return HeartbeatOutcome(
                False, False, HEARTBEAT_STATUS_AUTH_UNAVAILABLE
            )

    try:
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        if use_tls:
            var tls_client = HttpClient[
                TlsConnector[KernelTcpConnector]
            ].with_defaults(build_agent_jm_tls_connector())
            return send_heartbeat[
                BlockingRuntime[NoopSink], TlsConnector[KernelTcpConnector]
            ](tls_client, reactor, host, port, hb, True, auth_headers)
        var client = HttpClient[KernelTcpConnector].with_defaults(
            KernelTcpConnector.new()
        )
        return send_heartbeat[BlockingRuntime[NoopSink], KernelTcpConnector](
            client, reactor, host, port, hb, False, auth_headers
        )
    except e:
        log.warn[
            "agent: heartbeat runtime construction failed: {}",
            "komira_agent.heartbeat",
        ](ArgStr(String(e)))
        return HeartbeatOutcome(False, False, 0)


# =============================================================================
# §7 — BROKER-NODE heartbeat (BROKER-M6-FOLLOWON M6F-1) — the co-located node
# reports its identity + owned set and reconciles the JM's assignment reply.
# =============================================================================
# the agent-facing value projection of the coordinator's
# cluster routing map (the generated `BrokerClusterMap` decoded into plain value
# structs so the broker entrypoint never touches the generated Pb types — clean
# encapsulation: the agent owns the wire<->value projection).
struct BrokerEndpointView(Copyable, Movable, ImplicitlyCopyable):
    """One live broker's reachable Kafka endpoint (node_id + host + port)."""

    var node_id: Int32
    var host: String
    var port: Int32

    def __init__(out self, node_id: Int32, var host: String, port: Int32):
        self.node_id = node_id
        self.host = host^
        self.port = port


struct PartitionLeaderView(Copyable, Movable, ImplicitlyCopyable):
    """One partition's current leader node id (or NO_LEADER == -1)."""

    var partition_id: UInt32
    var leader_node_id: Int32

    def __init__(out self, partition_id: UInt32, leader_node_id: Int32):
        self.partition_id = partition_id
        self.leader_node_id = leader_node_id


struct BrokerClusterView(Movable):
    """The agent-facing cluster routing map: every live broker's endpoint + the
    per-partition leader. Empty when the coordinator reply carried no
    broker_cluster (an older coordinator / a failed POST)."""

    var nodes: List[BrokerEndpointView]
    var leaders: List[PartitionLeaderView]

    def __init__(out self):
        self.nodes = List[BrokerEndpointView]()
        self.leaders = List[PartitionLeaderView]()

    def __init__(
        out self,
        var nodes: List[BrokerEndpointView],
        var leaders: List[PartitionLeaderView],
    ):
        self.nodes = nodes^
        self.leaders = leaders^

    @always_inline
    def is_empty(self) -> Bool:
        return len(self.nodes) == 0 and len(self.leaders) == 0


struct BrokerHeartbeatOutcome(Movable):
    """The result of one BROKER-NODE heartbeat POST.

      ok                  — True iff the POST completed + returned a parseable
                            HeartbeatResponse (a network failure / non-2xx is
                            ok=False; the broker loop logs + backs off, NEVER
                            interrupting serving — a lost heartbeat must not stop
                            the data plane).
      status              — the HTTP status (0 when the POST never completed).
      assigned_partitions — the partitions the coordinator says THIS node should
                            serve (the assignment reply, field #2). Empty on a
                            failed POST (the broker keeps its current set).
      assigned_generations — the per-partition lease GENERATION for each assigned
                            partition, POSITIONALLY
                            PARALLEL to assigned_partitions (assigned_generations[i]
                            is the lease generation for assigned_partitions[i]).
                            The owner stamps this generation as its
                            `writer_lease_epoch` on appends so a stale displaced
                            owner is fenced at the manifest. Empty on a failed
                            POST / an older coordinator (the broker keeps its
                            current lease map; an empty/shorter list leaves the
                            generation 0 = the no-op fence default).
      cluster             — the cluster-wide routing map (field #4) the broker
                            applies to its Metadata so a vanilla single-bootstrap
                            client routes across the whole cluster. Empty on a
                            failed POST / an older coordinator (the broker keeps
                            its current peer/leader maps)."""

    var ok: Bool
    var status: Int
    var assigned_partitions: List[UInt32]
    var assigned_generations: List[Int64]
    var cluster: BrokerClusterView

    def __init__(
        out self,
        ok: Bool,
        status: Int,
        var assigned_partitions: List[UInt32],
        var cluster: BrokerClusterView,
    ):
        self.ok = ok
        self.status = status
        self.assigned_partitions = assigned_partitions^
        self.assigned_generations = List[Int64]()
        self.cluster = cluster^

    def __init__(
        out self,
        ok: Bool,
        status: Int,
        var assigned_partitions: List[UInt32],
        var assigned_generations: List[Int64],
        var cluster: BrokerClusterView,
    ):
        self.ok = ok
        self.status = status
        self.assigned_partitions = assigned_partitions^
        self.assigned_generations = assigned_generations^
        self.cluster = cluster^


def _broker_heartbeat_proto(
    node_id: String,
    records_served: UInt64,
    owned: List[UInt32],
    advertised_host: String,
    advertised_port: UInt32,
    reported_partition_total: UInt32,
) -> PbSupervisorHeartbeat:
    """Build the broker-node `SupervisorHeartbeat` wire message (the M6 fields
    #7/#8/#9 + the BROKER-PEER-ROUTING fields #10/#11). job_id / pod_name are
    nominal (a broker node is not a job); the M6 fields carry the node's identity
    + load + the partitions it currently serves; fields #10/#11 report this
    broker's REACHABLE Kafka endpoint so the coordinator can assemble the
    cluster-wide routing map it hands back to every node. The phase is RUNNING
    (a serving broker).

    BROKER-IT-NATIVE-MULTINODE-SCALING: `reported_partition_total` is the LIVE
    topic partition count this broker read from the topic's partition_map.json on
    S3 (PartitionMap.num_partitions()). It rides the NodeLoad block so the
    coordinator learns a split-driven P GROWTH from heartbeat state alone (the
    coordinator never re-reads S3). 0 means "not reported" (an older broker / a
    map read that failed) — the coordinator falls back to its env P for that
    node."""
    var owned_copy = List[UInt32]()
    for i in range(len(owned)):
        owned_copy.append(owned[i])
    # partition_count (#8.2) = the count this node OWNS; reported_partition_total
    # (#8.3) = the LIVE topic P this node observed in the map (split-aware).
    var rpt = Optional[UInt32]()
    if reported_partition_total > UInt32(0):
        rpt = Optional[UInt32](reported_partition_total)
    var load = PbNodeLoad(records_served, UInt32(len(owned)), rpt^)
    return PbSupervisorHeartbeat(
        String("00000000-0000-0000-0000-000000000000"),  # job_id (nominal)
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),  # phase
        String("broker-node-") + node_id,  # pod_name (nominal)
        Optional[UInt32](),  # progress
        Optional[String](),  # message
        Optional[PbFailureReport](),  # failure
        Optional[String](String(node_id)),  # node_id (M6 #7)
        Optional[PbNodeLoad](load^),  # load (M6 #8)
        owned_copy^,  # owned_partitions (M6 #9)
        Optional[String](String(advertised_host)),  # advertised_host (#10)
        Optional[UInt32](advertised_port),  # advertised_port (#11)
    )


def _cluster_view_from_proto(map: PbBrokerClusterMap) -> BrokerClusterView:
    """Project the generated `BrokerClusterMap` onto the agent-facing value
    `BrokerClusterView` (so the broker entrypoint never touches the Pb types)."""
    var nodes = List[BrokerEndpointView]()
    for i in range(len(map.nodes)):
        ref n = map.nodes[i]
        nodes.append(
            BrokerEndpointView(n.node_id, n.host.copy(), Int32(Int(n.port)))
        )
    var leaders = List[PartitionLeaderView]()
    for i in range(len(map.leaders)):
        ref l = map.leaders[i]
        leaders.append(
            PartitionLeaderView(l.partition_id, l.leader_node_id)
        )
    return BrokerClusterView(nodes^, leaders^)


def send_broker_heartbeat_over[
    RT: Runtime,
](
    mut client: HttpClient[KernelTcpConnector],
    mut reactor: Reactor[RT.Sink],
    host: String,
    port: UInt16,
    node_id: String,
    records_served: UInt64,
    owned: List[UInt32],
    advertised_host: String,
    advertised_port: UInt32,
    reported_partition_total: UInt32 = UInt32(0),
) -> BrokerHeartbeatOutcome:
    """The broker heartbeat POST over a CALLER-HELD, LONG-LIVED `client` +
    `reactor`, so the per-tick TCP connection is REUSED via the HttpClient's h1
    keepalive cache (client.mojo:_h1_idle_conn) instead of being re-dialed every
    tick. `send_broker_heartbeat_blocking` (below) is the back-compat wrapper
    that stands up a fresh client+runtime per call; the broker serve loop holds
    ONE client+runtime across ticks and calls THIS variant — N heartbeats →
    1 dial (no per-tick TIME_WAIT socket to the coordinator, so the host does
    not exhaust its ephemeral ports).

    Semantics are otherwise identical to `send_broker_heartbeat_blocking`:
    builds the broker `SupervisorHeartbeat`, POSTs it, decodes the
    `HeartbeatResponse.assigned_partitions[]` + `broker_cluster` routing map.
    NEVER raises — a network/decode failure is caught and returned as `ok=False`
    so the broker loop logs + backs off WITHOUT interrupting serving."""
    try:
        var hb = _broker_heartbeat_proto(
            node_id,
            records_served,
            owned,
            advertised_host,
            advertised_port,
            reported_partition_total,
        )
        var body_bytes = encode_proto[PbSupervisorHeartbeat](hb)
        var url = Url.http(host, port, String("/internal/heartbeat"))
        var headers = HeaderMap()
        headers.append(
            String("Content-Type"), String("application/protobuf")
        )
        var req = build_request_with_body[BytesBody](
            HttpMethod(code=HTTP_METHOD_POST),
            url^,
            headers^,
            BytesBody.from_bytes(body_bytes^),
        )
        var cr = client.send_buffered[RT, BytesBody](req^, reactor)
        var status = Int(cr.status)
        var ok = status >= 200 and status < 300
        var assigned = List[UInt32]()
        var assigned_gens = List[Int64]()
        var cluster = BrokerClusterView()
        var resp_bytes = cr.body.take_bytes()
        if ok:
            var resp = decode_proto[PbHeartbeatResponse](resp_bytes^)
            for i in range(len(resp.assigned_partitions)):
                assigned.append(resp.assigned_partitions[i])
            # the per-partition lease generations, positionally
            # parallel to assigned_partitions. An older coordinator omits them
            # (empty list -> generation 0 = the no-op fence default at the owner).
            for i in range(len(resp.assigned_generations)):
                assigned_gens.append(resp.assigned_generations[i])
            if resp.broker_cluster:
                cluster = _cluster_view_from_proto(resp.broker_cluster.value())
        return BrokerHeartbeatOutcome(
            ok, status, assigned^, assigned_gens^, cluster^
        )
    except e:
        log.warn[
            "broker: heartbeat POST failed: {}", "komira_agent.heartbeat"
        ](ArgStr(String(e)))
        return BrokerHeartbeatOutcome(
            False, 0, List[UInt32](), BrokerClusterView()
        )


def send_broker_heartbeat_blocking(
    host: String,
    port: UInt16,
    node_id: String,
    records_served: UInt64,
    owned: List[UInt32],
    advertised_host: String,
    advertised_port: UInt32,
    reported_partition_total: UInt32 = UInt32(0),
) -> BrokerHeartbeatOutcome:
    """Synchronous one-shot BROKER-NODE heartbeat POST (M6F-1 +
    BROKER-PEER-ROUTING). Builds the broker `SupervisorHeartbeat` (node_id +
    load + owned_partitions + this broker's reachable advertised_host/port),
    encodes it to protobuf-binary, POSTs it to the coordinator's
    `http://{host}:{port}/internal/heartbeat`, and decodes BOTH the
    `HeartbeatResponse.assigned_partitions[]` (the partitions this node should
    serve) AND the `broker_cluster` routing map (every live broker's endpoint +
    the per-partition leader). The broker applies the assigned diff in-process
    via `BrokerNodeState.apply_assignment` (D1, the relay) and applies the
    cluster map to its Metadata via `KafkaBrokerServer.apply_cluster_map`.

    BROKER-KEEPALIVE-REUSE: this stand-up-a-fresh-client form is the back-compat
    / one-shot entry; it builds a fresh HttpClient + BlockingRuntime per call (a
    fresh dial each time). The broker's steady-state serve loop should instead
    hold ONE client+runtime and call `send_broker_heartbeat_over` so the
    connection is reused across ticks (the per-tick re-dial was a contributor to
    host ephemeral-port exhaustion).

    NEVER raises: a network/decode failure is caught and returned as
    `ok=False` (empty assigned set + empty cluster) so the broker loop logs +
    backs off WITHOUT interrupting serving (a lost heartbeat must not stop the
    data plane)."""
    try:
        var client = HttpClient[KernelTcpConnector].with_defaults(
            KernelTcpConnector.new()
        )
        var rt = BlockingRuntime[NoopSink].new(
            NoopSink(_placeholder=UInt8(0))
        )
        ref reactor = rt.reactor()
        return send_broker_heartbeat_over[BlockingRuntime[NoopSink]](
            client,
            reactor,
            host,
            port,
            node_id,
            records_served,
            owned,
            advertised_host,
            advertised_port,
            reported_partition_total,
        )
    except e:
        # BlockingRuntime/reactor stand-up failed before the POST — same
        # never-raises contract: log + return ok=False (the broker loop backs
        # off; a lost heartbeat must not stop the data plane).
        log.warn[
            "broker: heartbeat runtime setup failed: {}",
            "komira_agent.heartbeat",
        ](ArgStr(String(e)))
        return BrokerHeartbeatOutcome(
            False, 0, List[UInt32](), BrokerClusterView()
        )
