# `komira_notify_proto`

## Responsibility

The notify wire (`komira.notify.v1`), as protobuf messages and the Mojo
structs generated from them. A service sends a notify service a request to
wake every device of one principal, and an application registers a device on
behalf of the user its own token verified. The HTTP routes, statuses and
authentication are in
[docs/design/notify_wire.md](https://github.com/komira-ai/komira/blob/main/docs/design/notify_wire.md);
the caller side is `komira_push`.

- `PrincipalRef`: a principal as `iss` and `sub`.
- `Trigger`: what happened, `id` and `kind`. There is no content field, and
  no `source`: the notify service sets a wake's source from the caller's
  verified identity.
- `NotifyRequest` (`recipient`, `trigger`, `idempotency_key`) and its answer
  `NotifyResult` (`sent`, `accepted`, `dead`, `transient`).
- `DeviceTransport`, `WebPushSubscription`, `DeviceSubscription`: a device a
  UI wants woken, either a Push API subscription or an FCM token.
- `RegisterDevice` (`on_behalf_of`, `device`) and its answer `Device`.
- `ErrorEnvelope` / `ErrorDetail`: the body of every error answer,
  `{"error":{"code":..,"message":..}}`.

Bodies are proto3 canonical JSON. A receiver decodes requests with the strict
decoder, so a member this file does not declare (a `source`, an
`onBehalfOf` in a UI's subscription) is refused.

## API

The definitions are in
[notify.proto](https://github.com/komira-ai/komira/blob/main/src/komira_notify_proto/notify.proto);
the Mojo module is `komira_notify_proto.notify`. Each message is a struct
whose constructor takes its fields in declaration order (a message field is
an `Optional`); an enum is a struct over its number (`.value`). Encode and
decode JSON with `komira_proto_codec`'s `encode_json` and `decode_json`.

## Examples

Every example below runs as a test when the package is built.

A wake request as it goes on the wire:

```mojo
from komira_notify_proto.notify import NotifyRequest, PrincipalRef, Trigger
from komira_proto_codec import encode_json
from std.testing import assert_equal

var request = NotifyRequest(
    Optional[PrincipalRef](PrincipalRef(String("https://issuer.example"), String("user-1"))),
    Optional[Trigger](Trigger(String("item-7"), String("failed"))),
    String("key-1"),  # idempotency_key
)
assert_equal(
    encode_json(request),
    String(
        '{"recipient":{"iss":"https://issuer.example","sub":"user-1"},'
        '"trigger":{"id":"item-7","kind":"failed"},"idempotencyKey":"key-1"}'
    ),
)
```

A request naming the wake's source is refused:

```mojo
from komira_notify_proto.notify import NotifyRequest
from komira_proto_codec import decode_json
from std.testing import assert_true

var refused = False
try:
    _ = decode_json[NotifyRequest](
        String('{"trigger":{"id":"i","kind":"k","source":"someone-else"}}')
    )
except:
    refused = True
assert_true(refused)
```
