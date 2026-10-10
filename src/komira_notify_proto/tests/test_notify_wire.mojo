# =============================================================================
# komira_notify_proto/tests/test_notify_wire.mojo
#   The notify wire as proto3 canonical JSON, byte for byte, and its field
#   numbers as protobuf bytes.
# =============================================================================
#
# The JSON goldens are written from the proto3 JSON mapping (lowerCamelCase
# member names, enums by name, scalars at their default value omitted), not
# read back from the encoder, so a renamed field, a renumbered enum value or
# a changed member name turns a golden red. Each golden is decoded again and
# compared, so the decoder reads what the encoder writes.
#
# The strict decoder must refuse a `source` member anywhere in a
# NotifyRequest: the notify service sets a wake's source from the caller's
# verified identity, and a request that tries to name it is a caller bug or
# an attempt to impersonate another service.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, encode_json, encode_proto

from komira_notify_proto.notify import (
    Device,
    DeviceSubscription,
    DeviceTransport,
    ErrorDetail,
    ErrorEnvelope,
    NotifyRequest,
    NotifyResult,
    PrincipalRef,
    RegisterDevice,
    Trigger,
    WebPushSubscription,
)


comptime NOTIFY_GOLDEN = (
    '{"recipient":{"iss":"https://issuer.example","sub":"user-1"},'
    '"trigger":{"id":"item-7","kind":"failed"},'
    '"idempotencyKey":"key-1"}'
)
comptime RESULT_GOLDEN = '{"sent":3,"accepted":1,"dead":1,"transient":1}'
comptime REGISTER_GOLDEN = (
    '{"onBehalfOf":{"iss":"https://issuer.example","sub":"user-1"},'
    '"device":{"transport":"DEVICE_TRANSPORT_WEB_PUSH",'
    '"webPush":{"endpoint":"https://push.example/s/1",'
    '"p256dh":"BPk","auth":"q1w"}}}'
)
comptime FCM_DEVICE_GOLDEN = (
    '{"transport":"DEVICE_TRANSPORT_FCM","fcmToken":"tok-1"}'
)
comptime DEVICE_GOLDEN = '{"deviceId":"dev-1","transport":"DEVICE_TRANSPORT_FCM"}'
comptime ERROR_GOLDEN = (
    '{"error":{"code":"invalid_request","message":"no device"}}'
)


def _who() -> PrincipalRef:
    return PrincipalRef(String("https://issuer.example"), String("user-1"))


def _notify() -> NotifyRequest:
    return NotifyRequest(
        Optional[PrincipalRef](_who()),
        Optional[Trigger](Trigger(String("item-7"), String("failed"))),
        String("key-1"),
    )


def test_notify_request_json() raises:
    assert_equal(encode_json(_notify()), String(NOTIFY_GOLDEN))
    var back = decode_json[NotifyRequest](String(NOTIFY_GOLDEN))
    assert_equal(back.recipient.value().iss, String("https://issuer.example"))
    assert_equal(back.recipient.value().sub, String("user-1"))
    assert_equal(back.trigger.value().id, String("item-7"))
    assert_equal(back.trigger.value().kind, String("failed"))
    assert_equal(back.idempotency_key, String("key-1"))


def test_notify_result_json() raises:
    var r = NotifyResult(UInt32(3), UInt32(1), UInt32(1), UInt32(1))
    assert_equal(encode_json(r), String(RESULT_GOLDEN))
    var back = decode_json[NotifyResult](String(RESULT_GOLDEN))
    assert_equal(back.sent, UInt32(3))
    assert_equal(back.accepted, UInt32(1))
    assert_equal(back.dead, UInt32(1))
    assert_equal(back.transient, UInt32(1))


