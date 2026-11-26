# Environment relay: tickets, six calls, signals, limits, and the move into komira

Status: design, not built. "Today" means the WebSocket multiplexer as it exists in the private repository it
was written in (section 2). "Target" is what this document specifies. Statements marked *(inferred)* are reasoning,
not facts read from code. Each limit in section 8 is a default that a flag can change, except where it says fixed.

Section numbers are stable, so the pull requests that build this can cite them:
1. What it is for, and what is out of scope
2. What exists today
3. The model: relay, shares, connections, tickets, bridges
4. Tickets
5. The six calls
6. The WebSocket: connect, signal frames, bridged frames, close codes
7. Delivery: the at-most-once rule and what the relay keeps
8. Limits, and sizing the first deployment
9. Flags
10. Moving the code into this repository
11. How it is tested
12. What must always hold
13. Decisions this document makes, and open questions

## 1. What it is for, and what is out of scope

An environment is one set of central services: an app registry, an OIDC issuer, a notification service and
one relay. The relay is the environment's connection plane. It holds the long-lived WebSocket connections to open
browsers (and to a few non-browser endpoints, such as a terminal agent in a job), so that apps can stay plain
request and response services and never hold a socket.

The relay does four things:

1. **Pushes signals.** An app tells the relay "views of this share are stale". The relay sends one small frame to
   every socket subscribed to that share. The browser then fetches fresh state from the app's API. A signal marks a
   view stale and carries nothing else (section 6.2).
2. **Admits sockets by ticket.** A browser connects with a short-lived, single-use ticket that the environment's
   issuer signed for one app. The relay checks it against the issuer's keys (section 4).
3. **Bridges two sockets.** For a terminal, the relay copies frames both ways between two sockets the app named,
   without reading them (section 6.3).
4. **Answers the app.** An app lists, and closes, the sockets it granted (section 5).

Out of scope, by design:

- **Content.** The relay never carries a notification, a record, a title or a body. Signals are references.
  Bridged frames are opaque bytes that the relay copies and never parses.
- **Durable state.** The relay keeps nothing that the apps' APIs cannot rebuild (section 7).
- **Delivery guarantees beyond at-most-once.** No queue for absent sockets, no replay, no acknowledgement.
- **Policy.** The relay does no user lookup and no role check. The app decides who may watch what when it asks
  for a ticket. The relay checks only that the ticket is genuine and that each request stays inside the app's own
  shares.
- **Client-to-app messages.** A socket that is not bridged only receives. There is no inbound callback from the
  relay to an app in this version (section 13, decision D7).
- **Bulk bytes, request and response traffic, and compute.** These go through the apps' APIs.
- **More than one relay process per environment, and fan-out across environments.** A share id is scoped to one
  relay instance (section 3). Sharding is not designed here.
- **TLS.** TLS ends in front of the relay, as for every komira HTTP service today
  ([http.md](http.md), "Nothing in this repository builds an HttpServer with a TlsConfig ... for an application").

## 2. What exists today

The relay starts from a content-blind WebSocket multiplexer, about 1,500 lines of Mojo in four modules plus a
welded test. It was written in a private repository and has not shipped. Section 10 moves it here.

| Module | Holds | Behaviour today |
|---|---|---|
| `ws_frame` | RFC 6455 frame codec | Decodes client frames (masking required; RSV bits refused; 7, 16 and 64-bit lengths; a payload above `WS_MAX_PAYLOAD_BYTES` = 16 MiB is an error). Encodes unmasked server frames with FIN always set. Does not reassemble fragments, check control-frame size, or refuse reserved opcodes. |
| `ws_handshake` | The opening handshake | Parses `GET /relay?share=<id>&role=<host\|joiner>&token=<t>`. Requires `Sec-WebSocket-Key`, `Upgrade: websocket` and a non-empty share. Computes the accept key with its own SHA-1 and base64. Does not check the path, `Connection`, `Origin`, or the version (`version_ok` is computed and never used). The token is parsed and never checked. |
| `relay_core` | The routing table | A `Slab[RelayConnection]` of owned records (fd, phase, role, share id, `rx` and `tx` byte lists). A host's data frame goes to every open joiner of the same share; a joiner's frame goes to the host only. No limit on hosts per share, connections, or buffer sizes. |
| `relay_serve` | One serve step | `serve_one_iteration(mut reg, listen_fd)`: accept everything pending, then for each connection read up to 16 KiB, advance the handshake or drain frames, flush `tx`, and drop closed connections. The head is capped at 8 KiB. There is no readiness poller: the caller calls the step in a loop. PING is answered with PONG; CLOSE is echoed. The relay never pings, and has no clock and no timeouts. |

The welded test binds a loopback listener on port 0 and drives real client sockets through four cases: fan-out
with byte-identical payloads, joiner input reaching the host only, share isolation and leave, and a malformed upgrade
refused with 400.

