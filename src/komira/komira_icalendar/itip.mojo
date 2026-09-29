# =============================================================================
# komira_icalendar/itip.mojo — the RFC 5546 (iTIP) scheduling state machine
# and the RFC 6047 §3 sender-binding control
# =============================================================================
#
# Invites cross organisations as EMAIL (iMIP, RFC 6047). This file is the half
# that decides what an arriving invite MEANS.
#
# ══════════════════════════════════════════════════════════════════════════
# §A  THE SHIPPED SET IS REQUEST / REPLY / CANCEL. THE REST IGNORE-WITH-A-LOG.
# ══════════════════════════════════════════════════════════════════════════
# COUNTER / DECLINECOUNTER / ADD / REFRESH are real iTIP methods and are
# deferred: Gmail does not surface COUNTER at all and Outlook's "propose new
# time" is the only common producer. They resolve to `ITIP_IGNORE_UNSUPPORTED`
# with the method NAMED in the reason, so the log says which one arrived — a
# silent drop would make the decision to defer them unmeasurable.
#
# ══════════════════════════════════════════════════════════════════════════
# §B  ★★ THE CONTROL IS NOT BYPASSABLE, BY CONSTRUCTION
# ══════════════════════════════════════════════════════════════════════════
# `decide_itip` takes a `binding` argument and REFUSES every state-changing
# outcome unless it is `ITIP_BIND_PASS`. You cannot run the state machine
# without first stating what you authenticated. That is deliberate: a security
# control that lives in a separate function the caller is *supposed* to call
# first is a control one forgotten call site removes (compare an admin check
# that only authenticates).
#
# RFC 6047 §2.3: *"The relevant address MUST be ascertained by opening the
# text/calendar MIME body part and examining the ATTENDEE and ORGANIZER
# properties"* — NOT the RFC 5322 `Sender` / `Reply-To` headers. §3 names both
# spoofing threats, Organizer AND Attendee. The RFC's own answer is S/MIME
# (§2.2.2), which essentially nobody deploys; Outlook meanwhile renders the
# sender FROM the ORGANIZER field, a documented in-the-wild phishing vector. So
# the binding has to be ours.
#
# ══════════════════════════════════════════════════════════════════════════
# §C  ⚠⚠ WHAT THE BINDING COVERS — AND THE THREE PATHS IT DOES NOT
# ══════════════════════════════════════════════════════════════════════════
# There is NO inbound DKIM VERIFIER here: no `DKIM-Signature` parser, no
# public-key DNS lookup, no verify path. So this file does not pretend to verify
# DKIM itself.
#
# What an SES receiving pipeline DOES hand over is AWS's own verdict: every
# inbound SES notification carries `receipt.dkimVerdict`. AWS ran the check
# before handing over the receipt. This control consumes THAT.
#
#   | ingest path                        | covered? | outcome                |
#   |------------------------------------|----------|------------------------|
#   | SES  (receipt / SNS notification)  | YES      | PASS / DOWNGRADE / REFUSE |
#   | Postmark webhook                    | **NO**  | DOWNGRADE, always      |
#   | direct SMTP                         | **NO**  | DOWNGRADE, always      |
#   | anything else / unstated            | **NO**  | DOWNGRADE, always      |
#
# The uncovered paths FAIL CLOSED — they can never reach `ITIP_BIND_PASS`, so
# `decide_itip` can never mutate a calendar from them. An invite arriving that
# way is rendered as a non-actionable attachment, not as an RSVP.
#
# ⚠ **THE RESIDUAL, STATED RATHER THAN HIDDEN.** SES's `dkimVerdict: PASS` means
# a DKIM signature verified. It does NOT tell us which `d=` domain signed —
# AWS exposes ALIGNMENT separately as `dmarcVerdict`, which this control does
# NOT consume. So it adds its own
# alignment leg — ORGANIZER domain == `From:` domain — and that leg is what
# makes the pair meaningful. A message DKIM-signed by `evil.test` and claiming
# `From: ada@komira.test` would still be caught by the alignment leg, because
# SES would then have to have verified a signature for a message whose From
# domain it does not match... which is exactly the gap `dmarcVerdict` closes and
# we have not measured. **Parsing `dmarcVerdict` and requiring it is the correct
# next step.** Until then the honest claim is: two
# independent legs, neither individually sufficient, and no verifier of our own.
#
# Alignment is EXACT-DOMAIN, not DMARC "relaxed"/organizational-domain: an
# organizational-domain match needs a Public Suffix List, which this package
# does not have, and guessing one is how `a.co.uk` becomes `co.uk`. Exact is
# stricter, so the error is a false DOWNGRADE, never a false PASS.
#
# Encapsulation: owned `String` / scalar surface; ZERO UnsafePointer in any
# signature; no wildcard origin.
# =============================================================================

