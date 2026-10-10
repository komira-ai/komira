# =============================================================================
# komira_push/notify_port.mojo -- the caller side of the notify wire.
# =============================================================================
#
# `NotifyPort` is what an application calls to wake a principal's devices,
# and to register a device for the user its own token verified. A deployment
# binds one conformer:
#   * `RemoteNotifyPort` (remote_notify.mojo): the notify service over HTTP,
#     docs/design/notify_wire.md;
#   * `NoopNotify`: notification switched off; every call answers
#     "not configured" and sends nothing;
#   * `RecordingNotify`: a test double that records every request and
#     answers what the test scripted.
#
# A wake is best effort for the caller: the port's methods do not raise. Every
# failure (a refused request, no answer, a non-success status, no client
# token) comes back as an outcome with `ok == False` and a reason that never
# quotes a response body or a credential.
#
# `check_notify_request` and `check_register_device` are the shape rules both
# ends apply; `parse_notify_request` and `parse_register_device` decode a body
# strictly (a member the wire does not declare is refused) and then check it.
#
# Encapsulation: no UnsafePointer anywhere. `RecordingNotify` shares its
# recording through an `ArcPointer` so a test can read it after the port has
# been moved into the code under test.
# =============================================================================

from std.memory import ArcPointer

from komira_proto_codec import decode_json

from komira_notify_proto.notify import (
    Device,
    DeviceSubscription,
    DeviceTransport,
    NotifyRequest,
    NotifyResult,
    PrincipalRef,
    RegisterDevice,
)


comptime NIL_UUID: String = "00000000-0000-0000-0000-000000000000"
"""A subject that is never a real principal; refused as a recipient."""


# =============================================================================
# Outcomes
# =============================================================================
@fieldwise_init
struct NotifyOutcome(Copyable, Movable, Deinitable):
    """The answer to `NotifyPort.notify`. `ok` is True only when the notify
    service accepted the request; `result` then holds its counts. `status` is
    the HTTP status when there was an answer, else 0. `reason` says why a
    call failed, without quoting a body or a credential."""

    var ok: Bool
    var status: Int
    var result: NotifyResult
    var reason: String

    @staticmethod
    def accepted(status: Int, var result: NotifyResult) -> NotifyOutcome:
        return NotifyOutcome(True, status, result^, String(""))

    @staticmethod
    def failed(status: Int, var reason: String) -> NotifyOutcome:
        return NotifyOutcome(
            False,
            status,
            NotifyResult(UInt32(0), UInt32(0), UInt32(0), UInt32(0)),
            reason^,
        )


@fieldwise_init
struct RegisterOutcome(Copyable, Movable, Deinitable):
    """The answer to `NotifyPort.register_device`, shaped as `NotifyOutcome`:
    `device` is meaningful only when `ok`."""

    var ok: Bool
    var status: Int
    var device: Device
    var reason: String

    @staticmethod
    def registered(status: Int, var device: Device) -> RegisterOutcome:
        return RegisterOutcome(True, status, device^, String(""))

    @staticmethod
    def failed(status: Int, var reason: String) -> RegisterOutcome:
        return RegisterOutcome(
            False,
            status,
            Device(
                String(""),
                DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_UNSPECIFIED),
            ),
            reason^,
        )


comptime NOT_CONFIGURED: String = "notify is not configured"
"""The reason `NoopNotify` gives for every call."""


# =============================================================================
# NotifyPort
# =============================================================================
trait NotifyPort(Movable, Deinitable):
    """The caller's seam to a notify service. Neither method raises: a
    failure is an outcome with `ok == False`."""

    def notify(mut self, request: NotifyRequest) -> NotifyOutcome:
        """Wake every device of `request.recipient`."""
        ...

    def register_device(mut self, request: RegisterDevice) -> RegisterOutcome:
        """Register `request.device` for `request.on_behalf_of`."""
        ...


# =============================================================================
# Shape rules (both ends)
# =============================================================================
def check_principal_ref(what: String, p: Optional[PrincipalRef]) raises:
    """`p` is present, its `iss` non-empty, its `sub` non-empty and not the
    nil UUID. `what` names the field in the message."""
    if not p:
        raise Error(String("komira_push: the ") + what + String(" is missing"))
    ref r = p.value()
    if r.iss.byte_length() == 0:
        raise Error(String("komira_push: the ") + what + String(" iss is empty"))
    if r.sub.byte_length() == 0:
        raise Error(String("komira_push: the ") + what + String(" sub is empty"))
    if r.sub == NIL_UUID:
        raise Error(
            String("komira_push: the ") + what + String(" sub is the nil UUID")
        )


def check_notify_request(request: NotifyRequest) raises:
    """A recipient (see `check_principal_ref`), a trigger with a non-empty
    `id` and `kind`, and a non-empty idempotency key."""
    check_principal_ref(String("recipient"), request.recipient)
    if not request.trigger:
        raise Error("komira_push: the trigger is missing")
    ref t = request.trigger.value()
    if t.id.byte_length() == 0:
        raise Error("komira_push: the trigger id is empty")
    if t.kind.byte_length() == 0:
        raise Error("komira_push: the trigger kind is empty")
    if request.idempotency_key.byte_length() == 0:
        raise Error("komira_push: the idempotency key is empty")


