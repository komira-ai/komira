# =============================================================================
# komira_mail_addr/envelope_transport.mojo — the READER of the trusted
#   envelope channel `X-Komira-Envelope-To`, and the grammar it is pinned to.
# =============================================================================
#
# ⛔ WHY THIS MODULE EXISTS — A GRAMMAR MISMATCH ACROSS THE CHANNEL. If the
# router Lambda and the ingest parse the trusted envelope channel with DIFFERENT
# GRAMMARS, the channel is a mis-delivery primitive. Consider a router that
# emits `", ".join(recipients)` (no escaping, no quoting, no refusal) and an
# ingest that splits on EVERY bare comma byte with zero quote awareness and then
# runs each fragment through a lenient address extractor that strips
# surrounding `<>"'` and validates NO DOMAIN AT ALL.
#
# RFC 5321 §4.1.2 `qtextSMTP` includes `%d44` — A COMMA IS LEGAL INSIDE A QUOTED
# LOCAL PART. So `"x@victim.example,y"@acme.example` is one address SES will
# accept a `RCPT TO` for, and under that pair of grammars it arrives as:
#
#     router emitted X-Komira-Envelope-To: "x@victim.example,y"@acme.example
#     ingest split -> ['"x@victim.example', 'y"@acme.example']
#     extractor    -> ['x@victim.example', 'y"@acme.example']
#
# ONE recipient, TWO mailbox writes, two different domains. The attacker owns
# `acme.example` (their own tenant), so the router routes it correctly to their
# own org and emits the ambiguous header; the ingest then writes into
# `x@victim.example`.
#
# ★ DO NOT ASSERT THE ASSUMPTION INSTEAD OF ENFORCING IT. "The value is
# produced by the router Lambda from ses.receipt.recipients[] (bare addresses),
# NOT by a sender, so it never carries quoted display names or angle-addrs" is
# true only if the router enforces a grammar. An assumption a comment states and
# no code checks is exactly the shape of defect this module exists to close.
#
# === THE FIX: ONE PINNED ENCODING WHOSE FRAGMENTS CANNOT CONTAIN THE DELIMITER
#
#     header   := fragment ( "," fragment )*
#     fragment := OWS ( literal | escape )+ OWS
#     literal  := A-Z a-z 0-9 @ . - _ +
#     escape   := "%" HEXDIG HEXDIG        (emitted UPPERCASE, accepted either)
#
# `,` is NOT a literal, so a comma is ALWAYS a separator and NEVER data. That is
# a property of the ALPHABET, not of anyone remembering to count quotes — which
# is why this is a fix and a comma-counting check would not have been. `%` is
# not a literal either, so the escape introducer cannot be forged (`%` -> `%25`).
#
# ⛔ CROSS-LANGUAGE CONTRACT, PINNED BY SHARED VECTORS. The producer is the
# router Lambda's recipient encoder. Both sides must be pinned to one shared
# table of encoding vectors, which both test suites read, so a vector the two
# implementations disagree about turns BOTH suites red. Pinning only the
# header's NAME across the boundary says nothing whatsoever about the VALUE's
# grammar.
#
# ★ THE READER REFUSES REGARDLESS OF WHAT THE WRITER DOES. Every function here
# raises rather than returning a best-effort parse. The caller maps that to a
# 500, which RETAINS the S3 object: a retained object plus an alarm beats a
# mis-filed message. There is no partial accept — the readable half of an
# unreadable envelope is not delivered, because acknowledging part of a message
# we could not fully parse is how a mis-parse becomes a silent half-delivery.
#
# ⚠️ ERRORS NAME STRUCTURE, NEVER BYTES. No raise message here interpolates any
# part of the address: these strings reach logs, and the address is PII.
#
# === ENCAPSULATION ===
# Pure String/List[String] in and out. ZERO UnsafePointer in any signature; no
# struct fields at all, so no pointer field and no stale-pointer hazard.
# def-based, Mojo 1.0.0b2.
# =============================================================================



