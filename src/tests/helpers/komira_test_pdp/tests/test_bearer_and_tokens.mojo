# =============================================================================
# test_bearer_and_tokens.mojo: reading `Authorization`, and the token table.
# =============================================================================
#
# `bearer_token`: the scheme matches `bearer` in any case and nothing else
# (a byte replaced at each of the six positions, one byte short, one byte
# long, other schemes); exactly one space; the token68 alphabet at each
# range edge (A Z a z 0 9 and - . _ ~ + / accepted; the byte just outside
# each range refused), `=` only as trailing padding; the token returned
# whole, padding included.
#
# `TokenTable`: exact lookup (near misses of a stored token are refused);
# expiry at `exp` exactly (now = exp - 1 accepted, now = exp refused, the
# last row of the table included); `add` refuses an empty token, an empty
# sub, a subject type other than the two, a repeat; `remove` forgets
# exactly one token.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_test_pdp import (
    BEARER_ABSENT,
    BEARER_MALFORMED,
    BEARER_PRESENT,
    SUBJECT_TYPE_CLIENT,
    SUBJECT_TYPE_USER,
    TokenTable,
    TokenVerifier,
    VerifiedToken,
    bearer_token,
    near_misses,
)


@fieldwise_init
struct Row(Copyable, Movable):
    var header: String
    var kind: Int
    var token: String


def test_bearer_header() raises:
    var rows = List[Row]()
    var A = BEARER_ABSENT
    var M = BEARER_MALFORMED
    var P = BEARER_PRESENT
    rows.append(Row("Bearer t", P, "t"))
    rows.append(Row("bearer t", P, "t"))
    rows.append(Row("BEARER t", P, "t"))
    rows.append(Row("bEaReR t", P, "t"))
    rows.append(Row("Bearer t=", P, "t="))
    rows.append(Row("Bearer t==", P, "t=="))
    rows.append(Row("Bearer AZaz09-._~+/", P, "AZaz09-._~+/"))
    # Another scheme, or no Bearer scheme at all.
    rows.append(Row("", A, ""))
    rows.append(Row("Basic t", A, ""))
    rows.append(Row("Beare t", A, ""))
    rows.append(Row("Bearerx t", A, ""))
    rows.append(Row("xBearer t", A, ""))
    rows.append(Row("Xearer t", A, ""))
    rows.append(Row("bXarer t", A, ""))
    rows.append(Row("beXrer t", A, ""))
    rows.append(Row("beaXer t", A, ""))
    rows.append(Row("bearXr t", A, ""))
    rows.append(Row("beareX t", A, ""))
    rows.append(Row(" Bearer t", A, ""))
    # Bearer, malformed.
    rows.append(Row("Bearer", M, ""))
    rows.append(Row("Bearer ", M, ""))
    rows.append(Row("Bearer  t", M, ""))
    rows.append(Row("Bearer t ", M, ""))
    rows.append(Row("Bearer t u", M, ""))
    rows.append(Row("Bearer t,u", M, ""))
    rows.append(Row("Bearer =", M, ""))
    rows.append(Row("Bearer ==", M, ""))
    rows.append(Row("Bearer =t", M, ""))
    rows.append(Row("Bearer t=u", M, ""))
    rows.append(Row("Bearer\tt", A, ""))
    # One byte outside each token68 range, last in the token.
    var outside = List[String]()
    outside.append(String("@"))  # before A
    outside.append(String("["))  # after Z
    outside.append(String("`"))  # before a
    outside.append(String("{"))  # after z
    outside.append(String(":"))  # after 9 (before 0 is /, allowed)
    outside.append(String(","))  # before -
    outside.append(String("^"))  # before _
    outside.append(String("}"))  # before ~
    outside.append(String("*"))  # before +
    outside.append(String('"'))
    outside.append(String("!"))
    for i in range(len(outside)):
        rows.append(Row(String("Bearer ab") + outside[i], M, ""))
        rows.append(Row(String("Bearer ") + outside[i] + "ab", M, ""))
    var misses = String("")
    for i in range(len(rows)):
        ref r = rows[i]
        var got = bearer_token(Optional[String](r.header))
        if got.kind != r.kind or got.token != r.token:
            misses += String("[") + r.header + "] -> " + String(got.kind) + " [" + got.token + "]\n"
    var none = bearer_token(None)
    if none.kind != BEARER_ABSENT:
        misses += "no header not absent\n"
    assert_equal(misses, String(""), misses)


def _claims(sub: String, exp: Int64) -> VerifiedToken:
    return VerifiedToken(SUBJECT_TYPE_USER, sub, "notes", "web", exp)


def test_table_lookup_is_exact() raises:
    var t = TokenTable()
    t.add("tok.alice", _claims("alice", 100))
    t.add("tok.bob", _claims("bob", 100))
    var misses = String("")
    var values = near_misses("tok.alice")
    for i in range(len(values)):
        if t.verify(values[i], 0):
            misses += String("[") + values[i] + "]\n"
    assert_equal(misses, String(""), "accepted:\n" + misses)
    var a = t.verify("tok.alice", 0)
    assert_true(Bool(a))
    assert_equal(a.value().sub, String("alice"))
    assert_equal(a.value().aud, String("notes"))
    assert_equal(a.value().client_id, String("web"))
    assert_equal(a.value().subject_type, String(SUBJECT_TYPE_USER))
    assert_equal(a.value().exp_s, Int64(100))
    var b = t.verify("tok.bob", 0)
    assert_equal(b.value().sub, String("bob"))


def test_table_expiry() raises:
    var t = TokenTable()
    t.add("first", _claims("alice", 100))
    t.add("last", _claims("bob", 200))
    assert_true(Bool(t.verify("first", 99)))
    assert_false(Bool(t.verify("first", 100)))
    assert_false(Bool(t.verify("first", 101)))
    assert_true(Bool(t.verify("last", 199)))
    assert_false(Bool(t.verify("last", 200)))


def test_table_add_and_remove() raises:
    var t = TokenTable()
    var raised: Bool
    for which in range(5):
        raised = False
        try:
            if which == 0:
                t.add("", _claims("alice", 100))
            elif which == 1:
                t.add("a", _claims("", 100))
            elif which == 2:
                t.add("a", VerifiedToken("user", "alice", "notes", "web", 100))
            elif which == 3:
                t.add("a", VerifiedToken("", "alice", "notes", "web", 100))
            else:
                t.add("x", _claims("alice", 100))
                t.add("x", _claims("bob", 100))
        except:
            raised = True
        assert_true(raised, String("add case ") + String(which) + " accepted")
    # One-byte token and sub are accepted; both subject types are.
    t.add("y", _claims("a", 100))
    t.add("z", VerifiedToken(SUBJECT_TYPE_CLIENT, "c", "pdp", "c", 100))
    assert_true(Bool(t.verify("y", 0)))
    assert_true(Bool(t.verify("z", 0)))
    # remove forgets exactly the one named, the last row included.
    assert_false(t.remove("q"))
    assert_true(t.remove("z"))
    assert_false(Bool(t.verify("z", 0)))
    assert_true(Bool(t.verify("y", 0)))
    assert_true(Bool(t.verify("x", 0)))
    assert_false(t.remove("z"))


def main() raises:
    test_bearer_header()
    test_table_lookup_is_exact()
    test_table_expiry()
    test_table_add_and_remove()
    print("PASS komira_test_pdp test_bearer_and_tokens")