Gaps the target closes: no authentication of any kind; unbounded per-connection buffers (a slow reader grows its
`tx` without limit); no connection cap; no timeouts; a busy loop with no poller. The test calls libc directly
through a pointer with no `# SAFETY:` comment (M3, M9), and waits on wall-clock deadlines and spin retries (T10,
T12). Section 10 says what the move changes.

## 3. The model: relay, shares, connections, tickets, bridges

**Relay instance.** One process per environment. It has an audience string (`--audience`), normally the
environment's `relay_url` setting, and an environment id (`--environment-id`). A ticket names both, so a ticket from
another environment, or for another relay, is refused.

**App.** A registered app of the environment, known to the relay only by its registered name, for example
`notifications` or `hub`. The relay never reads the registry. The name reaches it inside a signed ticket or a
service token.

**Share.** A named set of subscribed sockets. It replaces today's share id, which was any string. A share id is
`{app}/{segment}[/{segment}...]`. Its first segment is the owning app's name, and only that app may grant
subscriptions to it or publish into it. Examples: `notifications/inbox/u-7f3a`, `hub/registry`.
The grammar:

```
share_id = app_name 1*8( "/" segment )            ; at most 200 bytes in total
app_name = %x61-7A *62( %x61-7A / DIGIT / "-" )   ; [a-z][a-z0-9-]{0,62}
segment  = 1*64( ALPHA / DIGIT / "." / "_" / "~" / "-" )
```

A share has no record of its own. It exists while at least one socket subscribes to it. Share ids mean something
only inside one relay instance: the same string on another relay is a different share.

**Connection.** One accepted WebSocket. The relay gives it a `conn` id: `c_` followed by 16 lowercase hex digits.
The id is unique within one relay process and never reused there. Callers must not parse it. A connection belongs
to the app named in the ticket that opened it. It carries the ticket's `sub` and the ticket's shares.

**Ticket.** A compact JWS that the environment's issuer signs when an app calls `grant` (section 4). It is valid
once, for 60 seconds by default, to open one connection.

**Bridge.** A pairing of two tickets from the same app. When both connections are open, the relay copies each
data frame from one to the other, unchanged (section 6.3). Today's host and joiner pairing becomes either a bridge
(two parties, both ways) or a share (one publisher, many receivers).

## 4. Tickets

### 4.1 Format

A ticket is a compact JWS (RFC 7515) signed with the environment issuer's signing key: the same key set the issuer
publishes at its JWKS URI for access tokens. The `typ` header keeps the two apart.

Header, all members required:

| Member | Value |
|---|---|
| `alg` | The issuer's one signing algorithm (`ES256` or `EdDSA`, whichever the issuer design pins). The relay pins it with `--ticket-alg` and never reads it from the header to choose a verifier. |
| `kid` | The signing key's id in the issuer's JWKS. |
| `typ` | `komira-relay-ticket+jwt`, exactly. An access token (`at+jwt` or `JWT`) is never a ticket, and a ticket is never an access token. |

Claims. All are required except `nbf`. The relay ignores any claim it does not know (an additive change, B8).

| Claim | Type and rule | Meaning |
|---|---|---|
| `iss` | string, byte-equal to `--issuer-url` | The environment's issuer. |
| `aud` | string (not an array), byte-equal to `--audience` | This relay instance. |
| `env` | string, byte-equal to `--environment-id` | The environment. Refuses a ticket minted by another environment's issuer, even if the keys were shared by mistake. |
| `sub` | string, 1 to 256 printable ASCII bytes (0x21 to 0x7E) | Who the socket is for. It is the person's `sub` when the grant carried their access token; otherwise the app's own name (an endpoint the app runs, such as a terminal agent). |
| `app` | string, `app_name` grammar | The app that asked for the ticket. The issuer sets it from the authenticated client, never from a request field. |
| `shares` | array of 0 to 16 strings, each a `share_id` whose first segment equals `app`, with no duplicates | The shares the socket subscribes to. It is empty for a socket that will be bridged. |
| `max_age` | integer, 60 to 28800 | How many seconds the socket may stay open after it connects. |
| `iat` | integer, Unix seconds | Issue time. |
| `exp` | integer, Unix seconds; `0 < exp - iat <= 600` | The time by which the socket must connect. The issuer uses `iat + 60`. The relay does not close an open socket at `exp`; `max_age` does that. |
| `nbf` | optional integer | If present, checked as RFC 7519 says. |
| `jti` | string, 16 to 64 base64url characters | The ticket id. Single use (section 4.3). It is also the handle `bridge` takes. |

Example payload (whitespace added):

```json
{"iss": "https://id.example.test", "aud": "https://relay.example.test", "env": "example",
 "sub": "u-7f3a", "app": "notifications", "shares": ["notifications/inbox/u-7f3a"],
 "max_age": 7200, "iat": 1800000000, "exp": 1800000060, "jti": "q3Jt0kq1Vb8m2l9TQm7cXw"}
```

### 4.2 How a ticket is minted: `grant` at the issuer

The relay never signs. It holds only the issuer's public keys. A ticket comes from the issuer's token endpoint as
an OAuth 2.0 token exchange (RFC 8693). The issuer design adopts this request as one more grant type:

```
POST {issuer token endpoint}
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&requested_token_type=urn:komira:params:oauth:token-type:relay-ticket
&audience=<the relay's audience>
&relay_shares=<share ids, space-separated; may be empty>
&relay_max_age=<seconds; optional, default 7200>
&subject_token=<the person's access token; optional>
&subject_token_type=urn:ietf:params:oauth:token-type:access_token
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=<the app's private_key_jwt assertion>
```

The issuer:

1. Authenticates the client exactly as for `client_credentials`. The app is the client's registered name.
2. Refuses with `invalid_target` an `audience` that is not the relay of its own environment, or a share whose first
   segment is not the app's name.
3. Refuses with `invalid_request` more than 16 shares, a malformed share id, or a `relay_max_age` outside 60 to 28800.
4. If `subject_token` is present, verifies it as one of its own access tokens that is still valid, and copies its
   `sub`. An app therefore cannot mint a ticket that names a person who has not signed in to it. With no
   `subject_token`, `sub` is the app's name.
5. Signs the claims of section 4.1 with `iat` = now, `exp` = now + 60 and a fresh 16-byte random `jti`.

Reply (RFC 8693 section 2.2.1):

```json
{"access_token": "<the ticket>", "issued_token_type": "urn:komira:params:oauth:token-type:relay-ticket",
 "token_type": "N_A", "expires_in": 60}
```

The SDK's `grant` wraps this call and returns the ticket together with the URL to dial (section 5).

### 4.3 What the relay checks at connect

The checks run in this order, and the first failure answers. A refusal before the upgrade is an HTTP response
with `Connection: close` and a fixed short body. The reason code is logged, never the ticket.

| # | Check | Refusal |
|---|---|---|
| 1 | The head ends within 8 KiB; the method is `GET`; the path is `/v1/connect`; `Upgrade: websocket`; `Connection` contains `upgrade`; `Sec-WebSocket-Key` is base64 of 16 bytes. | 400 `bad_upgrade` |
| 2 | `Sec-WebSocket-Version: 13`. | 426, with `Sec-WebSocket-Version: 13` |
| 3 | `Sec-WebSocket-Protocol` offers `komira-relay.v1` and exactly one `ticket.<JWS>` entry, and the JWS is at most 4096 bytes. | 401 `ticket_missing` |
| 4 | The JWS header gate of `jose`: `alg` is the pinned algorithm; `kid` is present; `typ` is `komira-relay-ticket+jwt`; no `jwk`, `jku`, `x5u`, `x5c` or `crit`. | 401 `ticket_header` |
| 5 | The `kid` names a key in the issuer's JWKS, refreshed under the same rules as `http_auth`'s cache (max-age, one refetch per window, bounded staleness). | 401 `unknown_kid`, or 503 `keys_unavailable` with `Retry-After` |
| 6 | The signature verifies. | 401 `signature_invalid` |
| 7 | The claims hold as in section 4.1, with `--leeway` (default 30 s, at most 60) on `exp`, `iat` and `nbf`. | 401 with the claim's code: `iss_mismatch`, `aud_mismatch`, `env_mismatch`, `expired`, `not_yet_valid`, `lifetime_too_long`, `claims_invalid` |
| 8 | `iat` is no earlier than the relay process's start time minus the leeway. | 401 `issued_before_start` |
| 9 | The `jti` has not been used. The relay then records it until `exp` + leeway. | 401 `ticket_reused` |
| 10 | Below `--max-connections` in total and `--max-connections-per-sub` for this `(app, sub)`. | 503 `relay_full`, or 429 `too_many_for_sub`; both with `Retry-After: 5` |

On success the relay answers 101 with `Sec-WebSocket-Protocol: komira-relay.v1`. The connection is then open and
subscribed to the ticket's shares.

Check 8 is what lets the `jti` memory live only in RAM. After a restart the relay has forgotten which tickets were
used, so it refuses every ticket issued before it started. A client that loses its socket in a restart asks its app
for a new ticket anyway (section 6.4).

The ticket travels in `Sec-WebSocket-Protocol` because a browser cannot set `Authorization` on a WebSocket, and a
query string ends up in access logs. The relay ignores the query string. The relay does not check `Origin`: a
ticket is not an ambient credential like a cookie, so a cross-site page cannot open a socket without first
stealing a ticket. *(inferred)*

## 5. The six calls

The SDK has six calls. `grant` goes to the issuer (section 4.2). The other five go to the relay's admin listener,
each with `Authorization: Bearer <service token>`.

**The service token.** It is the app's own access token from the environment's issuer, obtained with
`client_credentials`. The token's `aud` must be the relay's audience. The token must be the app's own, so `sub`
equals `client_id` (RFC 9068), and that value is the app's registered name. A person's token is refused with 403
`not_an_app`. Verification is `http_auth`'s bearer middleware, pinned to the issuer's algorithm.

