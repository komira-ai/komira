# =============================================================================
# tests/test_mail_ingest_hazards.mojo — the falsifiers for the three ways the
#   inbound-mail path silently loses customer mail.
# =============================================================================
#
# WHAT EACH TEST IS EVIDENCE ABOUT. The fixtures reproduce the shape of a real
# SES inbound account, not a design opinion:
#
#   HAZARD 1 (one active route table) — the active table carries a different
#     name than the one a client defaults to. Activating the default would take
#     inbound mail down for every customer, silently.
#   HAZARD 2 (exact whole-string recipients) — a domain served at its apex and
#     its `inbound.` subdomain needs TWO rules, with two separate object-key
#     prefixes, because neither covers the other.
#   HAZARD 3 (DKIM rotation on create) — an Easy-DKIM identity carries 3 tokens;
#     a recreate mints 3 fresh ones and unverifies the domain.
#
# ⚠ THESE TESTS ASSERT ON THE REFUSAL MESSAGE'S CONTENT, not merely that
# something raised. A refusal whose text does not name the live table / the
# missing recipient sends the reader off to re-derive the account state by hand,
# which is the state this whole package exists to remove. So "it raised" is not
# the property under test; "it raised AND said which object is at risk" is.
#
# PURE — no socket, no credential, no mock. Every function under test is a
# decision over values, so these run on the farm with nothing host-bound.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_mail_ingest.mail_ingest import (
    ACTIVATION_NOOP,
    ACTIVATION_BOOTSTRAP,
    IDENTITY_ABSENT,
    IDENTITY_VERIFIED,
    MailRecipient,
    recipients_for_domain,
    MailDropTarget,
    MailIngestRoute,
    MailRouteTable,
    assert_route_deliverable,
    assert_table_covers,
    plan_activation,
    DkimRecord,
    MailIdentity,
    dkim_republish_required,
)


comptime _DOMAIN: String = "example.com"
comptime _SUB: String = "inbound.example.com"
comptime _BUCKET: String = "example-mail-inbound-111122223333-us-east-1"
comptime _TOPIC: String = "example-mail-inbound"
comptime _LIVE_TABLE: String = "example-mail-inbound"


def _route(recipient: String, enabled: Bool = True) raises -> MailIngestRoute:
    """One deliverable route for `recipient`, shaped like a real one: the drop
    prefix is the recipient plus a slash."""
    return MailIngestRoute(
        MailRecipient.parse(recipient),
        MailDropTarget(String(_BUCKET), recipient + "/"),
        String(_TOPIC),
        enabled,
    )


def _live_table() raises -> MailRouteTable:
    """A converged route table: the active set with two enabled rules — the apex
    and the `inbound.` subdomain, each with its own object-key prefix."""
    var routes = List[MailIngestRoute]()
    routes.append(_route(String(_SUB)))
    routes.append(_route(String(_DOMAIN)))
    return MailRouteTable(String(_LIVE_TABLE), True, routes^)


# =============================================================================
# HAZARD 2 — a recipient is an EXACT WHOLE STRING.
# =============================================================================
def test_parent_domain_does_not_cover_its_subdomain() raises:
    """⛔ THE TRAP. A table holding ONLY the apex `example.com` must be reported
    as NOT covering `inbound.example.com`.

    A coverage check built on suffix matching passes here and loses the
    subdomain's mail."""
    var routes = List[MailIngestRoute]()
    routes.append(_route(String(_DOMAIN)))  # the APEX ONLY
    var table = MailRouteTable(String(_LIVE_TABLE), True, routes^)

    # The apex itself IS covered — the check is not vacuously refusing everything.
    var apex_only = List[MailRecipient]()
    apex_only.append(MailRecipient.parse(String(_DOMAIN)))
    assert_table_covers(table, apex_only)

    # ...but the subdomain is NOT.
    var need = recipients_for_domain(String(_DOMAIN), String("inbound"))
    assert_equal(
        len(need), 2, "a domain needs TWO recipients: the apex and inbound."
    )
    var refused = False
    var msg = String("")
    try:
        assert_table_covers(table, need)
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused,
        "assert_table_covers MUST refuse a table that holds only the apex when"
        " the subdomain is also required — the parent covers NEITHER direction",
    )
    assert_true(
        String(_SUB) in msg,
        "the refusal must NAME the uncovered recipient; got: " + msg,
    )
    assert_true(
        String(_DOMAIN) in msg,
        "the refusal must also list the recipients that ARE present, or the"
        " reader cannot see that it is the subdomain specifically that is"
        " missing; got: " + msg,
    )
    print("  test_parent_domain_does_not_cover_its_subdomain: PASS")