def test_register_device_json() raises:
    var sub = WebPushSubscription(
        String("https://push.example/s/1"), String("BPk"), String("q1w")
    )
    var dev = DeviceSubscription(
        DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH),
        Optional[WebPushSubscription](sub^),
        String(""),
    )
    var reg = RegisterDevice(
        Optional[PrincipalRef](_who()), Optional[DeviceSubscription](dev^)
    )
    assert_equal(encode_json(reg), String(REGISTER_GOLDEN))
    var back = decode_json[RegisterDevice](String(REGISTER_GOLDEN))
    assert_equal(back.on_behalf_of.value().sub, String("user-1"))
    ref d = back.device.value()
    assert_equal(d.transport.value, DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH)
    assert_equal(d.web_push.value().endpoint, String("https://push.example/s/1"))
    assert_equal(d.web_push.value().p256dh, String("BPk"))
    assert_equal(d.web_push.value().auth, String("q1w"))


def test_fcm_subscription_and_device_json() raises:
    var dev = DeviceSubscription(
        DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_FCM),
        Optional[WebPushSubscription](None),
        String("tok-1"),
    )
    assert_equal(encode_json(dev), String(FCM_DEVICE_GOLDEN))
    var d = Device(
        String("dev-1"), DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_FCM)
    )
    assert_equal(encode_json(d), String(DEVICE_GOLDEN))
    var back = decode_json[Device](String(DEVICE_GOLDEN))
    assert_equal(back.device_id, String("dev-1"))
    assert_equal(back.transport.value, DeviceTransport.DEVICE_TRANSPORT_FCM)


def test_error_envelope_json() raises:
    var e = ErrorEnvelope(
        Optional[ErrorDetail](
            ErrorDetail(String("invalid_request"), String("no device"))
        )
    )
    assert_equal(encode_json(e), String(ERROR_GOLDEN))


def test_enum_numbers() raises:
    assert_equal(DeviceTransport.DEVICE_TRANSPORT_UNSPECIFIED, 0)
    assert_equal(DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH, 1)
    assert_equal(DeviceTransport.DEVICE_TRANSPORT_FCM, 2)


def test_notify_request_field_numbers() raises:
    # recipient = 1 (tag 0x0A), trigger = 2 (0x12), idempotency_key = 3
    # (0x1A); inside, iss/id = 1 (0x0A) and sub/kind = 2 (0x12).
    var r = NotifyRequest(
        Optional[PrincipalRef](PrincipalRef(String("i"), String("s"))),
        Optional[Trigger](Trigger(String("d"), String("k"))),
        String("x"),
    )
    var want: List[UInt8] = [
        0x0A, 0x06, 0x0A, 0x01, 0x69, 0x12, 0x01, 0x73,
        0x12, 0x06, 0x0A, 0x01, 0x64, 0x12, 0x01, 0x6B,
        0x1A, 0x01, 0x78,
    ]
    assert_equal(encode_proto(r), want)


def _refusal(body: String) -> String:
    try:
        _ = decode_json[NotifyRequest](body)
    except e:
        return String(e)
    return String("<decoded>")


def test_a_source_in_the_trigger_is_refused() raises:
    var msg = _refusal(
        String(
            '{"recipient":{"iss":"i","sub":"s"},'
            '"trigger":{"id":"d","kind":"k","source":"other-service"},'
            '"idempotencyKey":"x"}'
        )
    )
    assert_true(
        msg.startswith('JsonError: unknown field "source" at $.trigger'), msg
    )


def test_a_source_at_the_top_is_refused() raises:
    var msg = _refusal(
        String(
            '{"recipient":{"iss":"i","sub":"s"},'
            '"trigger":{"id":"d","kind":"k"},"source":"other-service"}'
        )
    )
    assert_true(msg.startswith('JsonError: unknown field "source" at $'), msg)


def main() raises:
    test_notify_request_json()
    test_notify_result_json()
    test_register_device_json()
    test_fcm_subscription_and_device_json()
    test_error_envelope_json()
    test_enum_numbers()
    test_notify_request_field_numbers()
    test_a_source_in_the_trigger_is_refused()
    test_a_source_at_the_top_is_refused()
    print("PASS komira_notify_proto notify wire")