def check_device_subscription(device: DeviceSubscription) raises:
    """Exactly one credential, matching the transport: a Web Push
    subscription with an `https://` endpoint and both keys, and no FCM token;
    or an FCM token and no Web Push subscription."""
    var t = device.transport.value
    if t == DeviceTransport.DEVICE_TRANSPORT_WEB_PUSH:
        if not device.web_push:
            raise Error("komira_push: a web push device has no subscription")
        if device.fcm_token.byte_length() != 0:
            raise Error("komira_push: a web push device carries an FCM token")
        ref s = device.web_push.value()
        if not s.endpoint.startswith("https://"):
            raise Error(
                "komira_push: a web push endpoint is an https:// URL"
            )
        if s.p256dh.byte_length() == 0:
            raise Error("komira_push: the web push p256dh key is empty")
        if s.auth.byte_length() == 0:
            raise Error("komira_push: the web push auth secret is empty")
    elif t == DeviceTransport.DEVICE_TRANSPORT_FCM:
        if device.fcm_token.byte_length() == 0:
            raise Error("komira_push: an FCM device has no token")
        if device.web_push:
            raise Error(
                "komira_push: an FCM device carries a web push subscription"
            )
    else:
        raise Error("komira_push: the device transport is not set")


def check_register_device(request: RegisterDevice) raises:
    """`on_behalf_of` (see `check_principal_ref`) and a device (see
    `check_device_subscription`)."""
    check_principal_ref(String("on_behalf_of"), request.on_behalf_of)
    if not request.device:
        raise Error("komira_push: the device is missing")
    check_device_subscription(request.device.value())


def parse_notify_request(body: String) raises -> NotifyRequest:
    """Decode a `NotifyRequest` body strictly (a member the wire does not
    declare, such as `source`, is refused) and check its shape."""
    var request = decode_json[NotifyRequest](body)
    check_notify_request(request)
    return request^


def parse_register_device(body: String) raises -> RegisterDevice:
    """Decode a `RegisterDevice` body strictly and check its shape."""
    var request = decode_json[RegisterDevice](body)
    check_register_device(request)
    return request^


def parse_device_subscription(body: String) raises -> DeviceSubscription:
    """Decode a `DeviceSubscription` body strictly (an `onBehalfOf` member is
    refused: the principal comes from the verified token, never the body) and
    check its shape."""
    var device = decode_json[DeviceSubscription](body)
    check_device_subscription(device)
    return device^


# =============================================================================
# NoopNotify
# =============================================================================
struct NoopNotify(NotifyPort, Defaultable, Movable, Deinitable):
    """Notification switched off: every call answers `ok == False`, status 0,
    reason `NOT_CONFIGURED`, and sends nothing."""

    def __init__(out self):
        pass

    def notify(mut self, request: NotifyRequest) -> NotifyOutcome:
        return NotifyOutcome.failed(0, String(NOT_CONFIGURED))

    def register_device(mut self, request: RegisterDevice) -> RegisterOutcome:
        return RegisterOutcome.failed(0, String(NOT_CONFIGURED))


# =============================================================================
# RecordingNotify
# =============================================================================
struct _Recording(Movable):
    var notifies: List[NotifyRequest]
    var registrations: List[RegisterDevice]
    var notify_answer: NotifyOutcome
    var register_answer: RegisterOutcome

    def __init__(out self):
        self.notifies = List[NotifyRequest]()
        self.registrations = List[RegisterDevice]()
        self.notify_answer = NotifyOutcome.accepted(
            202, NotifyResult(UInt32(1), UInt32(1), UInt32(0), UInt32(0))
        )
        self.register_answer = RegisterOutcome.registered(
            200,
            Device(
                String("recorded-device"),
                DeviceTransport(DeviceTransport.DEVICE_TRANSPORT_UNSPECIFIED),
            ),
        )


struct RecordingNotify(NotifyPort, Defaultable, Movable, Deinitable):
    """A test double: records every request and answers the scripted outcome
    (by default, notify accepted with one device sent and accepted, and a
    registration answered with device id `recorded-device`). `share()` gives
    a second handle over the same recording, for reading it after this one
    has been moved into the code under test."""

    var _p: ArcPointer[_Recording]

    def __init__(out self):
        self._p = ArcPointer[_Recording](_Recording())

    def __init__(out self, *, var _share: ArcPointer[_Recording]):
        self._p = _share^

    def share(self) -> RecordingNotify:
        """A second handle over the same recording. SAFETY: `ArcPointer`
        reference-counted shared ownership; a test double used on one
        thread."""
        return RecordingNotify(_share=ArcPointer[_Recording](copy=self._p))

    def answer_notify(mut self, var outcome: NotifyOutcome):
        self._p[].notify_answer = outcome^

    def answer_register(mut self, var outcome: RegisterOutcome):
        self._p[].register_answer = outcome^

    def notify_count(self) -> Int:
        return len(self._p[].notifies)

    def register_count(self) -> Int:
        return len(self._p[].registrations)

    def notify_at(self, i: Int) -> NotifyRequest:
        return self._p[].notifies[i].copy()

    def register_at(self, i: Int) -> RegisterDevice:
        return self._p[].registrations[i].copy()

    def notify(mut self, request: NotifyRequest) -> NotifyOutcome:
        self._p[].notifies.append(request.copy())
        return self._p[].notify_answer.copy()

    def register_device(mut self, request: RegisterDevice) -> RegisterOutcome:
        self._p[].registrations.append(request.copy())
        return self._p[].register_answer.copy()
