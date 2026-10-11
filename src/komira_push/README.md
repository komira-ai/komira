# `komira_push`

## Responsibility

The caller side of a notify service, and the content-blind wake. An
application calls a `NotifyPort` to wake a principal's devices when
something they care about happens; the wake carries only which item, what
kind of event and which service holds it, and the woken client fetches the
item from that service itself. The wire is
[docs/design/notify_wire.md](https://github.com/komira-ai/komira/blob/main/docs/design/notify_wire.md);
its messages are `komira_notify_proto`'s.

- `WakeTrigger` (`id`, `kind`, `source`) and `payload_json()`, the plaintext
  a push service carries. `check_wake_fields[T]()` refuses a struct with any
  other field (by reflection); `check_wake_payload(text)` refuses a plaintext
  with any other member, a non-string value or a repeated member.
- `NotifyPort`: `notify(NotifyRequest) -> NotifyOutcome` and
  `register_device(RegisterDevice) -> RegisterOutcome`. Neither raises: a
  wake is best effort for the caller, and every failure is an outcome with
  `ok == False`, the HTTP status (0 when there was no answer) and a reason
  that never quotes a body or a credential.
- `RemoteNotifyPort[T: HttpTransport, S: BearerTokenSource]`: the notify
  wire over HTTP. It checks each request's shape before sending, puts
  `Authorization: Bearer <token>` from `S` on every call, takes only 202
  (notify) or 200 (register) as success, and checks that a result balances
  (`accepted + dead + transient == sent`). The base URL is `https://` and a
  host, or `http://` to a loopback host.
- `NoopNotify`: notification switched off; every call answers
  `NOT_CONFIGURED` and sends nothing.
- `RecordingNotify`: a test double that records every request (readable
  through `share()` after the port is moved) and answers what was scripted.
- `register_device_for(port, principal, body) -> ProxyReply`: the route an
  application serves so its UI can register a device. The principal is the
  verified token's `iss` claim and subject, never the body; the body is a
  `DeviceSubscription` decoded strictly.
- `check_notify_request`, `check_register_device`,
  `check_device_subscription` and the strict parsers `parse_notify_request`,
  `parse_register_device`, `parse_device_subscription`: the shape rules
  both ends apply. A recipient's `sub` is never empty and never the nil
  UUID.

## Examples

Every example below runs as a test when the package is built.

The plaintext of a wake, and the guard refusing a payload with content:

```mojo
from komira_push import WakeTrigger, check_wake_payload
from std.testing import assert_equal, assert_true

var wake = WakeTrigger(String("item-7"), String("failed"), String("jobs"))
assert_equal(wake.payload_json(), String('{"id":"item-7","kind":"failed","source":"jobs"}'))
var refused = False
try:
    check_wake_payload(String('{"id":"item-7","title":"Your job failed"}'))
except:
    refused = True
assert_true(refused)
```

Application code is written against the trait; a deployment without a notify
service binds `NoopNotify`, and a test binds `RecordingNotify`:

```mojo
from komira_notify_proto.notify import NotifyRequest, PrincipalRef, Trigger
from komira_push import NoopNotify, NotifyPort, RecordingNotify
from std.testing import assert_equal, assert_false, assert_true

def wake_owner[P: NotifyPort](mut port: P, sub: String) -> Bool:
    var request = NotifyRequest(
        Optional[PrincipalRef](PrincipalRef(String("https://issuer.example"), sub.copy())),
        Optional[Trigger](Trigger(String("item-7"), String("failed"))),
        String("item-7-failed"),
    )
    return port.notify(request).ok

var off = NoopNotify()
assert_false(wake_owner(off, String("user-1")))
var recording = RecordingNotify()
var spy = recording.share()
assert_true(wake_owner(recording, String("user-1")))
assert_equal(spy.notify_at(0).recipient.value().sub, String("user-1"))
```