from .icalendar import (
    bytes_to_string,
    VEvent,
    VCalendar,
    VTimeZone,
    CalAddress,
    empty_cal_address,
)


# -----------------------------------------------------------------------------
# §1 — the iTIP methods (RFC 5546 §1.4).
# -----------------------------------------------------------------------------

comptime ITIP_METHOD_REQUEST: StaticString = "REQUEST"
comptime ITIP_METHOD_REPLY: StaticString = "REPLY"
comptime ITIP_METHOD_CANCEL: StaticString = "CANCEL"
comptime ITIP_METHOD_PUBLISH: StaticString = "PUBLISH"
comptime ITIP_METHOD_COUNTER: StaticString = "COUNTER"
comptime ITIP_METHOD_DECLINECOUNTER: StaticString = "DECLINECOUNTER"
comptime ITIP_METHOD_ADD: StaticString = "ADD"
comptime ITIP_METHOD_REFRESH: StaticString = "REFRESH"


# -----------------------------------------------------------------------------
# §2 — PARTSTAT values (RFC 5545 §3.2.12).
# -----------------------------------------------------------------------------

comptime PARTSTAT_NEEDS_ACTION: StaticString = "NEEDS-ACTION"
comptime PARTSTAT_ACCEPTED: StaticString = "ACCEPTED"
comptime PARTSTAT_DECLINED: StaticString = "DECLINED"
comptime PARTSTAT_TENTATIVE: StaticString = "TENTATIVE"
comptime PARTSTAT_DELEGATED: StaticString = "DELEGATED"


def is_valid_partstat(p: String) -> Bool:
    """True iff `p` is a PARTSTAT this implementation will STORE.

    ⚠ Fail-closed on an unknown value. RFC 5545 §3.2.12 permits x-name and
    iana-token extensions, so an unknown PARTSTAT is not necessarily malformed —
    but storing one means a later read renders a state no UI can describe and no
    comparison can order. Refusing an unknown value costs an interop edge case;
    accepting one costs a calendar whose contents we cannot reason about."""
    return (
        p == PARTSTAT_NEEDS_ACTION
        or p == PARTSTAT_ACCEPTED
        or p == PARTSTAT_DECLINED
        or p == PARTSTAT_TENTATIVE
        or p == PARTSTAT_DELEGATED
    )


# -----------------------------------------------------------------------------
# §3 — the sender-binding control (RFC 6047 §3).
# -----------------------------------------------------------------------------

comptime ITIP_BIND_PASS: Int = 0
"""The claimed CAL-ADDRESS is bound to an authenticated sending domain. The ONLY
value for which `decide_itip` will mutate anything."""

comptime ITIP_BIND_DOWNGRADE: Int = 1
"""Not verifiable — render the invite as a NON-ACTIONABLE attachment (no RSVP
control). The uncovered ingest paths and every non-PASS DKIM verdict land here."""

comptime ITIP_BIND_REFUSE: Int = 2
"""Verified AND CONTRADICTED — the message authenticated as one domain and
claims a CAL-ADDRESS at another. Distinct from DOWNGRADE on purpose: "we could
not check" and "we checked and it disagrees" are different facts, and only the
second is evidence of an attack worth surfacing."""

comptime ITIP_INGEST_SES: StaticString = "ses"
comptime ITIP_INGEST_POSTMARK_WEBHOOK: StaticString = "postmark_webhook"
comptime ITIP_INGEST_SMTP_DIRECT: StaticString = "smtp_direct"


@fieldwise_init
struct ItipBinding(Copyable, Movable, Deinitable):
    """The outcome of the sender-binding check plus WHY, for the log/UI.

    Fields:
        outcome: `ITIP_BIND_PASS` / `ITIP_BIND_DOWNGRADE` / `ITIP_BIND_REFUSE`.
        reason: an operator-readable sentence naming the leg that decided. Never
            empty, including on PASS — "it passed" without saying what was
            checked is the shape that lets a control rot into a no-op.
    """

    var outcome: Int
    var reason: String