**Scope.** An app sees only what it owns: connections opened with its own tickets, shares under its own prefix.
Anything else behaves as if it did not exist. `send` reports 0 delivered, `close` reports 0 closed, and `list`
leaves it out. This way one app cannot learn another app's connection ids.

**Errors.** Every error has a JSON body `{"code": "<reason>", "message": "<fixed text>"}` with these statuses:
400 for a bad body, 401 for a missing or bad token, 403 for a share outside the caller's prefix or a person's
token, 409 for a bridge conflict, 413 for a body over 16 KiB, and 503 when the keys are unavailable.

| Call | HTTP | Request | Reply |
|---|---|---|---|
| grant | `POST {issuer}/token` (section 4.2) | shares, optional `subject_token`, optional `max_age` | the ticket, its `jti`, `expires_in` |
| publish | `POST /v1/publish` | `{"share": S, "ref": R, "cursor": C?}` | 200 `{"delivered": n}`: the number of sockets the signal was queued for. It is a count, not an acknowledgement. |
| send | `POST /v1/send` | `{"conn": K, "ref": R, "cursor": C?}` | 200 `{"delivered": 0 or 1}`. 0 when the connection is gone, not the caller's, or bridged. |
| bridge | `POST /v1/bridges` | `{"a": jti, "b": jti, "idle_timeout_s": 1800?, "max_age_s": 14400?}` | 201 `{"bridge": "b_<16 hex>"}`. 409 when a ticket is already in a bridge, has shares, or `a` equals `b`. |
| close | `POST /v1/close` | exactly one of `{"conn": K}`, `{"bridge": B}`, `{"sub": U}`, `{"share": S}` | 200 `{"closed": n}`. Each socket gets close code 4002. |
| list | `GET /v1/conns?share=&sub=&limit=&page_token=` | filters optional; `limit` 1 to 500, default 100 | 200 `{"conns": [row...], "next_page_token": "..."}`. A row is `{"conn", "sub", "ticket", "shares", "opened_at", "bridge"?}`. Rows are ordered by `conn`. |

`ref` and `cursor` are defined in section 6.2. `publish` and `send` take a signal, not a payload, so no call can
push content through the relay.

**`bridge`, step by step.** The app grants two tickets with no shares, for example one for the browser's terminal
view and one that the terminal agent in a job will dial with. It calls `bridge(a, b)`, before or after either
socket connects. The relay copies frames once both are open. If either ticket's `exp` passes before its socket
connects, the bridge ends and the socket already open is closed with 4004. When one side closes, the relay closes
the other with 4004. A bridged socket receives no signals. `idle_timeout_s` (60 to 86400) counts seconds with no
data frame in either direction. `max_age_s` (60 to 86400) is the bridge's whole life. Each end also keeps its own
ticket's `max_age`. The relay applies whichever limit comes first.

### 5.1 As library calls (Mojo, `relay_sdk`)

The SDK is a library over `http_client`. It uses `oauth`'s `ClientCredentialSource` for the service token and for
the `private_key_jwt` assertion. Public signatures take and return values only (M1). The ids are newtypes that are
checked when they are constructed.

```mojo
struct ShareId(Copyable, Movable)       # share_id grammar; __init__ raises on a bad id
struct ConnId(Copyable, Movable)        # "c_" + 16 hex
struct TicketId(Copyable, Movable)      # the ticket's jti
struct BridgeId(Copyable, Movable)      # "b_" + 16 hex

struct Signal(Copyable, Movable):       # ref and optional cursor, grammar of section 6.2
    def __init__(out self, ref: String, cursor: Optional[String] = None) raises

struct Grant(Movable):                  # not Writable: the ticket must not reach a log by accident
    def url(self) -> String             # "<relay_url with wss scheme>/v1/connect"
    def ticket_id(self) -> TicketId
    def expires_at(self) -> Int64
    def subprotocols(self) -> List[String]   # ["komira-relay.v1", "ticket.<JWS>"]

struct RelayClient[C: Connector]:
    def __init__(out self, *, relay_url: String, issuer_token_url: String,
                 var credentials: ClientCredentialSource[...], var http: HttpClient[C]) raises
    def grant(mut self, shares: List[ShareId], subject_token: Optional[String] = None,
              max_age_s: Int = 7200) raises -> Grant
    def publish(mut self, share: ShareId, signal: Signal) raises -> Int
    def send(mut self, conn: ConnId, signal: Signal) raises -> Int
    def bridge(mut self, a: TicketId, b: TicketId, options: BridgeOptions = BridgeOptions()) raises -> BridgeId
    def close(mut self, target: CloseTarget) raises -> Int      # CloseTarget: one of conn, bridge, sub, share
    def list(mut self, filter: ConnFilter, page_token: String = "", limit: Int = 100) raises -> ConnPage
```

A refusal raises an `Error` whose message is `relay: <code>`, with `<code>` from the reason tables in sections 4.3
and 5. This follows the fixed-reason convention of `jose` and `http_auth`. The message never carries a token. The
exact names of `BridgeOptions`, `CloseTarget`, `ConnFilter` and `ConnPage` are settled in the SDK's pull request.
Their fields are the request fields above.