def test_subdomain_rule_does_not_cover_the_parent() raises:
    """The OTHER direction, which is just as false and easier to forget: a table
    holding only `inbound.example.com` does not receive for the apex."""
    var routes = List[MailIngestRoute]()
    routes.append(_route(String(_SUB)))
    var table = MailRouteTable(String(_LIVE_TABLE), True, routes^)

    var need = List[MailRecipient]()
    need.append(MailRecipient.parse(String(_DOMAIN)))
    var refused = False
    var msg = String("")
    try:
        assert_table_covers(table, need)
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused,
        "a subdomain route must NOT be reported as covering the parent domain",
    )
    assert_true(
        String(_DOMAIN) in msg, "the refusal must name the apex; got: " + msg
    )
    print("  test_subdomain_rule_does_not_cover_the_parent: PASS")


def test_a_disabled_route_contributes_no_coverage() raises:
    """⛔ A DISABLED ROUTE IS INERT — the provider rejects at RCPT exactly as if
    it did not exist. Counting it as coverage reports a domain live while nothing
    can be delivered to it, which is strictly worse than reporting it missing."""
    var routes = List[MailIngestRoute]()
    routes.append(_route(String(_DOMAIN), False))  # present but DISABLED
    var table = MailRouteTable(String(_LIVE_TABLE), True, routes^)

    assert_false(
        table.receives_for(MailRecipient.parse(String(_DOMAIN))),
        "a DISABLED route must not count as receiving for its recipient",
    )
    assert_equal(
        len(table.enabled_recipients()),
        0,
        "enabled_recipients must exclude disabled routes",
    )
    var need = List[MailRecipient]()
    need.append(MailRecipient.parse(String(_DOMAIN)))
    var refused = False
    try:
        assert_table_covers(table, need)
    except e:
        refused = True
    assert_true(
        refused, "a table whose only route is DISABLED covers nothing"
    )
    print("  test_a_disabled_route_contributes_no_coverage: PASS")


def test_recipient_parse_refuses_the_shapes_that_silently_match_nothing() raises:
    """Each refused form is one a caller reaches for when it believes suffix
    matching exists. All four are matched LITERALLY by the provider, so the rule
    exists and receives nothing — the worst failure mode available."""
    var cases = List[String]()
    cases.append(String("*.example.com"))  # no wildcard exists
    cases.append(String(".example.com"))  # the "suffix" shape
    cases.append(String("example.com."))  # FQDN trailing dot
    cases.append(String("example domain.com"))  # embedded whitespace
    cases.append(String(""))  # empty == catch-all/nothing

    for i in range(len(cases)):
        var refused = False
        try:
            _ = MailRecipient.parse(cases[i])
        except e:
            refused = True
        assert_true(
            refused,
            "MailRecipient.parse must REFUSE '"
            + cases[i]
            + "' — it is matched literally and would receive nothing",
        )

    # ...and the legitimate forms still parse, so the guard is not vacuous.
    assert_equal(
        MailRecipient.parse(String(_DOMAIN)).value,
        String(_DOMAIN),
        "a bare domain must parse",
    )
    assert_equal(
        MailRecipient.parse(String("user@" + _DOMAIN)).value,
        String("user@" + _DOMAIN),
        "a full address must parse",
    )
    print(
        "  test_recipient_parse_refuses_the_shapes_that_silently_match_nothing:"
        " PASS"
    )


def test_recipient_comparison_folds_case_and_only_case() raises:
    """Domains are case-insensitive (RFC 1035 §2.3.3), so `EXAMPLE.com` and
    `example.com` are ONE recipient. Nothing else is normalized — a normalizer
    that also stripped dots or labels would quietly turn one recipient into a
    different one."""
    var a = MailRecipient.parse(String("Example.COM"))
    var b = MailRecipient.parse(String(_DOMAIN))
    assert_true(a.equals(b), "recipient comparison must fold ASCII case")
    var c = MailRecipient.parse(String(_SUB))
    assert_false(
        a.equals(c),
        "case folding must NOT collapse distinct recipients — the apex and the"
        " subdomain stay different",
    )
    print("  test_recipient_comparison_folds_case_and_only_case: PASS")