def check_itip_sender_binding(
    claimed_address: CalAddress,
    from_header_domain: String,
    dkim_verdict: String,
    ingest_path: String,
) -> ItipBinding:
    """Bind a claimed iTIP CAL-ADDRESS to an authenticated sending domain.

    Used with the **ORGANIZER** on a REQUEST / CANCEL and with the **replying
    ATTENDEE** on a REPLY — RFC 6047 §3 names both spoofing threats, so one
    function covers both rather than an organizer-only rule that leaves the
    attendee half to be remembered.

    Args:
        claimed_address: The ORGANIZER or replying ATTENDEE, read from the
            `text/calendar` part itself (RFC 6047 §2.3 — never from `Sender:`).
        from_header_domain: The domain of the RFC 5322 `From:` header,
            lowercased, no `@`. "" if it could not be determined.
        dkim_verdict: SES's `receipt.dkimVerdict` status text, e.g. "PASS".
        ingest_path: Which ingest produced this message — one of
            `ITIP_INGEST_*`. Anything else is treated as uncovered.

    Returns:
        An `ItipBinding`. See §C in the file header for exactly what each ingest
        path can and cannot reach.
    """
    # LEG 0 — the ingest path must be one we have an authentication signal for.
    # This is FIRST because it is the only leg that is a property of our own
    # deployment rather than of the message, and getting it wrong means every
    # other leg is evaluating attacker-supplied data as if it were checked.
    if ingest_path != ITIP_INGEST_SES:
        return ItipBinding(
            ITIP_BIND_DOWNGRADE,
            String("ingest path '")
            + ingest_path
            + String(
                "' carries no inbound authentication signal (there is no DKIM"
                " VERIFIER here, only the SES receipt's verdict),"
                " so no CAL-ADDRESS can be bound on it"
            ),
        )
    # LEG 1 — there must be something to bind.
    if not claimed_address.is_present():
        return ItipBinding(
            ITIP_BIND_DOWNGRADE,
            String("the scheduling message states no CAL-ADDRESS to bind"),
        )
    if claimed_address.email.byte_length() == 0:
        return ItipBinding(
            ITIP_BIND_DOWNGRADE,
            String("CAL-ADDRESS '")
            + claimed_address.value
            + String(
                "' is not a mailto: URI, so it has no domain to align against"
            ),
        )
    # LEG 2 — AWS's own DKIM verdict.
    if dkim_verdict != "PASS":
        return ItipBinding(
            ITIP_BIND_DOWNGRADE,
            String("SES dkimVerdict is '")
            + (dkim_verdict if dkim_verdict.byte_length() > 0 else String("<absent>"))
            + String("', not PASS"),
        )
    # LEG 3 — alignment. See §C: this leg exists because dkimVerdict does not
    # state WHICH domain signed, and `dmarcVerdict` (which would) is not parsed.
    var claimed_domain = domain_of(claimed_address.email)
    if from_header_domain.byte_length() == 0:
        return ItipBinding(
            ITIP_BIND_DOWNGRADE,
            String(
                "the From: header domain could not be determined, so the"
                " authenticated domain cannot be aligned with the CAL-ADDRESS"
            ),
        )
    if claimed_domain != from_header_domain:
        # ★ VERIFIED AND CONTRADICTED. Not a downgrade.
        return ItipBinding(
            ITIP_BIND_REFUSE,
            String("CAL-ADDRESS domain '")
            + claimed_domain
            + String("' does not match the authenticated From: domain '")
            + from_header_domain
            + String("' — RFC 6047 §3 organizer/attendee spoofing shape"),
        )
    return ItipBinding(
        ITIP_BIND_PASS,
        String("SES dkimVerdict=PASS and CAL-ADDRESS domain '")
        + claimed_domain
        + String("' matches the From: domain exactly"),
    )


def domain_of(email_lower: String) -> String:
    """The domain of a normalized addr-spec — everything after the LAST `@`,
    lowercased. "" if there is no `@` or nothing follows it.

    The LAST `@` because RFC 5321 §4.1.2 permits a quoted local part containing
    `@` (`"a@b"@example.com`); taking the first would return `b"` as a domain."""
    var bs = email_lower.as_bytes()
    var at = -1
    var i = 0
    while i < len(bs):
        if bs[i] == UInt8(ord("@")):
            at = i
        i += 1
    if at < 0 or at == len(bs) - 1:
        return String("")
    var out = List[UInt8]()
    var k = at + 1
    while k < len(bs):
        var c = bs[k]
        if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            out.append(c + UInt8(32))
        else:
            # An IDN domain is non-ASCII; doubling its octets would make two
            # spellings of one domain compare unequal. See icalendar.mojo §0.
            out.append(c)
        k += 1
    return bytes_to_string(out)


