# The notification service: states, dedupe, recipients, history, channels and the wire

Status: design, not built. Everything here is a proposal for review; the choices this doc makes where
a case could go more than one way are listed with their reasons under [Decisions](#decisions). The
libraries that will implement it are named in [What is built from this](#what-is-built-from-this).

## What is it for, and what is out of scope?

An environment is one deployment of a small set of central services: an app registry, an OIDC issuer,
the notification service, and a relay that pushes signals to open browsers. Many registered apps run
in it. Each app has faults and events a person should see: a host that went silent, a queue that is
stuck, a branch whose CI went red. Today each app reports in its own way, or not at all. The
notification service is the one place in an environment where those reports land, where a person
acknowledges them, and where their history is kept.

It is a central service beside the registry and the issuer, not part of a user-facing app, so any app
can publish and any client can read the inbox while no user-facing app is up.

In scope: the notification record, the states and every transition, the dedupe rule and its scope, how
recipients are chosen, the history, the delivery channels and what each must do, the notification id,
how a producer proves which app it is, the HTTP wire, and how existing producers map onto kinds.

Out of scope: the app registration record, beyond the fields this doc assumes below; minting tokens (the issuer); the relay's own protocol; reminders while a
notification stays unacknowledged; digests; and fan-out across environments, which never happens: a
notification belongs to exactly one environment and is read only there.

### What this doc assumes from the registry and the issuer

From an app's registration record, this doc uses only these fields:

| Field | Used for |
|---|---|
| `name` | the app's name, unique within the environment; the notification's `app` |
| `owner` | `{"person": {"iss", "sub"}}` or `{"team": "<team name>"}`: the default recipient |
| `auth.client_id` | finding the app from a producer's token |
| `notification_kinds` | the kinds the app may publish, each `{name, default_severity}` |
| `retired` | whether the app is retired: a retired app cannot publish |
| `environment_id` | the environment the record belongs to |

From the environment it uses the `issuer_url` setting (the one issuer its tokens may come from), the
issuer's published keys (JWKS), and three reads of the environment's directory: the members of a team,
whether a person is still a member of the environment, and the people who hold a role on an app. On a
call, a person's roles come from the `roles` claim of their token: a map from app name to a list of
role names. The registrar is a person with the registry's `registrar` role, who registers and retires
apps.

## Terms

| Term | Meaning |
|---|---|
| environment | one set of central services, named by an environment id: a short lowercase slug, unique and never reused (`[a-z][a-z0-9-]{1,30}`) |
| app | a registered app, named by its record's `name` |
| kind | a name the app's record declares in `notification_kinds`, with a default severity, for example `silent_host`; the pattern is `[a-z][a-z0-9_]{0,62}` |
| severity | one of four levels, in order: `info`, `warning`, `error`, `critical` |
| producer | the app that publishes a notification: always the app the caller's token names, never a field of the request |
| dedupe key | an optional string the producer chooses, 1 to 200 bytes of printable ASCII (0x21 to 0x7e), that names one ongoing condition, such as one host's silence |
| dedupe scope | `(environment, app, dedupe_key)`: two publishes are the same condition only when all three match; the kind is not part of the scope |
| live notification | a notification in state `open` or `acknowledged` |
| a role on the app | the caller's token has `roles[<app>]` holding at least one role other than `publisher`, or the caller is the app's owner (the person, or a member of the owner team); outside a call, the directory's role holders of the app plus the owner |

## The notification record

| Field | Type | Set by | Changes |
|---|---|---|---|
| `id` | string, see [The notification id](#the-notification-id) | the service | never |
| `environment_id` | string | the service | never |
| `app` | string | the service, from the token | never |
| `kind` | string | the producer | never |
| `severity` | `info` \| `warning` \| `error` \| `critical` | the producer; the kind's default when the publish leaves it out | on a repeat |
| `title` | string, 1 to 200 bytes of UTF-8, one line, not only blanks | the producer | on a repeat |
| `body` | string, 0 to 4000 bytes of UTF-8 | the producer; empty when left out | on a repeat |
| `link` | absolute `https` URL, up to 2000 bytes, or absent | the producer | on a repeat |
| `dedupe_key` | string or absent | the producer | never |
| `state` | `open` \| `acknowledged` \| `resolved` | the transitions below | by the transitions below |
| `count` | integer, starts at 1 | the service | +1 on each repeat |
| `first_seen` | RFC 3339 UTC time | the service | never |
| `last_seen` | RFC 3339 UTC time | the service | on each repeat |
| `acknowledged` | `{by, at, note}` or absent | the service | once, on acknowledge |
| `resolved` | `{by, at, note, cause}` or absent; `cause` is `producer`, `person` or `app_retired` | the service | once, on resolve |

`by` is an actor in one of three forms: a person, `{"person": {"iss": ..., "sub": ...}}` (a person is
the pair of issuer and subject, because two issuers may mint the same subject); an app,
`{"app": "<name>"}`; or the registry, `{"service": "registry"}`. Who `by` is for each event is in the
transition table. Times are the service's clock, never the producer's, so a producer cannot backdate or
reorder a notification.

A body is plain text. It never carries raw log lines, serial numbers, addresses or secrets: the
producer's normalized message goes in it, and the full detail stays with the producer, behind `link`.

## Publish and dedupe

A publish is one call: `kind`, an optional `severity`, `title`, an optional `body`, an optional `link`,
an optional `dedupe_key`, and an optional `resolve` (default `false`). The producer is the app the
token names ([How a producer proves which app it is](#how-a-producer-proves-which-app-it-is)).

The service looks up the live notifications in the dedupe scope `(environment, app, dedupe_key)`.
There is at most one `open` notification in a scope, held by a unique constraint, and any number of
`acknowledged` ones, because rule 3 leaves each acknowledged one in place. The rules:

1. **No dedupe key: always a new notification.** It is `open`. A producer that wants repeats folded,
   or wants to resolve its own notifications, sends a key.
2. **A repeat while open updates the open one.** Same scope, an `open` notification exists: `count`
   goes up by one, `last_seen` moves, and `severity`, `title`, `body` and `link` take the new values
   (a `body` or `link` left out becomes empty or absent). No second notification is made.
3. **A repeat after an acknowledgement opens a new one.** Same scope, no `open` one, one or more
   `acknowledged`: a new `open` notification is made, and each acknowledged one stays exactly as it
   was. Acknowledging means "I have seen this"; a later fire is news and reaches people again.
4. **A repeat after a resolve opens a new one.** Same scope, only `resolved` ones: a new `open`
   notification. A resolved notification is never reopened.
5. **The kind must match.** A publish whose key matches a live notification of another kind is
   refused (409 `dedupe_kind_conflict`): one key naming two conditions is a producer bug, and folding
   them would hide one. Every key in the [producer mapping](#producer-mapping) starts with its kind, so
   a producer that follows it never sees this.
6. **A resolve by the producer resolves every live one in the scope.** `resolve: true` with a key: the
   `open` one and every `acknowledged` one become `resolved` with cause `producer`, and the reply lists
   them in id order. When there is none, the call does nothing and says so (`resolved: []`). So a
   resolve is idempotent, and a producer may resend it after a lost reply.
7. **A resolve needs a key and a matching kind.** `resolve: true` without `dedupe_key` is refused (400
   `resolve_needs_dedupe_key`). `kind` is required and must match the live ones (rule 5). `title` and
   `body` are optional on a resolve; the resolve note is the `body` when given, else the `title`, else
   absent (the producer's "cleared" message), and a note over 2000 bytes is 400 `field_too_long`.
   `severity` and `link` sent with a resolve are ignored: neither checked nor stored.
8. **Severity changes on a repeat.** The new severity replaces the old. When it rises, the recipients
   are worked out again for the new severity, and each (person, channel) that has no recipient row for
   this notification yet gets one and is told (an escalation, see [Recipients](#recipients)). A
   (person, channel) already told is never told again for the same notification, so a severity that
   falls and rises again sends nothing new. When severity falls, nobody is told.

**Concurrency.** Publishes in one scope are serialised on the scope. A publish that loses a race to
open the scope's `open` notification runs rules 2 to 5 again against the winner's row: a repeat of the
same kind folds into it (rule 2), and another kind is refused (rule 5).

**A publish resent after a lost reply** is a repeat: it adds one to `count`. The count is an
indication of how often a producer fired, not an exact tally.

## States and transitions

Three states: `open`, `acknowledged`, `resolved`. `resolved` is final. Every row that changes something
writes exactly one history event per notification it changes; a row marked "no change" writes none.

| # | From | Event | `by` | To | History event | Reply |
|---|---|---|---|---|---|---|
| 1 | (none) | publish, no key | the producer app | `open` (new) | `opened` | 201, the new notification |
| 2 | no notification in scope | publish with key | the producer app | `open` (new) | `opened` | 201, the new notification |
| 3 | `open` | publish, same scope, same kind | the producer app | `open` (same, `count`+1) | `repeated` | 200, the notification |
| 4 | `open` | publish, same scope, higher severity | the producer app | `open` (same, `count`+1) | `repeated`, with the old and new severity | 200; newly qualifying recipients told |
| 5 | one or more `acknowledged`, no `open` | publish, same scope, same kind | the producer app | old ones unchanged; new `open` | `opened` on the new one only | 201, the new notification |
| 6 | only `resolved` ones | publish, same scope | the producer app | new `open` | `opened` on the new one | 201, the new notification |
| 7 | any live one, of another kind | publish or resolve, same scope | the producer app | no change | none | 409 `dedupe_kind_conflict` |
| 8 | `open` | publish `resolve: true`, same scope | the producer app | `resolved`, cause `producer` | `resolved` | 200, `resolved: [the notification]` |
| 9 | one or more `acknowledged` | publish `resolve: true`, same scope | the producer app | each `resolved`, cause `producer` | `resolved` on each | 200, `resolved: [each, in id order]` |
| 10 | `open` and one or more `acknowledged` | publish `resolve: true`, same scope | the producer app | all `resolved`, cause `producer` | `resolved` on each | 200, `resolved: [all, in id order]` |
| 11 | no live one in scope | publish `resolve: true` | the producer app | no change | none | 200, `resolved: []` |
| 12 | any | publish `resolve: true`, no key | the producer app | no change | none | 400 `resolve_needs_dedupe_key` |
| 13 | `open`, below `critical` | acknowledge, note optional | the person | `acknowledged` | `acknowledged`, with the note | 200, the notification |
| 14 | `open`, `critical` | acknowledge with a note | the person | `acknowledged` | `acknowledged`, with the note | 200, the notification |
| 15 | `open`, `critical` | acknowledge without a note, or with only blanks | the person | no change | none | 400 `note_required` |
| 16 | `acknowledged` | acknowledge again | the person | no change | none | 409 `not_open`, with the notification |
| 17 | `resolved` | acknowledge | the person | no change | none | 409 `not_open`, with the notification |
| 18 | `open` or `acknowledged` | resolve by id, note optional | the person | `resolved`, cause `person` | `resolved` | 200, the notification |
| 19 | `resolved` | resolve by id | the person | no change | none | 200, the notification (idempotent) |
| 20 | `open` or `acknowledged` | the app is retired | the registrar (a person) | `resolved`, cause `app_retired`, note `app retired` | `resolved` on each | 200 to the registry's retire hook |
| 21 | any | publish by a retired app (a token minted before the retire) | none | no change | none | 403 `app_retired` |
| 22 | any | acknowledge or resolve without a role on the app | none | no change | none | 403 `role_missing` |
| 23 | any | any call on an id that does not name a notification of this environment the caller may see | none | no change | none | 404 `not_found` |

Notes on the edge cases:

- **Repeat after acknowledgement (row 5).** Afterwards the scope holds the acknowledged one and a new
  `open` one. A third fire updates the `open` one (row 3). If a person acknowledges that one too, the
  scope holds two acknowledged ones, and the next fire opens a third. The acknowledged ones stay
  acknowledged until a person resolves each, or the producer resolves them all at once (rows 9 and 10).
- **Acknowledging a `critical` notification needs a note (rows 14 and 15):** at least one non-blank
  character, up to 2000 bytes. Below `critical` the note is optional. The rule reads the severity at
  the time of the acknowledgement, so a notification that rose to `critical` on a repeat needs a note.
- **A repeat racing an acknowledgement.** Both write the scope, one after the other. When the
  acknowledgement lands first, the repeat opens a new notification (row 5); when the repeat lands
  first, its count is in the notification the person then acknowledges (rows 3 and 13). Either order
  leaves no fire unseen.
- **A producer's resolve racing a person's.** Whichever lands first resolves; the second sees
  `resolved` and changes nothing (rows 11 and 19). The history shows one `resolved` event.
- **Retire (row 20).** The registry's retire calls the notification service's retire hook (an
  internal call between the two central services, not part of the public wire) with the app's name and
  the registrar. The hook resolves every live notification of the app with the note `app retired`, is
  idempotent, and the registry retries it until it answers 200. Meanwhile the app's publishes are
  already refused (row 21), because the service reads the record's `retired` field on every publish.
  Acknowledging or resolving a retired app's notification by id still works while one is live (rows 13
  to 19). The history and the resolved notifications stay. If the same name is registered again later,
  dedupe matches only live notifications, so nothing of the old app's carries over.
- **A producer restart.** A producer that re-publishes its standing conditions when it starts gives a
  repeat (row 3) for a condition still `open`, and a new notification (row 5) for one a person
  acknowledged. A producer that must not re-notify after a restart keeps its own record of what it has
  sent.

## Recipients

The recipients of a notification are worked out when it is opened, and again when its severity rises,
and written as recipient rows (notification, person, channel) in the same transaction:

1. **The app's owner.** The record's `owner` is a person or a team. A team means its members when the
   rows are written (teams are not nested); a person who joins the team later gets nothing for a
   notification already open until it escalates, when the team is read again. The owner always gets the notification in the inbox, whatever its
   severity.
2. **Every subscriber.** A person subscribes per app, per kind or all of the app's kinds, and per
   channel, with a minimum severity. A subscription matches when the notification's severity is at or
   above that minimum.

The owner's channels start at a default: inbox for every severity, mail for `error` and above, push for
`critical`. An owner's own subscription for mail or push on a kind replaces the default for that
channel and kind; nothing turns the owner's inbox off.

At the time the rows are written, the resolver drops every person who is no longer a member of the
environment, and every subscriber who holds no role on the app. A person removed from the environment
also loses their subscriptions and drops out of inbox reads; their name in past history events stays.
A subscription is set by the person, through the subscription calls of the wire. A change applies to
notifications opened or escalated after it, never to ones already delivered.

The resolver is a pure function of the notification, the owner, the subscriptions, the members of the
owner's team, the environment's members and the role holders of the app. Its output is the set of
(person, channel) pairs.

## History

Every notification and every event on it is kept, and none is ever edited or deleted. History is kept
forever: notifications are small text, and the history is how a team learns what failed and how often.
A history event is:

| Field | Meaning |
|---|---|
| `notification_id` | the notification |
| `seq` | 1, 2, 3, ... within the notification, with no gaps |
| `event` | `opened`, `repeated`, `acknowledged` or `resolved` |
| `at` | the service's time |
| `by` | the actor, as the transition table says |
| `note` | the acknowledge or resolve note, or absent |
| `cause` | on `resolved` only: `producer`, `person` or `app_retired` |
| `changes` | an object `{field: {"old": v, "new": v}}`: on `opened`, every field of the record with no `old`; on `repeated`, always `count` and `last_seen`, and each of `severity`, `title`, `body` and `link` that changed |

**Replay.** The notification is the replay of its events in `seq` order: `opened` sets every field and
`state = open`; `repeated` applies its `changes`; `acknowledged` sets `state` and `acknowledged = {by,
at, note}`; `resolved` sets `state` and `resolved = {by, at, note, cause}`. A store may keep the
notification as a row next to its events or rebuild it from them, and the conformance suite checks the
row equals the replay.

History is queried by app, kind and time; a caller sees only the history of apps on which they hold a
role. New event names may be added later, so a reader skips an event name it does not know.

## Channels

Three channels: the inbox, mail and push. Each is part of the environment's notification service; none
of them is an app.

| Channel | What it does | Delivered on |
|---|---|---|
| inbox | the recipient rows behind `GET /v1/notifications`; each event also sends one signal to the environment's relay so open inboxes fetch again | every event (the relay only marks a view stale; the inbox call is the source) |
| mail | one mail per recipient through the environment's mail relay | the open, to the rows written on open; an escalation, to the rows it adds; `resolved`, to each person mailed the open |
| push | one push per device of the recipient, through the push provider the environment configures | the same as mail |

What every channel must do:

- **Carry only the record's own fields:** `id`, `app`, `kind`, `severity`, `state`, `title`, `body`,
  `link`, `count`. Mail and push carry no token and no secret, and a push carries no `body`.
- **Deliver at least once, and tell each person once.** Each delivery has an idempotency key
  `(notification_id, person, channel, purpose)`, where `purpose` is `opened` or `resolved`; an
  escalation's delivery has purpose `opened`, because it is that person's first message. Each delivery
  has a delivery row with its state (`pending`, `sent`, `failed`) and its last error. A channel retries a
  failed send with backoff; a mail or push server that dedupes on the key turns at least once into once.
- **Never hold up a publish or a state change.** Delivery rows are written in the same transaction as
  the event and sent after it commits. A channel that is down leaves its rows `pending`, and the
  notification's state is unaffected.
- **Send no repeat on mail or push.** A repeat (row 3) changes the inbox count only, so a flapping
  producer cannot flood a mailbox.

A new channel is added by naming it and its rules here; a subscription names its channel, so adding
one is additive.

## The notification id

`<environment_id>.n.<ulid>`: the environment id, `.n.`, and a ULID in lowercase Crockford base32 (26
characters: a 48-bit millisecond time and 80 random bits from the operating system's random source).
For example `example-env.n.01jdzq3v7k8m2n4p6r8t0w2y4a`.

- **Globally unique.** The environment id is unique and never reused, and the ULID is unique within the
  environment's store, which holds a unique constraint on `id` and draws a new ULID on a conflict.
- **Ordered by time** within an environment, so an id order is a `first_seen` order to the
  millisecond.
- **Self-routing.** A service that receives an id whose prefix is not its own environment id, or that
  is not of this shape, answers 404 `not_found` (row 23) and never looks it up.
- **Opaque to clients.** A client compares ids for equality and never reads the time out of them.
- URL-safe: an id appears in a URL path as is.

## How a producer proves which app it is

A producer never states its app name; the service derives it from a token the producer cannot forge.

1. **The app's credential.** Registering an app creates its OIDC client in the environment's issuer.
   The app holds that client's credential (a client secret, or a key for `private_key_jwt` as
   [HTTP auth](http_auth.md) describes), read from a file named by a flag.
2. **The token.** The app gets an access token from the issuer with the client-credentials grant. Its
   `sub` and `client_id` are the app's client id, and its `roles` claim holds
   `{"<app name>": ["publisher"]}`. The registrar grants `publisher` when the app is registered.
3. **What the service checks on every publish**, in this order, each with its own refusal:
   1. `iss` equals the environment's `issuer_url` setting, read before the keys are chosen. A token from
      another environment's issuer is 401 `wrong_issuer`.
   2. The signature, against that issuer's published keys, with the algorithm pinned. Otherwise 401
      `invalid_token`.
   3. `aud` contains the notification service's audience, and `exp` and `nbf` hold. Otherwise 401
      `invalid_token`.
   4. The token is an app's, not a person's: `sub` equals `client_id`, and that client id is the
      `auth.client_id` of a record in this environment's registry, read on every publish. Otherwise 403
      `not_an_app`.
   5. That record is not `retired`. Otherwise 403 `app_retired`.
   6. `roles[<that record's name>]` contains `publisher`. Otherwise 403 `role_missing`.
   7. The request body is valid ([Request rules](#request-rules)). Otherwise 400.
   8. `kind` is not `health`, which is the registry's (below). Otherwise 403 `reserved_kind`.
   9. `kind` is one of the record's `notification_kinds`. Otherwise 422 `unknown_kind`.
4. **The producer is that record's name.** The request has no app field. An unknown field is ignored,
   never read, so a request that sends `"app": "someone-else"` still publishes as the token's app.

An app can therefore publish only its own kinds, under its own name, in its own environment, and a
leaked token is good for its lifetime and for that one app.

**The `health` kind is the registry's.** When the registry's poll of an app's `health_url` fails, the
registry publishes kind `health`, severity `error`, key `health/<app name>`, in that app's scope, with
`by` `{"service": "registry"}`, and resolves it when the app is up again. The registry does this
through an internal call between the two central services, not the public publish call. Every app has
the `health` kind without declaring it, and a subscription may name it.

**Internal calls.** The registry's `health` publish and its retire hook are served under `/internal/`
and take the registry's own client-credentials token, checked like a publish's (checks 1 to 3); its
client id is the one the service's `--registry-client-id` flag names. Any other caller is 403
`not_registry`.

**Person calls.** Every other call is a person's. Checks 1 to 3 apply to it unchanged. An app's token
(`sub` equals `client_id`) on a person's call is 403 `not_a_person`. The person is `(iss, sub)` from the
token, and their roles are the token's `roles` claim.

## The wire

HTTP/JSON over HTTPS, under `/v1` on the environment's notification service. Every call needs a
bearer token. An error is the JSON object `{code, message}`, with the codes in
[Errors](#errors).

| Call | Path | Who | Request | Reply |
|---|---|---|---|---|
| Publish | `POST /v1/notifications` | an app's `publisher` token | `kind`, `severity`?, `title` (optional only with `resolve: true`), `body`?, `link`?, `dedupe_key`?, `resolve`? | 201 or 200 `{notification}`; with `resolve: true`, 200 `{resolved: [...]}` |
| Acknowledge | `POST /v1/notifications/{id}/ack` | a person with a role on the app | `note` (required for `critical`) | 200 `{notification}` |
| Resolve | `POST /v1/notifications/{id}/resolve` | a person with a role on the app | `note`? | 200 `{notification}` |
| Get | `GET /v1/notifications/{id}` | a recipient, or a person with a role on the app | none | 200 `{notification}` |
| List inbox | `GET /v1/notifications` | any signed-in person | `?state=`, `?app=`, `?min_severity=`, `?limit=`, `?page_token=` | 200 `{notifications, next_page_token?}`: the caller's own, newest first |
| Query history | `GET /v1/notifications/history` | any signed-in person | `?app=`, `?kind=`, `?from=`, `?to=`, `?limit=`, `?page_token=` | 200 `{events, next_page_token?}` for apps the caller has a role on |
| List subscriptions | `GET /v1/subscriptions` | any signed-in person | none | 200 `{subscriptions}`: the caller's own |
| Set subscription | `PUT /v1/subscriptions` | a person with a role on the app | `app`, `kind`? (absent: every kind of the app), `channel`, `min_severity` | 200 `{subscription}` |
| Delete subscription | `DELETE /v1/subscriptions?app=&kind=&channel=` | any signed-in person | none | 204, also when there was none |

A publish, for example:

```json
{
  "kind": "silent_host",
  "severity": "critical",
  "title": "host n17 has been silent for 6 minutes",
  "body": "No heartbeat since its last report. The host is cordoned.",
  "link": "https://app.example/hosts/n17",
  "dedupe_key": "silent_host/n17"
}
```

and its reply, the first time (201):

```json
{
  "notification": {
    "id": "example-env.n.01jdzq3v7k8m2n4p6r8t0w2y4a",
    "environment_id": "example-env",
    "app": "example-app",
    "kind": "silent_host",
    "severity": "critical",
    "title": "host n17 has been silent for 6 minutes",
    "body": "No heartbeat since its last report. The host is cordoned.",
    "link": "https://app.example/hosts/n17",
    "dedupe_key": "silent_host/n17",
    "state": "open",
    "count": 1,
    "first_seen": "2026-12-01T09:00:00Z",
    "last_seen": "2026-12-01T09:00:00Z"
  }
}
```

The producer's clear when the host reports again:

```json
{"kind": "silent_host", "dedupe_key": "silent_host/n17", "resolve": true, "body": "host n17 is reporting again"}
```

### Request rules

- A body is a JSON object of at most 16 KiB with no duplicate keys; a field of the wrong JSON type is
  refused. Both are 400 `invalid_request`, naming the field.
- A field over its limit is refused, never cut: 400 `field_too_long`. This covers notes over 2000 bytes.
- An empty, blank or multi-line `title`, an empty `dedupe_key` or one outside printable ASCII, and text
  that is not UTF-8 are 400 `invalid_request`. An empty `dedupe_key` is never read as absent.
- `severity` outside the four levels is 400 `invalid_severity`; a `link` that is not an absolute
  `https` URL is 400 `invalid_link`.
- A body over 16 KiB is refused before its fields are read, as `invalid_request`.
- Order: the token checks (401, 403) come first, then the body (400), then the kind (403
  `reserved_kind`, 422 `unknown_kind`), then the state rules (409).
- Unknown fields are ignored, so a newer producer works against an older service.

### Listing

- `limit` defaults to 50 and is at most 200; a larger one is 400 `invalid_request`.
- `next_page_token` is an opaque string, absent on the last page; a token the service did not issue is
  400 `invalid_request`.
- `state` and `min_severity` take one value or a comma-separated list for `state`; the inbox's default
  `state` is `open,acknowledged`. An unknown value is 400 `invalid_request`.
- `from` and `to` are RFC 3339 UTC times bounding the event's `at`, `from` inclusive and `to`
  exclusive; a time of another form, or a `from` later than `to`, is 400 `invalid_request`. History is
  ordered by `(at, notification_id, seq)`.
- The inbox's `app` filter narrows the caller's own rows. History's `app` filter naming an app the
  caller holds no role on returns nothing; it is not an error, so the reply does not say whether the app
  exists. For the same reason a subscription to an app the caller holds no role on, existing or not, is
  403 `role_missing`.

### Errors

| Code | Status | When |
|---|---|---|
| `invalid_token` | 401 | no token, a bad signature, or a wrong audience or time |
| `wrong_issuer` | 401 | a token from another environment's issuer |
| `not_an_app` | 403 | a person's token on publish, or a client id no record of this environment holds |
| `not_a_person` | 403 | an app's token on a person's call |
| `app_retired` | 403 | a publish by a retired app |
| `role_missing` | 403 | no `publisher` role on publish; no role on the app for acknowledge, resolve or a subscription |
| `reserved_kind` | 403 | an app publishes kind `health` |
| `not_registry` | 403 | an internal call by anyone but the registry |
| `invalid_request` | 400 | the request rules above |
| `field_too_long` | 400 | a field over its limit |
| `invalid_severity` | 400 | a severity outside the four |
| `invalid_link` | 400 | a link that is not an absolute `https` URL |
| `resolve_needs_dedupe_key` | 400 | `resolve: true` without a key |
| `note_required` | 400 | acknowledging a `critical` notification without a note |
| `unknown_kind` | 422 | a kind the record does not declare (other than `health`); a subscription to one |
| `unknown_channel` | 422 | a subscription to a channel that is not one of the three |
| `not_found` | 404 | an id not of this shape, of another environment, of no notification, or of one the caller is neither a recipient of nor holds a role on |
| `not_open` | 409 | acknowledging a notification that is not `open` |
| `dedupe_kind_conflict` | 409 | a key matching a live notification of another kind |

**Versioning.** The wire changes additively only: a new optional request field, a new reply field, a
new history event name, a new channel, a new error code. A client ignores reply fields it does not
know. The four severities and three states are closed sets: adding one would change the order a
subscription compares against, so it would be a `/v2`.

## Producer mapping

This section maps the alert sources of five open-source projects onto kinds: hostkeeper, jobscheduler,
kbf and mopm (each in its own `komira-ai` repository) and this repository's own main-red alert. It is
marked to move out of this doc into a home of its own; the rest of the doc does not depend on it, and
nothing in it names a deployment, a host or an account.

The rows come from each producer's source on its `main` branch at the time of writing; the files each
table was read from are named under its heading, as paths in that project's repository. A producer
adopts its rows in its own change, with a publish client behind a flag; until then nothing here changes
what it does.

Rules every row follows:

- **The app is the producer's registered name**, and its record declares every kind in its table.
- **The dedupe key starts with the kind**, then the parts that name one instance, joined by `/`, so one
  key never names two kinds (rule 5). Where the producer already has a key that starts with its kind,
  that key is used as is.
- **A clear is `resolve: true` with the same key.** A producer whose source has no clear event today
  needs one added: the row says so.
- **`link`** points at the producer's own page for the instance (its console, status page or issue),
  never at the notification service.
- **`error` is a level a producer may leave unused.** hostkeeper's alerts have only `critical` and
  `warning`, and they map one to one.

### hostkeeper: host alerts and the host-health kinds

Source, in `komira-ai/hostkeeper`: `crates/hostkeeper-coordinator/src/alerts_kind.rs` and `alerts.rs`
(the built kinds and their severities), `crates/hostkeeper-proto/proto/hostkeeper/operator/v1/operator.proto`
(`AlertKind`), `docs/design/host-health-alerts.md` sections 5.1 and 5.2 (the host-health kinds, designed,
not built).

Today the coordinator derives alerts on every observation and forgets one silently when its condition
ends; nothing is sent anywhere. The host-health design adds an `alert_raised` and an `alert_cleared`
record for every alert that names a host. The publish client publishes on `alert_raised` (or, for an
alert that names no host, when the derivation first finds it) and resolves on `alert_cleared` (or
when the derivation stops finding it). A coordinator restart re-finds a standing condition and
publishes it again: a repeat (row 3) while the notification is open, and a new notification (row 5)
after a person acknowledged it. To avoid the second case, the publish client publishes a host-naming
alert only on its `alert_raised` record, which the design writes once per condition, not on every
derivation.

| hostkeeper kind | Severity | Dedupe key | Fires | Clears |
|---|---|---|---|---|
| `halt` | critical | `halt/<service>` (the groups sharing the halt go in the body) | a service of the rollout file is halted | the halt is cleared |
| `waiting_for_operator` | warning | `waiting_for_operator/<request>` | an enrollment request waits | the request is approved or removed |
| `duplicate` | critical | `duplicate/<host>` | two live daemons report one identity | the store no longer marks the host duplicate |
| `duplicate_claim_pending` | warning | `duplicate_claim_pending/<request>` | a request claims another host's or request's identity | the request is resolved |
| `failed_canary` | critical | `failed_canary/<service>/<version>/<host>` | a canary failed a release | the version is no longer marked bad |
| `held_on_bad_version` | warning | `held_on_bad_version/<service>/<host>` | a held host runs a version marked bad | the hold is released or the mark removed |
| `abandoned_while_updating` | warning | `abandoned_while_updating/<service>/<host>` | a host stays excluded after an abandoned update | the host is no longer excluded |
| `silent_host` | warning today; critical with the host-health change | `silent_host/<host>` | no heartbeat for the silence limit | the host beats again |
| `cert_near_expiry` | warning | `cert_near_expiry` | the certificate served to hosts is near expiry or expired | it is renewed |
| `store_unreachable` | critical | `store_unreachable` | the coordinator lost its database session | the link is back |
| `trusted_root` | warning | `trusted_root/<host>` | a host's trusted root is stale, missing or unreadable | its heartbeat no longer says so |
| `prerequisite_failed` | warning | `prerequisite_failed/<host>` | a host's prerequisite failed | none is failed |
| `xcode_release_waiting` | warning | `xcode_release_waiting/<version>` | a newer Xcode release is not in the store | the store holds it |
| `xcode_version_taken` | warning | `xcode_version_taken/<version>` | a second build under a held version was refused | the held archive is removed |
| `updates_due` | warning | `updates_due/<group>`, or `updates_due/-` for hosts in no group | a group's hosts report maintenance due | none is due |
| `failed_update` | critical | `failed_update/<service>/<host>` | a host failed to reach the version its group wants | the host reports another outcome, or another version is wanted |
| `host_halt` | critical | `host_halt/<service>/<host>` | a host holds a halt of its own | the host no longer reports it |
| `maintenance_halted` | critical | `maintenance_halted/<host>` | a maintenance step failed and the host stays cordoned | the turn moves on after a retry or put back |
| `maintenance_not_back` | critical | `maintenance_not_back/<host>` | a host rebooting in maintenance is not back | the host reports again |
| `repeated_deferral` | critical | `repeated_deferral/<service>/<host>` | a host declined the wanted version three times in a row | the host updates, gives another reason, or another version is wanted |
| `hardware_fault` (designed) | the record's: warning, or critical, which cordons | `hardware_fault/<host>/<finding>` | a memory, CPU, PCIe, thermal, power or board record at warning or above | the record is deasserted or leaves the 7-day window |
| `capacity_regressed` (designed) | warning | `capacity_regressed/<host>/<finding>` | installed capacity is below the baseline | the record is deasserted (a rebaseline does this) |
| `storage_failing` (designed) | the record's; a nearly full file system is warning at 90% and critical at 97% | `storage_failing/<host>/<finding>` | a disk or file-system record, or a nearly full file system | the record is deasserted or ages out |
| `unexpected_reboot` (designed) | warning | `unexpected_reboot/<host>/<boot id>` | a reboot with no clean-shutdown marker in the last 24 hours | it leaves the 24-hour window |
| `service_unhealthy` (designed) | warning; critical after 30 minutes | `service_unhealthy/<service>/<host>`, or `service_unhealthy/<service>/group/<group>` for the collapsed alert | a managed service is unhealthy past the limit | it is healthy again |
| `service_crash_loop` (designed) | critical | `service_crash_loop/<service>/<host>` | restarts past the limit in 10 minutes | the derivation no longer finds it |
| `host_not_monitored` (designed) | warning | `host_not_monitored/<host>/<source>` | an expected source is unsupported or unreadable | the source reports again |
| `bmc_missing` (designed) | warning | `bmc_missing/<host>` | a Linux host's BMC is absent or does not answer | the BMC answers |

Not mapped: `AlertKind` values 12 to 15. They are kept in the proto because a shipped value is never
removed, and no coordinator raises them since the coordinator's device management was removed.

`service_unhealthy` rising to `critical` after 30 minutes is a repeat with a higher severity (row 4):
the same notification, escalated, with the people who subscribed at `critical` told only then.

hostkeeper's own acknowledgement (`hk alerts ack`, with notes) and this service's acknowledgement are
separate for now: acknowledging in one does not acknowledge in the other. The console banner stays.

### jobscheduler: `js-alert`

Source, in `komira-ai/jobscheduler`: `crates/js-alert` (the webhook sender, its dedupe and retry), and
its three callers: `crates/js-lease-server` (the scaler's alerts in `scaler/alert.rs`, and
`store_health.rs`) and `crates/js-watch` (`watcher.rs`).

`js-alert` posts `{source, key, text}` to a webhook with an optional bearer token. It has no kind, no
severity and no clear: it sends a key on first appearance, resends it every `repeat_after` while the
condition holds, and forgets it silently when the condition ends. Its key already starts with its kind
(the part before the first `:`), so the mapping keeps the key as is. Adopting the service needs four
changes in `js-alert`:

1. A body in the wire's fields: `kind` from the key's prefix, `dedupe_key` the key, `title` the text,
   and a severity per prefix (the table below).
2. A clear when a key leaves the set of holding alerts, sent as `resolve: true`.
3. No resend while a condition holds. Today it resends every `repeat_after`; against this service each
   resend after an acknowledgement would open a new notification (row 5) and tell people again, so the
   client publishes on first appearance and on clear only.
4. A client-credentials token from the issuer in place of the optional static bearer token. The
   sender already posts to `https` URLs, so the transport needs no other change.

The lease server and the watcher publish as one app, `jobscheduler`; their keys never collide. The severities are assigned here: the source has none.

| `js-alert` key | Kind | Severity | Fires | Clears |
|---|---|---|---|---|
| `orphan:<pool>:<name>:<cloud id>` | `orphan` | warning | a machine of ours that no record knows; counted against the caps and never released | the record goes or stops being an orphan |
| `pool:<pool>:<name>:<cloud id>` | `pool` | warning | a counted record of a pool the server no longer has | the pool returns or the record goes |
| `silent:<host>` | `silent` | warning | a host silent past twice the unknown hold, with its lease given up, not busy, and not marked for release | the condition stops holding |
| `releasing:<pool>:<name>:<cloud id>` | `releasing` | warning | a release the provider does not confirm in time | the record leaves releasing |
| `revoke:<host>` | `revoke` | error | a host's join token could not be revoked, so its machine is kept | the revoke succeeds |
| `remove:<host>` | `remove` | warning | the registry refuses to remove a gone machine's host | the removal succeeds |
| `brake:<pool>` | `brake` | error | too many boots failed in a row; the pool launches nothing until an operator resets the brake | the brake is reset |
| `offer:<provider>:<offer>:<zone or ->` | `offer` | info | an offer whose machine did not match was cooled down | the cool-down ends |
| `store:unreachable` | `store` | critical | the lease server's store has failed for its window | the first good tick |
| `heartbeat:<pool>` | `heartbeat` | error | a pool that must tick has not ticked for the stale limit | the tick moves or the pool goes |
| `heartbeat` | `heartbeat` | error | the watcher cannot read the server's status for the stale limit | the status reads again |
| `list:<cloud>` | `list` | warning | the watcher cannot list a cloud's instances, so nothing is checked | the listing succeeds |
| `unexplained:<cloud>:<instance id>` | `unexplained` | error | an instance the server's status does not explain, for the confirm ticks | it is explained or gone |
| `sweep:<cloud>` | `sweep` | warning | the leftover sweep failed | a later sweep succeeds |
| `stray:<kind>:<region>:<id>` | `stray` | warning | the sweep found a leftover with the scheduler's marks | a later sweep no longer lists it |

The two `heartbeat` keys share a kind and differ in key, so they are two conditions.

### kbf: `kbf-alert`

Source, in `komira-ai/kbf`: `crates/kbf-alert` (`alert.rs`, `book.rs`, `outbox.rs`, `webhook.rs`), and
the alerts kbf's design docs plan.

`kbf-alert` is a library with no caller yet. It already has what the service needs: an alert book
keyed by `(rule, subject)` with hysteresis, a `raised` and a `resolved` transition, a severity of
`info`, `warning` or `critical`, and a durable outbox delivered at least once. It defines no rule names:
each caller chooses them. So the mapping is one rule, not a list:

| `kbf-alert` field | Notification field |
|---|---|
| `rule` | `kind` (the caller's rule names are the kinds kbf's record declares) |
| `rule` and `subject` | `dedupe_key`: `<rule>/<subject>` |
| `severity` (`info`, `warning`, `critical`) | the same `severity`; kbf leaves `error` unused |
| `transition: raised` | a publish |
| `transition: resolved` | a publish with `resolve: true` |
| `summary` | `title` |
| `fix` | `body` |

Three changes are needed in `kbf-alert` to adopt the service:

1. The webhook sender refuses `https` today, and the service is `https` only.
2. The sender's static bearer token becomes a client-credentials token from the issuer.
3. The outbox sends strictly in order and retries its head forever, so one event the service refuses
   for good would hold every later one, resolves included. The sender treats a 400, 403, 404, 409 or 422 as a
   refusal: it logs it, drops that event and moves on. A 401 (a credential to fix), other statuses and
   network errors keep retrying.

The alerts its design docs plan (a capability withdrawn, a farm fault without a probe, a node
suspected, a farm verdict memoised, a lost blob, a held rollout, a client gate waiting, a node not
back, a credential near expiry) each become a kind when their caller lands.

### jobscheduler: job completion callbacks

Source, in `komira-ai/jobscheduler`: `crates/js-callback`, `crates/js-lease-server` (the delivery of
callbacks), `docs/design/job-retry-and-completion-callback.md`, and `JobState` in the job proto.

A completion callback is not a notification. It is a bare POST with an empty body, signed with the
submitter's per-job key (Standard Webhooks v1: `webhook-id`, `webhook-timestamp`,
`webhook-signature`), sent once when a job has finally ended, at least once, and identical for every
end state. The server refuses a job with a callback today, so none is sent yet. The callback stays as
designed. A small registered bridge app receives callbacks for the jobs it submitted or was given,
reads the job with its own token to learn how it ended, and publishes (the kinds and severities are
assigned here):

| Job end state | Kind | Severity | Dedupe key |
|---|---|---|---|
| `SUCCEEDED` | `job_succeeded` | info | `job_succeeded/<job id>` |
| `FAILED` | `job_failed` | error | `job_failed/<job id>` |
| `CANCELLED` | `job_cancelled` | info | `job_cancelled/<job id>` |
| `LOST` | `job_lost` | error | `job_lost/<job id>` |
| `FAILED_TO_START` | `job_failed_to_start` | error | `job_failed_to_start/<job id>` |

A job ends once, so the bridge never resolves these; a person acknowledges or resolves them. The
bridge drops a repeated `webhook-id` before it publishes, because a repeated callback after a person
acknowledged would otherwise open a second notification (row 5). Which job kinds the bridge maps, and
what it does on a callback that expires undelivered, belong to the bridge's own design.

### mopm

Source, in `komira-ai/mopm`: `service/infra/stacks/lib/publish-stack.ts` (the alarms),
`docs/what-mopm-stores.md`.

mopm sends no mail today, and no mopm doc plans one. mopm stores no email address, so it has no
recipient to mail. Its alert-like producers are eight registry alarms defined in its infrastructure
stack, each wired to no action. They map as below (the kinds and severities are assigned here; one
deployment of mopm is one app in its environment, so the deployment's stage is not in the key):

| mopm alarm | Kind | Severity | Fires | Clears |
|---|---|---|---|---|
| `native-mirror-failed` | `native_mirror_failed` | error | the native mirror failed at least once in its 6-hour period | a period with no errors |
| `validate-dlq-depth` | `dead_letters` | error | a validate message failed 3 times and sits in the dead-letter queue | the queue is redriven or emptied |
| `index-dlq-depth` | `dead_letters` | error | the same, for the index queue | the same |
| `group-dlq-depth` | `dead_letters` | error | the same, for the group queue | the same |
| `group-invariant` | `group_invariant` | critical | a committed group has a member a reader cannot account for | a period with no such reading |
| `group-pending-rows` | `group_pending_rows` | warning | a package holds 100 or more pending version rows | the maximum drops below 100 |
| `group-oldest-active` | `group_stalled` | warning | a validating or committed group shows no sign of life for 30 minutes | the age drops below 30 minutes |
| `group-stalled` | `group_stalled` | error | the sweeper gave up resending a group; a person decides | the group is ended or left |

The dedupe key is `<kind>/<alarm name>`, so the three dead-letter alarms are three conditions of one
kind. Publishing needs a small forwarder from the alarm's state changes (`ALARM` publishes, `OK`
resolves); the mail and account events a person might want from mopm (a namespace claimed, a version
published, a member changed) are mopm's own design to add as kinds.

### komira: main red

Source, in this repository: [`release/ci/main_red.zig`](../../release/ci/main_red.zig) and
`release/ci/main_red/`, the `main-red` workflow, [ci.md](../ci.md).

When a watched workflow's push run on `main` fails, the `main-red` workflow opens one issue labelled
`main-red` or, when one is open, comments on the oldest open one; a green run closes every open one
with `Fixed: main is green at ...`. A red run whose head a later green run already contains writes
nothing.

| Event | Publish |
|---|---|
| a red run, no open issue (the issue is opened) | kind `main_red`, severity `error`, key `main_red/<repository>`, title the issue's title, body the run's fields (`Run`, `Head`, `Last green`, `Culprits`, `Failing`), link the issue |
| a red run, an issue is open (a comment) | the same key: a repeat (row 3), or after an acknowledgement a new notification (row 5) |
| a green run (the issues are closed) | `resolve: true` with the same key |
| a duplicate issue from a race, closed at once | nothing: the key is the same, so the two runs fold |

Severity `error`, not `critical`: the rule for a red main is to fix forward or revert within the hour
([ci.md](../ci.md)), which a person does from the issue; nothing is lost while it is red. To publish,
the workflow needs an app credential of its own, which is the main-red adopter's change to design.

## What is built from this

| Library or app | What it holds |
|---|---|
| `notify_core` | the record, the states, the dedupe rule, the history events, the id, and a `NotificationStore` trait with an in-memory and a Postgres store, both held to one conformance suite built from the transition table |
| subscriptions and recipients | the subscription store and the recipient resolver, a pure function of the inputs [Recipients](#recipients) lists |
| the HTTP service | the calls of [The wire](#the-wire) over the two above, with the producer checks |
| each producer's client | a small publish client behind a flag in each producer, using the mapping |

The conformance suite holds, at least: one test per row of the transition table; that the dedupe scope
is all three of environment, app and key (a key reused by another app, or in another environment, makes
a separate notification); that every event writes exactly one history row and no history row is ever
changed; that ids carry the environment prefix and do not repeat across a large batch; that two
concurrent publishes of one kind in one scope leave one `open` notification with `count` 2, and of two
kinds leave one with `count` 1 and refuse the other with 409; that open, acknowledge, repeat,
acknowledge, then a producer's resolve resolves both acknowledged ones in one call; that a severity of
`critical`, then `warning`, then `critical` mails a `critical`-only subscriber once; and that the
notification row equals the replay of its events. The recipient resolver's table tests hold that the
owner always gets the inbox, a subscriber below the minimum gets nothing, a deleted subscription stops
delivery, and a person who left the environment, or a subscriber with no role on the app, is dropped.

## Decisions

Choices this doc makes where a case could go more than one way, each with its reason:

- **The kind is not in the dedupe scope; a key reused across kinds is refused.** The scope is
  (environment, app, key), so a producer names a condition once; refusing the mixed case (rule 5) is
  safer than folding two conditions into one.
- **A producer's resolve takes every live notification in the scope, the acknowledged ones too.** The
  condition has cleared, so nothing about it is still live.
- **Resolving with nothing live is a success that names nothing**, so a producer's resend after a lost
  reply is harmless.
- **A second acknowledgement is 409, not a silent success**, so a second person's note is never dropped
  without them knowing.
- **A repeat takes the producer's latest severity, title and body**, and only a rise re-runs the
  recipients, telling only (person, channel) pairs not told before: the latest is the truest, and only
  news should reach people again.
- **Acknowledged notifications in one scope are not capped.** Each acknowledgement is a person's
  record of having seen one fire; merging them would lose whose note went with which.
- **Retire is a hook the registry calls and retries**, not one transaction: the two are separate
  services, and the publish refusal (row 21) already holds while the hook is pending.
- **Critical needs an acknowledgement note; the other levels do not.** A critical fault is the one a
  later reader most needs the why of.
- **History is kept forever.** Notifications are small text; revisit if the store grows large.
- **The owner always gets the inbox; mail and push follow defaults the owner can change.**
- **A subscriber needs a role on the app**, the same bar as acknowledging.
- **Repeats are history events.** History is every event, and a count alone loses when the title
  changed.
- **Mail and push send no repeats, and do send the resolve** to whoever got the open, so a person who
  was told also learns it cleared.
- **Ids are `<environment_id>.n.<ulid>`**: unique with no coordination, ordered by time, routable by
  prefix, URL-safe.
- **A notification of severity `info` follows the same states** as any other. A producer of pure events
  (a job ended, a package published) can publish with a dedupe key and resolve them itself; there is no
  state that skips `open`.
- **The registry publishes `health` itself**, through an internal call, with key `health/<app name>`,
  and no app may: an app that is down cannot report itself down.
- **The mapping's severities for js-alert, completion callbacks, mopm and main red are assigned
  here**, because those sources carry none.

## Open questions

- Reminders while a notification stays unacknowledged, and their interval.
- A digest when a producer is first switched on with many conditions already true.
- Whether erasure of a person, if the environment defines one, replaces `by` in history with a
  pseudonymous id; history is otherwise never edited.
