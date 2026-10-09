# =============================================================================
# test_endpoint.mojo: TestPdp's order of checks, its replies, its policy
# verbs and what it keeps.
# =============================================================================
#
# What each test proves:
#   - order: the path before the method, the method before the bearer, the
#     bearer before the body (a request failing several checks is answered
#     by the first), and the body size before the shape;
#   - the path and the method are exact (near misses are 404 / 405);
#   - replies: the status, `Cache-Control: no-store` on every reply, the
#     challenge of each 401 and 400, an error body that names only the
#     status class (never the reason), and the exact 200 bodies, single and
#     batch, with and without `context.max_age_s`;
#   - the body bound: 65536 bytes is read, 65537 is 413;
#   - the decision: every field of a rule must match exactly (a near miss of
#     the resource type, id, action or subject is a deny); an action the
#     decision point does not know is judged as admin, and a near miss of a
#     known action is unknown; a declared action is judged as itself;
#   - policy verbs: `allow` refuses an undeclared type or action and a
#     repeated rule; `revoke` removes exactly the rule named (a near miss
#     removes nothing) and the next request sees it; `declare_*` refuse ""
#     and a repeat; `set_max_age_s` refuses below -1;
#   - what is kept: one `DecisionRecord` per decided resource with the
#     action as asked, no token anywhere in it; `request_count` counts
#     every call, refused ones included.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_test_pdp import (
    MAX_BODY_BYTES,
    REASON_BEARER_MALFORMED,
    REASON_BEARER_MISSING,
    REASON_BODY_NOT_JSON,
    REASON_BODY_TOO_LARGE,
    REASON_DECIDED,
    REASON_METHOD,
    REASON_NOT_FOUND,
    REASON_SUBJECT_INVALID,
    SUBJECT_TYPE_CLIENT,
    SUBJECT_TYPE_USER,
    PdpReply,
    PolicyRule,
    TestPdp,
    TokenTable,
    VerifiedToken,
    batch_json,
    evaluation_json,
    near_misses,
)

comptime NOW: Int64 = 1000
comptime EXP: Int64 = 2000


def _pdp() raises -> TestPdp[TokenTable]:
    var t = TokenTable()
    t.add("bearer", VerifiedToken(SUBJECT_TYPE_CLIENT, "notes", "pdp", "notes", EXP))
    t.add("subject", VerifiedToken(SUBJECT_TYPE_USER, "alice", "notes", "web", EXP))
    var pdp = TestPdp(t^, "pdp", NOW)
    pdp.declare_kind("note")
    pdp.declare_action("notes.share")
    pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", "note", "n1"))
    pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "admin", "note", "n2"))
    pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "notes.share", "note", "n1"))
    return pdp^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _body(action: String, kind: String, id: String) -> String:
    return evaluation_json(
        SUBJECT_TYPE_USER, "alice", "S", action, kind, id, "notes"
    ).replace("<<S>>", "subject")


def _post(mut pdp: TestPdp[TokenTable], body: String) -> PdpReply:
    return pdp.handle(
        "POST", "/access/v1/evaluation", String("Bearer bearer"), _bytes(body)
    )


def _decision(mut pdp: TestPdp[TokenTable], action: String, kind: String, id: String) -> String:
    var r = _post(pdp, _body(action, kind, id))
    if r.reason != REASON_DECIDED:
        return r.reason
    return r.body


comptime ALLOW: String = '{"decision":true}'
comptime DENY: String = '{"decision":false}'


