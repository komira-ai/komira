# =============================================================================
# komira_push/tests/test_remote_notify.mojo
#   RemoteNotifyPort over a scripted transport: the bytes it sends and how it
#   reads every answer.
# =============================================================================
#
# The request goldens are the notify wire (docs/design/notify_wire.md):
# method, URL, the one Authorization header and the JSON body, byte for byte.
#
# The answer table sends every status that is not the success status and
# checks each is a failure carrying that status, with a reason that does not
# quote the body. A 503 in that table is the case a best-effort caller cares
# about most: the port must return it as an outcome, and the port's methods
# cannot raise (the trait declares them without `raises`), so a caller's
# business path never sees an exception from a wake.
#
# A raising transport and a raising token source are failures too; a notify
# request or a registration that fails its shape check, and a missing token,
# each send nothing. The balance check sums in 64 bits: a result that
# balances only after a 32-bit wrap is a failure.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_client.auth import BearerTokenSource, StaticTokenSource
from komira_http_client.http_transport import (
    PM_METHOD_POST,
    PM_METHOD_PUT,
    SharedScriptedTransport,
)
from komira_notify_proto.notify import (
    DeviceSubscription,
    DeviceTransport,
    NotifyRequest,
    PrincipalRef,
    RegisterDevice,
    Trigger,
    WebPushSubscription,
)
from komira_push import RemoteNotifyPort, check_notify_base_url


comptime BASE = "https://notify.example"
comptime NOTIFY_BODY = (
    '{"recipient":{"iss":"https://issuer.example","sub":"user-1"},'
    '"trigger":{"id":"item-7","kind":"failed"},'
    '"idempotencyKey":"key-1"}'
)
comptime REGISTER_BODY = (
    '{"onBehalfOf":{"iss":"https://issuer.example","sub":"user-1"},'
    '"device":{"transport":"DEVICE_TRANSPORT_WEB_PUSH",'
    '"webPush":{"endpoint":"https://push.example/s/1",'
    '"p256dh":"BPk","auth":"q1w"}}}'
)
comptime SECRET_BODY = "do-not-echo-this-body"


struct _NoToken(BearerTokenSource, Movable, Deinitable):
    def __init__(out self):
        pass

    def fetch_token(self) raises -> String:
        raise Error("token endpoint said no")


def _notify_request(sub: String) -> NotifyRequest:
    return NotifyRequest(
        Optional[PrincipalRef](
            PrincipalRef(String("https://issuer.example"), sub.copy())
        ),
        Optional[Trigger](Trigger(String("item-7"), String("failed"))),
        String("key-1"),
    )


def _register_request() -> RegisterDevice:
    var dev = DeviceSubscription(
        DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH),
        Optional[WebPushSubscription](
            WebPushSubscription(
                String("https://push.example/s/1"), String("BPk"), String("q1w")
            )
        ),
        String(""),
    )
    return RegisterDevice(
        Optional[PrincipalRef](
            PrincipalRef(String("https://issuer.example"), String("user-1"))
        ),
        Optional[DeviceSubscription](dev^),
    )


comptime Port = RemoteNotifyPort[SharedScriptedTransport, StaticTokenSource]


def _port(status: Int, body: String, mut spy: SharedScriptedTransport) raises -> Port:
    var t = SharedScriptedTransport()
    t.add(String(""), status, body)
    spy = t.share()
    return Port(t^, StaticTokenSource(String("client-token")), String(BASE))


def test_notify_sends_the_golden_request() raises:
    var spy = SharedScriptedTransport()
    var port = _port(
        202, String('{"sent":2,"accepted":1,"dead":1}'), spy
    )
    var out = port.notify(_notify_request(String("user-1")))
    assert_true(out.ok, out.reason)
    assert_equal(out.status, 202)
    assert_equal(out.result.sent, UInt32(2))
    assert_equal(out.result.accepted, UInt32(1))
    assert_equal(out.result.dead, UInt32(1))
    assert_equal(out.result.transient, UInt32(0))
    assert_equal(spy.call_count(), 1)
    assert_equal(spy.method_at(0), PM_METHOD_POST)
    assert_equal(spy.url_at(0), String("https://notify.example/v1/notify"))
    assert_equal(spy.header_name_at(0), String("Authorization"))
    assert_equal(spy.header_value_at(0), String("Bearer client-token"))
    assert_equal(spy.body_at(0), String(NOTIFY_BODY))


