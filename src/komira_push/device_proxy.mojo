# =============================================================================
# komira_push/device_proxy.mojo -- register a user's device through the app.
# =============================================================================
#
# A user's token is issued for one application, so the notify service does
# not accept it. The user's UI therefore sends its push subscription to its
# own application (`PUT /v1/devices` with the user's bearer token); the
# application's route calls `register_device_for` with the principal its
# token verifier produced and the request body, and answers with the
# returned status and body. `register_device_for`:
#
#   1. takes the principal from the verified token, never from the body:
#      `subject` must be non-empty and the `iss` claim present, else 401;
#   2. decodes the body strictly as a `DeviceSubscription` (so a body naming
#      `onBehalfOf`, or any other undeclared member, is refused) and checks
#      its shape, else 400;
#   3. calls `NotifyPort.register_device` with
#      `on_behalf_of = {iss, sub}` of that principal;
#   4. answers 200 with the `Device` JSON, or maps a failure: notify's 400
#      to 400, its 403 to 403, anything else (no answer, not configured, a
#      5xx, no client token) to 503.
#
# Every error body is the envelope `{"error":{"code":..,"message":..}}`
# (komira_notify_proto `ErrorEnvelope`). No message quotes the request body,
# the notify service's answer or a credential.
#
# Encapsulation: owned values only; no pointer anywhere.
# =============================================================================

from komira_http_server.middleware import Principal
from komira_proto_codec import decode_json, encode_json

from komira_notify_proto.notify import (
    DeviceSubscription,
    ErrorDetail,
    ErrorEnvelope,
    PrincipalRef,
    RegisterDevice,
)

from .notify_port import NotifyPort, check_device_subscription


@fieldwise_init
struct ProxyReply(Copyable, Movable, Deinitable):
    """The HTTP status and JSON body an application answers its UI with."""

    var status: Int
    var body: String


def error_body(code: String, message: String) -> String:
    """`{"error":{"code":"<code>","message":"<message>"}}`."""
    var env = ErrorEnvelope(
        Optional[ErrorDetail](ErrorDetail(code.copy(), message.copy()))
    )
    try:
        return encode_json(env)
    except:
        return String('{"error":{"code":"internal","message":""}}')


def _reply(status: Int, code: String, message: String) -> ProxyReply:
    return ProxyReply(status, error_body(code, message))


def register_device_for[
    P: NotifyPort
](mut port: P, principal: Principal, body: String) -> ProxyReply:
    """Register the device in `body` for `principal` (module header)."""
    if principal.subject.byte_length() == 0:
        return _reply(
            401, String("unauthenticated"), String("no verified subject")
        )
    var iss = principal.claims.get(String("iss"))
    if not iss or iss.value().byte_length() == 0:
        return _reply(
            401, String("unauthenticated"), String("no verified issuer")
        )
    var device: DeviceSubscription
    try:
        device = decode_json[DeviceSubscription](body)
    except:
        return _reply(
            400,
            String("invalid_request"),
            String("the body is not a device subscription"),
        )
    try:
        check_device_subscription(device)
    except e:
        return _reply(400, String("invalid_request"), String(e))
    var request = RegisterDevice(
        Optional[PrincipalRef](
            PrincipalRef(iss.value().copy(), principal.subject.copy())
        ),
        Optional[DeviceSubscription](device^),
    )
    var outcome = port.register_device(request)
    if outcome.ok:
        try:
            return ProxyReply(200, encode_json(outcome.device))
        except:
            return _reply(
                503, String("unavailable"), String("device registration failed")
            )
    if outcome.status == 400:
        return _reply(
            400,
            String("invalid_request"),
            String("the notify service refused the device"),
        )
    if outcome.status == 403:
        return _reply(
            403,
            String("forbidden"),
            String("device registration is not allowed"),
        )
    return _reply(
        503, String("unavailable"), String("device registration is unavailable")
    )