def test_order_of_checks() raises:
    var pdp = _pdp()
    var junk = _bytes("{")
    # Wrong path and wrong method and no bearer: the path answers.
    var r = pdp.handle("GET", "/access/v1/x", None, junk)
    assert_equal(r.reason, REASON_NOT_FOUND)
    assert_equal(r.status, 404)
    # Right path, wrong method, no bearer: the method answers.
    r = pdp.handle("GET", "/access/v1/evaluation", None, junk)
    assert_equal(r.reason, REASON_METHOD)
    assert_equal(r.status, 405)
    # No bearer and a broken body: the bearer answers.
    r = pdp.handle("POST", "/access/v1/evaluation", None, junk)
    assert_equal(r.reason, REASON_BEARER_MISSING)
    # A good bearer and a broken body: the body answers.
    r = pdp.handle("POST", "/access/v1/evaluation", String("Bearer bearer"), junk)
    assert_equal(r.reason, REASON_BODY_NOT_JSON)
    assert_equal(r.status, 400)
    # Too large and broken: the size answers.
    var big = List[UInt8]()
    for _ in range(MAX_BODY_BYTES + 1):
        big.append(0x7B)
    r = pdp.handle("POST", "/access/v1/evaluation", String("Bearer bearer"), big)
    assert_equal(r.reason, REASON_BODY_TOO_LARGE)
    assert_equal(r.status, 413)


def test_paths_and_method_are_exact() raises:
    var pdp = _pdp()
    var body = _body("read", "note", "n1")
    var misses = String("")
    var paths = near_misses("/access/v1/evaluation")
    var batch_paths = near_misses("/access/v1/evaluations")
    for i in range(len(batch_paths)):
        if batch_paths[i] != "/access/v1/evaluation":
            paths.append(batch_paths[i])
    for i in range(len(paths)):
        var r = pdp.handle("POST", paths[i], String("Bearer bearer"), _bytes(body))
        if r.reason != REASON_NOT_FOUND:
            misses += String("path [") + paths[i] + "] -> " + r.reason + "\n"
    var methods = near_misses("POST")
    methods.append(String("GET"))
    for i in range(len(methods)):
        var r = pdp.handle(methods[i], "/access/v1/evaluation", String("Bearer bearer"), _bytes(body))
        if r.reason != REASON_METHOD:
            misses += String("method [") + methods[i] + "] -> " + r.reason + "\n"
    assert_equal(misses, String(""), "accepted:\n" + misses)
    # Both exact paths are served.
    assert_equal(_post(pdp, body).body, String(ALLOW))
    var ids = List[String]()
    ids.append(String("n1"))
    var b = batch_json(SUBJECT_TYPE_USER, "alice", "S", "read", ids^, "notes").replace("<<S>>", "subject")
    var rb = pdp.handle("POST", "/access/v1/evaluations", String("Bearer bearer"), _bytes(b))
    assert_equal(rb.body, String('{"evaluations":[{"decision":true}]}'))


def test_replies() raises:
    var pdp = _pdp()
    var r = _post(pdp, _body("read", "note", "n1"))
    assert_equal(r.status, 200)
    assert_equal(r.body, String(ALLOW))
    assert_equal(r.cache_control, String("no-store"))
    assert_equal(r.www_authenticate, String(""))

    r = pdp.handle("POST", "/access/v1/evaluation", None, _bytes("{}"))
    assert_equal(r.status, 401)
    assert_equal(r.www_authenticate, String("Bearer"))
    assert_equal(r.cache_control, String("no-store"))
    assert_equal(r.body, String('{"error":{"code":"unauthorized","message":"unauthorized"}}'))

    r = pdp.handle("POST", "/access/v1/evaluation", String("Bearer unknown"), _bytes("{}"))
    assert_equal(r.status, 401)
    assert_equal(r.www_authenticate, String('Bearer error="invalid_token"'))

    r = pdp.handle("POST", "/access/v1/evaluation", String("Bearer a b"), _bytes("{}"))
    assert_equal(r.status, 400)
    assert_equal(r.reason, REASON_BEARER_MALFORMED)
    assert_equal(r.www_authenticate, String('Bearer error="invalid_request"'))

    r = _post(pdp, "{}")
    assert_equal(r.reason, REASON_SUBJECT_INVALID)
    assert_equal(r.www_authenticate, String(""))
    assert_equal(r.body, String('{"error":{"code":"bad_request","message":"bad_request"}}'))

    r = _post(pdp, _body("read", "note", "n1").replace('"id":"alice"', '"id":"bob"'))
    assert_equal(r.status, 403)
    assert_equal(r.body, String('{"error":{"code":"forbidden","message":"forbidden"}}'))

    r = pdp.handle("POST", "/x", None, _bytes("{}"))
    assert_equal(r.body, String('{"error":{"code":"not_found","message":"not_found"}}'))
    r = pdp.handle("PUT", "/access/v1/evaluation", None, _bytes("{}"))
    assert_equal(r.body, String('{"error":{"code":"method_not_allowed","message":"method_not_allowed"}}'))
    var big = List[UInt8]()
    for _ in range(MAX_BODY_BYTES + 1):
        big.append(0x20)
    r = pdp.handle("POST", "/access/v1/evaluation", String("Bearer bearer"), big)
    assert_equal(r.body, String('{"error":{"code":"payload_too_large","message":"payload_too_large"}}'))
    assert_equal(r.cache_control, String("no-store"))


