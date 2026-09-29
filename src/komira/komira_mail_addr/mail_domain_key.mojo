# =============================================================================
# komira_mail_addr/mail_domain_key.mojo — `normalize_mail_domain`, the
#   REGISTRY KEY function. The WRITE side of the domain->route registry.
# =============================================================================
#
# WHAT THIS IS. The one function that turns a domain (or a full address) into the
# partition key of a domain -> route registry (for example a DynamoDB table). Its
# twin is the mail router's own domain normalizer, on the READ side.
#
# ⛔ THE TWO SIDES MUST AGREE EXACTLY, AND THE AGREEMENT IS TESTED, NOT ASSERTED.
# This is the failure the whole registry design turns on. The partition key is the
# uniqueness proof — "one domain, one org" is structural only if both sides agree
# what "one domain" is. Two ways it breaks, both silent:
#
#   * The CP writes `Acme.Example` and the router looks up `acme.example`. A
#     verified tenant's mail quarantines forever, and the control plane reports
#     the domain as healthy because the SQL row IS verified.
#   * Two spellings of one domain become TWO items. Now `acme.example` belongs to
#     org A and `acme.example.` belongs to org B, the registry answers both, and
#     the property the partition key was chosen to give — that a domain cannot be
#     claimed twice — is gone without any code having asked for it.
#
# So the two implementations must be pinned to a SHARED VECTOR TABLE that both
# test suites read: adding a vector the two disagree on turns BOTH suites red. A
# comment reading "mirrors the router's normalizer" is exactly as strong as
# nothing.
#
# THE SPEC:
#   1. strip whitespace, strip `<>`, strip whitespace again.
#   2. REFUSE outright on any control character (see below — this is step 2, not
#      step 5, and the ordering is load-bearing).
#   3. take the part after the LAST `@`.
#   4. strip whitespace; ASCII-lowercase; strip ALL trailing dots.
#   5. validate: total <= 253; every label 1..63; charset [a-z0-9.-]; no empty
#      label; no label starting or ending `-`; at least one dot. Any violation
#      returns "".
#   6. A-labels only. A byte > 0x7F is REFUSED here, never converted: the CP is
#      the ONLY place a U-label may be punycoded, and it must happen BEFORE the
#      value reaches this function.
#
# ★ WHY THE CONTROL-CHARACTER CHECK RUNS BEFORE THE `@` SPLIT. Measured, not
# theorised. `bob@acme.example\nX-Original-To: x@evil.example` sails through a
# per-label charset check placed AFTER the split, because the split on the LAST
# `@` has already discarded the newline and handed back a flawless
# `evil.example` — an attacker-chosen key, reached by a function whose validation
# all passed. A check placed after the split can only ever validate the tail the
# attacker selected. So the control character is fatal to the WHOLE input, before
# any part of it is chosen. (A SPACE is not fatal: `Bob Smith <bob@acme.example>`
# is a legitimate display-name form, and an embedded space that survives the split
# is caught by the charset check, which no split can route around.)
#
# ★ WHY "" IS A REFUSAL AND NOT A DEGRADED ANSWER. Every shape rejected here is
# unregistrable, so refusing loses no deliverable mail. The empty key is never
# written and never matches, so both sides fail closed on it — the router
# quarantines and the writer raises.
#
# Encapsulation: pure String -> String; no pointer of any kind crosses
# any boundary here.
# =============================================================================

comptime MAIL_DOMAIN_MAX_LEN: Int = 253
comptime MAIL_DOMAIN_MAX_LABEL_LEN: Int = 63


def _is_ldh_byte(b: Int) -> Bool:
    """True for the RFC 1035 letter-digit-hyphen set, ASCII-lowercase only.

    Note what this EXCLUDES and why each exclusion is deliberate: `_` (outside
    LDH, and a shape no registrar issues), `:` (a port suffix is not part of the
    domain), `[` / `]` (an address literal is not a registrable name), `/` and `%`
    (path separators and percent-escapes — the shapes that turn a key into a
    traversal), and every byte >= 0x80 (a U-label or a homoglyph)."""
    if b >= ord("a") and b <= ord("z"):
        return True
    if b >= ord("0") and b <= ord("9"):
        return True
    return b == ord("-")


def _is_ws_byte(b: Int) -> Bool:
    return b == ord(" ") or b == ord("\t") or b == ord("\n") or b == ord("\r")


