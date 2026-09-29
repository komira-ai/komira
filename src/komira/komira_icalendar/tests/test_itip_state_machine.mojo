# =============================================================================
# test_itip_state_machine — RFC 5546 REQUEST/REPLY/CANCEL + the RFC 6047 §3
# sender-binding control
# =============================================================================
#
# ★ EVERY SECURITY ASSERTION IN THIS FILE IS ABOUT A REFUSAL, AND EACH ONE IS
# PAIRED WITH THE POSITIVE CASE THAT WOULD OTHERWISE MAKE IT VACUOUS. A test
# that only shows "attack X is refused" passes just as well against a state
# machine that refuses everything; the paired accept is what proves the refusal
# is discriminating.
#
# THE FIVE THINGS THIS FILE FALSIFIES:
#   §1 the BINDING: the three uncovered ingest paths can never reach PASS; a
#      non-PASS SES verdict cannot; a domain MISMATCH is REFUSE (not DOWNGRADE)
#      because "we checked and it disagrees" is a different fact from "we could
#      not check".
#   §2 the GATE: with a non-PASS binding, NO method mutates anything. This is
#      the property that makes the control non-bypassable by construction.
#   §3 REVISION PRECEDENCE: SEQUENCE, then DTSTAMP, and an exact duplicate is
#      NOT an update — email re-delivers, and treating a retry as an update
#      clobbers an applied PARTSTAT with the organiser's original NEEDS-ACTION.
#   §4 the ORGANIZER-OWNERSHIP control, which is SEPARATE from the DKIM binding:
#      a perfectly authenticated CANCEL from an invitee's own domain must not
#      delete the organiser's meeting. A UID travels to every attendee.
#   §5 the BUILDERS: a REPLY carries exactly one ATTENDEE and echoes UID /
#      SEQUENCE / ORGANIZER unaltered; a CANCEL INCREMENTS SEQUENCE (a CANCEL
#      that reuses it is dropped by every conforming peer, silently).
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from komira_icalendar import (
    parse_vcalendar,
    parse_cal_address,
    emit_vcalendar,
    VEvent,
    check_itip_sender_binding,
    domain_of,
    decide_itip,
    supersedes,
    build_reply,
    build_cancel,
    build_request,
    is_valid_partstat,
    ITIP_BIND_PASS,
    ITIP_BIND_DOWNGRADE,
    ITIP_BIND_REFUSE,
    ITIP_INGEST_SES,
    ITIP_INGEST_POSTMARK_WEBHOOK,
    ITIP_INGEST_SMTP_DIRECT,
    ITIP_CREATE,
    ITIP_UPDATE,
    ITIP_SET_PARTSTAT,
    ITIP_CANCEL_SERIES,
    ITIP_CANCEL_INSTANCE,
    ITIP_IGNORE_STALE,
    ITIP_IGNORE_UNKNOWN_OBJECT,
    ITIP_IGNORE_UNSUPPORTED,
    ITIP_REFUSE_NOT_SCHEDULING,
    ITIP_REFUSE_UNBOUND,
    ITIP_REFUSE_ORGANIZER_MISMATCH,
    ITIP_REFUSE_MALFORMED,
    ITIP_METHOD_REQUEST,
    ITIP_METHOD_REPLY,
    ITIP_METHOD_CANCEL,
    PARTSTAT_ACCEPTED,
    PARTSTAT_DECLINED,
    ICAL_PRODID,
)


# -----------------------------------------------------------------------------
# Fixtures — built by PARSING `.ics`, so every test also exercises the parser
# the production path uses. A hand-built struct would test my belief about the
# lexer rather than the lexer.
# -----------------------------------------------------------------------------


def _event(
    uid: String,
    seq: Int,
    dtstamp: String,
    organizer: String,
    attendee_lines: String,
    extra: String,
) -> VEvent:
    var ics = String("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:")
    ics += uid
    ics += String("\r\nDTSTART:20260615T130000Z\r\nDTEND:20260615T140000Z\r\n")
    ics += String("SEQUENCE:") + String(seq) + String("\r\n")
    ics += String("DTSTAMP:") + dtstamp + String("\r\n")
    if organizer.byte_length() > 0:
        ics += String("ORGANIZER:mailto:") + organizer + String("\r\n")
    ics += attendee_lines
    ics += extra
    ics += String("END:VEVENT\r\nEND:VCALENDAR\r\n")
    return parse_vcalendar(ics).events[0].copy()


