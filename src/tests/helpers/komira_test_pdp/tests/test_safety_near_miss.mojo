# =============================================================================
# test_safety_near_miss.mojo: every comparison the safety conditions and the
# bearer check make is exact, from both sides.
# =============================================================================
#
# For each comparison, `near_misses` of the expected value (a prefix, an
# extension at either end, a suffix, a case variant, "", and one byte
# replaced at the first, a middle and the last position) are tried on one
# side while the other side holds the true value, and then the other way
# round. Each must be refused with that comparison's own reason code;
# every miss is collected into one assertion. A comparison written as
# `startswith`, `endswith`, a case-insensitive match or a loop that skips a
# byte accepts at least one of them.
#
#   comparison                                 body side        token side
#   subject.id == subject token sub            subject.id       sub
#   subject.type == subject token type         subject.type     (two values)
#   subject token aud == context.audience      context.audience aud
#   context.audience == bearer client_id       (see below)      client_id
#   bearer aud == the decision point's         (fixed)          aud
#
# For `context.audience == bearer client_id` the body side moves the
# audience and the subject token's `aud` together, so only that
# comparison can refuse.
#
# Planted defects (each red here): `startswith` for the subject comparison;
# the bearer audience compared case-insensitively.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_test_pdp import (
    REASON_AUDIENCE_MISMATCH,
    REASON_BEARER_AUDIENCE,
    REASON_CLIENT_MISMATCH,
    REASON_DECIDED,
    REASON_SUBJECT_MISMATCH,
    REASON_SUBJECT_TYPE_MISMATCH,
    SUBJECT_TYPE_CLIENT,
    SUBJECT_TYPE_USER,
    PdpReply,
    PolicyRule,
    TestPdp,
    TokenTable,
    VerifiedToken,
    evaluation_json,
    near_misses,
)

comptime NOW: Int64 = 1000
comptime EXP: Int64 = 2000


def _pdp(var table: TokenTable) raises -> TestPdp[TokenTable]:
    var pdp = TestPdp(table^, "pdp", NOW)
    pdp.declare_kind("note")
    pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", "note", "n1"))
    return pdp^


def _base_table() raises -> TokenTable:
    var t = TokenTable()
    t.add("bearer", VerifiedToken(SUBJECT_TYPE_CLIENT, "notes", "pdp", "notes", EXP))
    t.add("subject", VerifiedToken(SUBJECT_TYPE_USER, "alice", "notes", "web", EXP))
    return t^


def _ask(
    mut pdp: TestPdp[TokenTable],
    bearer: String,
    subject_type: String,
    subject_id: String,
    subject_token: String,
    audience: String,
) -> PdpReply:
    var body = evaluation_json(
        subject_type, subject_id, "S", "read", "note", "n1", audience
    ).replace("<<S>>", subject_token)
    var bytes = List[UInt8]()
    bytes.extend(Span(body.as_bytes()))
    return pdp.handle(
        "POST", "/access/v1/evaluation", String("Bearer ") + bearer, bytes
    )


def _expect(
    reply: PdpReply, reason: String, label: String, value: String
) -> String:
    if reply.reason == reason:
        return String("")
    return label + " [" + value + "] -> " + reply.reason + "\n"


def test_control_is_an_allow() raises:
    # Every row below differs from this one in one value only.
    var pdp = _pdp(_base_table())
    var r = _ask(pdp, "bearer", SUBJECT_TYPE_USER, "alice", "subject", "notes")
    assert_equal(r.reason, REASON_DECIDED)
    assert_equal(r.body, String('{"decision":true}'))


def test_subject_id_body_side() raises:
    var misses = String("")
    var pdp = _pdp(_base_table())
    var values = near_misses("alice")
    for i in range(len(values)):
        var r = _ask(pdp, "bearer", SUBJECT_TYPE_USER, values[i], "subject", "notes")
        misses += _expect(r, REASON_SUBJECT_MISMATCH, "subject.id", values[i])
    assert_equal(misses, String(""), "accepted:\n" + misses)


