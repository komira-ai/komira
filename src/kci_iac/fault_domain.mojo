# =============================================================================
# kci_iac/fault_domain.mojo — WHOSE FAULT a deploy error is, carried as
#   DATA, with the unclassified case reading as OURS.
# =============================================================================
#
# ★ THE QUESTION THIS ANSWERS: which deploy errors are OUR responsibility to
# fix?
#
# ── THE LOAD-BEARING DECISION: UNSET READS AS **OURS** ──────────────────────
# An error nobody classified is OUR responsibility until somebody proves
# otherwise. This is the whole design, and it is a choice about which way the
# scheme fails, not a default picked for tidiness:
#
#   * default OURS  -> an unclassified fault lands in our queue. We look at it,
#                      and either fix it or classify it. The cost is noise.
#   * default THEIRS-> an unclassified fault is filed as the customer's problem
#                      and we never hear about it. The cost is our own bugs,
#                      silently attributed to somebody who cannot fix them.
#
# The second failure mode is not hypothetical. Failures that look like
# "the app is broken" from outside are very often OURS:
#   * a JSON-envelope mismatch between a validator and the app (our two
#     components disagreeing);
#   * an h2 client livelock that surfaces as `HttpError[TIMEOUT]` on an IAM call
#     — an error whose text names a customer-side API and a timeout;
#   * a leftover-secret refusal that names a remedy NO code path performs.
# Pattern-matching any of those would file them as customer or provider
# faults. So the default is OURS, and `is_our_responsibility` is
# written so that adding a NEW domain constant tomorrow does not silently move
# anything out of our queue (see its body — it enumerates what is NOT ours).
#
# ── ⛔ CLASSIFY ON STRUCTURE, NEVER ON VENDOR PROSE ─────────────────────────
# This is the same rule a permanent-vs-transient retry classifier must follow,
# for the same reason: GCP words a PERMANENT malformed-member fault and a
# TRANSIENT propagation window IDENTICALLY, so only the member's STRUCTURE
# tells them apart.
# Attribution is strictly worse to get wrong than retry-classification, because
# a mis-attribution fails OPEN in the direction that hurts us: it stops us
# hearing about our own bug.
#
# ⇒ NOTHING IN THIS FILE MATCHES A PROVIDER'S WORDS. There are exactly two ways
# a domain is assigned, both of them a DECLARATION by code that knows:
#
#   (1) THE RAISE SITE STATES IT — `raise fault_error(FAULT_CUSTOMER, "...")`.
#       This stamps a canonical token WE author onto the front of the message,
#       and `fault_domain_of_error` reads that token back. A typed sentinel in
#       the only channel a Mojo `Error` has (a String), read by a predicate —
#       NOT prose matching, because we wrote both ends.
#
#   (2) THE CONFORMER DECLARES IT PER VERB — `Resource.fault_domain(verb)`.
#       A conformer knows what a failure of ITS OWN verb means: a
#       `setIamPolicy` that our deploy identity is not allowed to make is OURS
#       (our bootstrap should have granted it); an API-enable refused by the
#       customer's org policy is THEIRS. The signature deliberately does NOT
#       receive the error text, so classifying on prose is not merely
#       discouraged there — it is structurally unavailable.
#
# (1) BEATS (2) BEATS UNSET. A raise site that stated a domain knows more than a
# per-verb declaration; a per-verb declaration knows more than nothing.
#
# ── ⚠ WHAT THIS FILE DELIBERATELY DOES NOT DO ──────────────────────────────
# It does not classify anything. There is no table of status codes, no list of
# messages, no heuristic. It is the TYPE + the DEFAULT + the two readers. Every
# actual attribution is written by a human at a site that knows, and the honest
# report of this scheme is "N sites are classified, the rest read as ours" —
# never "everything is classified".
#
# ENCAPSULATION. Value-typed surface only: `Int` domains, `String`
# messages, an `Error`. ZERO UnsafePointer crosses any boundary; NO wildcard
# origin; NO unsafe_from_address; no heap-owning nested struct. Mojo 1.0.0b2
# (def-only).
# =============================================================================


