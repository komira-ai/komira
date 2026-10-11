# =============================================================================
# komira_push/tests/test_ports.mojo
#   NoopNotify and RecordingNotify.
# =============================================================================
#
# NoopNotify is what a deployment without a notify service binds: every call
# must be a failure named "notify is not configured", never a silent success
# a caller would count as delivered. RecordingNotify is the double an
# application's tests bind: it must record each request as sent, be readable
# through `share()` after the port was moved, and answer what was scripted.
# The generic helper `_wake` stands for application code written against the
# trait.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_notify_proto.notify import (
    Device,
    DeviceSubscription,
    DeviceTransport,
    NotifyRequest,
    NotifyResult,
    PrincipalRef,
    RegisterDevice,
    Trigger,
    WebPushSubscription,
)
from komira_push import (
    NoopNotify,
    NotifyOutcome,
    NotifyPort,
    RecordingNotify,
    RegisterOutcome,
)


def _request() -> NotifyRequest:
    return NotifyRequest(
        Optional[PrincipalRef](PrincipalRef(String("https://issuer.example"), String("u"))),
        Optional[Trigger](Trigger(String("item-1"), String("failed"))),
        String("key-1"),
    )


def _register() -> RegisterDevice:
    return RegisterDevice(
        Optional[PrincipalRef](PrincipalRef(String("https://issuer.example"), String("u"))),
        Optional[DeviceSubscription](
            DeviceSubscription(
                DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_FCM),
                Optional[WebPushSubscription](None),
                String("tok"),
            )
        ),
    )


def _wake[P: NotifyPort](mut port: P) -> NotifyOutcome:
    return port.notify(_request())


def test_noop_answers_not_configured() raises:
    var port = NoopNotify()
    var out = _wake(port)
    assert_false(out.ok)
    assert_equal(out.status, 0)
    assert_equal(out.reason, String("notify is not configured"))
    var reg = port.register_device(_register())
    assert_false(reg.ok)
    assert_equal(reg.reason, String("notify is not configured"))


def test_recording_records_and_answers_by_default() raises:
    var port = RecordingNotify()
    var spy = port.share()
    var moved = port^
    var out = _wake(moved)
    assert_true(out.ok)
    assert_equal(out.status, 202)
    assert_equal(out.result.sent, UInt32(1))
    assert_equal(spy.notify_count(), 1)
    var seen = spy.notify_at(0)
    assert_equal(seen.recipient.value().sub, String("u"))
    assert_equal(seen.trigger.value().id, String("item-1"))
    assert_equal(seen.idempotency_key, String("key-1"))
    var reg = moved.register_device(_register())
    assert_true(reg.ok)
    assert_equal(reg.device.device_id, String("recorded-device"))
    assert_equal(spy.register_count(), 1)
    assert_equal(spy.register_at(0).device.value().fcm_token, String("tok"))


def test_recording_answers_what_was_scripted() raises:
    var port = RecordingNotify()
    port.answer_notify(NotifyOutcome.failed(503, String("scripted")))
    port.answer_register(
        RegisterOutcome.registered(
            200,
            Device(
                String("dev-2"), DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_FCM)
            ),
        )
    )
    var out = _wake(port)
    assert_false(out.ok)
    assert_equal(out.status, 503)
    assert_equal(out.reason, String("scripted"))
    assert_equal(port.register_device(_register()).device.device_id, String("dev-2"))
    assert_equal(port.notify_count(), 1)


def test_outcome_factories() raises:
    var ok = NotifyOutcome.accepted(
        202, NotifyResult(UInt32(2), UInt32(2), UInt32(0), UInt32(0))
    )
    assert_true(ok.ok)
    assert_equal(ok.reason, String(""))
    var bad = NotifyOutcome.failed(0, String("why"))
    assert_false(bad.ok)
    assert_equal(bad.result.sent, UInt32(0))


def main() raises:
    test_noop_answers_not_configured()
    test_recording_records_and_answers_by_default()
    test_recording_answers_what_was_scripted()
    test_outcome_factories()
    print("PASS komira_push ports")