def test_register_sends_the_golden_request() raises:
    var spy = SharedScriptedTransport()
    var port = _port(
        200,
        String('{"deviceId":"dev-9","transport":"DEVICE_TRANSPORT_WEB_PUSH"}'),
        spy,
    )
    var out = port.register_device(_register_request())
    assert_true(out.ok, out.reason)
    assert_equal(out.status, 200)
    assert_equal(out.device.device_id, String("dev-9"))
    assert_equal(
        out.device.transport.value, DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH
    )
    assert_equal(spy.method_at(0), PM_METHOD_PUT)
    assert_equal(spy.url_at(0), String("https://notify.example/v1/devices"))
    assert_equal(spy.header_name_at(0), String("Authorization"))
    assert_equal(spy.header_value_at(0), String("Bearer client-token"))
    assert_equal(spy.body_at(0), String(REGISTER_BODY))


def test_every_other_notify_status_is_a_failure() raises:
    var statuses: List[Int] = [200, 201, 204, 400, 401, 403, 404, 409, 429, 500, 503]
    for i in range(len(statuses)):
        var s = statuses[i]
        var spy = SharedScriptedTransport()
        var port = _port(s, String(SECRET_BODY), spy)
        var out = port.notify(_notify_request(String("user-1")))
        assert_false(out.ok, String(s))
        assert_equal(out.status, s)
        assert_equal(
            out.reason,
            String("komira_push: the notify service answered ") + String(s),
        )
        assert_equal(spy.call_count(), 1)


def test_every_other_register_status_is_a_failure() raises:
    var statuses: List[Int] = [201, 202, 400, 401, 403, 404, 500, 503]
    for i in range(len(statuses)):
        var s = statuses[i]
        var spy = SharedScriptedTransport()
        var port = _port(s, String(SECRET_BODY), spy)
        var out = port.register_device(_register_request())
        assert_false(out.ok, String(s))
        assert_equal(out.status, s)
        assert_equal(
            out.reason,
            String("komira_push: the notify service answered ") + String(s),
        )


def test_an_unbalanced_result_is_a_failure() raises:
    var spy = SharedScriptedTransport()
    var port = _port(202, String('{"sent":3,"accepted":1}'), spy)
    var out = port.notify(_notify_request(String("user-1")))
    assert_false(out.ok)
    assert_equal(out.status, 202)
    assert_equal(
        out.reason,
        String(
            "komira_push: the notify result does not balance"
            " (accepted + dead + transient != sent)"
        ),
    )


def test_a_result_that_balances_only_in_32_bits_is_a_failure() raises:
    # 4294967295 + 1 wraps to 0 in UInt32; the sum is taken in UInt64.
    var spy = SharedScriptedTransport()
    var port = _port(
        202, String('{"sent":0,"accepted":4294967295,"dead":1}'), spy
    )
    var out = port.notify(_notify_request(String("user-1")))
    assert_false(out.ok)
    assert_equal(out.status, 202)
    assert_equal(
        out.reason,
        String(
            "komira_push: the notify result does not balance"
            " (accepted + dead + transient != sent)"
        ),
    )


def test_a_result_that_balances_after_any_32_bit_pairing_is_a_failure() raises:
    # Every count is 2^31. Any two of accepted, dead, transient wrap to 0 in
    # UInt32, and the full UInt32 sum (3 * 2^31 mod 2^32) is 2^31 = sent, so
    # a sum that adds any pair, or all three, before widening balances. The
    # UInt64 sum is 6442450944, which is not sent.
    var spy = SharedScriptedTransport()
    var port = _port(
        202,
        String(
            '{"sent":2147483648,"accepted":2147483648,"dead":2147483648,'
            '"transient":2147483648}'
        ),
        spy,
    )
    var out = port.notify(_notify_request(String("user-1")))
    assert_false(out.ok)
    assert_equal(out.status, 202)
    assert_equal(
        out.reason,
        String(
            "komira_push: the notify result does not balance"
            " (accepted + dead + transient != sent)"
        ),
    )


