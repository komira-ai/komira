# =============================================================================
# komira_push/tests/test_notify_requests.mojo
#   The request shape rules and the strict parsers both ends use.
# =============================================================================
#
# A recipient must name a real principal. A caller that never set an owner
# sends an empty subject or the nil UUID, and a wake addressed that way
# reaches nobody, so an empty `sub`, an empty `iss` and the nil UUID are each
# refused by name. A request body naming a wake
# `source` is refused by `parse_notify_request` (strict decoding); a lenient
# decoder would drop the member and let the request through, which this
# test would see. The device rules refuse a credential that does not match
# its transport, and a plain-http Web Push endpoint.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_notify_proto.notify import (
    DeviceSubscription,
    DeviceTransport,
    NotifyRequest,
    PrincipalRef,
    Trigger,
    WebPushSubscription,
)
from komira_push import (
    check_device_subscription,
    check_notify_request,
    parse_device_subscription,
    parse_notify_request,
    parse_register_device,
)


def _req(iss: String, sub: String, id: String, kind: String, key: String) -> NotifyRequest:
    return NotifyRequest(
        Optional[PrincipalRef](PrincipalRef(iss.copy(), sub.copy())),
        Optional[Trigger](Trigger(id.copy(), kind.copy())),
        key.copy(),
    )


def _err(r: NotifyRequest) -> String:
    try:
        check_notify_request(r)
    except e:
        return String(e)
    return String("<accepted>")


def _parse_err(body: String) -> String:
    try:
        _ = parse_notify_request(body)
    except e:
        return String(e)
    return String("<accepted>")


def _dev_err(d: DeviceSubscription) -> String:
    try:
        check_device_subscription(d)
    except e:
        return String(e)
    return String("<accepted>")


def _web(endpoint: String, p256dh: String, auth: String, fcm: String) -> DeviceSubscription:
    return DeviceSubscription(
        DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH),
        Optional[WebPushSubscription](
            WebPushSubscription(endpoint.copy(), p256dh.copy(), auth.copy())
        ),
        fcm.copy(),
    )


def _fcm(token: String, with_web: Bool) -> DeviceSubscription:
    var web = Optional[WebPushSubscription](None)
    if with_web:
        web = Optional[WebPushSubscription](
            WebPushSubscription(String("https://push.example/2"), String("k"), String("a"))
        )
    return DeviceSubscription(
        DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_FCM), web^, token.copy()
    )


def test_a_well_formed_request_is_accepted() raises:
    assert_equal(_err(_req("https://issuer.example", "user-1", "i", "k", "key")), String("<accepted>"))


def test_the_recipient_rules() raises:
    assert_equal(
        _err(_req("https://issuer.example", "", "i", "k", "key")),
        String("komira_push: the recipient sub is empty"),
    )
    assert_equal(
        _err(_req("", "user-1", "i", "k", "key")),
        String("komira_push: the recipient iss is empty"),
    )
    assert_equal(
        _err(
            _req(
                "https://issuer.example",
                "00000000-0000-0000-0000-000000000000",
                "i",
                "k",
                "key",
            )
        ),
        String("komira_push: the recipient sub is the nil UUID"),
    )
    var no_recipient = NotifyRequest(
        Optional[PrincipalRef](None),
        Optional[Trigger](Trigger(String("i"), String("k"))),
        String("key"),
    )
    assert_equal(
        _err(no_recipient), String("komira_push: the recipient is missing")
    )


def test_the_trigger_and_key_rules() raises:
    assert_equal(
        _err(_req("https://issuer.example", "u", "", "k", "key")),
        String("komira_push: the trigger id is empty"),
    )
    assert_equal(
        _err(_req("https://issuer.example", "u", "i", "", "key")),
        String("komira_push: the trigger kind is empty"),
    )
    assert_equal(
        _err(_req("https://issuer.example", "u", "i", "k", "")),
        String("komira_push: the idempotency key is empty"),
    )


def test_a_missing_trigger_is_refused() raises:
    var r = NotifyRequest(
        Optional[PrincipalRef](
            PrincipalRef(String("https://issuer.example"), String("u"))
        ),
        Optional[Trigger](None),
        String("key"),
    )
    assert_equal(_err(r), String("komira_push: the trigger is missing"))
    assert_equal(
        _parse_err(
            String(
                '{"recipient":{"iss":"https://issuer.example","sub":"u"},'
                '"idempotencyKey":"key"}'
            )
        ),
        String("komira_push: the trigger is missing"),
    )


def test_parse_accepts_a_well_formed_body() raises:
    var r = parse_notify_request(
        String(
            '{"recipient":{"iss":"https://issuer.example","sub":"u"},'
            '"trigger":{"id":"i","kind":"k"},"idempotencyKey":"key"}'
        )
    )
    assert_equal(r.recipient.value().sub, String("u"))