# =============================================================================
# §1 — the DOMAIN codes. `FAULT_UNSET` is 0 so a zero-initialised / omitted
#      field is the unclassified case, which reads as OURS.
# =============================================================================
comptime FAULT_UNSET: Int = 0
"""NOBODY CLASSIFIED THIS. Reads as OURS (`is_our_responsibility` -> True).

This is the value a default-constructed `FaultAttribution` carries, the value
`Resource.fault_domain`'s trait default returns, and the value
`fault_domain_of_error` returns for an error with no token. It is 0 so that
every path that forgets to set a domain lands here rather than somewhere
convenient."""

comptime FAULT_OURS: Int = 1
"""OUR BUG, OUR CONFIG, OUR MISSING GRANT — we fix it. Distinct from
`FAULT_UNSET` on purpose: `OURS` means somebody LOOKED and said ours, `UNSET`
means nobody looked. They are treated identically by
`is_our_responsibility` and must be counted separately by any operator surface,
because the ratio of the two IS the coverage of this scheme."""

comptime FAULT_CUSTOMER: Int = 2
"""THE CUSTOMER'S ENVIRONMENT — they fix it. A revoked grant, an org policy that
forbids the resource, an exhausted quota in THEIR project, a container image of
theirs that does not start for a reason of theirs. Assigning this is a claim
that we could not have prevented it, and it removes the error from our queue —
so it is never a default and never a fallback."""

comptime FAULT_PROVIDER: Int = 3
"""THE CLOUD PROVIDER — nobody here fixes it; we absorb it.

⚠ A PROVIDER FAULT IS ONLY THE PROVIDER'S IF WE ALREADY DID OUR PART. A 500 we
retried to exhaustion is `FAULT_PROVIDER`. A 500 we never retried at all is
`FAULT_OURS` — the missing retry is our defect, and calling it the provider's
is exactly how a missing retry survives for a year. The site that knows whether
it retried is the site that must assign this."""


# =============================================================================
# §2 — the predicate the whole scheme turns on.
# =============================================================================
@always_inline
def is_our_responsibility(domain: Int) -> Bool:
    """True iff this error is OURS TO FIX — the question this scheme answers.

    ⚠ WRITTEN AS AN EXCLUSION LIST ON PURPOSE, and that is not a style choice.
    The inclusive spelling (`domain == FAULT_UNSET or domain == FAULT_OURS`)
    means a domain constant added tomorrow drops OUT of our queue by default,
    silently, with no edit here and no test failing. Written as an exclusion,
    a new constant lands IN our queue until somebody deliberately adds it to
    this list — which is the same fail-safe direction as `FAULT_UNSET` itself,
    applied to the evolution of the enum rather than to one error.

    So: NOT ours iff it is explicitly the customer's or explicitly the
    provider's. Everything else — `FAULT_UNSET`, `FAULT_OURS`, and any value
    this build has never heard of (a row written by a newer binary) — is ours.
    """
    if domain == FAULT_CUSTOMER:
        return False
    if domain == FAULT_PROVIDER:
        return False
    return True


@always_inline
def fault_domain_is_classified(domain: Int) -> Bool:
    """True iff somebody actually LOOKED at this error and assigned a domain.

    The complement of `FAULT_UNSET`. An operator surface must report the
    classified fraction alongside the our-fault count, because "12 our-fault
    errors" means something completely different when 12 of 12 are `UNSET`
    (nobody has classified anything and the number is a floor) than when 12 of
    400 are (the scheme is working and 12 is a real signal)."""
    return domain != FAULT_UNSET


# =============================================================================
# §3 — the stable WIRE tokens. These cross a process boundary (a stored
#      `deploy_log_line`, an operator JSON body), so they are frozen strings,
#      not the integers — an Int renumbering must never silently re-attribute a
#      row that a previous binary wrote.
# =============================================================================
comptime FAULT_WORD_UNSET: String = "unset"
comptime FAULT_WORD_OURS: String = "ours"
comptime FAULT_WORD_CUSTOMER: String = "customer"
comptime FAULT_WORD_PROVIDER: String = "provider"


def fault_domain_word(domain: Int) -> String:
    """The stable wire token for `domain`. An UNKNOWN Int renders as
    `FAULT_WORD_UNSET` rather than as a number, because the reader
    (`fault_domain_of_word`) maps unknown-to-UNSET too, and a round trip that
    lands on the fail-safe value is better than one that invents a token no
    consumer has a case for."""
    if domain == FAULT_OURS:
        return FAULT_WORD_OURS
    if domain == FAULT_CUSTOMER:
        return FAULT_WORD_CUSTOMER
    if domain == FAULT_PROVIDER:
        return FAULT_WORD_PROVIDER
    return FAULT_WORD_UNSET