def _strip_ws(s: String) -> String:
    """Strip ASCII whitespace from both ends."""
    var bs = s.as_bytes()
    var lo = 0
    var hi = len(bs)
    while lo < hi and _is_ws_byte(Int(bs[lo])):
        lo += 1
    while hi > lo and _is_ws_byte(Int(bs[hi - 1])):
        hi -= 1
    var out = String("")
    var i = lo
    while i < hi:
        out += chr(Int(bs[i]))
        i += 1
    return out^


def _strip_angles(s: String) -> String:
    """Strip `<` and `>` from both ends (the `<bob@acme.example>` form)."""
    var bs = s.as_bytes()
    var lo = 0
    var hi = len(bs)
    while lo < hi and (Int(bs[lo]) == ord("<") or Int(bs[lo]) == ord(">")):
        lo += 1
    while hi > lo and (Int(bs[hi - 1]) == ord("<") or Int(bs[hi - 1]) == ord(">")):
        hi -= 1
    var out = String("")
    var i = lo
    while i < hi:
        out += chr(Int(bs[i]))
        i += 1
    return out^


def normalize_mail_domain(value: String) -> String:
    """The registry key for `value`, or "" if `value` is not a usable key.

    See the module header for the spec and for why the control-character check
    runs where it does. "" is a REFUSAL: it is never stored and never matches."""
    # --- step 1 ---
    var v = _strip_ws(_strip_angles(_strip_ws(value)))

    # --- step 2: control characters and NON-ASCII are fatal to the WHOLE input,
    # BEFORE the split gets to choose which part of it survives.
    #
    # Rejecting >= 0x80 HERE rather than letting the per-label charset check catch
    # it is deliberate twice over. (a) It states rule 6 — A-labels only, refused
    # and never converted — as its own decision instead of as a side effect of a
    # charset table. (b) It leaves everything downstream pure ASCII, so the
    # byte-by-byte rebuild below is byte-exact; a `chr()` of a byte >= 0x80 would
    # re-encode it as TWO UTF-8 bytes and silently mutate the value being keyed. ---
    var b0 = v.as_bytes()
    var k = 0
    while k < len(b0):
        var c = Int(b0[k])
        if c < 0x20 or c >= 0x7F:
            return String("")
        k += 1

    # --- step 3: the part after the LAST `@`. `"a@b"@acme.example` is a legal
    # quoted local part; splitting on the FIRST `@` yields `b"@acme.example`,
    # which matches nothing and turns a legitimate address unroutable. ---
    var bs = v.as_bytes()
    var at = -1
    var i = 0
    while i < len(bs):
        if Int(bs[i]) == ord("@"):
            at = i
        i += 1
    var tail = String("")
    var start = 0
    if at >= 0:
        start = at + 1
    var j = start
    while j < len(bs):
        tail += chr(Int(bs[j]))
        j += 1

    # --- step 4: strip, ASCII-lowercase, drop ALL trailing dots. ---
    var t = _strip_ws(tail)
    var tb = t.as_bytes()
    var lowered = String("")
    var m = 0
    while m < len(tb):
        var c2 = Int(tb[m])
        if c2 >= ord("A") and c2 <= ord("Z"):
            lowered += chr(c2 + 32)
        else:
            lowered += chr(c2)
        m += 1
    var lb = lowered.as_bytes()
    var end = len(lb)
    while end > 0 and Int(lb[end - 1]) == ord("."):
        end -= 1
    var d = String("")
    var n = 0
    while n < end:
        d += chr(Int(lb[n]))
        n += 1

    # --- steps 5/6: validate. ---
    var db = d.as_bytes()
    if len(db) == 0 or len(db) > MAIL_DOMAIN_MAX_LEN:
        return String("")

    var dots = 0
    var label_len = 0
    var p = 0
    while p < len(db):
        var c3 = Int(db[p])
        if c3 == ord("."):
            # An empty label (`a..b`, or a leading `.`) is not registrable.
            if label_len == 0:
                return String("")
            # A label may not END with a hyphen.
            if Int(db[p - 1]) == ord("-"):
                return String("")
            dots += 1
            label_len = 0
        else:
            if not _is_ldh_byte(c3):
                return String("")
            # A label may not START with a hyphen.
            if label_len == 0 and c3 == ord("-"):
                return String("")
            label_len += 1
            if label_len > MAIL_DOMAIN_MAX_LABEL_LEN:
                return String("")
        p += 1

    # The final label: non-empty, and not hyphen-terminated.
    if label_len == 0:
        return String("")
    if Int(db[len(db) - 1]) == ord("-"):
        return String("")
    # At least one dot: a single label (`localhost`) is not a mail domain, and a
    # key no DNS proof can ever correspond to has no business in the registry.
    if dots == 0:
        return String("")
    return d^