# The recipient-domain rules. Identical to the router's domain normalization +
# validation and to `normalize_mail_domain`'s spec (mail_domain_key.mojo) —
# every one of these is unregistrable, so refusing loses nothing and closes the
# key space.
comptime _MAX_DOMAIN_LEN: Int = 253
comptime _MAX_LABEL_LEN: Int = 63


def decode_envelope_recipients(value: String) raises -> List[String]:
    """Decode the `X-Komira-Envelope-To` header value into its recipients.

    RAISES on anything that is not exactly N addr-specs under the pinned
    grammar. The caller MUST map a raise to a refusal that retains the source
    object (HTTP 500), never to a silent drop and never to a partial accept.

    An EMPTY or whitespace-only value is NOT an error: it returns an empty list,
    which the caller treats as "no envelope stated" and degrades to the
    tenant-gated visible-header scan. That distinction matters — a header-setting
    bug should degrade to a narrower path, not 500 the whole ingest."""
    var out = List[String]()
    var trimmed = _trim_ows(value)
    if len(trimmed.as_bytes()) == 0:
        return out^

    var bs = trimmed.as_bytes()
    var start = 0
    var i = 0
    var idx = 0
    while i <= len(bs):
        if i == len(bs) or Int(bs[i]) == ord(","):
            var frag = _trim_ows(_slice(bs, start, i))
            if len(frag.as_bytes()) == 0:
                # An empty fragment is a PRODUCER BUG, not a recipient. Refusing
                # keeps "the header names N recipients" a countable fact; a
                # decoder that skipped it would silently disagree with its
                # writer about how many people were addressed.
                raise Error(
                    "envelope: fragment "
                    + String(idx)
                    + " is empty — the header names a recipient it did not"
                    " supply"
                )
            # ★ THE CANONICAL FORM IS WHAT LEAVES THIS FUNCTION, not the wire
            # bytes. Returning the raw fragment would put a SECOND normalization
            # step downstream (whoever compares or dedups it), and two
            # normalizations that must agree is the shape of the defect this
            # module exists to close: if one language canonicalises here and
            # the other does not, `Alice@ACME.Example` decodes to two different
            # strings in the two languages, and the shared vectors catch it.
            var addr = parse_addr_spec_strict(_decode_fragment(frag, idx))
            if len(addr.as_bytes()) == 0:
                raise Error(
                    "envelope: fragment "
                    + String(idx)
                    + " is not exactly one addr-spec (local@domain with a"
                    " valid, dotted, LDH domain) — refusing the WHOLE envelope"
                    " rather than delivering the fragments that happened to"
                    " parse"
                )
            out.append(addr^)
            idx += 1
            start = i + 1
        i += 1
    return out^


def parse_addr_spec_strict(addr: String) -> String:
    """`addr` if it is EXACTLY ONE addr-spec (ASCII-lowercased, trailing root dot
    dropped); the EMPTY STRING otherwise. Never raises.

    ⛔ USE THIS, NOT A LENIENT EXTRACTOR, ON THE TRUSTED PATH, AND THE
    DIFFERENCE IS THE WHOLE DEFECT. A display-name extractor is a
    LENIENT parser for SENDER-AUTHORED display-name headers: it takes everything
    up to the FIRST comma, strips surrounding `<>"'`, and validates no domain
    whatsoever. Handed one legal quoted address it MUTILATES it into a different
    address — `"x@victim.example,y"@acme.example` becomes `x@victim.example`.
    Fixing only the header split would leave that intact ONE FRAME DOWN, with
    every test still green.

    A quoted local part is scanned to its closing quote (backslash escapes
    honored) and the next byte must be `@`; an unquoted local part may not
    contain `@` at all, which is what keeps this in agreement with the router's
    resolve-on-the-LAST-`@`."""
    var s = _trim_ows(addr)
    var bs = s.as_bytes()
    var n = len(bs)
    if n == 0:
        return String("")

    var at = -1
    if Int(bs[0]) == ord('"'):
        # Quoted local part: scan to the closing quote, honoring `\` escapes.
        var j = 1
        var closed = -1
        while j < n:
            var c = Int(bs[j])
            if c == ord("\\"):
                # An escape consumes the next byte; a trailing `\` is unbalanced.
                if j + 1 >= n:
                    return String("")
                j += 2
                continue
            if c == ord('"'):
                closed = j
                break
            # qtext: printable ASCII only (a comma IS legal here — that is the
            # entire reason this function exists).
            if c < 0x20 or c > 0x7E:
                return String("")
            j += 1
        if closed < 0:
            return String("")
        if closed == 1:
            # `""@d` names no mailbox.
            return String("")
        if closed + 1 >= n or Int(bs[closed + 1]) != ord("@"):
            return String("")
        at = closed + 1
    else:
        var j = 0
        while j < n:
            if Int(bs[j]) == ord("@"):
                if at >= 0:
                    # A second `@` outside quotes. Refusing keeps this reader
                    # from disagreeing with the router's rsplit-on-last-`@`.
                    return String("")
                at = j
            j += 1
        if at < 0:
            return String("")
        if not _valid_dot_atom_local(_slice(bs, 0, at)):
            return String("")

    var domain = _normalized_domain(_slice(bs, at + 1, n))
    if len(domain.as_bytes()) == 0:
        return String("")
    return _lower_ascii(_slice(bs, 0, at)) + String("@") + domain


