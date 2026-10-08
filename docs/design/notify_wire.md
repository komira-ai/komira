# The notify wire

A notify service wakes a principal's devices when something they care about
happens, without ever carrying the content. This document is the HTTP
contract between such a service and the services that call it. The messages
are [`komira_notify_proto`](../../src/komira_notify_proto/) (package
`komira.notify.v1`); the caller side is [`komira_push`](../../src/komira_push/).
The service itself (its device store, its push credentials, its policy) is not
part of komira; anything that serves these routes as written is a notify
service.

## Parties

- **A caller** is a service that wants a principal woken: an application's
  API, a job runner, a relay. It is an OAuth 2.0 client of the deployment's
  authorization server.
- **The notify service** holds the device registry, addressed by principal,
  and the push credentials (a VAPID key for Web Push, a Firebase project for
  FCM).
- **An application** registers its users' devices. A user's UI never calls
  the notify service: it sends its push subscription to its own application,
  which registers it (see `PUT /v1/devices`).
- **A device** receives a wake and fetches the item from the service named in
  it, over its own authenticated channel.

## Authentication

Every request carries `Authorization: Bearer <token>`, where the token is the
caller's own client token for the notify service's audience: an access token
obtained with the OAuth 2.0 client-credentials grant (RFC 6749 section 4.4)
and a `private_key_jwt` client assertion (RFC 7523), presented here as an
RFC 6750 bearer token. A client assertion is used only at the token endpoint,
never on a call to the notify service. A user's token is never accepted: its
audience is the user's application, not the notify service.

`RemoteNotifyPort` takes the token from a `BearerTokenSource` on every call
and never caches, mints or logs it.

The notify service verifies the token, takes the caller's identity from it
(`client_id`, or `sub` when it equals the client id), and asks the deployment's
authorizer whether that client may perform the action on the principal
(`notify.send` or `notify.register_device` on resource `principal/<sub>`),
with the client as the subject. It fails closed: an authorizer that does not
answer is a 503, never a send.

## Routes

Bodies are proto3 canonical JSON (`Content-Type: application/json`):
lowerCamelCase member names, enums by name, members at their default value
omitted. The notify service decodes every request with the strict decoder: a
member the message does not declare is refused with 400. A caller decodes
answers leniently, so a newer service may add members.

### `POST /v1/notify`

Wake every device of `recipient`.

| | |
|---|---|
| request | `NotifyRequest {recipient{iss, sub}, trigger{id, kind}, idempotencyKey}` |
| success | **202** `NotifyResult {sent, accepted, dead, transient}`, where `accepted + dead + transient == sent` |
| 400 | the body is not a `NotifyRequest`, carries an undeclared member (a `source`, a `title`), or breaks a rule below |
| 401 | no token, or a token the service does not accept |
| 403 | the caller may not notify this principal |
| 429 | the caller or the recipient is over its rate |
| 503 | the authorizer or the device store did not answer |

Rules: `recipient.iss` and `recipient.sub` are non-empty, and `sub` is never
the nil UUID (`00000000-0000-0000-0000-000000000000`); `trigger.id`,
`trigger.kind` and `idempotencyKey` are non-empty. A principal with no device
is a 202 with `sent = 0`. A repeat of the same `idempotencyKey` from the same
caller, within the service's retention window for keys, answers as the first
call did and sends nothing new.

What a device receives is the wake plaintext

```text
{"id":"<trigger.id>","kind":"<trigger.kind>","source":"<the caller's client id>"}
```

and nothing more: `source` comes from the caller's verified token, never
from the request, so one caller cannot wake devices in another's name. The
plaintext is encrypted for Web Push (RFC 8291, `aes128gcm`) or sent as the
FCM `data` map. A sender checks the bytes it is about to send with
`komira_push.check_wake_payload`.

`dead` counts devices whose push service reported the credential gone (Web
Push 404 or 410, FCM `UNREGISTERED`); the notify service removes them.
`transient` counts devices whose push service failed this time.

### `PUT /v1/devices`

An application registers a device for one of its users.

| | |
|---|---|
| request | `RegisterDevice {onBehalfOf{iss, sub}, device{transport, webPush{endpoint, p256dh, auth} or fcmToken}}` |
| success | **200** `Device {deviceId, transport}` |
| 400 | not a `RegisterDevice`, an undeclared member, or a device that breaks a rule below |
| 401, 403, 503 | as for `/v1/notify`; 403 also when the caller is not a client allowed to register devices on a user's behalf |

Rules: `onBehalfOf` as `recipient` above. `device.transport` is set; a
`DEVICE_TRANSPORT_WEB_PUSH` device has `webPush` with an `https://`
endpoint and both keys and no `fcmToken`; a `DEVICE_TRANSPORT_FCM` device has
`fcmToken` and no `webPush`. Registering the same credential again updates
the existing device and answers its `deviceId`. The notify service applies its
own endpoint policy (allowed push-service hosts, no redirects) and answers 400
for an endpoint outside it.

The application takes `onBehalfOf` from the user's verified token, never from
the UI. `komira_push.register_device_for` is that route: the UI sends
`PUT /v1/devices` to its application with its own bearer token and a
`DeviceSubscription` body; a body that names `onBehalfOf` is refused with 400
before the notify service is called.

### `DELETE /v1/principals/{iss}/{sub}/devices`

Remove every device of a principal (erasure). `{iss}` and `{sub}` are each
percent-encoded as one path segment. **204** whether or not any device
existed; 401, 403 and 503 as above. Only a client allowed to erase principals
may call it.

## Errors

Every error answer has the body

```text
{"error":{"code":"<code>","message":"<sentence>"}}
```

(`ErrorEnvelope`), with `code` one of `invalid_request`, `unauthenticated`,
`forbidden`, `rate_limited`, `unavailable`. A message never quotes a
credential or a request body.

## The caller's view

A wake is best effort for the caller, so `NotifyPort`'s methods do not raise.
`RemoteNotifyPort` returns an outcome with `ok == False` for a request that
breaks a rule (not sent), a token it could not get (not sent), no answer, any
status other than 202 (notify) or 200 (register), an answer it cannot read
and a result that does not balance. The outcome holds the status and a reason
that does not quote the answer. A deployment without a notify service binds
`NoopNotify`, whose every call answers "notify is not configured".

The base URL is `https://` and a host (and port), or `http://` to
`127.0.0.1`, `localhost` or `[::1]` for tests; the routes are appended to it.

## Versioning

The path carries the version. Within `v1` a change only adds: a new optional
member, a new enum value, a new route. Removing or renumbering a field, or
changing a status, takes `v2`, served beside `v1` until callers have moved.
