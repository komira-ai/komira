# =============================================================================
# komira_agent/jm_auth.mojo — THE SUPERVISOR'S AUTHENTICATED PATH TO THE JM.
# =============================================================================
#
# ⛔⛔ THE DEFECT. Every finite job's supervisor beats to
# `POST /internal/heartbeat` on the job manager, and the agent had ZERO token
# support — `send_heartbeat` built exactly one header (`Content-Type:
# application/protobuf`) and there was no metadata-server client in the
# agent. A job manager deployed as a Cloud Run service that is NOT
# `public_invoker` answers an anonymous request 403 at the Google Frontend on
# every route, before it reaches the container.
#
# So a supervisor running in a customer container could not authenticate, and
# every beat 403'd at the Google Frontend: the workload cannot report its own
# state if its report is refused at the door.
#
# ⚠ ONE CORRECTION TO THE FILING, RECORDED BECAUSE IT CHANGES WHERE YOU LOOK.
# `/internal/heartbeat` is NOT behind `is_tick_authenticated`.
# `job_manager_service.mojo:1918-1921` dispatches straight to
# `_handle_heartbeat_route`, which never calls that predicate — line 2365 is
# inside `_handle_tick_route`, gating `/internal/tick/*` and `/internal/place*`
# only. The gate that actually refuses the beat is the CLOUD RUN IAM INGRESS
# EDGE. The consequence for this file: the credential must be a Google-signed
# OIDC **ID token** whose `aud` is the JM's own service URL — NOT an OAuth2
# ACCESS token. `komira_gcp_core/creds_metadata.mojo` mints the latter off
# `/token` and is the WRONG instrument here; the right shape is
# `komira_peer_reachability/oidc.mojo`, whose identity-endpoint GET this file
# copies.
#
# ★ WHY THE SEAM RETURNS **HEADERS**, NOT A TOKEN. The obvious signature is
# `mint() -> String` and the caller writes `Authorization: Bearer <s>`. That
# shape does not extend to AWS and would have to be torn out. Measured: the AWS
# job-manager door is a Lambda **Function URL with `AuthType: AWS_IAM`**
# (`job-manager-aws.deploy.textproto:499`, `pod_spec.mojo:105`) — i.e. SigV4,
# which signs method + path + headers + body-hash and emits THREE headers, not
# one. So `jm_auth_headers` takes the method, the path and the body and returns
# a `List[HeaderEntry]`: the AWS arm is one more match arm with ZERO caller
# reshape. Nothing in this file is GCP-shaped except `GcpMetadataMinter`.
#
# ⛔ THE POSTURE IS DECLARED, NOT DERIVED FROM THE SCHEME, AND THAT IS THE
# LOAD-BEARING CHOICE. Deriving "https ⇒ mint a GCP token" would fix GCP with no
# cross-owner edit, but an ECS Fargate task has no GCP metadata server, so a
# fail-closed derive would red every AWS heartbeat, and a fail-OPEN derive would
# silently send the beat bearer-less — re-creating exactly the
# never-beat-at-all / beat-then-stopped ambiguity the heartbeat contract exists to
# remove. A declared posture is also the symmetric answer to the JM's own
# `KOMIRA_JM_INTERNAL_AUTH=iam`.
#
# ⛔ THE TOKEN IS SECRET MATERIAL AND LIVES ON NO CONFIGURATION CHANNEL. It is
# minted at run time off the metadata server into a local var, attached to one
# header, and never reaches argv, env, a log line or an error string. Every
# raise below carries the HTTP STATUS and the MODE, never the credential — an
# exception string is the most-copied text in an incident, and a JWT pasted into
# a ticket is a credential leak with a long tail.
#
# ENCAPSULATION + gap6: the surface is value-typed throughout (String in,
# `List[HeaderEntry]` out). No UnsafePointer crosses any boundary; no
# wildcard-origin field. Mojo 1.0.0.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderEntry, HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HTTP_METHOD_GET, HttpMethod
from komira_http_core.transport.kernel_tcp import KernelTcpConnector


# =============================================================================
# §1 — the GCP metadata identity endpoint (copied in shape from
#      komira_peer_reachability/oidc.mojo:89-178, which records why a COPY
#      rather than a dependency: that package is a leaf and this one must not
#      grow an edge to it for four constants).
# =============================================================================
comptime _METADATA_HOST: String = "metadata.google.internal"
comptime _METADATA_PORT: UInt16 = 80
comptime _METADATA_IDENTITY_PATH: String = (
    "/computeMetadata/v1/instance/service-accounts/default/identity"
)
comptime _METADATA_FLAVOR_HEADER: String = "Metadata-Flavor"
comptime _METADATA_FLAVOR_VALUE: String = "Google"

