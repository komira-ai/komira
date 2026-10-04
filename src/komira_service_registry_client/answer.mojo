# =============================================================================
# komira_service_registry_client/answer.mojo — THE CLASSIFIER. A registry
#   response becomes exactly ONE of five kinds, and a strict parser decides the
#   200 case.
# =============================================================================
#
# ★★ THE WHOLE POINT OF THIS FILE IS THAT "NO ANSWER" AND "THE ANSWER IS NO"
# ARE DIFFERENT EVENTS. The registry is what a peer dials BEFORE it can dial
# anything else, so a failed resolution has two readings with OPPOSITE fixes:
#
#     found:false        the registry answered. The name is UNREGISTERED.
#                        FIX: publish the endpoint (a deploy bug).
#     not reached        nothing answered, or something that is not the
#                        registry did. FIX: the edge / the URL / the network.
#
# Collapsing them is the defect class the serving app's `200 {"found":false}`
# decision exists to prevent, and a client that reads a 404 as "unregistered"
# re-creates it one layer out. So this file classifies, and it never guesses.
#
# ═══════════════════════════════════════════════════════════════════════════
#  THE TABLE. Two inputs decide everything: the STATUS and whether the response
#  carried the MARKER.
# ═══════════════════════════════════════════════════════════════════════════
#
#   status   marker    body            kind                  what it means
#   -------  --------  --------------  --------------------  --------------
#   200      any       parses          OK (found / absent)   the registry answered
#   200      any       does not parse  PROTOCOL_ERROR        it answered garbage
#   400      present   any             REFUSED               OUR request was bad
#   4xx/3xx  present   any             PROTOCOL_ERROR        route/version skew
#   5xx      present   any             REGISTRY_ERROR        it cannot answer; retry
#   ANY      ABSENT    any             NOT_REACHED           it was not the registry
#
# ★ WHY THE MARKER IS THE DISCRIMINATOR ON A NON-2xx AND NOT ON A 200.
#
# On a NON-2xx it is the ONLY discriminator there is. Three parties in front of
# this process emit a 404 byte-identical to an application 404 (Google's edge on
# `/healthz` before the IAM check; an `internal-and-cloud-load-balancing`
# service on EVERY path including a nonsense control; a DELETED service), and
# none of them will emit this header. Status alone cannot separate them.
#
# On a 200 the BODY is already an unforgeable discriminator: no edge, no proxy
# and no deleted service emits `{"found":…,"value":…,"key":…}`. So requiring the
# marker there as well would buy no distinction and would cost availability —
# ONE header-stripping hop anywhere on the path would turn every lookup in the
# fleet into a hard failure. The marker's ABSENCE on a 200 is therefore RECORDED
# (`PeerResolution.marker_state`) rather than fatal: the fact survives into the
# log line, where an operator can act on it, without being able to take the
# mesh down.
#
# ⚠ PRESENCE, NOT VALUE. `marker.byte_length() > 0` — the value is deliberately
# NOT compared against `SERVICE_REGISTRY_MARKER_VALUE`. A future server that
# bumps the value must not read as "the registry was not reached", which is the
# single most misleading thing this client can say. (Same call, same reason, as
# `LivePeerTransport.dial`'s "PRESENCE, not value" on the attribution header.)
#
# ⛔ A 404 IS NEVER ABSENCE. Not with the marker (that is a route that does not
# exist — a client/server version skew, fixed by shipping a matching client),
# and not without it (that is the edge). Neither is "the name is unregistered",
# which is only ever a 200 carrying `found:false`.
#
# ENCAPSULATION: pure functions over Strings. No I/O, no pointer, no origin, and
# NOTHING here raises — a taxonomy that has to be recovered by string-matching
# an exception is the fragility `directory.mojo` documents about store errors,
# and this file will not reproduce it one layer up.
# =============================================================================

from komira_service_registry.http_contract import (
    WIRE_FIELD_FOUND,
    WIRE_FIELD_KEY,
    WIRE_FIELD_VALUE,
)