## 6. The WebSocket: connect, signal frames, bridged frames, close codes

### 6.1 Connect

`GET {relay_url}/v1/connect`, with the ticket in `Sec-WebSocket-Protocol` (section 4.3). Browser code:

```js
const g = await fetch("/api/relay-ticket").then(r => r.json());   // the app's own API calls grant
const ws = new WebSocket(g.url, ["komira-relay.v1", "ticket." + g.ticket]);
```

### 6.2 Signal frames (relay to client)

A signal is one TEXT frame of JSON, which the relay writes itself from `publish` or `send`:

```json
{"type":"stale","share":"notifications/inbox/u-7f3a","ref":"inbox","cursor":"c-000193"}
```

| Field | Rule | Meaning |
|---|---|---|
| `type` | `"stale"` | The only type in this version. |
| `share` | the share id; absent for `send` | The share it was published into. |
| `ref` | 1 to 256 bytes of `[A-Za-z0-9._~:/-]` | Names the view or resource that changed, in the app's own terms. |
| `cursor` | optional, 1 to 128 bytes of the same set | The app's position, so a client can skip a refetch it has already done. It is opaque to the relay. |

The relay writes the fields in this order with no whitespace, so the bytes for a given input are fixed (a golden
test holds them). Because the character set needs no JSON escaping, the relay never escapes, and a signal is at most
about 640 bytes.

**What a client does with a signal.** It marks every view that shows `ref` as stale, and nothing else. A view on
screen refetches through the app's API, at most once per short debounce. A view off screen refetches when it is next
shown. A signal never carries data to display. *(inferred: this is the rule for clients; the relay cannot enforce
it.)* The privacy rule follows from this. A `ref` names a thing, not what it says. A share is granted only to
sockets the app judged may read it, so even a `ref` is seen only by them.

**Additive rule (B8).** A client ignores any field it does not know and any `type` it does not know. New fields
and new types are added this way, never renamed or re-meant. The subprotocol name carries the major version
(`komira-relay.v1`). A future v2 is a new name that the relay offers next to v1.

### 6.3 Bridged frames (both ways)

On a bridged socket, each TEXT or BINARY data frame is re-encoded unmasked with the same opcode and a
byte-identical payload, and queued to the peer. The relay never parses, logs or stores the payload. Each frame
must be a whole message (FIN set). A fragmented message closes the socket with 1002.

A data frame on a socket that is not bridged closes it with 1008, because such a socket only receives. PING is
answered with PONG on every socket.

### 6.4 Close codes and what a client does

| Code | When | Client |
|---|---|---|
| 1000 | The client closed. | Nothing. |
| 1001 | The relay is shutting down. | Reconnect and refetch. |
| 1002 | Protocol error: an unmasked frame, RSV bits, a reserved opcode, a fragmented message, or a control frame over 125 bytes or without FIN. | Report a bug; do not loop. |
| 1008 | A data frame on a socket that is not bridged. | Report a bug. |
| 1009 | A frame payload over 64 KiB. | Report a bug. |
| 4001 | The ticket's `max_age`, or the bridge's `max_age_s`, was reached. | Reconnect and refetch. |
| 4002 | The app called `close`. | Do not reconnect until the app says so. |
| 4003 | The socket fell behind: its queue overflowed (section 8), so signals may have been lost. | Reconnect and refetch. |
| 4004 | The bridge ended: the peer closed, never connected, or went idle. | The terminal view says so. |
| 4005 | Idle: no frame (including PONG) for 90 s. | Reconnect and refetch. |

"Reconnect and refetch" means: ask the app for a new ticket, with backoff (1 s, doubling to at most 5 minutes,
with jitter), then refetch every view on screen once. A ticket is used once, so a reconnect always needs a new one.

## 7. Delivery: the at-most-once rule and what the relay keeps

**The rule.** The relay delivers a signal at most once to each socket that is subscribed to the share when
`publish` runs. It queues nothing for a socket that is absent or not yet connected. It never replays and never
acknowledges. It never drops a signal silently. A socket whose queue is full is closed with 4003. So a client always
knows when it may have missed a signal, and refetching is always enough to recover. The API is the record, and the
relay is a hint.

**Order.** Signals to one socket arrive in the order the relay received the `publish` and `send` calls. Frames on a
bridge arrive in the order they were sent. Nothing is ordered across sockets.

**What the relay keeps, all in memory:**

| State | Rebuilt by |
|---|---|
| Open connections, with their sub, app, shares and queues | Clients reconnecting with new tickets |
| The set of `jti`s used, each until `exp` + leeway | Nothing needed: check 8 refuses tickets issued before the restart |
| Bridges and the tickets they wait for | The app calling `grant` and `bridge` again when its client reconnects |
| The issuer's JWKS | Fetching it again |