# =============================================================================
# HAZARD 1 — the account has exactly ONE active route table.
# =============================================================================
def test_activation_refuses_to_displace_a_different_live_table() raises:
    """⛔⛔ THE DISPLACEMENT HAZARD, AS A TEST. The live active table is
    `example-mail-inbound` with 2 enabled rules; a client's default name is
    `example-inbound`. Activating the default deactivates the live table for
    every customer at once and reports success.

    The refusal must name BOTH tables and the route count, because the operator
    reading it has to decide whether to adopt the live name or retire it — and
    cannot decide that from the word "refused"."""
    var refused = False
    var msg = String("")
    try:
        _ = plan_activation(String(_LIVE_TABLE), 2, String("example-inbound"))
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused,
        "plan_activation MUST refuse to activate a table while a DIFFERENT one"
        " is live — the account permits exactly one, so this silently stops"
        " inbound mail for every recipient the live table serves",
    )
    assert_true(
        String(_LIVE_TABLE) in msg,
        "the refusal must name the LIVE table that would be displaced; got: "
        + msg,
    )
    assert_true(
        String("example-inbound") in msg,
        "the refusal must name the table that was about to be activated; got: "
        + msg,
    )
    assert_true(
        String("2") in msg,
        "the refusal must state HOW MANY routes would stop receiving; got: "
        + msg,
    )
    print("  test_activation_refuses_to_displace_a_different_live_table: PASS")


def test_activation_is_a_noop_when_ours_is_already_active() raises:
    """The steady state must NOT refuse — a gate that refuses the converged case
    is a gate nobody can run twice, and would be indistinguishable from the
    dangerous case at the call site."""
    assert_equal(
        plan_activation(String(_LIVE_TABLE), 2, String(_LIVE_TABLE)),
        ACTIVATION_NOOP,
        "activating the table that is ALREADY active is a no-op, not a refusal",
    )
    print("  test_activation_is_a_noop_when_ours_is_already_active: PASS")


def test_activation_bootstraps_only_when_nothing_is_active() raises:
    """The ONE safe activation: no table is active, so activating ours takes
    nothing away from anyone.

    ⚠ The bootstrap arm is gated on the live NAME being empty, NOT on the route
    count. An active table with zero routes still belongs to someone, and
    displacing it is still displacing it — so that case must still refuse."""
    assert_equal(
        plan_activation(String(""), 0, String(_LIVE_TABLE)),
        ACTIVATION_BOOTSTRAP,
        "an account with NO active table is the safe bootstrap case",
    )
    var refused = False
    try:
        # A live table that is active but currently EMPTY. Route count 0 must not
        # be mistaken for "nothing is active".
        _ = plan_activation(String("someone-elses-table"), 0, String(_LIVE_TABLE))
    except e:
        refused = True
    assert_true(
        refused,
        "an ACTIVE table with zero routes still belongs to someone — a zero"
        " route count must NOT be treated as the bootstrap case",
    )
    print("  test_activation_bootstraps_only_when_nothing_is_active: PASS")


def test_activation_refuses_an_empty_desired_name() raises:
    """An empty desired name cannot be compared against the live table, so
    proceeding means activating an unnamed table over whatever is serving."""
    var refused = False
    try:
        _ = plan_activation(String(_LIVE_TABLE), 2, String(""))
    except e:
        refused = True
    assert_true(
        refused, "plan_activation must refuse an EMPTY desired table name"
    )
    print("  test_activation_refuses_an_empty_desired_name: PASS")


# =============================================================================
# HAZARD 3 — re-creating an identity rotates its DKIM keys.
# =============================================================================
def _identity(domain: String, tokens: List[String]) -> MailIdentity:
    """An identity carrying one CNAME record per Easy-DKIM token — the real
    shape (3 tokens, SigningAttributesOrigin AWS_SES)."""
    var recs = List[DkimRecord]()
    for i in range(len(tokens)):
        recs.append(
            DkimRecord(
                tokens[i] + "._domainkey." + domain,
                String("CNAME"),
                tokens[i] + ".dkim.amazonses.com",
            )
        )
    return MailIdentity(domain, IDENTITY_VERIFIED, recs^)