# The accepted spellings of KOMIRA_AGENT_JM_AUTH, rendered into the refusal so
# a typo tells the operator what it should have been.
comptime JM_AUTH_MODE_NONE_SPELLING: String = ""
comptime JM_AUTH_MODE_GCP_METADATA_SPELLING: String = "gcp-metadata"


# =============================================================================
# §2 — JmAuthMode — the DECLARED posture, a closed set.
# =============================================================================
struct JmAuthMode(Copyable, Movable, ImplicitlyCopyable):
    """How the supervisor authenticates to the job manager.

    A small Int tag, the `AgentPhase` idiom. Two arms today; the AWS SigV4 arm
    is the next tag and needs no change to this struct's shape."""

    var _tag: Int32  # 0 = none (bearer-less), 1 = GCP metadata ID token

    @always_inline
    def __init__(out self, tag: Int32):
        self._tag = tag

    @staticmethod
    @always_inline
    def none() -> JmAuthMode:
        """No credential. Byte-identical to the agent's behaviour before this seam existed, and
        the default — so an unset posture changes nothing about an in-cluster
        plaintext deploy."""
        return JmAuthMode(Int32(0))

    @staticmethod
    @always_inline
    def gcp_metadata() -> JmAuthMode:
        """Mint a Google-signed OIDC ID token off the instance metadata server,
        audience = the JM's own service URL."""
        return JmAuthMode(Int32(1))

    @always_inline
    def __eq__(self, other: JmAuthMode) -> Bool:
        return self._tag == other._tag

    @always_inline
    def __ne__(self, other: JmAuthMode) -> Bool:
        return self._tag != other._tag

    @always_inline
    def is_none(self) -> Bool:
        return self._tag == Int32(0)

    def name(self) -> String:
        """The MODE's own spelling, for logs and errors.

        ⛔ THIS RENDERS THE POSTURE AND NEVER A CREDENTIAL. It is the only
        thing the heartbeat's WARN line is permitted to say about auth."""
        if self._tag == Int32(1):
            return JM_AUTH_MODE_GCP_METADATA_SPELLING
        return String("none")


def parse_jm_auth_mode(s: String) raises -> JmAuthMode:
    """Parse the declared posture. EXACT match against a closed set.

    ⛔ A TYPO RAISES RATHER THAN FALLING BACK TO `none`, and that is the point.
    Silently degrading a misspelled `gcp_metadata` to bearer-less would beat
    into a 403 forever while every log line said the agent was healthy — the
    exact fail-open shape the heartbeat contract removes. Refusing at boot surfaces
    the mistake at its cause.

    ⚠ CASE-SENSITIVE ON PURPOSE. `GCP-METADATA` is refused rather than
    accepted, because a posture that accepts near-misses cannot tell an
    operator which spelling is canonical."""
    if s == JM_AUTH_MODE_NONE_SPELLING:
        return JmAuthMode.none()
    if s == JM_AUTH_MODE_GCP_METADATA_SPELLING:
        return JmAuthMode.gcp_metadata()
    raise Error(
        String("agent: KOMIRA_AGENT_JM_AUTH: unknown posture '")
        + s
        + String("' (accepted: '' for none, '")
        + JM_AUTH_MODE_GCP_METADATA_SPELLING
        + String("')")
    )


# =============================================================================
# §3 — jm_audience — the token's `aud`, derived from the JM URL.
# =============================================================================
def jm_audience(scheme: String, host: String, port: UInt16) -> String:
    """The Cloud Run SERVICE BASE URL the ID token must be minted for.

    ★ THE DEFAULT PORT IS OMITTED, AND THAT IS THE WHOLE CORRECTNESS CONDITION.
    Google validates the ID token's `aud` against the service URL, which is
    `https://job-manager-….run.app` — with NO `:443`. Minting for
    `https://host:443` produces a token the ingress edge rejects, which is
    indistinguishable at the agent from having no token at all. A non-default
    port IS rendered, so a self-hosted JM on `:8443` still gets a correct
    audience.

    Deriving this from the host/port the agent already has means the ordinary
    case needs no new deploy surface at all."""
    var default_port = UInt16(443) if scheme == String("https") else UInt16(80)
    if port == default_port:
        return scheme + String("://") + host
    return scheme + String("://") + host + String(":") + String(port)