def test_an_unreadable_result_is_a_failure() raises:
    var spy = SharedScriptedTransport()
    var port = _port(202, String(SECRET_BODY), spy)
    var out = port.notify(_notify_request(String("user-1")))
    assert_false(out.ok)
    assert_equal(out.reason, String("komira_push: the notify result is unreadable"))


def test_a_newer_result_member_is_skipped() raises:
    var spy = SharedScriptedTransport()
    var port = _port(202, String('{"sent":1,"accepted":1,"queued":0}'), spy)
    var out = port.notify(_notify_request(String("user-1")))
    assert_true(out.ok, out.reason)


def test_an_empty_device_id_is_a_failure() raises:
    var spy = SharedScriptedTransport()
    var port = _port(200, String('{"transport":"DEVICE_TRANSPORT_FCM"}'), spy)
    var out = port.register_device(_register_request())
    assert_false(out.ok)
    assert_equal(out.reason, String("komira_push: the device id is empty"))


def test_a_raising_transport_is_a_failure() raises:
    # No scripted row: SharedScriptedTransport raises on the request.
    var t = SharedScriptedTransport()
    var spy = t.share()
    var port = Port(t^, StaticTokenSource(String("client-token")), String(BASE))
    var out = port.notify(_notify_request(String("user-1")))
    assert_false(out.ok)
    assert_equal(out.status, 0)
    assert_equal(
        out.reason, String("komira_push: no answer from the notify service")
    )
    assert_equal(spy.call_count(), 1)


def test_a_raising_transport_is_a_failed_registration() raises:
    # No scripted row: SharedScriptedTransport raises on the request.
    var t = SharedScriptedTransport()
    var spy = t.share()
    var port = Port(t^, StaticTokenSource(String("client-token")), String(BASE))
    var out = port.register_device(_register_request())
    assert_false(out.ok)
    assert_equal(out.status, 0)
    assert_equal(
        out.reason, String("komira_push: no answer from the notify service")
    )
    assert_equal(spy.call_count(), 1)


def test_an_unreadable_device_answer_is_a_failure() raises:
    var spy = SharedScriptedTransport()
    var port = _port(200, String(SECRET_BODY), spy)
    var out = port.register_device(_register_request())
    assert_false(out.ok)
    assert_equal(out.status, 200)
    assert_equal(
        out.reason, String("komira_push: the device answer is unreadable")
    )


def test_a_missing_token_sends_nothing() raises:
    var t = SharedScriptedTransport()
    t.add(String(""), 202, String('{"sent":0}'))
    var spy = t.share()
    var port = RemoteNotifyPort[SharedScriptedTransport, _NoToken](
        t^, _NoToken(), String(BASE)
    )
    var out = port.notify(_notify_request(String("user-1")))
    assert_false(out.ok)
    assert_equal(out.status, 0)
    assert_equal(out.reason, String("komira_push: the client token is unavailable"))
    var reg = port.register_device(_register_request())
    assert_false(reg.ok)
    assert_equal(reg.reason, String("komira_push: the client token is unavailable"))
    assert_equal(spy.call_count(), 0)


def test_a_refused_request_sends_nothing() raises:
    var spy = SharedScriptedTransport()
    var port = _port(202, String('{"sent":0}'), spy)
    var out = port.notify(
        _notify_request(String("00000000-0000-0000-0000-000000000000"))
    )
    assert_false(out.ok)
    assert_equal(out.status, 0)
    assert_equal(out.reason, String("komira_push: the recipient sub is the nil UUID"))
    assert_equal(spy.call_count(), 0)