def test_body_bound() raises:
    # A valid body padded with spaces to exactly MAX_BODY_BYTES is read.
    var pdp = _pdp()
    var body = _body("read", "note", "n1")
    var bytes = _bytes(body)
    while len(bytes) < MAX_BODY_BYTES:
        bytes.append(0x20)
    var r = pdp.handle("POST", "/access/v1/evaluation", String("Bearer bearer"), bytes)
    assert_equal(r.reason, REASON_DECIDED)
    bytes.append(0x20)
    r = pdp.handle("POST", "/access/v1/evaluation", String("Bearer bearer"), bytes)
    assert_equal(r.reason, REASON_BODY_TOO_LARGE)


def test_max_age() raises:
    var pdp = _pdp()
    pdp.set_max_age_s(0)
    assert_equal(_decision(pdp, "read", "note", "n1"), String('{"decision":true,"context":{"max_age_s":0}}'))
    pdp.set_max_age_s(120)
    var ids = List[String]()
    ids.append(String("n1"))
    ids.append(String("n2"))
    var b = batch_json(SUBJECT_TYPE_USER, "alice", "S", "read", ids^, "notes").replace("<<S>>", "subject")
    var r = pdp.handle("POST", "/access/v1/evaluations", String("Bearer bearer"), _bytes(b))
    assert_equal(
        r.body,
        String('{"evaluations":[{"decision":true,"context":{"max_age_s":120}},{"decision":false,"context":{"max_age_s":120}}]}'),
    )
    pdp.set_max_age_s(-1)
    assert_equal(_decision(pdp, "read", "note", "n1"), String(ALLOW))
    var raised = False
    try:
        pdp.set_max_age_s(-2)
    except:
        raised = True
    assert_true(raised, "max_age_s -2 accepted")


def test_rule_fields_are_exact() raises:
    var pdp = _pdp()
    var misses = String("")
    # Resource id.
    var ids = near_misses("n1")
    for i in range(len(ids)):
        if ids[i].byte_length() == 0:
            continue  # refused by the shape check, not a decision
        var d = _decision(pdp, "read", "note", ids[i])
        if d != DENY:
            misses += String("id [") + ids[i] + "] -> " + d + "\n"
    # Resource type: declared near misses, so only the rule can tell.
    var kinds = near_misses("note")
    for i in range(len(kinds)):
        if kinds[i].byte_length() == 0:
            continue
        pdp.declare_kind(kinds[i])
        var d = _decision(pdp, "read", kinds[i], "n1")
        if d != DENY:
            misses += String("type [") + kinds[i] + "] -> " + d + "\n"
    # Action: declared near misses of "read", so they are judged as
    # themselves, not as admin.
    var actions = near_misses("read")
    for i in range(len(actions)):
        if actions[i].byte_length() == 0:
            continue
        pdp.declare_action(actions[i])
        var d = _decision(pdp, actions[i], "note", "n1")
        if d != DENY:
            misses += String("action [") + actions[i] + "] -> " + d + "\n"
    assert_equal(misses, String(""), "allowed:\n" + misses)
    assert_equal(_decision(pdp, "read", "note", "n1"), String(ALLOW))