def _att(email: String, partstat: String) -> String:
    var s = String("ATTENDEE")
    if partstat.byte_length() > 0:
        s += String(";PARTSTAT=") + partstat
    s += String(":mailto:") + email + String("\r\n")
    return s^


def _stored() -> VEvent:
    """The organiser's meeting: ada organises, bob + carol invited."""
    return _event(
        String("meet-1@komira.test"),
        2,
        String("20260601T090000Z"),
        String("ada@komira.test"),
        _att(String("bob@partner.test"), String("NEEDS-ACTION"))
        + _att(String("carol@partner.test"), String("NEEDS-ACTION")),
        String(""),
    )


def _addr(email: String) -> String:
    return String("mailto:") + email


# =============================================================================
# §1 — the binding control.
# =============================================================================
def test_uncovered_ingest_paths_can_never_pass() raises:
    var org = parse_cal_address(
        String(""), _addr(String("ada@komira.test"))
    )
    # Every argument except the ingest path is the PERFECT case: DKIM PASS and
    # exact domain alignment. If the path leg were missing, these would PASS.
    for path in [
        String(ITIP_INGEST_POSTMARK_WEBHOOK),
        String(ITIP_INGEST_SMTP_DIRECT),
        String("imap_poll"),
        String(""),
    ]:
        var b = check_itip_sender_binding(
            org, String("komira.test"), String("PASS"), path
        )
        assert_equal(
            b.outcome,
            ITIP_BIND_DOWNGRADE,
            String("ingest path '")
            + path
            + String("' must DOWNGRADE even with a perfect DKIM verdict"),
        )
        assert_true(b.reason.byte_length() > 0, "the refusal states its reason")
    # ★ THE PAIRED POSITIVE — without it the loop above would pass against a
    # function that returns DOWNGRADE unconditionally.
    var ok = check_itip_sender_binding(
        org, String("komira.test"), String("PASS"), String(ITIP_INGEST_SES)
    )
    assert_equal(
        ok.outcome, ITIP_BIND_PASS, "the SES path with the same inputs PASSES"
    )
    print(
        "PASS binding-ingest-paths (Postmark webhook, direct SMTP and any"
        " unstated path fail closed to DOWNGRADE even with dkimVerdict=PASS and"
        " exact alignment; SES with identical inputs PASSES)"
    )


def test_non_pass_dkim_verdict_downgrades() raises:
    var org = parse_cal_address(String(""), _addr(String("ada@komira.test")))
    for v in [
        String("FAIL"),
        String("GRAY"),
        String("PROCESSING_FAILED"),
        String(""),
        String("pass"),
    ]:
        var b = check_itip_sender_binding(
            org, String("komira.test"), v, String(ITIP_INGEST_SES)
        )
        assert_equal(
            b.outcome,
            ITIP_BIND_DOWNGRADE,
            String("dkimVerdict '") + v + String("' is not PASS"),
        )
    print(
        "PASS binding-dkim-verdict (FAIL/GRAY/PROCESSING_FAILED/absent, and the"
        " lowercase spelling, all DOWNGRADE — the comparison is exact)"
    )