# -----------------------------------------------------------------------------
# §4 — the decision the state machine produces.
# -----------------------------------------------------------------------------

comptime ITIP_CREATE: Int = 0
"""No stored object for this (UID, RECURRENCE-ID) — store the incoming one."""

comptime ITIP_UPDATE: Int = 1
"""The incoming revision supersedes the stored one — replace it."""

comptime ITIP_SET_PARTSTAT: Int = 2
"""A REPLY — set `partstat_value` on the attendee at `attendee_index` of the
STORED event. Nothing else about the stored event changes: RFC 5546 §3.2.3 says
a REPLY MUST NOT alter the properties it echoes, so we take the PARTSTAT and
discard everything else the replier sent."""

comptime ITIP_CANCEL_SERIES: Int = 3
"""A CANCEL with no RECURRENCE-ID — mark the whole series STATUS:CANCELLED."""

comptime ITIP_CANCEL_INSTANCE: Int = 4
"""A CANCEL with a RECURRENCE-ID — mark that one occurrence CANCELLED."""

comptime ITIP_IGNORE_STALE: Int = 5
"""A revision we already have or have superseded. Not an error — retries and
duplicate deliveries are normal on email transport."""

comptime ITIP_IGNORE_UNKNOWN_OBJECT: Int = 6
"""A REPLY or CANCEL for a (UID, RECURRENCE-ID) we hold nothing for."""

comptime ITIP_IGNORE_UNSUPPORTED: Int = 7
"""COUNTER / DECLINECOUNTER / ADD / REFRESH / PUBLISH — the deferred set."""

comptime ITIP_REFUSE_NOT_SCHEDULING: Int = 8
"""No METHOD, or a METHOD that is not an iTIP method. A calendar OBJECT, not a
scheduling MESSAGE (RFC 5545 §3.7.2)."""

comptime ITIP_REFUSE_UNBOUND: Int = 9
"""The sender-binding check did not PASS. See §C."""

comptime ITIP_REFUSE_ORGANIZER_MISMATCH: Int = 10
"""The incoming ORGANIZER is not the organiser of the STORED object.

★ THIS IS A SEPARATE CONTROL FROM THE DKIM BINDING AND BOTH ARE NEEDED. The
binding proves the sender owns the domain it claims. THIS proves the sender is
the party who owns THIS meeting. Without it, anyone who learns a UID — and a UID
travels to every attendee — can send a perfectly authenticated CANCEL from their
own domain and delete a meeting they were merely invited to."""

comptime ITIP_REFUSE_MALFORMED: Int = 11
"""The message is structurally unusable for its own method — e.g. a REPLY with
no ATTENDEE, or with more than one (a REPLY carries exactly the replier; several
would be one party setting other parties' PARTSTAT)."""


@fieldwise_init
struct ItipDecision(Copyable, Movable, Deinitable):
    """What to do with an arriving iTIP message.

    Fields:
        action: one of the `ITIP_*` action constants above.
        reason: an operator-readable sentence. Never empty — every ignore and
            every refusal must say which rule fired, or the deferred-method
            decision and the security refusals are both unmeasurable.
        attendee_index: for `ITIP_SET_PARTSTAT`, the index into the STORED
            event's `attendees`. -1 otherwise.
        partstat_value: for `ITIP_SET_PARTSTAT`, the PARTSTAT to write. ""
            otherwise.
    """

    var action: Int
    var reason: String
    var attendee_index: Int
    var partstat_value: String

    def is_mutation(self) -> Bool:
        """True iff this decision changes stored state. The four mutating
        actions are contiguous by construction, and this predicate is what a
        caller should branch on rather than re-listing them."""
        return self.action <= ITIP_CANCEL_INSTANCE


def _decision(action: Int, reason: String) -> ItipDecision:
    return ItipDecision(action, reason, -1, String(""))


# -----------------------------------------------------------------------------
# §5 — revision precedence (RFC 5546 §3.2).
# -----------------------------------------------------------------------------


def supersedes(incoming: VEvent, stored: VEvent) -> Bool:
    """True iff `incoming` is a LATER revision of `stored`.

    RFC 5546 §3.2: *"the highest SEQUENCE value obsoletes lower ones; when
    SEQUENCE values match, DTSTAMP serves as the tiebreaker."*

    ⚠ EQUAL SEQUENCE **and** EQUAL DTSTAMP returns False — the message is a
    duplicate, not an update. Email transport re-delivers; treating a duplicate
    as an update would clobber an already-applied PARTSTAT with the organiser's
    original NEEDS-ACTION every time a retry lands."""
    if incoming.sequence != stored.sequence:
        return incoming.sequence > stored.sequence
    return incoming.dtstamp > stored.dtstamp


