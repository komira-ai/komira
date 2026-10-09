# =============================================================================
# komira_job_supervisor/heartbeat_client.mojo: the heartbeat value, its wire
# encoding, and how it is delivered.
# =============================================================================
#
# A heartbeat says what the supervised job is doing: RUNNING while it runs,
# then one terminal COMPLETED / FAILED / CANCELLED, with failure forensics on
# FAILED. Where it goes is the operator's choice: the supervisor hands each
# heartbeat to a `HeartbeatReporter`, a trait the embedding binary chooses a
# conformer of. The reply may ask the supervisor to cancel the job.
#
# THE WIRE is the generated `komira.job_report.v1` messages
# (komira_job_report_proto): the request body is a `JobHeartbeat` and the
# reply a `JobHeartbeatReply`, both protobuf binary through
# komira_proto_codec. The message's `job_id` and `instance_name` fields carry
# the supervisor's `--job-name` and `--instance-name` values verbatim; both
# are opaque strings to the supervisor. The reply's directive is CONTINUE or
# CANCEL; only an explicit CANCEL stops the job (an empty reply is CONTINUE,
# and so is a directive number this build has no name for).
#
# THE SHIPPED REPORTER is `HttpHeartbeatReporter[A]`: one HTTP POST per beat to
# the operator's `--heartbeat-url` (http:// or https://, the latter verified
# against the system public-CA trust store), `Content-Type:
# application/protobuf`, plus whatever headers the `HeartbeatAuth` conformer
# `A` produces (heartbeat_auth.mojo; the shipped one is `NoHeartbeatAuth`).
# A 2xx reply is decoded as a `JobHeartbeatReply` for its directive.
#
# A HEARTBEAT IS BEST-EFFORT: `report` never raises. A failure comes back as
# `HeartbeatOutcome(ok=False)` and the run loop carries on; losing a beat must
# not kill the job. The outcome's `status` separates the failures that need
# different fixes: 0 is "the POST never completed" (a network failure),
# `HEARTBEAT_STATUS_AUTH_UNAVAILABLE` is "the auth conformer raised", and
# `HEARTBEAT_STATUS_AUTH_REFUSED` is "this configuration would have sent a
# credential in the clear" (nothing was produced or dialled).
#
# ENCAPSULATION: value-typed surface (a SupervisorHeartbeat value in, a
# HeartbeatOutcome out); the HTTP client owns every buffer. No pointer type
# crosses a boundary.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderEntry, HeaderMap
from komira_http_client.service import ClientRequest
from komira_http_client.tls_connector import (
    TlsConnector,
    build_unpinned_public_ca_tls_connector,
)
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_POST, HttpMethod
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_proto_codec import encode_proto, decode_proto

# The generated wire messages, aliased so the supervisor's own value structs
# below do not collide with them.
from komira_job_report_proto.job_report import (
    JobDirective as PbJobDirective,
    JobFailure as PbJobFailure,
    JobHeartbeat as PbJobHeartbeat,
    JobHeartbeatReply as PbJobHeartbeatReply,
    JobPhase as PbJobPhase,
)

from komira_job_supervisor.job_supervisor_state import (
    JobSupervisorPhase,
    FailureReport,
)
from komira_job_supervisor.heartbeat_auth import (
    HeartbeatAuth,
    credential_rides_in_clear,
)

import komira_log as log
from komira_log import ArgStr


# =============================================================================
# §1: SupervisorHeartbeat, the value the supervisor reports.
# =============================================================================
struct SupervisorHeartbeat(Movable):
    """One heartbeat.

      job_name      : the operator's name for this job (`--job-name`).
      phase         : RUNNING, or one of the three terminal phases.
      instance_name : the operator's name for this supervisor instance
                      (`--instance-name`; may be empty).
      progress      : optional progress percent.
      message       : optional status line.
      failure       : set only on a FAILED report (the forensics)."""

    var job_name: String
    var phase: JobSupervisorPhase
    var instance_name: String
    var progress: Optional[Int32]
    var message: Optional[String]
    var failure: Optional[FailureReport]

    def __init__(
        out self,
        var job_name: String,
        phase: JobSupervisorPhase,
        var instance_name: String,
        progress: Optional[Int32],
        var message: Optional[String],
        var failure: Optional[FailureReport],
    ):
        self.job_name = job_name^
        self.phase = phase
        self.instance_name = instance_name^
        self.progress = progress
        self.message = message^
        self.failure = failure^