def test_domain_mismatch_is_REFUSE_not_downgrade() raises:
    var org = parse_cal_address(String(""), _addr(String("ada@komira.test")))
    var b = check_itip_sender_binding(
        org, String("evil.test"), String("PASS"), String(ITIP_INGEST_SES)
    )
    # ⚠ THE DISTINCTION IS THE POINT. DOWNGRADE means "we could not check".
    # REFUSE means "we checked and it disagrees" — evidence of the RFC 6047 §3
    # spoofing shape, which an operator should see differently from a message
    # that merely arrived over an unauthenticated path.
    assert_equal(
        b.outcome,
        ITIP_BIND_REFUSE,
        "an authenticated domain that contradicts the ORGANIZER is REFUSE",
    )
    # Exact-domain, not organizational-domain: a SUBDOMAIN does not align.
    var sub = check_itip_sender_binding(
        org, String("mail.komira.test"), String("PASS"),
        String(ITIP_INGEST_SES),
    )
    assert_equal(
        sub.outcome,
        ITIP_BIND_REFUSE,
        "alignment is EXACT-domain — a subdomain does not align (no PSL here)",
    )
    # A non-mailto CAL-ADDRESS has no domain at all -> DOWNGRADE, not REFUSE:
    # there is nothing to contradict.
    var urn = parse_cal_address(String(""), String("urn:uuid:abc"))
    var b2 = check_itip_sender_binding(
        urn, String("komira.test"), String("PASS"), String(ITIP_INGEST_SES)
    )
    assert_equal(
        b2.outcome,
        ITIP_BIND_DOWNGRADE,
        "a non-mailto CAL-ADDRESS has no domain to align, so it cannot"
        " CONTRADICT one",
    )
    print(
        "PASS binding-alignment (a contradicting domain is REFUSE and a"
        " subdomain does not align; an address with no domain at all is"
        " DOWNGRADE, because nothing was contradicted)"
    )


def test_domain_of_takes_the_last_at() raises:
    assert_equal(
        domain_of(String("a@b.com")), String("b.com"), "the simple case"
    )
    # RFC 5321 §4.1.2 permits a quoted local part containing `@`. Taking the
    # FIRST `@` would return a fragment of the local part as a domain, which is
    # an alignment comparison against attacker-chosen text.
    assert_equal(
        domain_of(String('"a@b"@example.com')),
        String("example.com"),
        "the LAST @ wins, so a quoted local part cannot forge a domain",
    )
    assert_equal(domain_of(String("nodomain")), String(""), "no @ -> empty")
    assert_equal(domain_of(String("trailing@")), String(""), "empty domain")
    print("PASS domain-of (the LAST @ delimits the domain; malformed -> empty)")


# =============================================================================
# §2 — the gate. No PASS, no mutation, for any method.
# =============================================================================
def test_no_method_mutates_without_a_PASS_binding() raises:
    var stored = _stored()
    var req = _event(
        String("meet-1@komira.test"),
        5,
        String("20260602T090000Z"),
        String("ada@komira.test"),
        _att(String("bob@partner.test"), String("NEEDS-ACTION")),
        String(""),
    )
    for m in [
        String(ITIP_METHOD_REQUEST),
        String(ITIP_METHOD_REPLY),
        String(ITIP_METHOD_CANCEL),
    ]:
        for bind in [ITIP_BIND_DOWNGRADE, ITIP_BIND_REFUSE]:
            var d = decide_itip(m, req, True, stored, bind)
            assert_equal(
                d.action,
                ITIP_REFUSE_UNBOUND,
                String("METHOD:") + m + String(" refuses on a non-PASS binding"),
            )
            assert_false(d.is_mutation(), "and mutates nothing")
    # ★ PAIRED POSITIVE: the same REQUEST with a PASS binding DOES mutate.
    var ok = decide_itip(
        String(ITIP_METHOD_REQUEST), req, True, stored, ITIP_BIND_PASS
    )
    assert_equal(ok.action, ITIP_UPDATE, "with PASS, the same message updates")
    assert_true(ok.is_mutation(), "and is a mutation")
    print(
        "PASS gate-unbypassable (REQUEST/REPLY/CANCEL x DOWNGRADE/REFUSE = 6"
        " combinations, none of which mutates; the same REQUEST with PASS does)"
    )


def test_deferred_methods_are_ignored_by_name() raises:
    var stored = _stored()
    for m in [
        String("COUNTER"),
        String("DECLINECOUNTER"),
        String("ADD"),
        String("REFRESH"),
        String("PUBLISH"),
    ]:
        var d = decide_itip(m, stored, True, stored, ITIP_BIND_PASS)
        assert_equal(
            d.action,
            ITIP_IGNORE_UNSUPPORTED,
            String("METHOD:") + m + String(" is deferred, not implemented"),
        )
        # ⚠ The reason must NAME the method. "ignored" without which one makes
        # the decision to defer them unmeasurable — we would never learn which
        # of the four peers actually send.
        assert_true(
            d.reason.byte_length() > m.byte_length(), "the log line names the method"
        )
    print(
        "PASS deferred-methods (COUNTER/DECLINECOUNTER/ADD/REFRESH/PUBLISH are"
        " ignored with the method NAMED in the reason)"
    )