def _tokens(a: String, b: String, c: String) -> List[String]:
    var t = List[String]()
    t.append(a)
    t.append(b)
    t.append(c)
    return t^


def test_recreating_an_identity_demands_a_dns_republish() raises:
    """⛔ EASY DKIM MINTS FRESH TOKENS ON EVERY CREATION. The provider reports the
    create as a success and surfaces nothing about the rotation, so it must be
    DERIVED from the records — which is what this asserts."""
    var before = _identity(
        String(_DOMAIN), _tokens(String("aaa"), String("bbb"), String("ccc"))
    )
    var after = _identity(
        String(_DOMAIN), _tokens(String("xxx"), String("yyy"), String("zzz"))
    )
    assert_true(
        dkim_republish_required(before, after),
        "three NEW tokens after a recreate MUST demand a DNS republish — the"
        " previously-published records now verify nothing",
    )
    print("  test_recreating_an_identity_demands_a_dns_republish: PASS")


def test_an_unchanged_identity_demands_no_republish() raises:
    """The adopt path must NOT demand a needless republish — otherwise every
    re-run of onboarding rewrites DNS, and the signal stops meaning anything."""
    var t = _tokens(String("aaa"), String("bbb"), String("ccc"))
    var before = _identity(String(_DOMAIN), t)
    var after = _identity(String(_DOMAIN), t)
    assert_false(
        dkim_republish_required(before, after),
        "an ADOPTED identity with identical records needs no republish",
    )
    print("  test_an_unchanged_identity_demands_no_republish: PASS")


def test_token_reorder_is_not_a_rotation() raises:
    """Providers do not promise token ORDER. Treating a reorder as a rotation
    would make every read demand a republish, which trains the operator to
    ignore the signal — the way a real rotation then gets missed."""
    var before = _identity(
        String(_DOMAIN), _tokens(String("aaa"), String("bbb"), String("ccc"))
    )
    var after = _identity(
        String(_DOMAIN), _tokens(String("ccc"), String("aaa"), String("bbb"))
    )
    assert_false(
        dkim_republish_required(before, after),
        "a REORDER of the same tokens is not a rotation",
    )
    print("  test_token_reorder_is_not_a_rotation: PASS")


def test_a_partial_token_change_is_a_rotation() raises:
    """One changed token out of three still leaves the domain unable to verify
    with the published set. A count-only comparison passes here and misses it."""
    var before = _identity(
        String(_DOMAIN), _tokens(String("aaa"), String("bbb"), String("ccc"))
    )
    var after = _identity(
        String(_DOMAIN), _tokens(String("aaa"), String("bbb"), String("ZZZ"))
    )
    assert_true(
        dkim_republish_required(before, after),
        "a SINGLE changed token is a rotation — the record count is unchanged,"
        " so a count-only comparison would miss it",
    )
    print("  test_a_partial_token_change_is_a_rotation: PASS")


def test_creating_from_absent_is_a_rotation() raises:
    """The from-scratch onboarding path: an ABSENT identity has no records, so
    the first create always demands a publish."""
    var before = MailIdentity.absent(String(_DOMAIN))
    assert_equal(
        before.state, IDENTITY_ABSENT, "absent() must report ABSENT"
    )
    assert_false(before.is_verified(), "an absent identity is not verified")
    var after = _identity(
        String(_DOMAIN), _tokens(String("aaa"), String("bbb"), String("ccc"))
    )
    assert_true(
        dkim_republish_required(before, after),
        "creating an identity from ABSENT always demands a DNS publish",
    )
    print("  test_creating_from_absent_is_a_rotation: PASS")


def test_comparing_two_different_domains_is_refused() raises:
    """A rotation is a statement about ONE domain over time. Answering it across
    two domains is meaningless in either direction, so it is a caller bug and
    must raise rather than return a plausible Bool."""
    var a = _identity(
        String(_DOMAIN), _tokens(String("aaa"), String("bbb"), String("ccc"))
    )
    var b = _identity(
        String("spoolr.com"),
        _tokens(String("aaa"), String("bbb"), String("ccc")),
    )
    var refused = False
    var msg = String("")
    try:
        _ = dkim_republish_required(a, b)
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused, "comparing identities for DIFFERENT domains must refuse"
    )
    assert_true(
        String("spoolr.com") in msg and String(_DOMAIN) in msg,
        "the refusal must name BOTH domains; got: " + msg,
    )
    print("  test_comparing_two_different_domains_is_refused: PASS")