**A restart** drops every socket. Clients reconnect and refetch. A `publish` that runs while the relay is down fails
at the caller. The app logs the failure and goes on: the state is committed in the app, and clients refetch when
they reconnect. An app never retries a publish in a loop. Its own record is what clients read.

**An app that publishes.** It publishes after it commits the change, in the same request. The relay reads no
database and no change stream.

## 8. Limits, and sizing the first deployment

Each limit is a flag (section 9) with the default shown. A limit marked **fixed** is a protocol constant.

| Limit | Default | When it is exceeded |
|---|---|---|
| Handshake head | 8 KiB, fixed | 400 |
| Handshake deadline (head complete after accept) | 10 s | The socket is closed with no response. |
| Ticket size | 4096 bytes, fixed | 401 `ticket_missing` |
| Ticket connect-by window (`exp - iat`) | at most 600 s, fixed; the issuer uses 60 s | 401 `lifetime_too_long` |
| Ticket `max_age` | 60 to 28800 s; the issuer's default is 7200 s | 401 `claims_invalid` |
| Shares per ticket | 16, fixed | 401 `claims_invalid` |
| Connections in total | 4096 (`--max-connections`) | 503 `relay_full` |
| Connections per `(app, sub)` | 32 (`--max-connections-per-sub`) | 429 `too_many_for_sub` |
| Frame payload, either direction | 64 KiB (`--max-frame-bytes`); the old 16 MiB cap goes | 1009 |
| Control frame payload | 125 bytes, fixed (RFC 6455) | 1002 |
| Queue per subscriber socket | 256 frames or 256 KiB, whichever comes first | 4003 |
| Queue per bridged socket | 1 MiB (`--bridge-queue-bytes`) | 4003 |
| Bridges | 256 (`--max-bridges`) | 503 `relay_full` |
| Bridge `idle_timeout_s` and `max_age_s` | 1800 s and 14400 s; each 60 to 86400 | 4004, 4001 |
| Pings | the relay pings every 30 s; closes after 90 s with no frame | 4005 |
| `jti` memory | 100,000 entries (`--max-ticket-ids`) | 503 `relay_full`. A full set never forgets early, because forgetting early would allow a replay. |
| Admin request body | 16 KiB, fixed | 413 |
| `list` page | 500 rows, fixed | `limit` is clamped |

**Sizing the first deployment.** One environment, the team's own, with *(inferred)* up to 100 people. Each person
has a few tabs open, and each tab holds one socket per app it shows live (the hub and the notification inbox), so
about 2 sockets. That is under 1,000 sockets in practice. The defaults leave 4x headroom on that.

- **Memory, worst case.** Every socket's queue full at once:
  4096 × 256 KiB = 1 GiB for subscriber sockets, plus 256 bridges × 2 ends × 1 MiB = 512 MiB. Add about 50 MiB for
  the process, 4096 × 64 KiB of worst-case read buffers (256 MiB), and the `jti` set (100,000 × about 100 bytes =
  10 MiB). The total is under 2 GiB.
- **Memory, normal case.** About 2 KiB per idle socket, so 1,000 sockets is about 2 MiB.
- **Machine.** 2 vCPU and 2 GiB of RAM covers the worst case, and the normal load is a small fraction of it.
- **File descriptors.** The deploy sets `RLIMIT_NOFILE` to at least 8,192: two listeners plus up to 4,096 sockets,
  with room to spare.
- **CPU.** Publish cost is proportional to the share's subscribers (an index from share to sockets, not today's
  scan of every connection). A busy publisher in this environment fans out to a few sockets. The relay needs a
  readiness poller rather than today's busy loop (section 10, stage 2), so an idle relay uses no CPU.
- **Ticket rate.** 100,000 `jti` entries, each kept for at most 660 s, allows about 150 tickets per second
  sustained, far above what 100 people need.

Raise the flags when the measured socket count passes half of `--max-connections`. *(inferred)*

## 9. Flags

Configuration is flags only, never environment variables (S2).

| Flag | Required | Meaning |
|---|---|---|
| `--ws-listen=ADDR:PORT` | yes | The WebSocket listener. The deploy points `{relay_url}/v1/connect` at it. |
| `--admin-listen=ADDR:PORT` | yes | The admin HTTP listener for the five relay calls. The deploy points the rest of `{relay_url}/v1/` at it. |
| `--issuer-url` | yes | Must equal the tickets' and service tokens' `iss`. |
| `--jwks-url` | yes | The issuer's JWKS URI. |
| `--audience` | yes | This relay's audience, normally `relay_url`. |
| `--environment-id` | yes | Must equal the tickets' `env`. |
| `--ticket-alg` | yes | `ES256` or `EdDSA`. It pins tickets and service tokens alike. |
| `--leeway`, and the limit flags of section 8 | no | As listed there. |

Both listeners bind to loopback by default when `ADDR` is left out, and TLS ends in front of them. They are two
listeners because `http_server` cannot hand a connection over after an HTTP/1.1 upgrade ([http.md](http.md):
"Limit: no WebSocket framing"). The relay keeps its own raw-socket loop for WebSockets, and serves the admin routes
with `http_server`. One thread steps both.