def test_a_calendar_object_is_not_a_scheduling_message() raises:
    var stored = _stored()
    var d = decide_itip(String(""), stored, False, stored, ITIP_BIND_PASS)
    assert_equal(
        d.action,
        ITIP_REFUSE_NOT_SCHEDULING,
        "no METHOD -> a calendar OBJECT, not an invitation",
    )
    var d2 = decide_itip(
        String("SUBSCRIBE"), stored, False, stored, ITIP_BIND_PASS
    )
    assert_equal(
        d2.action, ITIP_REFUSE_NOT_SCHEDULING, "an invented METHOD is refused"
    )
    print(
        "PASS not-a-scheduling-message (an ORGANIZER+ATTENDEE .ics with no"
        " METHOD, and an unknown METHOD, both refuse)"
    )


# =============================================================================
# §3 — revision precedence.
# =============================================================================
def test_sequence_then_dtstamp_and_a_duplicate_is_not_an_update() raises:
    var stored = _stored()  # SEQUENCE 2, DTSTAMP 2026-06-01T09:00Z
    var higher_seq = _event(
        String("meet-1@komira.test"), 3, String("20260601T090000Z"),
        String("ada@komira.test"), String(""), String(""),
    )
    var same_seq_later_stamp = _event(
        String("meet-1@komira.test"), 2, String("20260601T100000Z"),
        String("ada@komira.test"), String(""), String(""),
    )
    var lower_seq_later_stamp = _event(
        String("meet-1@komira.test"), 1, String("20260601T230000Z"),
        String("ada@komira.test"), String(""), String(""),
    )
    assert_true(supersedes(higher_seq, stored), "a higher SEQUENCE supersedes")
    assert_true(
        supersedes(same_seq_later_stamp, stored),
        "equal SEQUENCE -> the later DTSTAMP wins (RFC 5546 §3.2)",
    )
    assert_false(
        supersedes(lower_seq_later_stamp, stored),
        "SEQUENCE dominates DTSTAMP — a lower revision never supersedes, no"
        " matter how recently it was stamped",
    )
    # ★ THE DUPLICATE. Email transport re-delivers. If an exact duplicate were
    # an update, every retry would overwrite an applied PARTSTAT with the
    # organiser's original NEEDS-ACTION and the user's answer would evaporate.
    assert_false(
        supersedes(stored, stored),
        "an EXACT duplicate (same SEQUENCE, same DTSTAMP) is NOT an update",
    )
    var d = decide_itip(
        String(ITIP_METHOD_REQUEST), stored, True, stored, ITIP_BIND_PASS
    )
    assert_equal(
        d.action, ITIP_IGNORE_STALE, "and the state machine ignores it"
    )
    print(
        "PASS revision-precedence (SEQUENCE dominates, DTSTAMP breaks ties, and"
        " an exact duplicate is IGNORE_STALE — a re-delivery cannot clobber an"
        " applied PARTSTAT)"
    )


def test_request_creates_then_updates() raises:
    var req = _event(
        String("meet-1@komira.test"), 0, String("20260601T090000Z"),
        String("ada@komira.test"),
        _att(String("bob@partner.test"), String("NEEDS-ACTION")), String(""),
    )
    var empty = _stored()
    var d = decide_itip(
        String(ITIP_METHOD_REQUEST), req, False, empty, ITIP_BIND_PASS
    )
    assert_equal(d.action, ITIP_CREATE, "an unknown object is CREATEd")
    var stored = _stored()
    var newer = _event(
        String("meet-1@komira.test"), 7, String("20260603T090000Z"),
        String("ada@komira.test"), String(""), String(""),
    )
    var d2 = decide_itip(
        String(ITIP_METHOD_REQUEST), newer, True, stored, ITIP_BIND_PASS
    )
    assert_equal(d2.action, ITIP_UPDATE, "a newer revision UPDATEs")
    print("PASS request-create-update (unknown -> CREATE, newer -> UPDATE)")