# -----------------------------------------------------------------------------
# §6 — the state machine.
# -----------------------------------------------------------------------------


def decide_itip(
    method: String,
    incoming: VEvent,
    has_stored: Bool,
    stored: VEvent,
    binding: Int,
) -> ItipDecision:
    """Decide what an arriving iTIP message does to our stored calendar.

    Args:
        method: The VCALENDAR `METHOD` property, UPPERCASED. "" for a calendar
            object that is not a scheduling message.
        incoming: The arriving VEVENT.
        has_stored: Whether we hold an object for `incoming.itip_key()`. The
            caller does the lookup; this function does no I/O.
        stored: The stored VEVENT (ignored when `has_stored` is False).
        binding: The `outcome` of `check_itip_sender_binding`. ★ REQUIRED —
            see §B. Every mutating outcome is gated on `ITIP_BIND_PASS`.

    Returns:
        An `ItipDecision`. The caller applies it; this function is pure.
    """
    # --- 0. Is this a scheduling message at all? ---------------------------
    if method.byte_length() == 0:
        return _decision(
            ITIP_REFUSE_NOT_SCHEDULING,
            String(
                "no METHOD — an ORGANIZER+ATTENDEE calendar OBJECT is not an"
                " invitation (RFC 5545 §3.7.2)"
            ),
        )
    # --- 1. The deferred methods, named so the log is measurable. ----------
    if (
        method == ITIP_METHOD_COUNTER
        or method == ITIP_METHOD_DECLINECOUNTER
        or method == ITIP_METHOD_ADD
        or method == ITIP_METHOD_REFRESH
        or method == ITIP_METHOD_PUBLISH
    ):
        return _decision(
            ITIP_IGNORE_UNSUPPORTED,
            String("METHOD:")
            + method
            + String(
                " is not implemented (shipped set is REQUEST/REPLY/CANCEL);"
                " ignored with this log line"
            ),
        )
    if (
        method != ITIP_METHOD_REQUEST
        and method != ITIP_METHOD_REPLY
        and method != ITIP_METHOD_CANCEL
    ):
        return _decision(
            ITIP_REFUSE_NOT_SCHEDULING,
            String("METHOD:") + method + String(" is not an iTIP method"),
        )
    # --- 2. ★ THE GATE. No PASS, no mutation, for any method. --------------
    if binding != ITIP_BIND_PASS:
        var word = String("REFUSE") if binding == ITIP_BIND_REFUSE else String(
            "DOWNGRADE"
        )
        return _decision(
            ITIP_REFUSE_UNBOUND,
            String("sender binding did not PASS (")
            + word
            + String(
                ") — the message is rendered as a non-actionable attachment and"
                " changes no stored state (RFC 6047 §3)"
            ),
        )
    # --- 3. UID is the identity. Without it nothing can be keyed. ----------
    if incoming.uid.byte_length() == 0:
        return _decision(
            ITIP_REFUSE_MALFORMED,
            String("the VEVENT carries no UID, so it identifies no scheduling"
                   " object (RFC 5546 §3.2 makes UID required on every method)"),
        )

    if method == ITIP_METHOD_REQUEST:
        return _decide_request(incoming, has_stored, stored)
    if method == ITIP_METHOD_REPLY:
        return _decide_reply(incoming, has_stored, stored)
    return _decide_cancel(incoming, has_stored, stored)


def _decide_request(
    incoming: VEvent, has_stored: Bool, stored: VEvent
) -> ItipDecision:
    if not has_stored:
        return _decision(
            ITIP_CREATE,
            String("new scheduling object ")
            + incoming.itip_key()
            + String(" at SEQUENCE ")
            + String(incoming.sequence),
        )
    var org_check = _same_organizer(incoming, stored)
    if org_check.byte_length() > 0:
        return _decision(ITIP_REFUSE_ORGANIZER_MISMATCH, org_check)
    if not supersedes(incoming, stored):
        return _decision(
            ITIP_IGNORE_STALE,
            String("REQUEST at SEQUENCE ")
            + String(incoming.sequence)
            + String("/DTSTAMP ")
            + String(incoming.dtstamp)
            + String(" does not supersede the stored SEQUENCE ")
            + String(stored.sequence)
            + String("/DTSTAMP ")
            + String(stored.dtstamp),
        )
    return _decision(
        ITIP_UPDATE,
        String("REQUEST supersedes stored revision: SEQUENCE ")
        + String(stored.sequence)
        + String(" -> ")
        + String(incoming.sequence),
    )