def fault_domain_of_word(word: String) -> Int:
    """Parse a wire token back to a domain. ⚠ AN UNRECOGNISED TOKEN IS
    `FAULT_UNSET`, i.e. OURS — never a raise and never a guess. A row written by
    a newer binary with a domain this one does not know must not be silently
    filed as somebody else's problem; landing it in our queue is the safe
    reading, and it is visible there."""
    if word == FAULT_WORD_OURS:
        return FAULT_OURS
    if word == FAULT_WORD_CUSTOMER:
        return FAULT_CUSTOMER
    if word == FAULT_WORD_PROVIDER:
        return FAULT_PROVIDER
    return FAULT_UNSET


# =============================================================================
# §4 — the RAISE-SITE carrier. A Mojo `Error` holds one `String` and nothing
#      else — there is no exception hierarchy and no payload — so a domain
#      stated at a raise site rides a canonical token WE author on the front of
#      the message.
# =============================================================================
comptime FAULT_TAG_OPEN: String = "[fault="
comptime FAULT_TAG_CLOSE: String = "] "


@always_inline
def _has_prefix(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(sb) < len(pb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def fault_tag(domain: Int) -> String:
    """The canonical token for `domain` — `[fault=customer] `, and so on.

    ⚠ `FAULT_UNSET` EMITS A TOKEN (`[fault=unset] `), AND IT IS A NOTE TO A
    HUMAN, NOT A SIGNAL TO THE READER. `fault_domain_of_error` cannot tell an
    explicitly-unset message from an untagged one — both answer `FAULT_UNSET`,
    both read as OURS — and no consumer should be written as if it could. What
    the explicit form buys is that the next person to read that raise site can
    see it was considered. `engine._node_verb_error` therefore does NOT stamp
    unset onto its own enriched errors: on that path the token would be pure
    churn against every existing log grep."""
    return FAULT_TAG_OPEN + fault_domain_word(domain) + FAULT_TAG_CLOSE


def fault_error(domain: Int, message: String) -> Error:
    """THE RAISE-SITE HELPER: `raise fault_error(FAULT_CUSTOMER, "...")`.

    Stamps the canonical token on the front of `message` so the domain survives
    the `raise` — the only channel a Mojo `Error` offers. The message is
    otherwise VERBATIM: a grep an operator was already using for the backend's
    own words keeps working, because the token is a PREFIX and nothing in the
    message is rewritten.

    ⚠ THE TOKEN IS PART OF THE MESSAGE, so a caller that surfaces `String(e)`
    to a human shows it. That is deliberate — an operator reading a deploy
    failure should see whose fault it was without a second lookup — but a caller
    rendering into a customer-facing field should call `fault_message_of_error`
    to strip it."""
    return Error(fault_tag(domain) + message)


def fault_domain_of_error(err: String) -> Int:
    """Read back the domain a raise site stated. NO TOKEN -> `FAULT_UNSET`, i.e.
    OURS.

    ⛔ THIS IS NOT PROSE MATCHING, AND THE DISTINCTION IS THE WHOLE POINT. It
    matches ONE fixed prefix that `fault_error` in this same file wrote. It
    never looks at the backend's words, never at a status code embedded in
    them, and never anywhere but the very front of the string — so a provider
    rewording a message, or a message that happens to contain the word
    `customer`, cannot move an attribution. If you find yourself wanting to
    extend this function to look at the body, the correct change is to classify
    at the raise site instead."""
    if not _has_prefix(err, FAULT_TAG_OPEN):
        return FAULT_UNSET
    var open_len = FAULT_TAG_OPEN.byte_length()
    var eb = err.as_bytes()
    # Scan for the closing bracket; a token longer than any word we emit, or one
    # with no terminator, is not our token — UNSET (ours).
    var i = open_len
    var limit = len(eb)
    while i < limit:
        if eb[i] == UInt8(ord("]")):
            break
        i += 1
    if i >= limit:
        return FAULT_UNSET
    var word = String("")
    for j in range(open_len, i):
        word += chr(Int(eb[j]))
    return fault_domain_of_word(word)


def fault_message_of_error(err: String) -> String:
    """`err` with our token removed — the customer-facing rendering. An error
    with no token is returned BYTE-IDENTICAL, so every existing caller and every
    existing fixture is unchanged by this file existing."""
    if not _has_prefix(err, FAULT_TAG_OPEN):
        return err
    var eb = err.as_bytes()
    var limit = len(eb)
    var i = FAULT_TAG_OPEN.byte_length()
    while i < limit:
        if eb[i] == UInt8(ord("]")):
            break
        i += 1
    if i >= limit:
        return err
    # Skip the `]` and the single space `FAULT_TAG_CLOSE` writes after it.
    var start = i + 1
    if start < limit and eb[start] == UInt8(ord(" ")):
        start += 1
    var out = String("")
    for j in range(start, limit):
        out += chr(Int(eb[j]))
    return out^


# =============================================================================
# §5 — FaultAttribution — the record an apply hands back on the failing path.
# =============================================================================
struct FaultAttribution(Copyable, Movable, Deinitable):
    """WHOSE FAULT a deploy failure was, plus enough to find it again.

    ⚠ THIS IS AN OUT-PARAMETER TYPE, NOT A RETURN TYPE, and that is the same
    reason `apply_graph_tracked`'s `landed` / `pending` are out-parameters: a
    return value DOES NOT EXIST ON THE FAILING PATH, and the failing path is the
    only one this record is about. An engine fills it as it goes; a caller reads
    it in its `except` arm.

    DEFAULT-CONSTRUCTED IS UNSET, WHICH IS OURS. A caller that declares one and
    never has it filled — because the failure came from somewhere that has not
    been retrofitted yet — reports our responsibility, not silence."""

    var domain: Int
    """The FAULT_* code. `FAULT_UNSET` until something assigns it."""

    var logical_id: String
    """The graph node that failed, empty if the failure was not node-scoped."""

    var verb: String
    """The `Resource` verb that raised (`read_status` / `create` / `update` /
    `delete`), empty if not verb-scoped."""

    var reason: String
    """The message, WITHOUT our token (`fault_message_of_error`) — the same
    text the backend produced, so an operator's existing grep still matches."""

    def __init__(out self):
        """The UNCLASSIFIED attribution — `FAULT_UNSET`, therefore OURS. This is
        the state a caller's `var attribution = FaultAttribution()` starts in and
        the state it STAYS in if nothing fills it, which is exactly the
        behaviour the default-to-ours rule demands."""
        self.domain = FAULT_UNSET
        self.logical_id = String("")
        self.verb = String("")
        self.reason = String("")

    def __init__(
        out self,
        domain: Int,
        var logical_id: String,
        var verb: String,
        var reason: String,
    ):
        self.domain = domain
        self.logical_id = logical_id^
        self.verb = verb^
        self.reason = reason^

    @staticmethod
    def of_error(err: String, var logical_id: String, var verb: String) -> Self:
        """Recover the attribution from an error that already crossed a `raise`.

        THE READ SIDE OF `fault_error`, and the ONLY way a caller several frames
        above the failure gets the domain — Mojo unwinds a `String`, so an
        out-parameter would have to be threaded through every intermediate
        signature and a token does not. An error with no token yields
        `FAULT_UNSET`, i.e. OURS, with the message intact."""
        return Self(
            fault_domain_of_error(err),
            logical_id^,
            verb^,
            fault_message_of_error(err),
        )

    def is_ours(self) -> Bool:
        """See `is_our_responsibility` — including for an attribution nothing
        ever filled."""
        return is_our_responsibility(self.domain)

    def is_classified(self) -> Bool:
        """True iff somebody assigned a domain (see
        `fault_domain_is_classified`)."""
        return fault_domain_is_classified(self.domain)

    def operator_line(self) -> String:
        """ONE line for an operator surface, leading with the answer to the
        question that was asked. An UNSET attribution says so IN the line —
        `OURS (unclassified)` — because "ours" and "nobody classified it" must
        never look the same to the person deciding whether to page."""
        var out = String("FAULT: ")
        if self.is_ours():
            out += String("OURS")
            if not self.is_classified():
                out += String(" (unclassified — no site attributed this)")
        else:
            out += String("NOT OURS [") + fault_domain_word(self.domain) + String("]")
        if self.logical_id.byte_length() > 0:
            out += String(" node=") + self.logical_id
        if self.verb.byte_length() > 0:
            out += String(" verb=") + self.verb
        if self.reason.byte_length() > 0:
            out += String(" — ") + self.reason
        return out^