# =============================================================================
# Route deliverability — the envelope carrier.
# =============================================================================
def test_a_route_with_no_notify_channel_is_refused() raises:
    """⛔ The stored message body does NOT contain the SMTP envelope. Without a
    notification carrying the recipient list the provider observed, the dropped
    object is unattributable and every message becomes unroutable — while the
    provider accepts the mail and reports nothing wrong."""
    var bad = MailIngestRoute(
        MailRecipient.parse(String(_DOMAIN)),
        MailDropTarget(String(_BUCKET), String(_DOMAIN) + "/"),
        String(""),  # NO notify channel
        True,
    )
    var refused = False
    var msg = String("")
    try:
        assert_route_deliverable(bad)
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused, "a route with no notify channel must be REFUSED"
    )
    assert_true(
        String("envelope") in msg,
        "the refusal must say WHY a notify channel is load-bearing (the body"
        " carries no envelope); got: " + msg,
    )
    # ...and a well-formed route passes, so the guard is not vacuous.
    assert_route_deliverable(_route(String(_DOMAIN)))
    print("  test_a_route_with_no_notify_channel_is_refused: PASS")


def test_a_route_with_no_drop_container_is_refused() raises:
    """A route with nowhere to write is accepted at RCPT and discards the body."""
    var bad = MailIngestRoute(
        MailRecipient.parse(String(_DOMAIN)),
        MailDropTarget(String(""), String(_DOMAIN) + "/"),
        String(_TOPIC),
        True,
    )
    var refused = False
    try:
        assert_route_deliverable(bad)
    except e:
        refused = True
    assert_true(refused, "a route with no drop container must be REFUSED")
    print("  test_a_route_with_no_drop_container_is_refused: PASS")


# =============================================================================
# A converged account, as a single end-to-end assertion.
# =============================================================================
def test_a_converged_table_covers_its_domain() raises:
    """The positive control, built from a converged state: the active table
    `example-mail-inbound` with its two enabled rules covers both recipients the
    domain needs, and its activation is a no-op.

    This is what stops the suite from being a pile of refusals that would also
    "pass" against an implementation that refuses everything."""
    var table = _live_table()
    assert_true(table.active, "the converged table is the ACTIVE one")
    var need = recipients_for_domain(String(_DOMAIN), String("inbound"))
    assert_table_covers(table, need)
    assert_equal(
        len(table.enabled_recipients()),
        2,
        "both live rules are enabled",
    )
    assert_equal(
        plan_activation(String(_LIVE_TABLE), 2, String(_LIVE_TABLE)),
        ACTIVATION_NOOP,
        "the converged account needs no activation",
    )
    for i in range(len(table.routes)):
        assert_route_deliverable(table.routes[i])
    print(
        "  test_a_converged_table_covers_its_domain: PASS"
    )


def main() raises:
    print("test_mail_ingest_hazards:")
    test_parent_domain_does_not_cover_its_subdomain()
    test_subdomain_rule_does_not_cover_the_parent()
    test_a_disabled_route_contributes_no_coverage()
    test_recipient_parse_refuses_the_shapes_that_silently_match_nothing()
    test_recipient_comparison_folds_case_and_only_case()
    test_activation_refuses_to_displace_a_different_live_table()
    test_activation_is_a_noop_when_ours_is_already_active()
    test_activation_bootstraps_only_when_nothing_is_active()
    test_activation_refuses_an_empty_desired_name()
    test_recreating_an_identity_demands_a_dns_republish()
    test_an_unchanged_identity_demands_no_republish()
    test_token_reorder_is_not_a_rotation()
    test_a_partial_token_change_is_a_rotation()
    test_creating_from_absent_is_a_rotation()
    test_comparing_two_different_domains_is_refused()
    test_a_route_with_no_notify_channel_is_refused()
    test_a_route_with_no_drop_container_is_refused()
    test_a_converged_table_covers_its_domain()
    print("test_mail_ingest_hazards: ALL PASS")