def _decide_reply(
    incoming: VEvent, has_stored: Bool, stored: VEvent
) -> ItipDecision:
    if not has_stored:
        return _decision(
            ITIP_IGNORE_UNKNOWN_OBJECT,
            String("REPLY for ")
            + incoming.itip_key()
            + String(", which we do not organise or hold"),
        )
    # RFC 5546 §3.2.3: a REPLY carries the REPLIER as its ATTENDEE. Exactly one.
    if len(incoming.attendees) == 0:
        return _decision(
            ITIP_REFUSE_MALFORMED,
            String("REPLY carries no ATTENDEE, so it states no response"),
        )
    if len(incoming.attendees) > 1:
        # ★ FAIL CLOSED. A multi-ATTENDEE REPLY is one party setting other
        # parties' participation status. Picking the first would make WHICH
        # attendee gets updated depend on the attacker's ordering.
        return _decision(
            ITIP_REFUSE_MALFORMED,
            String("REPLY carries ")
            + String(len(incoming.attendees))
            + String(
                " ATTENDEEs — a REPLY states exactly one party's own response"
                " (RFC 5546 §3.2.3); refusing rather than guessing which"
            ),
        )
    var replier = incoming.attendees[0].copy()
    var idx = stored.find_attendee(replier.email)
    if idx < 0:
        return _decision(
            ITIP_REFUSE_MALFORMED,
            String("REPLY from '")
            + replier.email
            + String("', who is not an ATTENDEE of the stored event"),
        )
    if not is_valid_partstat(replier.partstat):
        return _decision(
            ITIP_REFUSE_MALFORMED,
            String("REPLY carries PARTSTAT '")
            + (
                replier.partstat if replier.partstat.byte_length()
                > 0 else String("<absent>")
            )
            + String("', which is not a value this implementation stores"),
        )
    # An attendee replying to an OLDER revision than the one we hold is stale:
    # they answered a question we have since changed. RFC 5546 §3.2.3 lets the
    # organiser ignore it; we do, and say so.
    if incoming.sequence < stored.sequence:
        return _decision(
            ITIP_IGNORE_STALE,
            String("REPLY is against SEQUENCE ")
            + String(incoming.sequence)
            + String(" but the stored revision is ")
            + String(stored.sequence),
        )
    return ItipDecision(
        ITIP_SET_PARTSTAT,
        String("REPLY from '")
        + replier.email
        + String("' -> PARTSTAT ")
        + replier.partstat,
        idx,
        replier.partstat,
    )


def _decide_cancel(
    incoming: VEvent, has_stored: Bool, stored: VEvent
) -> ItipDecision:
    if not has_stored:
        return _decision(
            ITIP_IGNORE_UNKNOWN_OBJECT,
            String("CANCEL for ")
            + incoming.itip_key()
            + String(", which we do not hold"),
        )
    var org_check = _same_organizer(incoming, stored)
    if org_check.byte_length() > 0:
        return _decision(ITIP_REFUSE_ORGANIZER_MISMATCH, org_check)
    # RFC 5546 §3.2.5 requires a CANCEL's SEQUENCE to be higher than the one it
    # cancels. Real implementations send equal; the DTSTAMP tiebreak in
    # `supersedes` covers that, and a strictly LOWER one is a replay.
    if incoming.sequence < stored.sequence:
        return _decision(
            ITIP_IGNORE_STALE,
            String("CANCEL at SEQUENCE ")
            + String(incoming.sequence)
            + String(" is below the stored SEQUENCE ")
            + String(stored.sequence)
            + String(" — a replay of a superseded revision"),
        )
    if incoming.recurrence_id.byte_length() > 0:
        return _decision(
            ITIP_CANCEL_INSTANCE,
            String("CANCEL of the single occurrence RECURRENCE-ID=")
            + incoming.recurrence_id,
        )
    return _decision(
        ITIP_CANCEL_SERIES,
        String("CANCEL of the whole series ") + incoming.uid,
    )