def test_subject_id_token_side() raises:
    # The body says alice; the token's sub is a near miss. "" is not a sub
    # a table can hold (it refuses an empty sub), so it is skipped.
    var misses = String("")
    var values = near_misses("alice")
    var table = _base_table()
    for i in range(len(values)):
        if values[i].byte_length() == 0:
            continue
        table.add(
            String("s") + String(i),
            VerifiedToken(SUBJECT_TYPE_USER, values[i], "notes", "web", EXP),
        )
    var pdp = _pdp(table^)
    for i in range(len(values)):
        if values[i].byte_length() == 0:
            continue
        var r = _ask(pdp, "bearer", SUBJECT_TYPE_USER, "alice", String("s") + String(i), "notes")
        misses += _expect(r, REASON_SUBJECT_MISMATCH, "sub", values[i])
    assert_equal(misses, String(""), "accepted:\n" + misses)


def test_subject_type_body_side() raises:
    var misses = String("")
    var pdp = _pdp(_base_table())
    var values = near_misses(SUBJECT_TYPE_USER)
    values.append(SUBJECT_TYPE_CLIENT)
    for i in range(len(values)):
        var r = _ask(pdp, "bearer", values[i], "alice", "subject", "notes")
        misses += _expect(r, REASON_SUBJECT_TYPE_MISMATCH, "subject.type", values[i])
    assert_equal(misses, String(""), "accepted:\n" + misses)


def test_subject_type_token_side() raises:
    # A client token whose sub is alice, named as a user.
    var table = _base_table()
    table.add("c", VerifiedToken(SUBJECT_TYPE_CLIENT, "alice", "notes", "alice", EXP))
    var pdp = _pdp(table^)
    var r = _ask(pdp, "bearer", SUBJECT_TYPE_USER, "alice", "c", "notes")
    assert_equal(r.reason, REASON_SUBJECT_TYPE_MISMATCH)
    # Named as what it is, it reaches the decision (the user rule does not
    # hold for a client subject).
    var ok = _ask(pdp, "bearer", SUBJECT_TYPE_CLIENT, "alice", "c", "notes")
    assert_equal(ok.reason, REASON_DECIDED)
    assert_equal(ok.body, String('{"decision":false}'))


def test_audience_body_side() raises:
    # context.audience moves alone: the subject token's aud stays "notes",
    # so the first comparison that refuses is token aud == audience.
    var misses = String("")
    var pdp = _pdp(_base_table())
    var values = near_misses("notes")
    for i in range(len(values)):
        var r = _ask(pdp, "bearer", SUBJECT_TYPE_USER, "alice", "subject", values[i])
        misses += _expect(r, REASON_AUDIENCE_MISMATCH, "context.audience", values[i])
    assert_equal(misses, String(""), "accepted:\n" + misses)


def test_audience_token_side() raises:
    var misses = String("")
    var values = near_misses("notes")
    var table = _base_table()
    for i in range(len(values)):
        table.add(
            String("s") + String(i),
            VerifiedToken(SUBJECT_TYPE_USER, "alice", values[i], "web", EXP),
        )
    var pdp = _pdp(table^)
    for i in range(len(values)):
        var r = _ask(pdp, "bearer", SUBJECT_TYPE_USER, "alice", String("s") + String(i), "notes")
        misses += _expect(r, REASON_AUDIENCE_MISMATCH, "token aud", values[i])
    assert_equal(misses, String(""), "accepted:\n" + misses)


def test_client_body_side() raises:
    # The audience and the subject token's aud move together, so they agree
    # with each other and only the bearer's client_id ("notes") differs.
    var misses = String("")
    var values = near_misses("notes")
    var table = _base_table()
    for i in range(len(values)):
        table.add(
            String("s") + String(i),
            VerifiedToken(SUBJECT_TYPE_USER, "alice", values[i], "web", EXP),
        )
    var pdp = _pdp(table^)
    for i in range(len(values)):
        var r = _ask(pdp, "bearer", SUBJECT_TYPE_USER, "alice", String("s") + String(i), values[i])
        misses += _expect(r, REASON_CLIENT_MISMATCH, "audience vs client_id", values[i])
    assert_equal(misses, String(""), "accepted:\n" + misses)


