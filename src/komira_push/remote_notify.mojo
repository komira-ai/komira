# =============================================================================
# komira_push/remote_notify.mojo -- NotifyPort over HTTP: the notify wire.
# =============================================================================
#
# `RemoteNotifyPort[T, S]` sends the requests of docs/design/notify_wire.md
# through an `HttpTransport` `T`, with `Authorization: Bearer <token>` where
# the token comes from a `BearerTokenSource` `S`, fetched on every call. In a
# deployment that source returns the application's client token for the
# notify service's audience (an OAuth client-credentials token); the port
# never mints, caches or logs it.
#
#   notify           POST {base}/v1/notify    NotifyRequest -> 202 NotifyResult
#   register_device  PUT  {base}/v1/devices   RegisterDevice -> 200 Device
#
# What the port does, in order:
#   1. checks the request's shape (notify_port.mojo); a refused request is
#      never sent, and its outcome carries the check's message with status 0;
#   2. fetches the token; a failure is the outcome "the client token is
#      unavailable", status 0, and nothing is sent;
#   3. sends; a transport that raises is the outcome "no answer from the
#      notify service", status 0;
#   4. reads the answer: only 202 (notify) or 200 (register) is success, and
#      its body must decode and, for notify, balance
#      (accepted + dead + transient == sent). Any other status is the outcome
#      "the notify service answered <status>", and the body is not quoted.
#
# The answer body is decoded leniently (an unknown member is skipped), so a
# newer service that adds a member to NotifyResult or Device still reads; the
# requests the service receives are decoded strictly on its side.
#
# Encapsulation: no pointer anywhere; the port owns its transport and token
# source by value.
# =============================================================================

from komira_http_client.auth import BearerTokenSource
from komira_http_client.http_transport import (
    HttpTransport,
    PM_METHOD_POST,
    PM_METHOD_PUT,
)
from komira_proto_codec import decode_json_lenient, encode_json

from komira_notify_proto.notify import (
    Device,
    NotifyRequest,
    NotifyResult,
    RegisterDevice,
)

from .notify_port import (
    NotifyOutcome,
    NotifyPort,
    RegisterOutcome,
    check_notify_request,
    check_register_device,
)


comptime NOTIFY_PATH: String = "/v1/notify"
comptime DEVICES_PATH: String = "/v1/devices"
comptime NOTIFY_ACCEPTED: Int = 202
comptime DEVICE_REGISTERED: Int = 200


def _loopback_host(host: String) -> Bool:
    return host == "127.0.0.1" or host == "localhost" or host == "[::1]"


def check_notify_base_url(url: String) raises -> String:
    """The notify service's base URL, without a trailing `/`: `https://` and
    a host, or `http://` to a loopback host (127.0.0.1, localhost, [::1]) for
    tests. No path beyond `/`, no query and no fragment, so the routes are
    always `{base}/v1/...`."""
    var start: Int
    var plain = False
    if url.startswith("https://"):
        start = 8
    elif url.startswith("http://"):
        start = 7
        plain = True
    else:
        raise Error("komira_push: the notify URL is not https://")
    var end = url.byte_length()
    if end > start and url.endswith("/"):
        end -= 1
    var rest = String(url[byte=start:end])
    if rest.byte_length() == 0:
        raise Error("komira_push: the notify URL has no host")
    var b = rest.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if (
            c == UInt8(ord("/"))
            or c == UInt8(ord("?"))
            or c == UInt8(ord("#"))
            or c == UInt8(ord("@"))
        ):
            raise Error(
                "komira_push: the notify URL is a scheme and a host only"
            )
    if plain:
        var host_end = rest.byte_length()
        if rest.startswith("["):
            var close = rest.find("]")
            if close < 0:
                raise Error("komira_push: the notify URL host is malformed")
            host_end = close + 1
        else:
            var colon = rest.find(":")
            if colon >= 0:
                host_end = colon
        var host = String(rest[byte=0:host_end])
        if not _loopback_host(host):
            raise Error(
                "komira_push: a plain http:// notify URL must name a loopback"
                " host"
            )
    if plain:
        return String("http://") + rest
    return String("https://") + rest