## 10. Moving the code into this repository

### 10.1 Why it moves

Every environment needs a relay, and the apps that use it are built from public repositories. A public repository
cannot depend on private code, so the relay and its SDK must live here. The relay also needs `jose`, `jwks` and
`http_auth`, which are here.

### 10.2 Supersession check (B22)

Before the move, the check found:

- **Uses of the private copy:** none outside its own test. A search of that repository for the package and module
  names (`ws_frame`, `ws_handshake`, `relay_core`, `relay_serve`), over Mojo, BUCK, Starlark, TOML, YAML and shell
  files, finds only the package itself and one task-seeding script that names it.
- **Markers:** no document in that repository marks the package superseded, retired, transitional or scheduled for
  deletion. The keywords searched were the usual ones: superseded, deletion, retire, transitional, obsolete,
  orphaned, deprecated, replaced, folded.
- **Here:** nothing in this repository already provides a WebSocket codec or a relay. `git grep -i websocket src`
  finds comments and generated names only, and [http.md](http.md) records the limit.

So the moved package supersedes the private copy for every use, and the private copy has no other use to hand over.

### 10.3 Packages here

| Package | Target | Holds |
|---|---|---|
| `relay` | `//src/relay:relay` | The four modules of section 2. Then the ticket check, shares, bridges, limits and admin routes. |
| `relay` (binary) | `//src/relay:relay_server` | A `main` that only parses the flags of section 9 and calls the library. |
| `relay_sdk` | `//src/relay_sdk:relay_sdk` | The six calls of section 5.1. |

The WebSocket codec stays inside `relay` and is not split into its own package. A second user would justify a
split, and none exists (B20).

### 10.4 Stages