# -----------------------------------------------------------------------------
# §1 — the five kinds.
# -----------------------------------------------------------------------------

comptime ANSWER_OK: Int = 1
"""The registry answered a lookup. `found` says WHAT the answer was."""

comptime ANSWER_NOT_REACHED: Int = 2
"""Nothing that carried the marker answered. The edge, a proxy, a deleted
service, private ingress, or a wrong base URL — not the registry."""

comptime ANSWER_REGISTRY_ERROR: Int = 3
"""The registry answered and said it could not read its store (5xx). It IS
there, which is a strictly more informative fact than NOT_REACHED. Retryable."""

comptime ANSWER_PROTOCOL_ERROR: Int = 4
"""The registry answered something this client cannot read: a body that is not
the contract, or a status the contract does not define on this route. A
client/server version skew — NOT a network fault and NOT an absence."""

comptime ANSWER_REFUSED: Int = 5
"""The registry refused OUR request (400): it says there was no key to consult.
Our input is wrong; retrying it will fail identically."""


@fieldwise_init
struct RegistryAnswer(Copyable, Movable, Deinitable):
    """One classified registry response.

    `found` / `value` / `key` are meaningful ONLY when `kind == ANSWER_OK`; on
    every other kind they are the zero values and `detail` says why. They are
    not an Optional because the kind IS the discriminator, and two
    discriminators for one fact is how they drift apart."""

    var kind: Int
    var found: Bool
    var value: String
    var key: String
    """The key the SERVER reported it consulted. Carried VERBATIM — this client
    never re-derives it. See `WIRE_FIELD_KEY`'s ⛔ block: re-deriving turns the
    log line into a report of the client's own belief, and a belief compared
    with itself detects nothing."""
    var detail: String
    """A short, CONSTANT-SHAPED reason. Never echoes the response body: a body
    from an unknown intermediary is attacker-influenced bytes and this string
    ends up in logs."""

    @staticmethod
    def ok(found: Bool, var value: String, var key: String) -> Self:
        return Self(ANSWER_OK, found, value^, key^, String(""))

    @staticmethod
    def failed(kind: Int, var detail: String) -> Self:
        return Self(kind, False, String(""), String(""), detail^)

    def kind_name(self) -> StaticString:
        """⚠ `StaticString`, NOT `String`: every arm returns a literal."""
        if self.kind == ANSWER_OK:
            return "ok"
        if self.kind == ANSWER_NOT_REACHED:
            return "not-reached"
        if self.kind == ANSWER_REGISTRY_ERROR:
            return "registry-error"
        if self.kind == ANSWER_PROTOCOL_ERROR:
            return "protocol-error"
        if self.kind == ANSWER_REFUSED:
            return "refused"
        return "unset"


# -----------------------------------------------------------------------------
# §2 — the strict body parser.
#
# ★ STRICT ABOUT WHAT IT KNOWS, TOLERANT OF WHAT IT DOES NOT.
#
# The three contract fields must be present, exactly once each, with the right
# JSON TYPE — `found` a `true`/`false` LITERAL, never the STRING `"false"`,
# which is the difference between a caller that checks a key is present and one
# that checks its value (`json_bool`'s docstring on the server's writer states
# the same trap from the writing end).
#
# An UNKNOWN member is SKIPPED, not refused. A strict-on-everything parser turns
# "the server added a field" into "every peer in the fleet stopped resolving" —
# a fleet outage caused by a compatible change. Forward compatibility is not a
# nicety here: server and clients deploy independently and by design.
#
# ⚠ A DUPLICATE contract member IS refused. `{"found":false,"found":true,…}` has
# two answers and no rule for choosing; last-wins would let anything that can
# append bytes to a body flip the verdict.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Cursor(Copyable, Movable, Deinitable):
    """Parse position + failure flag. A value type, so a failed sub-parse cannot
    leave the caller reading uninitialised state."""

    var pos: Int
    var bad: Bool


