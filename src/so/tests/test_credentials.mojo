# SessionCredentials: credentials defined in three steps, held by name, and
# the named error a wrong definition gives.
#
# Rows:
#   * test_a_good_definition_is_sealed_under_its_name: AwsKeys with key_id and
#     secret is sealed, with its kind, generation 1 and no session token; ids
#     count up from 1 and the definition is closed after.
#   * test_each_kind_needs_its_fields: for each of the eight kinds, a seal with
#     no field names the first field the kind needs, word for word, and a seal
#     with the needed fields (and every optional one) is accepted.
#   * test_a_field_of_another_kind_is_refused_and_discards_the_definition: a
#     field the kind does not take, and a number that is no field (0 and 14),
#     are refused by name and the definition is gone after.
#   * test_a_value_is_checked_and_never_echoed: an empty value, a value of
#     4097 bytes and one that is not UTF-8 are refused, each message exactly
#     what is asserted (so the value is not in it); 4096 bytes is accepted.
#   * test_a_name_outside_the_grammar_is_refused_unquoted: empty, 129 bytes,
#     a `/` and a space are refused with one message that does not quote the
#     name; 128 bytes and `ambient-2` are accepted.
#   * test_ambient_and_anonymous_are_not_defined: in any case.
#   * test_an_unknown_kind_is_refused: 0 and 9.
#   * test_an_id_that_is_not_open_is_refused: never added, already sealed.
#   * test_a_scope_other_than_session_is_refused: 0 and 2, and the
#     definition is discarded.
#   * test_a_byte_equal_seal_keeps_its_generation: the same value sealed again
#     keeps generation 1; a new secret takes the next generation; a second
#     name takes its own; a value of another kind under the name replaces it.
#   * test_a_value_sealed_with_fewer_fields_drops_the_others: a session token
#     sealed once and not the next time is no longer held.
#   * test_a_lookup_of_an_unsealed_name_is_credential_unbound: kind_of,
#     generation_of, has_field and node_id_of of a name with no value, and a
#     node_id_of a field the value does not set.
#   * test_setting_a_field_again_replaces_it: the last value set is the one
#     sealed.
#   * test_a_session_starts_with_no_credential: and a moved session keeps its
#     credentials.
#   * test_the_store_replaces_removes_and_compares: a value put again replaces
#     the old one; equals compares every byte and length; removing a ref it
#     does not hold does nothing; a shared handle sees a removal; resolving a
#     ref it does not hold raises naming the ref, and counts.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from so import (
    KOMIRA_BIND_SESSION,
    KOMIRA_CRED_AWS_KEYS,
    KOMIRA_CRED_AWS_PROFILE,
    KOMIRA_CRED_AZURE_KEY,
    KOMIRA_CRED_AZURE_SAS,
    KOMIRA_CRED_BEARER,
    KOMIRA_CRED_GCP_SERVICE_ACCOUNT,
    KOMIRA_CRED_GCP_TOKEN,
    KOMIRA_CRED_OAUTH2_CLIENT,
    KOMIRA_FIELD_ACCOUNT,
    KOMIRA_FIELD_CLIENT_ID,
    KOMIRA_FIELD_CLIENT_SECRET,
    KOMIRA_FIELD_FILE,
    KOMIRA_FIELD_KEY,
    KOMIRA_FIELD_KEY_ID,
    KOMIRA_FIELD_PROFILE,
    KOMIRA_FIELD_SAS,
    KOMIRA_FIELD_SCOPE,
    KOMIRA_FIELD_SECRET,
    KOMIRA_FIELD_SESSION_TOKEN,
    KOMIRA_FIELD_TOKEN,
    KOMIRA_FIELD_TOKEN_URL,
    Session,
    SessionCredentials,
    SessionSecretStore,
)