# =============================================================================
# §1 — the fragment codec.
# =============================================================================


def _decode_fragment(frag: String, idx: Int) raises -> String:
    """One fragment's literal/escape alphabet -> its bytes. Raises on any byte
    the grammar does not admit."""
    var bs = frag.as_bytes()
    var n = len(bs)
    var out = String("")
    var i = 0
    while i < n:
        var c = Int(bs[i])
        if c == ord("%"):
            if i + 2 >= n:
                raise Error(
                    "envelope: fragment "
                    + String(idx)
                    + " has a truncated percent-escape — `%` must be followed"
                    " by exactly two hex digits"
                )
            var hi = _hex_val(Int(bs[i + 1]))
            var lo = _hex_val(Int(bs[i + 2]))
            if hi < 0 or lo < 0:
                raise Error(
                    "envelope: fragment "
                    + String(idx)
                    + " has a non-hex percent-escape"
                )
            out += chr(hi * 16 + lo)
            i += 3
            continue
        if not _is_literal(c):
            # ★ THE REFUSAL THAT CLOSES THE DEFECT. A raw `"`, a raw interior
            # space, a raw `<` — none are literals, so the ambiguous wire value
            # `"x@victim.example,y"@acme.example` is unparseable HERE, before
            # any domain gate is consulted and before any mailbox is named.
            raise Error(
                "envelope: fragment "
                + String(idx)
                + " contains a byte outside the pinned alphabet"
                " [A-Za-z0-9@.-_+%] — an address carrying any other byte must"
                " be percent-escaped by the producer"
            )
        out += chr(c)
        i += 1
    return out^


def _is_literal(c: Int) -> Bool:
    """The literal alphabet. `,` and `%` are deliberately ABSENT: the delimiter
    cannot occur inside a fragment, and the escape introducer cannot be forged."""
    if c >= ord("A") and c <= ord("Z"):
        return True
    if c >= ord("a") and c <= ord("z"):
        return True
    if c >= ord("0") and c <= ord("9"):
        return True
    return (
        c == ord("@")
        or c == ord(".")
        or c == ord("-")
        or c == ord("_")
        or c == ord("+")
    )


def _hex_val(c: Int) -> Int:
    if c >= ord("0") and c <= ord("9"):
        return c - ord("0")
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    return -1


# =============================================================================
# §2 — addr-spec validation (local part + domain).
# =============================================================================


def _valid_dot_atom_local(local: String) -> Bool:
    """An UNQUOTED local part: non-empty atext, no leading/trailing `.`, no `..`,
    and (enforced by the caller) no `@`."""
    var bs = local.as_bytes()
    var n = len(bs)
    if n == 0:
        return False
    if Int(bs[0]) == ord(".") or Int(bs[n - 1]) == ord("."):
        return False
    var i = 0
    while i < n:
        var c = Int(bs[i])
        if c == ord("."):
            if i + 1 < n and Int(bs[i + 1]) == ord("."):
                return False
            i += 1
            continue
        if not _is_atext(c):
            return False
        i += 1
    return True