def test_rule_subject_is_exact() raises:
    # Tokens whose sub is a near miss of alice, asking about n1.
    var t = TokenTable()
    t.add("bearer", VerifiedToken(SUBJECT_TYPE_CLIENT, "notes", "pdp", "notes", EXP))
    var subs = near_misses("alice")
    for i in range(len(subs)):
        if subs[i].byte_length() != 0:
            t.add(String("s") + String(i), VerifiedToken(SUBJECT_TYPE_USER, subs[i], "notes", "web", EXP))
    t.add("c", VerifiedToken(SUBJECT_TYPE_CLIENT, "alice", "notes", "alice", EXP))
    var pdp = TestPdp(t^, "pdp", NOW)
    pdp.declare_kind("note")
    pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", "note", "n1"))
    var misses = String("")
    for i in range(len(subs)):
        if subs[i].byte_length() == 0:
            continue
        var b = evaluation_json(SUBJECT_TYPE_USER, subs[i], "S", "read", "note", "n1", "notes").replace(
            "<<S>>", String("s") + String(i)
        )
        var r = _post(pdp, b)
        if r.body != DENY:
            misses += String("sub [") + subs[i] + "] -> " + r.reason + " " + r.body + "\n"
    # The same sub as a client is another subject.
    var bc = evaluation_json(SUBJECT_TYPE_CLIENT, "alice", "S", "read", "note", "n1", "notes").replace("<<S>>", "c")
    var rc = _post(pdp, bc)
    if rc.body != DENY:
        misses += String("client alice -> ") + rc.reason + " " + rc.body + "\n"
    assert_equal(misses, String(""), "allowed:\n" + misses)


def test_unknown_action_is_admin() raises:
    # alice holds admin on n2 and read on n1, not admin on n1.
    var pdp = _pdp()
    var misses = String("")
    var unknown = near_misses("read")
    unknown.append(String("notes.archive"))
    for i in range(len(unknown)):
        if unknown[i].byte_length() == 0:
            continue
        if _decision(pdp, unknown[i], "note", "n2") != ALLOW:
            misses += String("[") + unknown[i] + "] on n2 not judged as admin\n"
        if _decision(pdp, unknown[i], "note", "n1") != DENY:
            misses += String("[") + unknown[i] + "] on n1 not judged as admin\n"
    assert_equal(misses, String(""), misses)
    # Each known action is judged as itself: read on n2 is a deny (only
    # admin is held there), read on n1 an allow.
    assert_equal(_decision(pdp, "read", "note", "n2"), String(DENY))
    assert_equal(_decision(pdp, "write", "note", "n2"), String(DENY))
    assert_equal(_decision(pdp, "delete", "note", "n2"), String(DENY))
    assert_equal(_decision(pdp, "admin", "note", "n2"), String(ALLOW))
    assert_equal(_decision(pdp, "admin", "note", "n1"), String(DENY))
    # A declared verb is judged as itself, the last declared action included.
    assert_equal(_decision(pdp, "notes.share", "note", "n1"), String(ALLOW))
    assert_equal(_decision(pdp, "notes.share", "note", "n2"), String(DENY))
    pdp.declare_action("notes.move")
    assert_equal(_decision(pdp, "notes.move", "note", "n2"), String(DENY))