# =============================================================================
# §2: HeartbeatOutcome, the result of one delivery.
# =============================================================================
# The auth conformer raised: no credential could be produced. Negative, so it
# never collides with an HTTP status, and distinct from 0 ("never
# connected"): an instance that can never authenticate and a network blip
# need different fixes.
comptime HEARTBEAT_STATUS_AUTH_UNAVAILABLE: Int = -1

# The (plaintext, credential-attaching auth) pair: refused before the auth
# conformer was asked and before anything was dialled.
comptime HEARTBEAT_STATUS_AUTH_REFUSED: Int = -2


def terminal_beat_retryable(status: Int) -> Bool:
    """Whether a failed beat with this `HeartbeatOutcome.status` may succeed
    if sent again: no reply at all (0), a credential that could not be read
    this time (HEARTBEAT_STATUS_AUTH_UNAVAILABLE; the file form re-reads it),
    408, 429 and every 5xx. Not a credential refused over plaintext, and not
    any other status: a 4xx says the request itself is refused."""
    if status == 0 or status == HEARTBEAT_STATUS_AUTH_UNAVAILABLE:
        return True
    if status == 408 or status == 429:
        return True
    return status >= 500 and status <= 599


struct HeartbeatOutcome(Copyable, Movable, ImplicitlyCopyable):
    """The result of one heartbeat.

      ok     : True iff the beat was delivered and a 2xx reply decoded.
      cancel : the reply asked the supervisor to cancel the job (only
               meaningful when ok).
      status : the HTTP status; 0 when the POST never completed; or one of
               the negative HEARTBEAT_STATUS_* values."""

    var ok: Bool
    var cancel: Bool
    var status: Int

    def __init__(out self, ok: Bool, cancel: Bool, status: Int):
        self.ok = ok
        self.cancel = cancel
        self.status = status


# =============================================================================
# §3: HeartbeatReporter, the delivery seam.
# =============================================================================
trait HeartbeatReporter(Movable, Deinitable):
    """Delivers heartbeats to wherever the operator collects them. The
    embedding binary picks the conformer; `HttpHeartbeatReporter` is the one
    this package ships."""

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        """Deliver one heartbeat. NEVER raises: a failure is an outcome with
        ok=False."""
        ...


# =============================================================================
# §4: the wire projection.
# =============================================================================
def _phase_to_proto(phase: JobSupervisorPhase) -> PbJobPhase:
    if phase == JobSupervisorPhase.completed():
        return PbJobPhase(PbJobPhase.JOB_PHASE_COMPLETED)
    if phase == JobSupervisorPhase.failed():
        return PbJobPhase(PbJobPhase.JOB_PHASE_FAILED)
    if phase == JobSupervisorPhase.cancelled():
        return PbJobPhase(PbJobPhase.JOB_PHASE_CANCELLED)
    return PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING)


def _failure_to_proto(f: FailureReport) -> PbJobFailure:
    var tail = List[String]()
    for ref l in f.stderr_tail:
        tail.append(l)
    var pm = Optional[String]()
    if f.panic_message:
        pm = Optional[String](f.panic_message.value())
    return PbJobFailure(f.exit_code, f.signal, tail^, pm^)


def _to_proto(hb: SupervisorHeartbeat) -> PbJobHeartbeat:
    var progress = Optional[UInt32]()
    if hb.progress:
        progress = Optional[UInt32](UInt32(Int(hb.progress.value())))
    var message = Optional[String]()
    if hb.message:
        message = Optional[String](hb.message.value())
    var failure = Optional[PbJobFailure]()
    if hb.failure:
        failure = Optional[PbJobFailure](_failure_to_proto(hb.failure.value()))
    return PbJobHeartbeat(
        String(hb.job_name),  # job_id
        _phase_to_proto(hb.phase),  # phase
        String(hb.instance_name),  # instance_name
        progress^,  # progress
        message^,  # message
        failure^,  # failure
    )