def _same_organizer(incoming: VEvent, stored: VEvent) -> String:
    """"" if the incoming ORGANIZER is the stored object's organiser; otherwise
    the reason it is not. See `ITIP_REFUSE_ORGANIZER_MISMATCH`."""
    if not stored.organizer.is_present():
        # Nothing to compare against. Fail closed rather than accept: a stored
        # object with no ORGANIZER is not one anybody may reschedule remotely.
        return String(
            "the stored object has no ORGANIZER, so no remote party can be"
            " shown to own it"
        )
    if not incoming.organizer.is_present():
        return String(
            "the incoming message states no ORGANIZER (RFC 5546 §3.2 requires"
            " one on REQUEST and CANCEL)"
        )
    if incoming.organizer.email != stored.organizer.email:
        return (
            String("ORGANIZER '")
            + incoming.organizer.email
            + String("' is not the organiser of the stored object ('")
            + stored.organizer.email
            + String("')")
        )
    return String("")


# -----------------------------------------------------------------------------
# §7 — the BUILDERS: the messages we SEND.
#
# iTIP is symmetric — we ingest REQUEST/REPLY/CANCEL and we must emit all three.
# These produce a `VCalendar` with its `method` set; `icalendar_emit.emit_vcalendar`
# turns it into bytes and an iMIP composer wraps those in MIME.
# Splitting it that way is what keeps the wire-format rules (RFC 6047 §2.4's
# method agreement, [MS-STANOICAL]'s media-type rules) in ONE place instead of
# once per builder.
# -----------------------------------------------------------------------------


def _one_event_calendar(var ev: VEvent, method: String) -> VCalendar:
    """A VCALENDAR carrying exactly one VEVENT and a METHOD.

    ⚠ NO VTIMEZONE. `icalendar_emit` refuses a TZID-local event outright (it cannot
    reproduce a parsed VTIMEZONE faithfully), so a calendar built here that
    would need one fails at EMIT time with a message naming the TZID — loudly,
    at the point of the problem, rather than shipping an unresolvable DTSTART."""
    var evs = List[VEvent]()
    evs.append(ev^)
    return VCalendar(evs^, List[VTimeZone](), method)


def build_reply(
    request: VEvent,
    replier_email_lower: String,
    partstat: String,
    dtstamp_now: Int64,
) raises -> VCalendar:
    """The REPLY we send when our user accepts / declines / tentatively accepts.

    RFC 5546 §3.2.3 is unusually prescriptive and this follows it literally:

    * the REPLY carries **exactly one ATTENDEE** — the replier — with the new
      PARTSTAT. Echoing the other invitees would leak the attendee list back at
      the organiser as if we were restating it, and would let a bug of ours set
      someone else's status.
    * `UID`, `SEQUENCE` and `ORGANIZER` are echoed **unaltered** — that is the
      section's own MUST NOT ("a change requires COUNTER, not REPLY"). The
      organiser's raw CAL-ADDRESS spelling is preserved byte-for-byte, which is
      why `CalAddress.value` is kept alongside the normalized `email`.
    * `DTSTAMP` is NEW: it is when THIS message was produced, not when the
      request was. It is also the tiebreaker the organiser uses when two replies
      carry the same SEQUENCE, so a stale clock here loses a user's answer.
    * **No DTSTART/DTEND/SUMMARY.** They are optional in a REPLY, and omitting
      them is what lets this builder work for a TZID-local request without
      re-emitting a VTIMEZONE we cannot reproduce.

    Raises:
        If `partstat` is not a value we store, or the replier is not an
        ATTENDEE of `request`. Refusing to build is the right failure: a REPLY
        from a non-attendee is one the organiser will reject anyway, and
        producing it would put our domain's name on a malformed message.
    """
    if not is_valid_partstat(partstat):
        raise Error(
            String("itip.build_reply: PARTSTAT '")
            + partstat
            + String("' is not a value this implementation sends")
        )
    var idx = request.find_attendee(replier_email_lower)
    if idx < 0:
        raise Error(
            String("itip.build_reply: '")
            + replier_email_lower
            + String(
                "' is not an ATTENDEE of the request being replied to; a REPLY"
                " from a non-attendee is not a thing RFC 5546 defines"
            )
        )
    # Echo the organiser's OWN spelling of the replier's address (RFC 5546
    # §3.2.3 — "MUST NOT be altered"), with only the PARTSTAT changed and RSVP
    # cleared: the question has been answered, so re-asserting RSVP=TRUE would
    # tell the organiser we are still waiting on ourselves.
    var src = request.attendees[idx].copy()
    var me = CalAddress(
        src.value,
        src.email,
        src.cn,
        partstat,
        src.role,
        src.cutype,
        False,
        src.sent_by,
        src.delegated_to,
        src.delegated_from,
    )
    var atts = List[CalAddress]()
    atts.append(me^)
    var ev = VEvent(
        request.uid,
        String(""),          # SUMMARY — omitted, see docstring
        Int64(0),            # DTSTART — omitted
        Int64(0),            # DTEND — omitted
        False,
        String(""),          # RRULE — omitted
        String(""),          # TZID
        False,               # has_tz — MUST stay False; see _one_event_calendar
        request.recurrence_id,
        request.recurrence_id_instant,
        List[Int64](),
        List[Int64](),
        String(""),          # TRANSP
        request.organizer.copy(),
        atts^,
        request.sequence,    # echoed UNALTERED
        String(""),          # STATUS — the organiser owns STATUS, not the replier
        dtstamp_now,         # NEW — this message's own timestamp
        String(""),
        String(""),
    )
    return _one_event_calendar(ev^, String(ITIP_METHOD_REPLY))