def test_client_token_side() raises:
    # The bearer's client_id is a near miss of "notes". "" is refused
    # earlier (a bearer must carry a client_id), so it is skipped here.
    var misses = String("")
    var values = near_misses("notes")
    var table = _base_table()
    for i in range(len(values)):
        if values[i].byte_length() == 0:
            continue
        table.add(
            String("b") + String(i),
            VerifiedToken(SUBJECT_TYPE_CLIENT, "notes", "pdp", values[i], EXP),
        )
    var pdp = _pdp(table^)
    for i in range(len(values)):
        if values[i].byte_length() == 0:
            continue
        var r = _ask(pdp, String("b") + String(i), SUBJECT_TYPE_USER, "alice", "subject", "notes")
        misses += _expect(r, REASON_CLIENT_MISMATCH, "client_id", values[i])
    assert_equal(misses, String(""), "accepted:\n" + misses)


def test_bearer_audience() raises:
    # The decision point's audience is "pdp"; each bearer's aud a near miss.
    var misses = String("")
    var values = near_misses("pdp")
    var table = _base_table()
    for i in range(len(values)):
        table.add(
            String("b") + String(i),
            VerifiedToken(SUBJECT_TYPE_CLIENT, "notes", values[i], "notes", EXP),
        )
    var pdp = _pdp(table^)
    for i in range(len(values)):
        var r = _ask(pdp, String("b") + String(i), SUBJECT_TYPE_USER, "alice", "subject", "notes")
        misses += _expect(r, REASON_BEARER_AUDIENCE, "bearer aud", values[i])
        if r.status != 401:
            misses += String("bearer aud status ") + String(r.status) + "\n"
    assert_equal(misses, String(""), "accepted:\n" + misses)


def test_one_byte_client_id_is_a_client_id() raises:
    # The client_id presence check is a length check: a one-byte client_id
    # passes it (and then matches a one-byte audience).
    var table = TokenTable()
    table.add("bearer", VerifiedToken(SUBJECT_TYPE_CLIENT, "n", "pdp", "n", EXP))
    table.add("subject", VerifiedToken(SUBJECT_TYPE_USER, "alice", "n", "web", EXP))
    var pdp = _pdp(table^)
    var r = _ask(pdp, "bearer", SUBJECT_TYPE_USER, "alice", "subject", "n")
    assert_equal(r.reason, REASON_DECIDED)
    assert_equal(r.body, String('{"decision":true}'))


def test_near_misses_shape() raises:
    # The generator itself: nine distinct values, none equal to the input.
    var v = near_misses("alice")
    assert_equal(len(v), 9)
    for i in range(len(v)):
        assert_true(v[i] != "alice", "near miss equals its input")
        for j in range(i + 1, len(v)):
            assert_true(v[i] != v[j], "repeated near miss " + v[i])
    assert_equal(v[0], String("alic"))
    assert_equal(v[1], String("alicex"))
    assert_equal(v[2], String("xalice"))
    assert_equal(v[3], String("lice"))
    assert_equal(v[4], String("ALICE"))
    assert_equal(v[5], String(""))
    assert_equal(v[6], String("qlice"))
    assert_equal(v[7], String("alqce"))
    assert_equal(v[8], String("alicq"))


def main() raises:
    test_near_misses_shape()
    test_control_is_an_allow()
    test_subject_id_body_side()
    test_subject_id_token_side()
    test_subject_type_body_side()
    test_subject_type_token_side()
    test_audience_body_side()
    test_audience_token_side()
    test_client_body_side()
    test_client_token_side()
    test_bearer_audience()
    test_one_byte_client_id_is_a_client_id()
    print("PASS komira_test_pdp test_safety_near_miss")