# =============================================================================
# §4 — ORGANIZER ownership, separate from the DKIM binding.
# =============================================================================
def test_an_authenticated_invitee_cannot_cancel_the_organisers_meeting() raises:
    var stored = _stored()  # organised by ada@komira.test
    # Bob is a legitimate invitee. He knows the UID — every attendee does. He
    # sends a CANCEL from HIS OWN domain, correctly DKIM-signed, so the binding
    # PASSES: `partner.test` really did send it and the ORGANIZER field really
    # does say partner.test.
    var bob_cancel = _event(
        String("meet-1@komira.test"), 9, String("20260604T090000Z"),
        String("bob@partner.test"), String(""), String("STATUS:CANCELLED\r\n"),
    )
    var bind = check_itip_sender_binding(
        bob_cancel.organizer,
        String("partner.test"),
        String("PASS"),
        String(ITIP_INGEST_SES),
    )
    assert_equal(
        bind.outcome,
        ITIP_BIND_PASS,
        "★ the binding PASSES — this attack is perfectly authenticated",
    )
    var d = decide_itip(
        String(ITIP_METHOD_CANCEL), bob_cancel, True, stored, bind.outcome
    )
    assert_equal(
        d.action,
        ITIP_REFUSE_ORGANIZER_MISMATCH,
        "★ and it is STILL refused — the DKIM binding proves who sent it, this"
        " control proves who owns the meeting",
    )
    assert_false(d.is_mutation(), "nothing is cancelled")
    # PAIRED POSITIVE: the real organiser's CANCEL, same shape, goes through.
    var ada_cancel = _event(
        String("meet-1@komira.test"), 9, String("20260604T090000Z"),
        String("ada@komira.test"), String(""), String("STATUS:CANCELLED\r\n"),
    )
    var d2 = decide_itip(
        String(ITIP_METHOD_CANCEL), ada_cancel, True, stored, ITIP_BIND_PASS
    )
    assert_equal(
        d2.action, ITIP_CANCEL_SERIES, "the ORGANISER's CANCEL is honoured"
    )
    # And the same substitution on a REQUEST is a hijack, refused identically.
    var bob_request = _event(
        String("meet-1@komira.test"), 9, String("20260604T090000Z"),
        String("bob@partner.test"), String(""), String(""),
    )
    var d3 = decide_itip(
        String(ITIP_METHOD_REQUEST), bob_request, True, stored, ITIP_BIND_PASS
    )
    assert_equal(
        d3.action,
        ITIP_REFUSE_ORGANIZER_MISMATCH,
        "an invitee cannot RESCHEDULE the organiser's meeting either",
    )
    print(
        "PASS organizer-ownership (a fully DKIM-bound CANCEL and REQUEST from an"
        " INVITEE's own domain are refused; the organiser's identical CANCEL is"
        " honoured — two independent controls, both needed)"
    )


def test_cancel_variants() raises:
    var stored = _stored()
    var unknown = _event(
        String("nope@komira.test"), 3, String("20260604T090000Z"),
        String("ada@komira.test"), String(""), String(""),
    )
    assert_equal(
        decide_itip(
            String(ITIP_METHOD_CANCEL), unknown, False, stored, ITIP_BIND_PASS
        ).action,
        ITIP_IGNORE_UNKNOWN_OBJECT,
        "a CANCEL for something we do not hold is ignored, not an error",
    )
    var replay = _event(
        String("meet-1@komira.test"), 1, String("20260604T090000Z"),
        String("ada@komira.test"), String(""), String(""),
    )
    assert_equal(
        decide_itip(
            String(ITIP_METHOD_CANCEL), replay, True, stored, ITIP_BIND_PASS
        ).action,
        ITIP_IGNORE_STALE,
        "a CANCEL below the stored SEQUENCE is a replay",
    )
    var one_instance = _event(
        String("meet-1@komira.test"), 4, String("20260604T090000Z"),
        String("ada@komira.test"), String(""),
        String("RECURRENCE-ID:20260622T130000Z\r\n"),
    )
    assert_equal(
        decide_itip(
            String(ITIP_METHOD_CANCEL), one_instance, True, stored,
            ITIP_BIND_PASS,
        ).action,
        ITIP_CANCEL_INSTANCE,
        "a RECURRENCE-ID scopes the CANCEL to one occurrence",
    )
    print(
        "PASS cancel-variants (unknown -> ignore; below-SEQUENCE -> replay;"
        " RECURRENCE-ID -> instance, not series)"
    )