def test_a_refused_registration_sends_nothing() raises:
    var spy = SharedScriptedTransport()
    var port = _port(
        200,
        String('{"deviceId":"dev-9","transport":"DEVICE_TRANSPORT_WEB_PUSH"}'),
        spy,
    )
    var request = _register_request()
    request.on_behalf_of = Optional[PrincipalRef](
        PrincipalRef(
            String("https://issuer.example"),
            String("00000000-0000-0000-0000-000000000000"),
        )
    )
    var out = port.register_device(request)
    assert_false(out.ok)
    assert_equal(out.status, 0)
    assert_equal(
        out.reason, String("komira_push: the on_behalf_of sub is the nil UUID")
    )
    assert_equal(spy.call_count(), 0)


def test_a_registration_with_a_bad_device_sends_nothing() raises:
    # A valid on_behalf_of and an FCM device with no token: the refusal must
    # come from the device half of the shape check.
    var spy = SharedScriptedTransport()
    var port = _port(
        200,
        String('{"deviceId":"dev-9","transport":"DEVICE_TRANSPORT_FCM"}'),
        spy,
    )
    var request = _register_request()
    request.device = Optional[DeviceSubscription](
        DeviceSubscription(
            DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_FCM),
            Optional[WebPushSubscription](None),
            String(""),
        )
    )
    var out = port.register_device(request)
    assert_false(out.ok)
    assert_equal(out.status, 0)
    assert_equal(out.reason, String("komira_push: an FCM device has no token"))
    assert_equal(spy.call_count(), 0)


def _url_err(url: String) -> String:
    try:
        return String("ok ") + check_notify_base_url(url)
    except e:
        return String(e)


def test_the_base_url_rules() raises:
    assert_equal(_url_err(String("https://notify.example")), String("ok https://notify.example"))
    assert_equal(_url_err(String("https://notify.example/")), String("ok https://notify.example"))
    assert_equal(_url_err(String("https://notify.example:8443")), String("ok https://notify.example:8443"))
    assert_equal(_url_err(String("http://127.0.0.1:8080")), String("ok http://127.0.0.1:8080"))
    assert_equal(_url_err(String("http://localhost:9")), String("ok http://localhost:9"))
    assert_equal(_url_err(String("http://[::1]:9")), String("ok http://[::1]:9"))
    var loopback = String(
        "komira_push: a plain http:// notify URL must name a loopback host"
    )
    assert_equal(_url_err(String("http://notify.example")), loopback)
    assert_equal(_url_err(String("http://127.0.0.1.example:80")), loopback)
    assert_equal(
        _url_err(String("http://[localhost")),
        String("komira_push: the notify URL host is malformed"),
    )
    assert_equal(
        _url_err(String("ftp://notify.example")),
        String("komira_push: the notify URL is not https://"),
    )
    assert_equal(
        _url_err(String("https://")),
        String("komira_push: the notify URL has no host"),
    )
    var host_only = String("komira_push: the notify URL is a scheme and a host only")
    assert_equal(_url_err(String("https://notify.example/api")), host_only)
    assert_equal(_url_err(String("https://notify.example?x=1")), host_only)
    assert_equal(_url_err(String("https://user@notify.example")), host_only)
    assert_equal(_url_err(String("http://localhost#x")), host_only)


def main() raises:
    test_notify_sends_the_golden_request()
    test_register_sends_the_golden_request()
    test_every_other_notify_status_is_a_failure()
    test_every_other_register_status_is_a_failure()
    test_an_unbalanced_result_is_a_failure()
    test_a_result_that_balances_only_in_32_bits_is_a_failure()
    test_a_result_that_balances_after_any_32_bit_pairing_is_a_failure()
    test_an_unreadable_result_is_a_failure()
    test_a_newer_result_member_is_skipped()
    test_an_empty_device_id_is_a_failure()
    test_a_raising_transport_is_a_failure()
    test_a_raising_transport_is_a_failed_registration()
    test_an_unreadable_device_answer_is_a_failure()
    test_a_missing_token_sends_nothing()
    test_a_refused_request_sends_nothing()
    test_a_refused_registration_sends_nothing()
    test_a_registration_with_a_bad_device_sends_nothing()
    test_the_base_url_rules()
    print("PASS komira_push remote notify")