def test_parse_refuses_a_source() raises:
    var msg = _parse_err(
        String(
            '{"recipient":{"iss":"https://issuer.example","sub":"u"},'
            '"trigger":{"id":"i","kind":"k","source":"someone-else"},'
            '"idempotencyKey":"key"}'
        )
    )
    assert_true(
        msg.startswith('JsonError: unknown field "source" at $.trigger'), msg
    )


def test_parse_checks_the_shape() raises:
    assert_equal(
        _parse_err(
            String(
                '{"recipient":{"iss":"https://issuer.example","sub":""},'
                '"trigger":{"id":"i","kind":"k"},"idempotencyKey":"key"}'
            )
        ),
        String("komira_push: the recipient sub is empty"),
    )


def test_the_device_rules() raises:
    assert_equal(_dev_err(_web("https://push.example/1", "k", "a", "")), String("<accepted>"))
    assert_equal(_dev_err(_fcm("tok", False)), String("<accepted>"))
    assert_equal(
        _dev_err(_web("http://push.example/1", "k", "a", "")),
        String("komira_push: a web push endpoint is an https:// URL"),
    )
    assert_equal(
        _dev_err(_web("https://push.example/1", "", "a", "")),
        String("komira_push: the web push p256dh key is empty"),
    )
    assert_equal(
        _dev_err(_web("https://push.example/1", "k", "", "")),
        String("komira_push: the web push auth secret is empty"),
    )
    assert_equal(
        _dev_err(_web("https://push.example/1", "k", "a", "tok")),
        String("komira_push: a web push device carries an FCM token"),
    )
    var bare_web = DeviceSubscription(
        DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH),
        Optional[WebPushSubscription](None),
        String(""),
    )
    assert_equal(
        _dev_err(bare_web),
        String("komira_push: a web push device has no subscription"),
    )
    assert_equal(
        _dev_err(_fcm("", False)),
        String("komira_push: an FCM device has no token"),
    )
    assert_equal(
        _dev_err(_fcm("tok", True)),
        String("komira_push: an FCM device carries a web push subscription"),
    )
    var unset = DeviceSubscription(
        DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_UNSPECIFIED),
        Optional[WebPushSubscription](None),
        String("tok"),
    )
    assert_equal(
        _dev_err(unset), String("komira_push: the device transport is not set")
    )


def test_a_subscription_naming_a_principal_is_refused() raises:
    var msg = String("<accepted>")
    try:
        _ = parse_device_subscription(
            String(
                '{"transport":"DEVICE_TRANSPORT_FCM","fcmToken":"t",'
                '"onBehalfOf":{"iss":"https://issuer.example","sub":"victim"}}'
            )
        )
    except e:
        msg = String(e)
    assert_true(
        msg.startswith('JsonError: unknown field "onBehalfOf" at $'), msg
    )


def test_parse_device_subscription() raises:
    # A well-formed body decodes; a body that decodes but breaks a device
    # rule is refused by the shape check, with the rule's message.
    var d = parse_device_subscription(
        String('{"transport":"DEVICE_TRANSPORT_FCM","fcmToken":"t"}')
    )
    assert_equal(d.transport.value, DeviceTransport.DEVICE_TRANSPORT_FCM)
    assert_equal(d.fcm_token, String("t"))
    var msg = String("<accepted>")
    try:
        _ = parse_device_subscription(
            String('{"transport":"DEVICE_TRANSPORT_FCM"}')
        )
    except e:
        msg = String(e)
    assert_equal(msg, String("komira_push: an FCM device has no token"))


def test_parse_register_device() raises:
    var r = parse_register_device(
        String(
            '{"onBehalfOf":{"iss":"https://issuer.example","sub":"u"},'
            '"device":{"transport":"DEVICE_TRANSPORT_FCM","fcmToken":"t"}}'
        )
    )
    assert_equal(r.device.value().fcm_token, String("t"))
    var msg = String("<accepted>")
    try:
        _ = parse_register_device(
            String('{"onBehalfOf":{"iss":"https://issuer.example","sub":"u"}}')
        )
    except e:
        msg = String(e)
    assert_equal(msg, String("komira_push: the device is missing"))
    msg = String("<accepted>")
    try:
        _ = parse_register_device(
            String(
                '{"onBehalfOf":{"iss":"https://issuer.example","sub":"u"},'
                '"device":{"transport":"DEVICE_TRANSPORT_FCM","fcmToken":"t"},'
                '"source":"someone-else"}'
            )
        )
    except e:
        msg = String(e)
    assert_true(msg.startswith('JsonError: unknown field "source" at $'), msg)


def main() raises:
    test_a_well_formed_request_is_accepted()
    test_the_recipient_rules()
    test_the_trigger_and_key_rules()
    test_a_missing_trigger_is_refused()
    test_parse_accepts_a_well_formed_body()
    test_parse_refuses_a_source()
    test_parse_checks_the_shape()
    test_the_device_rules()
    test_a_subscription_naming_a_principal_is_refused()
    test_parse_device_subscription()
    test_parse_register_device()
    print("PASS komira_push notify requests")