# =============================================================================
# §5 — REPLY ingest and the builders.
# =============================================================================
def test_reply_ingest_refusals_and_the_accept() raises:
    var stored = _stored()
    # (a) no ATTENDEE at all.
    var no_att = _event(
        String("meet-1@komira.test"), 2, String("20260602T090000Z"),
        String("ada@komira.test"), String(""), String(""),
    )
    assert_equal(
        decide_itip(
            String(ITIP_METHOD_REPLY), no_att, True, stored, ITIP_BIND_PASS
        ).action,
        ITIP_REFUSE_MALFORMED,
        "a REPLY with no ATTENDEE states no response",
    )
    # (b) ★ TWO ATTENDEEs — one party setting another's PARTSTAT. Refused
    # rather than "take the first", which would make WHICH attendee is updated
    # depend on the sender's ordering.
    var two = _event(
        String("meet-1@komira.test"), 2, String("20260602T090000Z"),
        String("ada@komira.test"),
        _att(String("bob@partner.test"), String("ACCEPTED"))
        + _att(String("carol@partner.test"), String("DECLINED")),
        String(""),
    )
    assert_equal(
        decide_itip(
            String(ITIP_METHOD_REPLY), two, True, stored, ITIP_BIND_PASS
        ).action,
        ITIP_REFUSE_MALFORMED,
        "a multi-ATTENDEE REPLY is refused, not resolved by position",
    )
    # (c) a replier who is not on the event.
    var stranger = _event(
        String("meet-1@komira.test"), 2, String("20260602T090000Z"),
        String("ada@komira.test"),
        _att(String("mallory@evil.test"), String("ACCEPTED")), String(""),
    )
    assert_equal(
        decide_itip(
            String(ITIP_METHOD_REPLY), stranger, True, stored, ITIP_BIND_PASS
        ).action,
        ITIP_REFUSE_MALFORMED,
        "a REPLY from a non-attendee cannot add them to the event",
    )
    # (d) an unstorable PARTSTAT.
    var weird = _event(
        String("meet-1@komira.test"), 2, String("20260602T090000Z"),
        String("ada@komira.test"),
        _att(String("bob@partner.test"), String("X-MAYBE")), String(""),
    )
    assert_equal(
        decide_itip(
            String(ITIP_METHOD_REPLY), weird, True, stored, ITIP_BIND_PASS
        ).action,
        ITIP_REFUSE_MALFORMED,
        "an unknown PARTSTAT is refused rather than stored",
    )
    # (e) a REPLY to an OLDER revision than we hold.
    var stale = _event(
        String("meet-1@komira.test"), 1, String("20260602T090000Z"),
        String("ada@komira.test"),
        _att(String("bob@partner.test"), String("ACCEPTED")), String(""),
    )
    assert_equal(
        decide_itip(
            String(ITIP_METHOD_REPLY), stale, True, stored, ITIP_BIND_PASS
        ).action,
        ITIP_IGNORE_STALE,
        "a REPLY against a superseded SEQUENCE answers a changed question",
    )
    # ★ (f) THE PAIRED ACCEPT — without it every refusal above is vacuous.
    var good = _event(
        String("meet-1@komira.test"), 2, String("20260602T090000Z"),
        String("ada@komira.test"),
        _att(String("carol@partner.test"), String("DECLINED")), String(""),
    )
    var d = decide_itip(
        String(ITIP_METHOD_REPLY), good, True, stored, ITIP_BIND_PASS
    )
    assert_equal(d.action, ITIP_SET_PARTSTAT, "a well-formed REPLY is applied")
    assert_equal(
        d.attendee_index,
        1,
        "and names the STORED index of the replier (carol is attendee 1)",
    )
    assert_equal(
        d.partstat_value, String("DECLINED"), "with the PARTSTAT to write"
    )
    assert_true(d.is_mutation(), "SET_PARTSTAT is a mutation")
    print(
        "PASS reply-ingest (no-ATTENDEE, multi-ATTENDEE, non-attendee replier,"
        " unknown PARTSTAT and a stale SEQUENCE are all refused/ignored; a"
        " well-formed REPLY resolves to the right STORED attendee index)"
    )