def _is_atext(c: Int) -> Bool:
    """RFC 5322 atext. Note `%` IS atext — an address may legitimately contain
    one, which is exactly why the wire encoding escapes `%` itself."""
    if c >= ord("A") and c <= ord("Z"):
        return True
    if c >= ord("a") and c <= ord("z"):
        return True
    if c >= ord("0") and c <= ord("9"):
        return True
    var specials = String("!#$%&'*+-/=?^_`{|}~")
    var sb = specials.as_bytes()
    var i = 0
    while i < len(sb):
        if Int(sb[i]) == c:
            return True
        i += 1
    return False


def _normalized_domain(domain: String) -> String:
    """The ASCII-lowercased, root-dot-stripped domain, or "" if it violates ANY
    of the rules. Mirrors the router's `normalize_domain` + validation exactly.

    ⚠️ NON-ASCII IS REFUSED, NOT CONVERTED. SMTP `RCPT TO` is already A-label for
    non-SMTPUTF8 mail, and a second IDN implementation on the read side is a
    second thing that can disagree with the write side. Refusal fails closed."""
    var s = _lower_ascii(_strip_trailing_dots(_trim_ows(domain)))
    var bs = s.as_bytes()
    var n = len(bs)
    if n == 0 or n > _MAX_DOMAIN_LEN:
        return String("")

    var seen_dot = False
    var label_len = 0
    var label_start = 0
    var i = 0
    while i < n:
        var c = Int(bs[i])
        if c == ord("."):
            seen_dot = True
            if label_len == 0:
                return String("")
            if not _valid_label(bs, label_start, i):
                return String("")
            label_len = 0
            label_start = i + 1
        else:
            var ok = (
                (c >= ord("a") and c <= ord("z"))
                or (c >= ord("0") and c <= ord("9"))
                or c == ord("-")
            )
            if not ok:
                return String("")
            label_len += 1
            if label_len > _MAX_LABEL_LEN:
                return String("")
        i += 1
    if label_len == 0:
        return String("")
    if not _valid_label(bs, label_start, n):
        return String("")
    if not seen_dot:
        # A single-label domain is unregistrable.
        return String("")
    return s^


def _valid_label(bs: Span[UInt8, _], start: Int, end: Int) -> Bool:
    if end <= start:
        return False
    if Int(bs[start]) == ord("-") or Int(bs[end - 1]) == ord("-"):
        return False
    return True


# =============================================================================
# §3 — small string helpers (self-contained; no dependency on the webhook parser).
# =============================================================================


def _slice(bs: Span[UInt8, _], start: Int, end: Int) -> String:
    var out = String("")
    var i = start
    while i < end:
        out += chr(Int(bs[i]))
        i += 1
    return out^


def _trim_ows(s: String) -> String:
    """Trim leading/trailing ASCII space / tab / CR / LF. Applied AROUND a
    fragment only — interior whitespace is not a literal and is refused, so the
    decoder can never silently rewrite an address by squeezing spaces out."""
    var bs = s.as_bytes()
    var n = len(bs)
    var start = 0
    while start < n:
        var c = Int(bs[start])
        if c == 32 or c == 9 or c == 13 or c == 10:
            start += 1
            continue
        break
    var end = n
    while end > start:
        var c = Int(bs[end - 1])
        if c == 32 or c == 9 or c == 13 or c == 10:
            end -= 1
            continue
        break
    return _slice(bs, start, end)


def _strip_trailing_dots(s: String) -> String:
    var bs = s.as_bytes()
    var end = len(bs)
    while end > 0 and Int(bs[end - 1]) == ord("."):
        end -= 1
    return _slice(bs, 0, end)


def _strip_root_dot(s: String) -> String:
    return _strip_trailing_dots(s)


def _lower_ascii(s: String) -> String:
    var bs = s.as_bytes()
    var out = String("")
    var i = 0
    while i < len(bs):
        var c = Int(bs[i])
        if c >= ord("A") and c <= ord("Z"):
            c += 32
        out += chr(c)
        i += 1
    return out^
