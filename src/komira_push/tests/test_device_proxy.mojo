# =============================================================================
# komira_push/tests/test_device_proxy.mojo
#   register_device_for: the application route that registers its user's
#   device with notify.
# =============================================================================
#
# The defect this guards most is registering a device for someone else. The
# principal sent to notify must be the verified token's `iss` and `sub`, and
# a body that tries to name one (`onBehalfOf`) must be refused before notify
# is called. A missing subject or issuer is 401 and calls nothing.
#
# The status table: notify's 400 and 403 reach the UI as themselves; every
# other failure (not configured, no answer, 5xx) is 503. Each error body is
# the `{"error":{"code","message"}}` envelope, asserted byte for byte, and
# never quotes the request body.
# =============================================================================

from std.testing import assert_equal

from komira_http_server.middleware import Principal
from komira_notify_proto.notify import Device, DeviceTransport, ErrorEnvelope
from komira_proto_codec import decode_json
from komira_push import (
    NoopNotify,
    RecordingNotify,
    RegisterOutcome,
    error_body,
    register_device_for,
)


comptime WEB_BODY = (
    '{"transport":"DEVICE_TRANSPORT_WEB_PUSH",'
    '"webPush":{"endpoint":"https://push.example/s/1","p256dh":"BPk",'
    '"auth":"q1w"}}'
)


def _user() raises -> Principal:
    return Principal(scheme=String("jwt"), subject=String("user-1")).with_claim(
        String("iss"), String("https://issuer.example")
    )


def test_the_principal_comes_from_the_token() raises:
    var port = RecordingNotify()
    var spy = port.share()
    port.answer_register(
        RegisterOutcome.registered(
            200,
            Device(
                String("dev-1"),
                DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH),
            ),
        )
    )
    var reply = register_device_for(port, _user(), String(WEB_BODY))
    assert_equal(reply.status, 200)
    assert_equal(
        reply.body,
        String('{"deviceId":"dev-1","transport":"DEVICE_TRANSPORT_WEB_PUSH"}'),
    )
    assert_equal(spy.register_count(), 1)
    var sent = spy.register_at(0)
    assert_equal(sent.on_behalf_of.value().iss, String("https://issuer.example"))
    assert_equal(sent.on_behalf_of.value().sub, String("user-1"))
    ref d = sent.device.value()
    assert_equal(d.web_push.value().endpoint, String("https://push.example/s/1"))
    assert_equal(d.web_push.value().p256dh, String("BPk"))
    assert_equal(d.web_push.value().auth, String("q1w"))


def test_a_body_naming_a_principal_is_refused() raises:
    var port = RecordingNotify()
    var spy = port.share()
    var reply = register_device_for(
        port,
        _user(),
        String(
            '{"transport":"DEVICE_TRANSPORT_FCM","fcmToken":"t",'
            '"onBehalfOf":{"iss":"https://issuer.example","sub":"victim"}}'
        ),
    )
    assert_equal(reply.status, 400)
    assert_equal(
        reply.body,
        String(
            '{"error":{"code":"invalid_request",'
            '"message":"the body is not a device subscription"}}'
        ),
    )
    assert_equal(spy.register_count(), 0)


def test_a_bad_shape_is_400_with_the_rule() raises:
    var port = RecordingNotify()
    var spy = port.share()
    var reply = register_device_for(
        port,
        _user(),
        String(
            '{"transport":"DEVICE_TRANSPORT_WEB_PUSH","webPush":'
            '{"endpoint":"http://push.example/s/1","p256dh":"k","auth":"a"}}'
        ),
    )
    assert_equal(reply.status, 400)
    assert_equal(
        reply.body,
        String(
            '{"error":{"code":"invalid_request",'
            '"message":"komira_push: a web push endpoint is an https:// URL"}}'
        ),
    )
    assert_equal(spy.register_count(), 0)


def test_a_web_push_device_without_a_subscription_is_400() raises:
    var port = RecordingNotify()
    var spy = port.share()
    var reply = register_device_for(
        port, _user(), String('{"transport":"DEVICE_TRANSPORT_WEB_PUSH"}')
    )
    assert_equal(reply.status, 400)
    assert_equal(
        reply.body,
        String(
            '{"error":{"code":"invalid_request",'
            '"message":"komira_push: a web push device has no subscription"}}'
        ),
    )
    assert_equal(spy.register_count(), 0)