def _ws(b: Span[UInt8, _], var i: Int) -> Int:
    var n = len(b)
    while i < n:
        var c = b[i]
        if c == UInt8(32) or c == UInt8(9) or c == UInt8(10) or c == UInt8(13):
            i += 1
        else:
            break
    return i


def _hex_val(c: UInt8) -> Int:
    if c >= UInt8(48) and c <= UInt8(57):
        return Int(c) - 48
    if c >= UInt8(97) and c <= UInt8(102):
        return Int(c) - 87
    if c >= UInt8(65) and c <= UInt8(70):
        return Int(c) - 55
    return -1


def _parse_string(b: Span[UInt8, _], var i: Int, mut out: List[UInt8]) -> Int:
    """Parse a JSON string at `i` (which must be the opening quote) into `out`.
    Returns the index just past the closing quote, or -1 on any violation.

    ⚠ BYTE-FAITHFUL. Every byte >= 0x20 that is not `"` or `\\` is copied
    VERBATIM into `out`; nothing is routed through a codepoint. The inverse
    mistake — `chr(Int(byte))` — re-encodes 0x80-0xFF as multi-byte UTF-8, which
    is precisely the defect the server's own writer is gated against
    (`escaped_run_is_byte_faithful`). A registry echoes bytes an operator typed
    into a bundle; an internationalised host name is a legal URL."""
    var n = len(b)
    if i >= n or b[i] != UInt8(34):
        return -1
    i += 1
    while i < n:
        var c = b[i]
        if c == UInt8(34):
            return i + 1
        if c == UInt8(92):  # backslash
            i += 1
            if i >= n:
                return -1
            var e = b[i]
            if e == UInt8(34):
                out.append(UInt8(34))
            elif e == UInt8(92):
                out.append(UInt8(92))
            elif e == UInt8(47):
                out.append(UInt8(47))
            elif e == UInt8(98):
                out.append(UInt8(8))
            elif e == UInt8(102):
                out.append(UInt8(12))
            elif e == UInt8(110):
                out.append(UInt8(10))
            elif e == UInt8(114):
                out.append(UInt8(13))
            elif e == UInt8(116):
                out.append(UInt8(9))
            elif e == UInt8(117):  # \uXXXX
                if i + 4 >= n:
                    return -1
                var h0 = _hex_val(b[i + 1])
                var h1 = _hex_val(b[i + 2])
                var h2 = _hex_val(b[i + 3])
                var h3 = _hex_val(b[i + 4])
                if h0 < 0 or h1 < 0 or h2 < 0 or h3 < 0:
                    return -1
                # ⛔ ONLY `\u00XX` IS ACCEPTED, AND THE REFUSAL IS DELIBERATE.
                # The server's writer emits `\u00XX` for control bytes and
                # NOTHING else — every byte >= 0x20 goes through raw. A higher
                # escape therefore did not come from our writer, and DECODING it
                # would mean choosing an encoding for it: the same guess that
                # produces mojibake in the opposite direction. Refusing names
                # the skew instead of inventing bytes.
                if h0 != 0 or h1 != 0:
                    return -1
                out.append(UInt8(h2 * 16 + h3))
                i += 4
            else:
                return -1
            i += 1
            continue
        if c < UInt8(32):
            return -1  # a raw control byte is not legal in a JSON string
        out.append(c)
        i += 1
    return -1