def test_build_reply_echoes_unaltered_and_carries_one_attendee() raises:
    var request = _stored()
    var reply = build_reply(
        request,
        String("bob@partner.test"),
        String(PARTSTAT_ACCEPTED),
        Int64(1790000000),
    )
    assert_equal(reply.method, String("REPLY"), "METHOD:REPLY")
    var ev = reply.events[0].copy()
    # RFC 5546 §3.2.3 — exactly the replier.
    assert_equal(
        len(ev.attendees), 1, "a REPLY carries exactly ONE ATTENDEE, the replier"
    )
    assert_equal(ev.attendees[0].email, String("bob@partner.test"), "who")
    assert_equal(ev.attendees[0].partstat, String("ACCEPTED"), "the answer")
    assert_false(
        ev.attendees[0].rsvp,
        "RSVP is cleared — the question has been answered",
    )
    # Echoed UNALTERED.
    assert_equal(ev.uid, request.uid, "UID echoed")
    assert_equal(ev.sequence, request.sequence, "SEQUENCE echoed UNALTERED")
    assert_equal(
        ev.organizer.email, request.organizer.email, "ORGANIZER echoed"
    )
    # NEW DTSTAMP — this message's own time, the organiser's tiebreaker.
    assert_equal(Int(ev.dtstamp), 1790000000, "DTSTAMP is the REPLY's own")
    assert_true(
        ev.dtstamp != request.dtstamp, "and is not the request's DTSTAMP"
    )
    # No DTSTART — which is also what lets a REPLY work for a TZID-local request.
    assert_equal(Int(ev.dtstart), 0, "a REPLY restates no timing")
    var bytes = emit_vcalendar(reply, String(ICAL_PRODID))
    assert_true(bytes.byte_length() > 0, "and it emits")
    # A non-attendee cannot be made to reply.
    var raised = False
    try:
        var _u = build_reply(
            request, String("mallory@evil.test"), String(PARTSTAT_ACCEPTED),
            Int64(1790000000),
        )
        _ = _u
    except:
        raised = True
    assert_true(raised, "build_reply refuses a non-attendee replier")
    print(
        "PASS build-reply (exactly one ATTENDEE with the new PARTSTAT and RSVP"
        " cleared; UID/SEQUENCE/ORGANIZER echoed unaltered; a NEW DTSTAMP; no"
        " DTSTART; and a non-attendee replier is refused)"
    )


def test_build_cancel_increments_sequence() raises:
    var stored = _stored()  # SEQUENCE 2
    var cancel = build_cancel(stored, Int64(1790000000), False)
    assert_equal(cancel.method, String("CANCEL"), "METHOD:CANCEL")
    var ev = cancel.events[0].copy()
    # ★ THE INCREMENT IS THE WHOLE MESSAGE. A CANCEL reusing SEQUENCE 2 is, to
    # every conforming peer, a duplicate of a revision it already applied — it
    # is dropped, the meeting stays on the invitee's calendar, and NOTHING
    # anywhere reports a failure.
    assert_equal(
        Int(ev.sequence),
        Int(stored.sequence) + 1,
        "a CANCEL INCREMENTS SEQUENCE (RFC 5546 §3.2.5)",
    )
    assert_equal(ev.status, String("CANCELLED"), "STATUS:CANCELLED")
    assert_true(ev.is_cancelled(), "and the predicate agrees")
    assert_equal(len(ev.attendees), 2, "attendees are echoed so each finds self")
    assert_false(ev.attendees[0].rsvp, "with RSVP cleared")
    # Our own state machine must accept it — the builder and the ingest half
    # have to agree, or we send messages we would ourselves reject.
    var d = decide_itip(
        String(ITIP_METHOD_CANCEL), ev, True, stored, ITIP_BIND_PASS
    )
    assert_equal(
        d.action,
        ITIP_CANCEL_SERIES,
        "★ our own CANCEL is accepted by our own state machine",
    )
    # Instance-cancel on a non-recurring event is refused, not silently widened.
    var raised = False
    try:
        var _u = build_cancel(stored, Int64(1790000000), True)
        _ = _u
    except:
        raised = True
    assert_true(
        raised,
        "cancelling 'one occurrence' of an event with no RECURRENCE-ID is"
        " refused, never widened to the series",
    )
    print(
        "PASS build-cancel (SEQUENCE incremented, STATUS:CANCELLED, attendees"
        " echoed with RSVP cleared; the message our builder produces is accepted"
        " by our own ingest; an instance-cancel with no RECURRENCE-ID refuses)"
    )