def encode_heartbeat(hb: SupervisorHeartbeat) raises -> List[UInt8]:
    """The heartbeat as protobuf-binary `JobHeartbeat` bytes."""
    return encode_proto[PbJobHeartbeat](_to_proto(hb))


def decode_cancel(var body: List[UInt8]) raises -> Bool:
    """True iff a protobuf-binary `JobHeartbeatReply` says CANCEL.

    Only the CANCEL number stops the job. An empty body is all defaults
    (CONTINUE), and a directive number this build has no name for is read as
    CONTINUE too, with a warning: stopping a job is not undone, so it is never
    inferred from a value the supervisor does not understand."""
    var reply = decode_proto[PbJobHeartbeatReply](body^)
    var d = reply.directive.value
    if d == PbJobDirective.JOB_DIRECTIVE_CANCEL:
        return True
    if d != PbJobDirective.JOB_DIRECTIVE_CONTINUE:
        log.warn[
            "job supervisor: heartbeat reply directive {} is unknown; continuing",
            "komira_job_supervisor.heartbeat",
        ](ArgStr(String(d)))
    return False


# =============================================================================
# §5: the HTTP delivery.
# =============================================================================
def parse_heartbeat_url(url: String) raises -> Url:
    """Parse and check an operator-supplied heartbeat URL: http or https
    only, and NO userinfo, because a URL is a command-line value and argv is
    readable by every user on the host. A credential belongs in a
    `HeartbeatAuth` conformer, which is where the refusal points."""
    var parsed = Url.parse(url)
    if parsed.userinfo.byte_length() > 0:
        raise Error(
            "job supervisor: the heartbeat URL carries userinfo; a credential"
            " does not belong on the command line (implement HeartbeatAuth)"
        )
    return parsed^


def build_heartbeat_request(
    url: String,
    var body: List[UInt8],
    auth_headers: List[HeaderEntry],
) raises -> ClientRequest[BytesBody]:
    """The serialized heartbeat POST: `Content-Type: application/protobuf`,
    then `auth_headers` in order, then `body`."""
    var headers = HeaderMap()
    headers.append(String("Content-Type"), String("application/protobuf"))
    for i in range(len(auth_headers)):
        headers.append(auth_headers[i].name, auth_headers[i].value)
    return build_request_with_body[BytesBody](
        HttpMethod(code=HTTP_METHOD_POST),
        parse_heartbeat_url(url),
        headers^,
        BytesBody.from_bytes(body^),
    )


def send_heartbeat[
    RT: Runtime,
    C: Connector,
](
    mut client: HttpClient[C],
    mut reactor: Reactor[RT.Sink],
    url: String,
    var body: List[UInt8],
    auth_headers: List[HeaderEntry],
) -> HeartbeatOutcome:
    """POST one encoded heartbeat over the caller's client, whose transport
    `C` the caller chose to match `url`'s scheme. NEVER raises."""
    try:
        var req = build_heartbeat_request(url, body^, auth_headers)
        var cr = client.send_buffered[RT, BytesBody](req^, reactor)
        var status = Int(cr.status)
        # Only a 2xx carries a JobHeartbeatReply; anything else is an error
        # envelope and is not decoded.
        var ok = status >= 200 and status < 300
        var cancel = False
        var resp_bytes = cr.body.take_bytes()
        if ok:
            cancel = decode_cancel(resp_bytes^)
        return HeartbeatOutcome(ok, cancel, status)
    except e:
        log.warn[
            "job supervisor: heartbeat POST failed: {}",
            "komira_job_supervisor.heartbeat",
        ](ArgStr(String(e)))
        return HeartbeatOutcome(False, False, 0)