def _skip_value(b: Span[UInt8, _], var i: Int, depth: Int) -> Int:
    """Skip ONE JSON value at `i`; return the index just past it, or -1.

    Used only for members this client does not know — see the forward-compat
    note in §2's header. `depth` bounds nesting so a hostile body cannot make
    this recurse without limit."""
    var n = len(b)
    if depth > 16:
        return -1
    i = _ws(b, i)
    if i >= n:
        return -1
    var c = b[i]
    if c == UInt8(34):
        var sink = List[UInt8]()
        return _parse_string(b, i, sink)
    if c == UInt8(123) or c == UInt8(91):  # { or [
        var close = UInt8(125) if c == UInt8(123) else UInt8(93)
        i += 1
        while True:
            i = _ws(b, i)
            if i >= n:
                return -1
            if b[i] == close:
                return i + 1
            if b[i] == UInt8(44):  # comma
                i += 1
                continue
            if b[i] == UInt8(58):  # colon
                i += 1
                continue
            var nxt = _skip_value(b, i, depth + 1)
            if nxt < 0:
                return -1
            i = nxt
    # A literal or a number: run to the next structural byte.
    var start = i
    while i < n:
        var d = b[i]
        if (
            d == UInt8(44)
            or d == UInt8(125)
            or d == UInt8(93)
            or d == UInt8(32)
            or d == UInt8(9)
            or d == UInt8(10)
            or d == UInt8(13)
        ):
            break
        i += 1
    if i == start:
        return -1
    return i


def parse_resolve_body(body: String) -> RegistryAnswer:
    """Parse a `200` body into an `ANSWER_OK`, or return an
    `ANSWER_PROTOCOL_ERROR` naming what was wrong with it.

    THIS FUNCTION IS THE ONLY READER OF THE WIRE BODY. It never raises and never
    partially succeeds: either all three contract fields were present, unique
    and correctly typed, or the answer is a protocol error."""
    var b = body.as_bytes()
    var n = len(b)
    var i = _ws(b, 0)
    if i >= n or b[i] != UInt8(123):
        return RegistryAnswer.failed(
            ANSWER_PROTOCOL_ERROR,
            String("registry response body is not a JSON object"),
        )
    i += 1

    var have_found = False
    var have_value = False
    var have_key = False
    var found = False
    var value = String("")
    var key = String("")
    var first = True

    while True:
        i = _ws(b, i)
        if i >= n:
            return RegistryAnswer.failed(
                ANSWER_PROTOCOL_ERROR,
                String("registry response body ended inside the object"),
            )
        if b[i] == UInt8(125):  # }
            i += 1
            break
        if not first:
            if b[i] != UInt8(44):
                return RegistryAnswer.failed(
                    ANSWER_PROTOCOL_ERROR,
                    String("registry response body: expected ',' between members"),
                )
            i += 1
            i = _ws(b, i)
        first = False

        var name_bytes = List[UInt8]()
        var after_name = _parse_string(b, i, name_bytes)
        if after_name < 0:
            return RegistryAnswer.failed(
                ANSWER_PROTOCOL_ERROR,
                String("registry response body: member name is not a string"),
            )
        i = _ws(b, after_name)
        if i >= n or b[i] != UInt8(58):
            return RegistryAnswer.failed(
                ANSWER_PROTOCOL_ERROR,
                String("registry response body: expected ':' after a member name"),
            )
        i = _ws(b, i + 1)
        var name = String(unsafe_from_utf8=Span(name_bytes))

        if name == WIRE_FIELD_FOUND:
            if have_found:
                return RegistryAnswer.failed(
                    ANSWER_PROTOCOL_ERROR,
                    String("registry response body: duplicate 'found' member"),
                )
            # ⛔ THE LITERAL, NEVER THE STRING. `"found":"false"` is a protocol
            # error, not an absence: a client that accepted it would report a
            # peer as unregistered because a writer quoted a boolean.
            if i + 4 <= n and String(body[byte = i : i + 4]) == String("true"):
                found = True
                i += 4
            elif i + 5 <= n and String(body[byte = i : i + 5]) == String(
                "false"
            ):
                found = False
                i += 5
            else:
                return RegistryAnswer.failed(
                    ANSWER_PROTOCOL_ERROR,
                    String(
                        "registry response body: 'found' is not a true/false"
                        " literal"
                    ),
                )
            have_found = True
        elif name == WIRE_FIELD_VALUE:
            if have_value:
                return RegistryAnswer.failed(
                    ANSWER_PROTOCOL_ERROR,
                    String("registry response body: duplicate 'value' member"),
                )
            var vb = List[UInt8]()
            var after = _parse_string(b, i, vb)
            if after < 0:
                return RegistryAnswer.failed(
                    ANSWER_PROTOCOL_ERROR,
                    String("registry response body: 'value' is not a string"),
                )
            value = String(unsafe_from_utf8=Span(vb))
            i = after
            have_value = True
        elif name == WIRE_FIELD_KEY:
            if have_key:
                return RegistryAnswer.failed(
                    ANSWER_PROTOCOL_ERROR,
                    String("registry response body: duplicate 'key' member"),
                )
            var kb = List[UInt8]()
            var after2 = _parse_string(b, i, kb)
            if after2 < 0:
                return RegistryAnswer.failed(
                    ANSWER_PROTOCOL_ERROR,
                    String("registry response body: 'key' is not a string"),
                )
            key = String(unsafe_from_utf8=Span(kb))
            i = after2
            have_key = True
        else:
            # Unknown member: SKIP it. See §2 — a compatible server-side
            # addition must not stop the fleet resolving.
            var skipped = _skip_value(b, i, 0)
            if skipped < 0:
                return RegistryAnswer.failed(
                    ANSWER_PROTOCOL_ERROR,
                    String(
                        "registry response body: unreadable value for an"
                        " unknown member"
                    ),
                )
            i = skipped

    var tail = _ws(b, i)
    if tail != n:
        return RegistryAnswer.failed(
            ANSWER_PROTOCOL_ERROR,
            String("registry response body: trailing bytes after the object"),
        )
    if not have_found:
        return RegistryAnswer.failed(
            ANSWER_PROTOCOL_ERROR,
            String("registry response body: no 'found' member"),
        )
    if not have_value:
        return RegistryAnswer.failed(
            ANSWER_PROTOCOL_ERROR,
            String("registry response body: no 'value' member"),
        )
    if not have_key:
        return RegistryAnswer.failed(
            ANSWER_PROTOCOL_ERROR,
            String("registry response body: no 'key' member"),
        )
    # ⚠ A `found:true` WITH AN EMPTY `value` IS A PROTOCOL ERROR, NOT A HIT. The
    # caller would dial `""`; the server never emits it (a hit's value is the
    # stored URL bytes). Refusing here is what stops an empty string being
    # cached and served as an endpoint for a whole TTL.
    if found and value.byte_length() == 0:
        return RegistryAnswer.failed(
            ANSWER_PROTOCOL_ERROR,
            String("registry response body: 'found' is true with an empty 'value'"),
        )
    return RegistryAnswer.ok(found, value^, key^)