def test_policy_verbs() raises:
    var pdp = _pdp()
    var raised: Bool
    # allow: undeclared type, undeclared action, a repeated rule.
    raised = False
    try:
        pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", "folder", "n1"))
    except:
        raised = True
    assert_true(raised, "rule with an undeclared type accepted")
    raised = False
    try:
        pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "notes.move", "note", "n1"))
    except:
        raised = True
    assert_true(raised, "rule with an undeclared action accepted")
    raised = False
    try:
        pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", "note", "n1"))
    except:
        raised = True
    assert_true(raised, "repeated rule accepted")
    # declare_*: "" and a repeat.
    for which in range(4):
        raised = False
        try:
            if which == 0:
                pdp.declare_kind("")
            elif which == 1:
                pdp.declare_kind("note")
            elif which == 2:
                pdp.declare_action("")
            else:
                pdp.declare_action("read")
        except:
            raised = True
        assert_true(raised, String("declare case ") + String(which) + " accepted")
    # One-byte names are names.
    pdp.declare_kind("k")
    pdp.declare_action("v")
    pdp.allow(PolicyRule(SUBJECT_TYPE_USER, "alice", "v", "k", "n1"))
    assert_equal(_decision(pdp, "v", "k", "n1"), String(ALLOW))

    # revoke: a near miss of any field removes nothing.
    var misses = String("")
    var ids = near_misses("n1")
    for i in range(len(ids)):
        if pdp.revoke(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", "note", ids[i])):
            misses += String("revoke id [") + ids[i] + "]\n"
    var subs = near_misses("alice")
    for i in range(len(subs)):
        if pdp.revoke(PolicyRule(SUBJECT_TYPE_USER, subs[i], "read", "note", "n1")):
            misses += String("revoke sub [") + subs[i] + "]\n"
    if pdp.revoke(PolicyRule(SUBJECT_TYPE_CLIENT, "alice", "read", "note", "n1")):
        misses += "revoke subject type\n"
    var acts = near_misses("read")
    for i in range(len(acts)):
        if pdp.revoke(PolicyRule(SUBJECT_TYPE_USER, "alice", acts[i], "note", "n1")):
            misses += String("revoke action [") + acts[i] + "]\n"
    var kinds = near_misses("note")
    for i in range(len(kinds)):
        if pdp.revoke(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", kinds[i], "n1")):
            misses += String("revoke type [") + kinds[i] + "]\n"
    assert_equal(misses, String(""), misses)
    assert_equal(_decision(pdp, "read", "note", "n1"), String(ALLOW))

    # The exact rule goes, and the next request sees it; once.
    assert_true(pdp.revoke(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", "note", "n1")))
    assert_equal(_decision(pdp, "read", "note", "n1"), String(DENY))
    assert_false(pdp.revoke(PolicyRule(SUBJECT_TYPE_USER, "alice", "read", "note", "n1")))
    # The other rules stay, the last one added included.
    assert_equal(_decision(pdp, "admin", "note", "n2"), String(ALLOW))
    assert_equal(_decision(pdp, "v", "k", "n1"), String(ALLOW))
    assert_true(pdp.revoke(PolicyRule(SUBJECT_TYPE_USER, "alice", "v", "k", "n1")))
    assert_equal(_decision(pdp, "v", "k", "n1"), String(DENY))


def test_what_is_kept() raises:
    var pdp = _pdp()
    assert_equal(pdp.request_count(), 0)
    _ = _post(pdp, _body("notes.archive", "note", "n2"))
    _ = pdp.handle("GET", "/x", None, _bytes("{}"))
    _ = _post(pdp, "{")
    var ids = List[String]()
    ids.append(String("n1"))
    ids.append(String("n3"))
    var b = batch_json(SUBJECT_TYPE_USER, "alice", "S", "read", ids^, "notes").replace("<<S>>", "subject")
    _ = pdp.handle("POST", "/access/v1/evaluations", String("Bearer bearer"), _bytes(b))
    assert_equal(pdp.request_count(), 4)
    var log = pdp.decisions()
    assert_equal(len(log), 3)
    # The action as asked, not the tier it was judged at.
    assert_equal(log[0].action, String("notes.archive"))
    assert_equal(log[0].subject_type, String(SUBJECT_TYPE_USER))
    assert_equal(log[0].subject, String("alice"))
    assert_equal(log[0].resource_type, String("note"))
    assert_equal(log[0].resource_id, String("n2"))
    assert_true(log[0].decision)
    assert_equal(log[1].resource_id, String("n1"))
    assert_true(log[1].decision)
    assert_equal(log[2].resource_id, String("n3"))
    assert_false(log[2].decision)
    for i in range(len(log)):
        ref e = log[i]
        var all = e.subject_type + e.subject + e.action + e.resource_type + e.resource_id
        # The two tokens are the strings "subject" and "bearer".
        assert_true(all.find("subject") < 0, "subject token in the log")
        assert_true(all.find("bearer") < 0, "bearer in the log")
    assert_equal(pdp.last_reason(), String(REASON_DECIDED))


def main() raises:
    test_order_of_checks()
    test_paths_and_method_are_exact()
    test_replies()
    test_body_bound()
    test_max_age()
    test_rule_fields_are_exact()
    test_rule_subject_is_exact()
    test_unknown_action_is_admin()
    test_policy_verbs()
    test_what_is_kept()
    print("PASS komira_test_pdp test_endpoint")