struct RemoteNotifyPort[T: HttpTransport, S: BearerTokenSource](
    NotifyPort, Movable, Deinitable
):
    """`NotifyPort` over the notify wire (module header)."""

    var _transport: Self.T
    var _tokens: Self.S
    var _base: String

    def __init__(
        out self, var transport: Self.T, var tokens: Self.S, base_url: String
    ) raises:
        """Refuses a base URL `check_notify_base_url` refuses."""
        self._base = check_notify_base_url(base_url)
        self._transport = transport^
        self._tokens = tokens^

    def _send(
        mut self, method: Int, path: String, body: String, mut status: Int
    ) -> String:
        """Sends `body`; returns the answer body and sets `status`, or sets
        `status` to -1 when there is no token and to 0 when there is no
        answer."""
        var token: String
        try:
            token = self._tokens.fetch_token()
        except:
            status = -1
            return String("")
        try:
            var resp = self._transport.request(
                method,
                self._base + path,
                String("Authorization"),
                String("Bearer ") + token,
                body,
            )
            status = resp.status
            return resp.body.copy()
        except:
            status = 0
            return String("")

    def notify(mut self, request: NotifyRequest) -> NotifyOutcome:
        # The shape check is the only refusal here: encode_json raises for
        # none of the notify messages (strings, uint32s, an enum and
        # sub-messages), so one handler serves both calls.
        var body: String
        try:
            check_notify_request(request)
            body = encode_json(request)
        except e:
            return NotifyOutcome.failed(0, String(e))
        var status = 0
        var answer = self._send(PM_METHOD_POST, String(NOTIFY_PATH), body, status)
        if status == -1:
            return NotifyOutcome.failed(
                0, String("komira_push: the client token is unavailable")
            )
        if status == 0:
            return NotifyOutcome.failed(
                0, String("komira_push: no answer from the notify service")
            )
        if status != NOTIFY_ACCEPTED:
            return NotifyOutcome.failed(
                status,
                String("komira_push: the notify service answered ")
                + String(status),
            )
        try:
            var result = decode_json_lenient[NotifyResult](answer)
            var counted = (
                UInt64(result.accepted)
                + UInt64(result.dead)
                + UInt64(result.transient)
            )
            if counted != UInt64(result.sent):
                return NotifyOutcome.failed(
                    status,
                    String(
                        "komira_push: the notify result does not balance"
                        " (accepted + dead + transient != sent)"
                    ),
                )
            return NotifyOutcome.accepted(status, result^)
        except:
            return NotifyOutcome.failed(
                status, String("komira_push: the notify result is unreadable")
            )

    def register_device(mut self, request: RegisterDevice) -> RegisterOutcome:
        # The shape check is the only refusal here: encode_json raises for
        # none of the notify messages (strings, uint32s, an enum and
        # sub-messages), so one handler serves both calls.
        var body: String
        try:
            check_register_device(request)
            body = encode_json(request)
        except e:
            return RegisterOutcome.failed(0, String(e))
        var status = 0
        var answer = self._send(PM_METHOD_PUT, String(DEVICES_PATH), body, status)
        if status == -1:
            return RegisterOutcome.failed(
                0, String("komira_push: the client token is unavailable")
            )
        if status == 0:
            return RegisterOutcome.failed(
                0, String("komira_push: no answer from the notify service")
            )
        if status != DEVICE_REGISTERED:
            return RegisterOutcome.failed(
                status,
                String("komira_push: the notify service answered ")
                + String(status),
            )
        try:
            var device = decode_json_lenient[Device](answer)
            if device.device_id.byte_length() == 0:
                return RegisterOutcome.failed(
                    status, String("komira_push: the device id is empty")
                )
            return RegisterOutcome.registered(status, device^)
        except:
            return RegisterOutcome.failed(
                status, String("komira_push: the device answer is unreadable")
            )