| Stage | Work | Done when |
|---|---|---|
| 1. Move | Copy the four modules and the test into `src/relay`, with today's behaviour. Change only: imports (`komira_async.reactor.*` to `async_rt.reactor.*`, `komira_collections.slab` to `containers.slab`); comments (drop the private repository's task ids, design paths, dates and product names, and fix stale header paths); the test (client sockets through `async_rt`'s socket helpers instead of direct libc calls and pointers; waits on explicit progress counts from `ServeOutcome` instead of wall-clock deadlines and spin retries; split by behaviour into several files, each named in `test_srcs`); new codec and handshake tests to reach 99% line and branch coverage (T1); a `test_no_product_vocabulary` test like `jose`'s; a README example (T18). The private SHA-1 and base64 are replaced by `crypto.sha1` and `encoding.base64_encode`, which removes code that would otherwise need its own coverage. | The package builds and its tests pass on the farm for every release platform. No internal name is in the package. |
| 2. Tickets and admin | Sections 3 to 9: the `/v1/connect` handshake with the ticket checks of section 4.3, shares in place of host and joiner, signals, bridges, limits, close codes, an injected clock (pings, `max_age`, deadlines, ticket times), a readiness poller in place of the busy loop, the admin routes, and the `relay_server` binary. It needs `http_auth`'s JWKS cache to verify ES256 or EdDSA (today it verifies RS256 only), and the issuer to accept the token exchange of section 4.2. | The tests of section 11 pass, and the content-blind fan-out test from stage 1 is kept. |
| 3. SDK | `relay_sdk`, tested against the real `relay` library in-process. | Each call, and each refusal, is proven. |
| 4. Delete the private copy | In the private repository, after stage 1 merges: move its pin of this repository past the merge, then delete its copy of the package in one change, with this section's supersession result in that change's description. Its one script that names the package is edited in the same change. | The private repository builds with no copy of the relay. |

Stage 4 does not start before stage 1 is merged and pinned. Until then the private copy is left untouched and not
edited. Nothing in this repository ever depends on it.

## 11. How it is tested

Every test is welded into its library's build, uses a loopback listener on port 0 and an injected clock, and
asserts the reason code or close code of every refusal. No test waits on wall-clock time (T10) or depends on the
network (T12). Tickets are signed by the test issuer (`komira_test_issuer`'s `sign_claims`, which can set any
`typ`). Stage 1 keeps today's four behaviours. Stage 2 adds these tests, in `src/relay/tests/`:

| Test | Asserts |
|---|---|
| `test_ticket_refused` | Each row of section 4.3 answers with its status and code: no ticket; ticket in the query only; bad header; unknown `kid`; bad signature; another issuer; another audience; another environment; expired; `exp - iat` over 600; issued before the relay started; a share outside the app's prefix; 17 shares; a used `jti`. |
| `test_keys_unavailable` | A JWKS that cannot be fetched past its staleness bound gives 503 with `Retry-After`. |
| `test_publish_reaches_only_share_subscribers` | A signal reaches every subscriber of its share, byte for byte as the golden frame, and no socket of any other share. `delivered` equals that count. |
| `test_no_replay_for_late_subscriber` | A socket that connects after a publish never receives it (at most once). |
| `test_queue_overflow_closes_4003` | A reader that never reads is closed with 4003 at 256 frames, and the others keep receiving. |
| `test_bridge_copies_frames_byte_identical` | Opaque TEXT and BINARY frames, including bytes that look like JSON or an HTTP head, cross a bridge unchanged both ways (content-blind). |
| `test_bridge_ends_together` | One end closing closes the other with 4004; a ticket that never connects ends the bridge at its `exp`. |
| `test_unbridged_data_frame_closes_1008` | A data frame on a socket that is not bridged closes it with 1008. |
| `test_frame_limits` | Payloads of 64 KiB pass and 64 KiB + 1 closes with 1009. A fragmented message, an unmasked frame and a 126-byte PING each close with 1002. A head of 8 KiB + 1 gets 400. |
| `test_connection_caps` | Connection 4097 gets 503 and connection 33 for one sub gets 429. |
| `test_max_age_and_idle` | Advancing the clock past `max_age` closes with 4001, and past 90 s of silence closes with 4005. |
| `test_admin_auth` | No token gives 401. A person's token gives 403 `not_an_app`. A token for another audience gives 401. |
| `test_admin_scope` | `send`, `close` and `list` never see another app's connections; `publish` into another app's share gives 403. |
| `test_list_pages` | Rows are ordered by `conn`, `limit` is clamped to 500, and the page token resumes where the last page ended. |
| `test_signal_golden` | The signal bytes for fixed inputs equal a committed golden file. |
| `test_unknown_claims_and_fields` | A ticket with an extra claim is accepted. The SDK's decoders accept a reply with an extra field. These are the cross-version tests for B8: a new field changes nothing for an older reader. |

## 12. What must always hold

- The relay never parses, logs or stores a bridged payload, and never sends content of its own beyond the
  signal fields.
- A socket is opened only with a ticket that verifies against the configured issuer's keys, for this audience and
  this environment, used once.
- An app reaches only its own shares and its own connections.
- A signal is delivered at most once, and a socket that might have missed one is closed with a code that tells the
  client to refetch.
- Every buffer and table has a bound, and reaching it is answered with a named status or close code.
- The relay holds no signing key, and no state that a restart cannot rebuild.

## 13. Decisions this document makes, and open questions

Decisions:

- **D1. The issuer mints tickets, by token exchange.** The relay holds only public keys, so a stolen relay leaks
  no signing key, and the issuer is the one place that knows which app is asking. The alternative, a relay that
  signs its own tickets, would make tickets "checked against the relay", not against the issuer.
- **D2. A distinct `typ`, `komira-relay-ticket+jwt`.** It uses the same keys as access tokens, but neither kind can
  stand in for the other. `jose`'s `ClaimPolicy` accepts only `at+jwt` and `JWT`, so the relay verifies with
  `JwsVerifier.verify_with_typ` and checks the claims itself. `jose` does not change.
- **D3. An `env` claim.** It is the environment seam: two environments never accept each other's tickets, even if
  their audiences were configured to the same string by mistake.
- **D4. The ticket rides in `Sec-WebSocket-Protocol`.** A browser cannot set `Authorization` on a WebSocket, and a
  query string is logged.
- **D5. Refuse tickets issued before the relay started.** This keeps single use correct across a restart without
  persisting `jti`s.
- **D6. Signals are built by the relay from `ref` and `cursor`.** No call takes a free payload, so "marks a view
  stale, nothing else" is a property of the wire, not a convention.
- **D7. No inbound callbacks in this version.** A socket that is not bridged only receives. Every known use (live
  inbox, stale views, terminals) fits signals plus bridges. Inbound calls are a later, additive feature.
- **D8. Shares replace host and joiner.** A share is one-to-many, and a bridge is the two-way pairing. The share's
  first segment is its owning app, which is how the relay scopes apps without reading the registry.
- **D9. Two listeners in one process.** `http_server` cannot hand a connection over after an upgrade, so the
  WebSocket loop stays the relay's own.
- **D10. A full queue closes the socket (4003) instead of dropping a signal.** A dropped signal would leave a view
  stale with no sign of it. A close tells the client to refetch.
- **D11. The 16 MiB frame cap becomes 64 KiB.** Signals are under 1 KiB, and a terminal frame is far smaller than
  64 KiB.
- **D12. The move keeps one package.** The WebSocket codec is split out only when a second user appears.

Open questions:

- **Q1. Member removal.** When a person is removed, each app that granted them a ticket calls `close({"sub": ...})`.
  The relay could instead take the issuer's signed removal notice itself and close every socket of that `sub`, in
  one place. Recommendation: do this once the issuer's removal notice format is fixed. It adds one route to the
  relay and no call to the SDK.
- **Q2. Several apps on one socket.** A tab that shows live views of two apps holds two sockets today, because a
  ticket's shares all belong to one app. Recommendation: keep it until a page needs more than three.
- **Q3. A second relay instance.** Out of scope (section 1). Share ids are scoped to one instance, so sharding by
  share would add instances without changing a ticket or a call.