def _b(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(text.as_bytes())
    return out^


def _n(n: Int, c: String = "a") -> String:
    var out = String("")
    for _ in range(n):
        out += c
    return out^


def _add_err(mut c: SessionCredentials, kind: Int32, name: String) -> String:
    try:
        _ = c.add(kind, name)
        return "no error"
    except e:
        return String(e)


def _set(mut c: SessionCredentials, id: Int32, field: Int32, text: String) raises:
    c.set(id, field, text.as_bytes())


def _set_err(mut c: SessionCredentials, id: Int32, field: Int32, value: List[UInt8]) -> String:
    try:
        c.set(id, field, Span(value))
        return "no error"
    except e:
        return String(e)


def _seal_err(mut c: SessionCredentials, id: Int32, scope: Int32 = KOMIRA_BIND_SESSION) -> String:
    try:
        c.seal(id, scope)
        return "no error"
    except e:
        return String(e)


def _aws(mut c: SessionCredentials, name: String, key_id: String, secret: String) raises:
    var id = c.add(KOMIRA_CRED_AWS_KEYS, name)
    _set(c, id, KOMIRA_FIELD_KEY_ID, key_id)
    _set(c, id, KOMIRA_FIELD_SECRET, secret)
    c.seal(id, KOMIRA_BIND_SESSION)


def test_a_good_definition_is_sealed_under_its_name() raises:
    var c = SessionCredentials()
    var id = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    assert_equal(id, Int32(1))
    assert_equal(c.open_definitions(), 1)
    assert_false(c.is_sealed("raw-etl"), "not sealed before seal")
    _set(c, id, KOMIRA_FIELD_KEY_ID, "AKIDONE")
    _set(c, id, KOMIRA_FIELD_SECRET, "one-secret")
    c.seal(id, KOMIRA_BIND_SESSION)
    assert_true(c.is_sealed("raw-etl"))
    assert_equal(c.kind_of("raw-etl"), KOMIRA_CRED_AWS_KEYS)
    assert_equal(c.generation_of("raw-etl"), 1)
    assert_true(c.has_field("raw-etl", KOMIRA_FIELD_KEY_ID))
    assert_true(c.has_field("raw-etl", KOMIRA_FIELD_SECRET))
    assert_false(c.has_field("raw-etl", KOMIRA_FIELD_SESSION_TOKEN))
    assert_equal(c.open_definitions(), 0)
    assert_equal(c.add(KOMIRA_CRED_BEARER, "next"), Int32(2))


def _check_kind(
    kind: Int32, label: String, var needed: List[Int32], var optional: List[Int32], first: String
) raises:
    var c = SessionCredentials()
    var bare = c.add(kind, "k")
    assert_equal(
        _seal_err(c, bare),
        "CREDENTIALS_INVALID: seal credential=k: " + label + " needs " + first,
    )
    var full = c.add(kind, "k")
    for i in range(len(needed)):
        _set(c, full, needed[i], "v" + String(i))
    for i in range(len(optional)):
        _set(c, full, optional[i], "o" + String(i))
    c.seal(full, KOMIRA_BIND_SESSION)
    assert_equal(c.kind_of("k"), kind)
    for i in range(len(optional)):
        assert_true(c.has_field("k", optional[i]), label + " keeps its optional field")
    # Each needed field alone short of the others is refused.
    if len(needed) > 1:
        var partial = c.add(kind, "p")
        _set(c, partial, needed[0], "x")
        assert_true(_seal_err(c, partial).startswith("CREDENTIALS_INVALID: seal credential=p: " + label + " needs "))


def test_each_kind_needs_its_fields() raises:
    _check_kind(KOMIRA_CRED_AWS_KEYS, "AwsKeys", [KOMIRA_FIELD_KEY_ID, KOMIRA_FIELD_SECRET], [KOMIRA_FIELD_SESSION_TOKEN], "key_id=")
    _check_kind(KOMIRA_CRED_AWS_PROFILE, "AwsProfile", [KOMIRA_FIELD_PROFILE], List[Int32](), "profile=")
    _check_kind(KOMIRA_CRED_GCP_SERVICE_ACCOUNT, "GcpServiceAccount", [KOMIRA_FIELD_FILE], List[Int32](), "file=")
    _check_kind(KOMIRA_CRED_GCP_TOKEN, "GcpToken", [KOMIRA_FIELD_TOKEN], List[Int32](), "token=")
    _check_kind(KOMIRA_CRED_AZURE_KEY, "AzureKey", [KOMIRA_FIELD_ACCOUNT, KOMIRA_FIELD_KEY], List[Int32](), "account=")
    _check_kind(KOMIRA_CRED_AZURE_SAS, "AzureSas", [KOMIRA_FIELD_ACCOUNT, KOMIRA_FIELD_SAS], List[Int32](), "account=")
    _check_kind(KOMIRA_CRED_BEARER, "BearerToken", [KOMIRA_FIELD_TOKEN], List[Int32](), "token=")
    _check_kind(
        KOMIRA_CRED_OAUTH2_CLIENT,
        "OAuth2ClientCredentials",
        [KOMIRA_FIELD_CLIENT_ID, KOMIRA_FIELD_CLIENT_SECRET],
        [KOMIRA_FIELD_SCOPE, KOMIRA_FIELD_TOKEN_URL],
        "client_id=",
    )


def test_a_field_of_another_kind_is_refused_and_discards_the_definition() raises:
    var c = SessionCredentials()
    var id = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    assert_equal(
        _set_err(c, id, KOMIRA_FIELD_TOKEN, _b("tok-value")),
        "CREDENTIALS_INVALID: set credential=raw-etl: AwsKeys has no token=",
    )
    assert_equal(c.open_definitions(), 0)
    assert_equal(
        _set_err(c, id, KOMIRA_FIELD_KEY_ID, _b("AKID")),
        "CREDENTIALS_INVALID: set credential: id 1 is not an open definition",
    )
    var zero = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    assert_equal(
        _set_err(c, zero, Int32(0), _b("v")),
        "CREDENTIALS_INVALID: set credential=raw-etl: field 0 is not a KOMIRA_FIELD_* field",
    )
    var past = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    assert_equal(
        _set_err(c, past, Int32(14), _b("v")),
        "CREDENTIALS_INVALID: set credential=raw-etl: field 14 is not a KOMIRA_FIELD_* field",
    )
    assert_equal(c.open_definitions(), 0)
    assert_false(c.is_sealed("raw-etl"))


def test_a_value_is_checked_and_never_echoed() raises:
    var c = SessionCredentials()
    var id = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    assert_equal(
        _set_err(c, id, KOMIRA_FIELD_SECRET, List[UInt8]()),
        "CREDENTIALS_INVALID: set credential=raw-etl: secret= is empty",
    )
    id = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    assert_equal(
        _set_err(c, id, KOMIRA_FIELD_SECRET, _b(_n(4097, "s"))),
        "CREDENTIALS_INVALID: set credential=raw-etl: secret= is longer than 4096 bytes",
    )
    id = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    var bad = _b("se")
    bad.append(UInt8(0xFF))
    bad.append(UInt8(0xFE))
    assert_equal(
        _set_err(c, id, KOMIRA_FIELD_SECRET, bad),
        "CREDENTIALS_INVALID: set credential=raw-etl: secret= is not UTF-8",
    )
    id = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    _set(c, id, KOMIRA_FIELD_KEY_ID, "AKID")
    _set(c, id, KOMIRA_FIELD_SECRET, _n(4096, "s"))
    c.seal(id, KOMIRA_BIND_SESSION)
    assert_true(c.is_sealed("raw-etl"), "4096 bytes is accepted")


def test_a_name_outside_the_grammar_is_refused_unquoted() raises:
    var c = SessionCredentials()
    var refusal = String(
        "CREDENTIALS_INVALID: add credential: the name is not 1 to 128 bytes of"
        " letters, digits, '_', '.' and '-'"
    )
    assert_equal(_add_err(c, KOMIRA_CRED_BEARER, ""), refusal)
    assert_equal(_add_err(c, KOMIRA_CRED_BEARER, _n(129)), refusal)
    assert_equal(_add_err(c, KOMIRA_CRED_BEARER, "AKIA/pasted"), refusal)
    assert_equal(_add_err(c, KOMIRA_CRED_BEARER, "two words"), refusal)
    assert_equal(c.open_definitions(), 0)
    _ = c.add(KOMIRA_CRED_BEARER, _n(128))
    _ = c.add(KOMIRA_CRED_BEARER, "ambient-2")
    _ = c.add(KOMIRA_CRED_BEARER, "A.b_c-9")
    assert_equal(c.open_definitions(), 3)


def test_ambient_and_anonymous_are_not_defined() raises:
    var c = SessionCredentials()
    var refusal = String(
        "CREDENTIALS_INVALID: add credential: ambient and anonymous are built in and are not defined"
    )
    assert_equal(_add_err(c, KOMIRA_CRED_AWS_KEYS, "ambient"), refusal)
    assert_equal(_add_err(c, KOMIRA_CRED_AWS_KEYS, "anonymous"), refusal)
    assert_equal(_add_err(c, KOMIRA_CRED_AWS_KEYS, "Ambient"), refusal)
    assert_equal(_add_err(c, KOMIRA_CRED_AWS_KEYS, "ANONYMOUS"), refusal)
    assert_equal(c.open_definitions(), 0)


def test_an_unknown_kind_is_refused() raises:
    var c = SessionCredentials()
    assert_equal(
        _add_err(c, Int32(0), "raw-etl"),
        "CREDENTIALS_INVALID: add credential: kind 0 is not a KOMIRA_CRED_* kind",
    )
    assert_equal(
        _add_err(c, Int32(9), "raw-etl"),
        "CREDENTIALS_INVALID: add credential: kind 9 is not a KOMIRA_CRED_* kind",
    )
    assert_equal(c.open_definitions(), 0)


def test_an_id_that_is_not_open_is_refused() raises:
    var c = SessionCredentials()
    assert_equal(
        _seal_err(c, Int32(5)),
        "CREDENTIALS_INVALID: seal credential: id 5 is not an open definition",
    )
    _aws(c, "raw-etl", "AKID", "secret-one")
    assert_equal(
        _seal_err(c, Int32(1)),
        "CREDENTIALS_INVALID: seal credential: id 1 is not an open definition",
    )
    assert_equal(
        _set_err(c, Int32(1), KOMIRA_FIELD_SECRET, _b("x")),
        "CREDENTIALS_INVALID: set credential: id 1 is not an open definition",
    )


def test_a_scope_other_than_session_is_refused() raises:
    var c = SessionCredentials()
    for scope in [Int32(0), Int32(2)]:
        var id = c.add(KOMIRA_CRED_BEARER, "tok")
        _set(c, id, KOMIRA_FIELD_TOKEN, "t")
        assert_equal(
            _seal_err(c, id, scope),
            "CREDENTIALS_INVALID: seal credential=tok: scope " + String(scope) + " is not KOMIRA_BIND_SESSION",
        )
        assert_equal(c.open_definitions(), 0)
    assert_false(c.is_sealed("tok"))


def test_a_byte_equal_seal_keeps_its_generation() raises:
    var c = SessionCredentials()
    _aws(c, "raw-etl", "AKID", "secret-one")
    assert_equal(c.generation_of("raw-etl"), 1)
    _aws(c, "raw-etl", "AKID", "secret-one")
    assert_equal(c.generation_of("raw-etl"), 1, "a byte-equal value keeps its generation")
    _aws(c, "raw-etl", "AKID", "secret-two")
    assert_equal(c.generation_of("raw-etl"), 2, "a new secret is a new generation")
    _aws(c, "other", "AKID", "secret-two")
    assert_equal(c.generation_of("other"), 3, "another name takes its own")
    var tok = c.add(KOMIRA_CRED_BEARER, "raw-etl")
    _set(c, tok, KOMIRA_FIELD_TOKEN, "AKID")
    c.seal(tok, KOMIRA_BIND_SESSION)
    assert_equal(c.kind_of("raw-etl"), KOMIRA_CRED_BEARER, "the name holds the new kind")
    assert_equal(c.generation_of("raw-etl"), 4)
    assert_false(c.has_field("raw-etl", KOMIRA_FIELD_SECRET))
    assert_false(c.secret_store().holds("raw-etl/2"), "the old secret is no longer held")


def test_a_value_sealed_with_fewer_fields_drops_the_others() raises:
    var c = SessionCredentials()
    var id = c.add(KOMIRA_CRED_AWS_KEYS, "temp")
    _set(c, id, KOMIRA_FIELD_KEY_ID, "ASIA")
    _set(c, id, KOMIRA_FIELD_SECRET, "s")
    _set(c, id, KOMIRA_FIELD_SESSION_TOKEN, "session")
    c.seal(id, KOMIRA_BIND_SESSION)
    assert_true(c.has_field("temp", KOMIRA_FIELD_SESSION_TOKEN))
    assert_true(c.secret_store().holds("temp/3"))
    _aws(c, "temp", "ASIA", "s")
    assert_equal(c.generation_of("temp"), 2, "dropping a field is a new value")
    assert_false(c.has_field("temp", KOMIRA_FIELD_SESSION_TOKEN))
    assert_false(c.secret_store().holds("temp/3"), "the dropped token is wiped")


def test_a_lookup_of_an_unsealed_name_is_credential_unbound() raises:
    var c = SessionCredentials()
    var unbound = String("CREDENTIAL_UNBOUND: credential=nope has no sealed value on this session")
    try:
        _ = c.kind_of("nope")
        assert_true(False, "kind_of raised nothing")
    except e:
        assert_equal(String(e), unbound)
    try:
        _ = c.generation_of("nope")
        assert_true(False, "generation_of raised nothing")
    except e:
        assert_equal(String(e), unbound)
    try:
        _ = c.has_field("nope", KOMIRA_FIELD_SECRET)
        assert_true(False, "has_field raised nothing")
    except e:
        assert_equal(String(e), unbound)
    try:
        _ = c.node_id_of("nope", KOMIRA_FIELD_SECRET)
        assert_true(False, "node_id_of raised nothing")
    except e:
        assert_equal(String(e), unbound)
    _aws(c, "raw-etl", "AKID", "secret-one")
    try:
        _ = c.node_id_of("raw-etl", KOMIRA_FIELD_SESSION_TOKEN)
        assert_true(False, "node_id_of of an unset field raised nothing")
    except e:
        assert_equal(
            String(e),
            "CREDENTIALS_INVALID: read credential=raw-etl: AwsKeys has no session_token=",
        )


def test_setting_a_field_again_replaces_it() raises:
    var c = SessionCredentials()
    _aws(c, "raw-etl", "AKID", "secret-two")
    var id = c.add(KOMIRA_CRED_AWS_KEYS, "raw-etl")
    _set(c, id, KOMIRA_FIELD_KEY_ID, "AKID")
    _set(c, id, KOMIRA_FIELD_SECRET, "secret-one")
    _set(c, id, KOMIRA_FIELD_SECRET, "secret-two")
    c.seal(id, KOMIRA_BIND_SESSION)
    assert_equal(c.generation_of("raw-etl"), 1, "the last value set is the one sealed")
    assert_true(c.secret_store().equals("raw-etl/2", "secret-two".as_bytes()))


def test_a_session_starts_with_no_credential() raises:
    var s = Session()
    assert_false(s.credentials.is_sealed("raw-etl"))
    assert_equal(s.credentials.open_definitions(), 0)
    _aws(s.credentials, "raw-etl", "AKID", "secret-one")
    var moved = s^
    assert_true(moved.credentials.is_sealed("raw-etl"))
    assert_equal(moved.credentials.secret_bindings().num_entries(), 2)


def test_the_store_replaces_removes_and_compares() raises:
    var st = SessionSecretStore()
    st.put("a/1", _b("one"))
    st.put("a/1", _b("two"))
    assert_true(st.equals("a/1", "two".as_bytes()), "the new value")
    assert_false(st.equals("a/1", "one".as_bytes()), "the old value is gone")
    assert_false(st.equals("a/1", "twp".as_bytes()), "one byte differs")
    assert_false(st.equals("a/1", "twoo".as_bytes()), "a longer value")
    assert_false(st.equals("b/1", "two".as_bytes()), "a ref it does not hold")
    st.remove("b/1")
    assert_true(st.holds("a/1"))
    var other = st.share()
    other.remove("a/1")
    assert_false(st.holds("a/1"), "a shared handle sees the removal")
    var message = String("")
    try:
        _ = st.resolve("a/1")
    except e:
        message = String(e)
    assert_equal(message, "SessionSecretStore: no value for a/1")
    assert_equal(other.resolve_count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