def build_heartbeat_tls_connector() raises -> TlsConnector[KernelTcpConnector]:
    """The TLS connector an https heartbeat URL is dialled through: the
    unpinned public-CA connector (system trust store, peer verification on,
    the URL host sent as SNI). There is deliberately no verify-skipping
    variant: a supervisor that does not verify its endpoint takes its cancel
    signal from whatever answered. An IP-literal https host cannot be used
    (an IP is not a valid SNI name); the dial fails rather than downgrading."""
    return build_unpinned_public_ca_tls_connector()


struct HttpHeartbeatReporter[A: HeartbeatAuth](HeartbeatReporter):
    """Delivers each heartbeat as one HTTP POST to an operator-supplied URL,
    authenticated by `A` (module header).

    Building one REFUSES an http:// URL with an `A` that attaches a
    credential; `report` refuses the same pair again before every beat."""

    var _url: String
    var _use_tls: Bool
    var _auth: Self.A

    def __init__(out self, url: String, var auth: Self.A) raises:
        var use_tls = parse_heartbeat_url(url).is_https()
        if credential_rides_in_clear[Self.A](use_tls, auth):
            raise Error(
                String("job supervisor: REFUSED heartbeat auth '")
                + auth.name()
                + String("' over a plaintext URL: it attaches a credential,")
                + String(" which would travel in the clear. Use an https URL.")
            )
        self._url = url
        self._use_tls = use_tls
        self._auth = auth^

    def url(self) -> String:
        return self._url

    def uses_tls(self) -> Bool:
        return self._use_tls

    def auth(ref self) -> ref [self._auth] Self.A:
        """The auth conformer this reporter signs with."""
        return self._auth

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        # No credential in the clear: refused before the auth conformer is
        # asked and before the dial, so nothing exists that could leak.
        if credential_rides_in_clear[Self.A](self._use_tls, self._auth):
            log.warn[
                (
                    "job supervisor: heartbeat REFUSED: auth {} would send a"
                    " credential over plaintext; nothing produced or dialled"
                ),
                "komira_job_supervisor.heartbeat",
            ](ArgStr(self._auth.name()))
            return HeartbeatOutcome(False, False, HEARTBEAT_STATUS_AUTH_REFUSED)

        var body: List[UInt8]
        try:
            body = encode_heartbeat(hb)
        except e:
            log.warn[
                "job supervisor: heartbeat encode failed: {}",
                "komira_job_supervisor.heartbeat",
            ](ArgStr(String(e)))
            return HeartbeatOutcome(False, False, 0)

        # Auth first, and fail closed: a raise never falls through to an
        # unauthenticated POST.
        var auth_headers = List[HeaderEntry]()
        try:
            auth_headers = self._auth.headers(String("POST"), self._url, body)
        except e:
            log.warn[
                "job supervisor: heartbeat auth {} unavailable: {}",
                "komira_job_supervisor.heartbeat",
            ](ArgStr(self._auth.name()), ArgStr(String(e)))
            return HeartbeatOutcome(
                False, False, HEARTBEAT_STATUS_AUTH_UNAVAILABLE
            )

        try:
            var rt = BlockingRuntime[NoopSink].new(
                NoopSink(_placeholder=UInt8(0))
            )
            ref reactor = rt.reactor()
            if self._use_tls:
                var tls_client = HttpClient[
                    TlsConnector[KernelTcpConnector]
                ].with_defaults(build_heartbeat_tls_connector())
                return send_heartbeat[
                    BlockingRuntime[NoopSink],
                    TlsConnector[KernelTcpConnector],
                ](tls_client, reactor, self._url, body^, auth_headers)
            var client = HttpClient[KernelTcpConnector].with_defaults(
                KernelTcpConnector.new()
            )
            return send_heartbeat[BlockingRuntime[NoopSink], KernelTcpConnector](
                client, reactor, self._url, body^, auth_headers
            )
        except e:
            log.warn[
                "job supervisor: heartbeat runtime construction failed: {}",
                "komira_job_supervisor.heartbeat",
            ](ArgStr(String(e)))
            return HeartbeatOutcome(False, False, 0)