def test_build_request_stamps_but_does_not_guess_sequence() raises:
    var ev = _stored()
    var before = ev.sequence
    var req = build_request(ev^, Int64(1790000001))
    assert_equal(req.method, String("REQUEST"), "METHOD:REQUEST")
    var out = req.events[0].copy()
    assert_equal(Int(out.dtstamp), 1790000001, "DTSTAMP is stamped here")
    # ⚠ SEQUENCE is NOT touched. RFC 5546 §3.2 requires it to increment when
    # DTSTART/DTEND/DURATION/RRULE/RDATE/EXDATE/STATUS change — a comparison
    # this function cannot make, because it is not given the previous revision.
    # Guessing either spams invitees with reschedule notices or suppresses a
    # real one.
    assert_equal(
        out.sequence, before, "SEQUENCE is the caller's fact, not a guess"
    )
    print(
        "PASS build-request (DTSTAMP is stamped; SEQUENCE is left to the caller,"
        " who is the only party that can see whether the timing changed)"
    )


def test_partstat_validation_is_fail_closed() raises:
    assert_true(is_valid_partstat(String("ACCEPTED")), "ACCEPTED")
    assert_true(is_valid_partstat(String("DECLINED")), "DECLINED")
    assert_true(is_valid_partstat(String("TENTATIVE")), "TENTATIVE")
    assert_true(is_valid_partstat(String("DELEGATED")), "DELEGATED")
    assert_true(is_valid_partstat(String("NEEDS-ACTION")), "NEEDS-ACTION")
    assert_false(is_valid_partstat(String("")), "absent is not a value")
    assert_false(is_valid_partstat(String("accepted")), "case-exact")
    assert_false(is_valid_partstat(String("X-MAYBE")), "x-name refused")
    print(
        "PASS partstat-validation (the five RFC 5545 §3.2.12 values, exactly;"
        " absent, lowercase and x-name extensions all refused)"
    )


def main() raises:
    test_uncovered_ingest_paths_can_never_pass()
    test_non_pass_dkim_verdict_downgrades()
    test_domain_mismatch_is_REFUSE_not_downgrade()
    test_domain_of_takes_the_last_at()
    test_no_method_mutates_without_a_PASS_binding()
    test_deferred_methods_are_ignored_by_name()
    test_a_calendar_object_is_not_a_scheduling_message()
    test_sequence_then_dtstamp_and_a_duplicate_is_not_an_update()
    test_request_creates_then_updates()
    test_an_authenticated_invitee_cannot_cancel_the_organisers_meeting()
    test_cancel_variants()
    test_reply_ingest_refusals_and_the_accept()
    test_build_reply_echoes_unaltered_and_carries_one_attendee()
    test_build_cancel_increments_sequence()
    test_build_request_stamps_but_does_not_guess_sequence()
    test_partstat_validation_is_fail_closed()
    print(
        "PASS test_itip_state_machine (the sender binding fails closed on the"
        " three uncovered ingest paths and distinguishes REFUSE from DOWNGRADE;"
        " no method mutates without a PASS binding; SEQUENCE/DTSTAMP precedence"
        " treats a re-delivery as a duplicate; an authenticated INVITEE cannot"
        " cancel or reschedule the organiser's meeting while the organiser can;"
        " and the builders produce messages our own ingest accepts)"
    )