def test_no_subject_or_issuer_is_401() raises:
    var port = RecordingNotify()
    var spy = port.share()
    var r1 = register_device_for(
        port,
        Principal(scheme=String("jwt"), subject=String("")).with_claim(
            String("iss"), String("https://issuer.example")
        ),
        String(WEB_BODY),
    )
    assert_equal(r1.status, 401)
    assert_equal(
        r1.body,
        String(
            '{"error":{"code":"unauthenticated","message":"no verified subject"}}'
        ),
    )
    var r2 = register_device_for(
        port,
        Principal(scheme=String("jwt"), subject=String("user-1")),
        String(WEB_BODY),
    )
    assert_equal(r2.status, 401)
    assert_equal(
        r2.body,
        String(
            '{"error":{"code":"unauthenticated","message":"no verified issuer"}}'
        ),
    )
    assert_equal(spy.register_count(), 0)


def _status_for(notify_status: Int) raises -> Int:
    var port = RecordingNotify()
    port.answer_register(RegisterOutcome.failed(notify_status, String("x")))
    return register_device_for(port, _user(), String(WEB_BODY)).status


def test_the_status_table() raises:
    assert_equal(_status_for(400), 400)
    assert_equal(_status_for(403), 403)
    assert_equal(_status_for(0), 503)
    assert_equal(_status_for(401), 503)
    assert_equal(_status_for(404), 503)
    assert_equal(_status_for(500), 503)
    assert_equal(_status_for(503), 503)
    var port = RecordingNotify()
    port.answer_register(RegisterOutcome.failed(403, String("x")))
    assert_equal(
        register_device_for(port, _user(), String(WEB_BODY)).body,
        String(
            '{"error":{"code":"forbidden",'
            '"message":"device registration is not allowed"}}'
        ),
    )


def test_a_success_without_a_device_id_is_503() raises:
    # A port that answers ok with an empty device id (RemoteNotifyPort
    # refuses one; another port may not) must not reach the UI as a 200.
    var port = RecordingNotify()
    port.answer_register(
        RegisterOutcome.registered(
            200,
            Device(
                String(""),
                DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH),
            ),
        )
    )
    var reply = register_device_for(port, _user(), String(WEB_BODY))
    assert_equal(reply.status, 503)
    assert_equal(
        reply.body,
        String(
            '{"error":{"code":"unavailable",'
            '"message":"device registration failed"}}'
        ),
    )


def _round_trip(code: String, message: String) raises:
    var env = decode_json[ErrorEnvelope](error_body(code, message))
    assert_equal(env.error.value().code, code)
    assert_equal(env.error.value().message, message)


def test_the_error_body_escapes_and_decodes() raises:
    # error_body writes the envelope itself; the strict proto3 decoder of
    # ErrorEnvelope must read back exactly what went in, escapes included.
    assert_equal(
        error_body(String('a"b'), String("c\\d\ne\tf")),
        String('{"error":{"code":"a\\"b","message":"c\\\\d\\ne\\tf"}}'),
    )
    # A carriage return and a control byte (0x1F) take the \r and \u00XX
    # escapes.
    assert_equal(
        error_body(String("c"), String("a\rb") + String(chr(0x1F))),
        String('{"error":{"code":"c","message":"a\\rb\\u001f"}}'),
    )
    # An empty value is written, not omitted (proto3 JSON would omit it):
    # both members are always present.
    assert_equal(
        error_body(String("x"), String("")),
        String('{"error":{"code":"x","message":""}}'),
    )
    assert_equal(
        error_body(String(""), String("m")),
        String('{"error":{"code":"","message":"m"}}'),
    )
    _round_trip(String("invalid_request"), String('say "no"'))
    _round_trip(String(""), String(""))
    _round_trip(String("x"), String("back\\slash, new\nline, café"))


def test_noop_is_503() raises:
    var port = NoopNotify()
    var reply = register_device_for(port, _user(), String(WEB_BODY))
    assert_equal(reply.status, 503)
    assert_equal(
        reply.body,
        String(
            '{"error":{"code":"unavailable",'
            '"message":"device registration is unavailable"}}'
        ),
    )


def main() raises:
    test_the_principal_comes_from_the_token()
    test_a_body_naming_a_principal_is_refused()
    test_a_bad_shape_is_400_with_the_rule()
    test_a_web_push_device_without_a_subscription_is_400()
    test_no_subject_or_issuer_is_401()
    test_the_status_table()
    test_a_success_without_a_device_id_is_503()
    test_the_error_body_escapes_and_decodes()
    test_noop_is_503()
    print("PASS komira_push device proxy")