def jm_credential_rides_in_clear(use_tls: Bool, mode: JmAuthMode) -> Bool:
    """True iff `mode` would attach a credential to a request that goes out in
    PLAINTEXT -- the one (transport, posture) pair that is never allowed.

    ⛔⛔ A BEARER CREDENTIAL NEVER RIDES A PLAINTEXT DIAL. Under
    `gcp-metadata` the credential is a Google-signed OIDC ID token; over plain
    HTTP it is readable on every hop and replayable until it expires, and it
    buys nothing, because the `http://` audience it would be minted for is one
    Cloud Run does not serve. So the pair is refused, not degraded: degrading to
    bearer-less would 403 at an IAM-gated door and read as a network blip.

    ★ ONE DEFINITION, THREE REFUSALS. `send_heartbeat_blocking` refuses the
    pair per beat, before the mint and before the dial; `AgentConfig.from_env`
    and `PodLoaderSupervisorConfig.from_env` refuse it once, at boot. They ask
    this function so the three cannot disagree about what "in the clear"
    means. (`GcpCloudProvider.create` refuses the same pair at placement with
    its own operator-facing text.)

    ⚠ `none` over plaintext is NOT this: it carries no credential, and it is the
    in-cluster / in-VPC posture every placement had before this seam."""
    return (not use_tls) and (not mode.is_none())


# =============================================================================
# §4 — JmTokenMinter — the seam. One method, and a conformer owns its
#      transport privately.
# =============================================================================
trait JmTokenMinter(Movable, Deinitable):
    """Mints the bearer credential for `audience`.

    ⚠ IT IS A TRAIT SO THE FAIL-CLOSED ARM CAN BE TESTED WITHOUT A HOST
    DEPENDENCY. Asserting "the mint fails because metadata.google.internal does
    not resolve here" would be a test of the BUILD BOX, and would flip
    green-to-red the day the suite runs on a GCE worker. A scripted conformer
    makes the refusal a property of the POSTURE, which is what is actually
    being claimed."""

    def mint(mut self, audience: String) raises -> String:
        """Return the raw bearer credential for `audience`. RAISES on any
        failure. ⛔ The raised Error must never carry the credential."""
        ...


struct GcpMetadataMinter(JmTokenMinter):
    """Mints a Google-signed OIDC **ID token** off the instance metadata
    server. The production conformer on GCP (Cloud Run Job, GCE VM, GKE).

    Copied in shape from `komira_peer_reachability/oidc.mojo:89-178` and from
    the live bash reference `deploy/factory-build/build_flow.sh:170-183`: GET
    the identity endpoint with `Metadata-Flavor: Google` over plain TCP on port
    80 — the metadata server is link-local (169.254.169.254) and is not
    TLS-fronted; dialling it over TLS fails.

    Holds no state: the token is a local in `mint` and is dropped as soon as the
    header is built. Nothing is cached, deliberately — a cached ID token is a
    credential with a lifetime nobody is tracking, and the beat cadence (~10s)
    is not a rate at which minting is a cost worth that risk."""

    var _placeholder: UInt8

    def __init__(out self):
        self._placeholder = UInt8(0)

    def mint(mut self, audience: String) raises -> String:
        """GET the metadata identity endpoint for `audience`; return the raw
        OIDC JWT.

        A non-2xx / empty / non-JWT body RAISES. ⛔ The error message NEVER
        carries the token or any part of it."""
        if audience.byte_length() == 0:
            raise Error("agent jm auth: empty audience")
        var path = (
            _METADATA_IDENTITY_PATH
            + String("?audience=")
            + _urlencode_query_component(audience)
            + String("&format=full")
        )
        var url = Url.http(_METADATA_HOST, _METADATA_PORT, path^)
        var headers = HeaderMap()
        headers.append(_METADATA_FLAVOR_HEADER, _METADATA_FLAVOR_VALUE)
        var req = build_request_with_body[EmptyBody](
            HttpMethod(code=HTTP_METHOD_GET),
            url^,
            headers^,
            EmptyBody.new(),
        )
        var client = HttpClient[KernelTcpConnector].with_defaults(
            KernelTcpConnector.new()
        )
        var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var cr = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req^, reactor
        )
        var status = Int(cr.status)
        var resp_bytes = cr.body.take_bytes()
        if status < 200 or status >= 300:
            raise Error(
                String("agent jm auth: metadata identity GET failed: HTTP ")
                + String(status)
            )
        var jwt = _strip_trailing_newline(
            String(unsafe_from_utf8=Span(resp_bytes))
        )
        if _dot_count(jwt) != 2 or jwt.byte_length() < 20:
            raise Error(
                "agent jm auth: metadata identity response is not a JWT"
            )
        return jwt^