# -----------------------------------------------------------------------------
# §3 — the classifier proper.
# -----------------------------------------------------------------------------


def classify_registry_response(status: Int, marker: String, body: String) -> RegistryAnswer:
    """Apply the table in this module's header. Never raises."""
    if status == 200:
        return parse_resolve_body(body)

    # PRESENCE, not value — see the ⚠ block in the header.
    if marker.byte_length() == 0:
        return RegistryAnswer.failed(
            ANSWER_NOT_REACHED,
            String("HTTP ")
            + String(status)
            + String(
                " with no x-service-registry marker — the registry was not"
                " reached (edge, proxy, private ingress, deleted service, or a"
                " wrong base URL)"
            ),
        )

    if status == 400:
        return RegistryAnswer.failed(
            ANSWER_REFUSED,
            String(
                "the registry refused the request (HTTP 400): it consulted no"
                " key"
            ),
        )
    if status >= 500 and status <= 599:
        return RegistryAnswer.failed(
            ANSWER_REGISTRY_ERROR,
            String("the registry could not read its store (HTTP ")
            + String(status)
            + String("); retryable"),
        )
    return RegistryAnswer.failed(
        ANSWER_PROTOCOL_ERROR,
        String("the registry answered HTTP ")
        + String(status)
        + String(
            " on a resolve route — this client and that server do not agree on"
            " the route table. NOT an absence: an unregistered name is 200"
            " with found:false"
        ),
    )