def build_cancel(
    stored: VEvent, dtstamp_now: Int64, cancel_instance: Bool
) raises -> VCalendar:
    """The CANCEL we send to call off a meeting we organise.

    RFC 5546 §3.2.5: `UID`, an **incremented** `SEQUENCE`, `ORGANIZER`, and
    `STATUS:CANCELLED`. Omit `RECURRENCE-ID` to kill the series; include it to
    kill one occurrence — which is what `cancel_instance` selects.

    ★ THE SEQUENCE INCREMENT IS THE WHOLE MESSAGE. A CANCEL that reuses the
    stored SEQUENCE is, to a conforming peer, a duplicate of a revision it has
    already applied — `supersedes` (ours) and every other implementation's
    equivalent will drop it. The meeting then stays on the invitee's calendar
    and nothing anywhere reports a failure. Incrementing here, once, is why the
    caller cannot get that wrong.

    Raises:
        If `cancel_instance` is asked for on an event with no RECURRENCE-ID —
        there is no occurrence to name, and sending a series CANCEL instead
        would cancel far more than the caller asked for.
    """
    if cancel_instance and stored.recurrence_id.byte_length() == 0:
        raise Error(
            String(
                "itip.build_cancel: asked to cancel a single occurrence of an"
                " event that carries no RECURRENCE-ID — refusing rather than"
                " silently cancelling the whole series"
            )
        )
    var atts = List[CalAddress]()
    var i = 0
    while i < len(stored.attendees):
        # Attendees are echoed so each recipient can find themselves, with RSVP
        # cleared — a cancelled meeting asks nothing of anyone.
        var a = stored.attendees[i].copy()
        atts.append(
            CalAddress(
                a.value,
                a.email,
                a.cn,
                a.partstat,
                a.role,
                a.cutype,
                False,
                a.sent_by,
                a.delegated_to,
                a.delegated_from,
            )
        )
        i += 1
    var rec_id = stored.recurrence_id if cancel_instance else String("")
    var rec_inst = (
        stored.recurrence_id_instant if cancel_instance else Int64(0)
    )
    var ev = VEvent(
        stored.uid,
        stored.summary,
        stored.dtstart,
        stored.dtend,
        stored.all_day,
        String("") if cancel_instance else stored.rrule,
        stored.tzid,
        stored.has_tz,
        rec_id,
        rec_inst,
        List[Int64](),
        List[Int64](),
        stored.transp,
        stored.organizer.copy(),
        atts^,
        stored.sequence + Int64(1),   # ★ the increment
        String("CANCELLED"),
        dtstamp_now,
        stored.description,
        stored.location,
    )
    return _one_event_calendar(ev^, String(ITIP_METHOD_CANCEL))


def build_request(var ev: VEvent, dtstamp_now: Int64) -> VCalendar:
    """A REQUEST for an event we organise.

    `DTSTAMP` is stamped here (RFC 5546 §3.2 makes it required and it is the
    SEQUENCE tiebreaker). `SEQUENCE` is taken from `ev` UNCHANGED: whether this
    is a new invitation or a reschedule is the CALLER's fact, and RFC 5546 §3.2
    is specific that SEQUENCE MUST increment when DTSTART / DTEND / DURATION /
    RRULE / RDATE / EXDATE / STATUS change — a comparison this function cannot
    make because it is not given the previous revision. Guessing it here would
    either spam invitees with reschedule notices or silently suppress a real
    one."""
    ev.dtstamp = dtstamp_now
    return _one_event_calendar(ev^, String(ITIP_METHOD_REQUEST))