# =============================================================================
# §5 — ★ THE SEAM ITSELF. Headers in the shape the caller sends them.
# =============================================================================
def jm_auth_headers[
    M: JmTokenMinter
](
    mode: JmAuthMode,
    mut minter: M,
    audience: String,
    method: String,
    path: String,
    body: List[UInt8],
) raises -> List[HeaderEntry]:
    """The auth headers for one job-manager request, or an EMPTY list under
    posture `none`.

    ⛔ A MINT FAILURE RAISES; IT DOES NOT RETURN AN EMPTY LIST. Degrading a
    declared posture to bearer-less is the fail-open path — the request would
    then 403 at the ingress edge and be reported to the agent loop as an
    ordinary transport failure, making "this image cannot authenticate"
    indistinguishable from "the network blipped". The heartbeat contract's premise
    is that those two must never share a code path.

    ⚠ `method`, `path` AND `body` ARE TAKEN THOUGH THE GCP ARM IGNORES THEM.
    That is not dead weight, it is the extension point: AWS SigV4 signs exactly
    those three plus the host, and emits `Authorization` + `X-Amz-Date` +
    `X-Amz-Content-Sha256`. Taking them now is what lets the AWS arm land as one
    additional branch with no caller reshape. A `-> String` bearer seam would
    have had to be torn out."""
    var out = List[HeaderEntry]()
    if mode.is_none():
        # The pre-existing behaviour, byte-for-byte: no header is added and the
        # request serializes exactly as it did before this file existed.
        _ = method
        _ = path
        _ = len(body)
        return out^
    if mode == JmAuthMode.gcp_metadata():
        _ = method
        _ = path
        _ = len(body)
        var token = minter.mint(audience)
        out.append(
            HeaderEntry(
                name=String("Authorization"),
                value=String("Bearer ") + token,
            )
        )
        return out^
    # Unreachable while the tag set is {0,1}; a new tag that forgets to add an
    # arm here must REFUSE rather than silently send bearer-less.
    raise Error(
        String("agent jm auth: no header arm for posture '")
        + mode.name()
        + String("'")
    )


# =============================================================================
# §6 — local helpers (copied with oidc.mojo's semantics).
# =============================================================================
def _urlencode_query_component(s: String) -> String:
    """Percent-encode `s` as a URL query component per RFC 3986 (the audience is
    a URL like `https://svc.run.app`, so `:` -> `%3A` / `/` -> `%2F`)."""
    var out = String("")
    var bs = s.as_bytes()
    var hex_chars = String("0123456789ABCDEF")
    for i in range(len(bs)):
        var b = bs[i]
        var is_alpha = (b >= UInt8(0x41) and b <= UInt8(0x5A)) or (
            b >= UInt8(0x61) and b <= UInt8(0x7A)
        )
        var is_digit = b >= UInt8(0x30) and b <= UInt8(0x39)
        var is_unreserved = (
            b == UInt8(0x2D)  # -
            or b == UInt8(0x5F)  # _
            or b == UInt8(0x2E)  # .
            or b == UInt8(0x7E)  # ~
        )
        if is_alpha or is_digit or is_unreserved:
            out += chr(Int(b))
        else:
            out += "%"
            out += chr(Int(ord(hex_chars[byte = Int(b >> 4)])))
            out += chr(Int(ord(hex_chars[byte = Int(b & 0x0F)])))
    return out^


def _strip_trailing_newline(s: String) -> String:
    var n = s.byte_length()
    if n > 0 and UInt8(ord(s[byte = (n - 1)])) == UInt8(0x0A):
        var out = List[UInt8]()
        var bs = s.as_bytes()
        for i in range(n - 1):
            out.append(bs[i])
        return String(unsafe_from_utf8=Span(out))
    return s


def _dot_count(s: String) -> Int:
    var bs = s.as_bytes()
    var c = 0
    for i in range(len(bs)):
        if bs[i] == UInt8(0x2E):
            c += 1
    return c
