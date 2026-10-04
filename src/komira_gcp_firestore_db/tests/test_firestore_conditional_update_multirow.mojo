# =============================================================================
# test_firestore_conditional_update_multirow.mojo — `conditional_update` IS AN
#   `UPDATE ... WHERE`, NOT A "FIND ONE DOC AND CAS IT".
# =============================================================================
#
# WHAT IT PINS. When the guard names no PK equality predicate,
# `FirestoreDatabase.conditional_update` must update EVERY document the guard
# matches, as every SQL backend does, and not resolve one document (the first
# equality pred with `LIMIT 1`, Firestore's implicit `__name__ ASC` picking the
# lowest doc id) and then check the rest of the guard against that one.
#
# WHAT A ONE-DOCUMENT RESOLVER WOULD BREAK. A provisioned-resource store's two
# stamping updates guard on `(owner_id, scope_id, item_id, kind, resource_name,
# <flag>)` and name no PK: one arbitrary row of the owner would be resolved and
# fail its client-side pre-check, so 0 rows are stamped and a teardown
# interlock `REAPABLE <=> (NOT delete_protected) AND created_by_deployment`
# can never be satisfied.
#
# ⛔ AND WHY IT IS IN *THIS* PACKAGE, NOT NEXT TO THE SQLITE ONE. A store test
# that passes on sqlite says NOTHING about the document backend. These cases
# drive `FirestoreDatabase[MockFirestoreConnector]` directly, so the code path
# under test is the code path a deployment runs.
#
# ZERO network, ZERO GCP: every call lands on the in-process mock.
#
# ⭐ §2 PINS THE ENCODER IN THE SAME WALK: `_apply_updates` must write every
# RAW_EXPR literal (`revoked = true` is the bool LITERAL a revoke sets) and
# refuse by name what it cannot evaluate, never skip it. The resolver picks the
# documents, the encoder decides what is written to them, and a falsifier for
# one is one `assert` away from covering the other.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import (
    DbValue,
    DbColVal,
    Pred,
    Filter,
)

from komira_gcp_firestore.firestore_client import FirestoreClient

from komira_gcp_firestore_db import (
    DeclaredIndexSet,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
    TableKeys,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]

# A synthetic collection with no declared key, so the PK is the conventional
# `id` — the shape of a table whose guards name a scope tuple rather than the
# row id.
comptime _TABLE: String = "gizmo"
comptime _OWNER: String = "owner-A"
comptime _SCOPE: String = "scope-1"
comptime _ITEM: String = "item-x"


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _fs_db(var transport: MockFirestore) -> _FsDb:
    var client = FirestoreClient[_MockT](
        transport.connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    return _FsDb(client^)


def _cols() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("owner_id"))
    out.append(String("scope_id"))
    out.append(String("item_id"))
    out.append(String("kind"))
    out.append(String("resource_name"))
    out.append(String("flag"))
    out.append(String("version"))
    return out^


def _row(
    id: String,
    owner: String,
    scope: String,
    item: String,
    kind: Int32,
    name: String,
    flag: Int32,
) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(id))
    out.append(DbValue.text(owner))
    out.append(DbValue.text(scope))
    out.append(DbValue.text(item))
    out.append(DbValue.int4(kind))
    out.append(DbValue.text(name))
    out.append(DbValue.int4(flag))
    out.append(DbValue.int8(Int64(1)))
    return out^


def _scope_guard(kind: Int32, name: String) raises -> List[Pred]:
    """The five-predicate scope narrowing every provisioned-resource write uses.
    NONE of them is the PK, and the FIRST one (`owner_id`) matches EVERY row of the
    owner — which is exactly what made the one-doc resolver pick the wrong row."""
    var g = List[Pred]()
    g.append(Pred.eq(String("owner_id"), DbValue.text(_OWNER)))
    g.append(Pred.eq(String("scope_id"), DbValue.text(_SCOPE)))
    g.append(Pred.eq(String("item_id"), DbValue.text(_ITEM)))
    g.append(Pred.eq(String("kind"), DbValue.int4(kind)))
    g.append(Pred.eq(String("resource_name"), DbValue.text(name)))
    return g^


def _flag_of(
    mut db: _FsDb, mut reactor: Reactor[NoopSink], id: String
) raises -> Int64:
    var got = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("id"), DbValue.text(id)
    )
    if not got:
        raise Error(String("row ") + id + String(" vanished"))
    var row = got.take()
    return row.get_int8(row.column_index(String("flag")))


def _version_of(
    mut db: _FsDb, mut reactor: Reactor[NoopSink], id: String
) raises -> Int64:
    var got = db.get_by_key[_Rt](
        reactor, _TABLE, _cols(), String("id"), DbValue.text(id)
    )
    if not got:
        raise Error(String("row ") + id + String(" vanished"))
    var row = got.take()
    return row.get_int8(row.column_index(String("version")))


def _seed(mut db: _FsDb, mut reactor: Reactor[NoopSink]) raises:
    """Four rows. `r-decoy` sorts FIRST by doc-id AND matches the guard's first
    equality (`owner_id`), so the old resolver always landed on it and then failed
    its own client-side kind/name pre-check -> 0 rows, silently."""
    _ = db.put[_Rt](
        reactor,
        _TABLE,
        _cols(),
        _row(String("r-decoy"), _OWNER, _SCOPE, _ITEM, Int32(1), String("svc"), Int32(0)),
    )
    # TWO rows describing the SAME resource — `record` INSERTs one per run, which
    # is why the write must reach EVERY matching row and not just one.
    _ = db.put[_Rt](
        reactor,
        _TABLE,
        _cols(),
        _row(String("r-hit-1"), _OWNER, _SCOPE, _ITEM, Int32(7), String("db"), Int32(0)),
    )
    _ = db.put[_Rt](
        reactor,
        _TABLE,
        _cols(),
        _row(String("r-hit-2"), _OWNER, _SCOPE, _ITEM, Int32(7), String("db"), Int32(0)),
    )
    # A different OWNER — must never be reachable.
    _ = db.put[_Rt](
        reactor,
        _TABLE,
        _cols(),
        _row(
            String("r-other-owner"),
            String("owner-B"),
            _SCOPE,
            _ITEM,
            Int32(7),
            String("db"),
            Int32(0),
        ),
    )


# =============================================================================
# (a) A five-predicate NON-PK guard whose first-EQ column matches MANY documents
#     updates EVERY matching document and returns their count.
# =============================================================================
def test_non_pk_guard_updates_every_matching_document() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _seed(db, reactor)

    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("flag"), DbValue.int4(Int32(1))))

    var n = db.conditional_update[_Rt](
        reactor,
        _TABLE,
        Filter.all_of(_scope_guard(Int32(7), String("db"))),
        updates,
        False,
        Optional[String](String("version")),
        List[String](),
    )
    assert_equal(
        n,
        UInt64(2),
        (
            "conditional_update is an UPDATE ... WHERE: BOTH rows describing the"
            " same resource are stamped (the one-doc resolver returned 0)"
        ),
    )
    assert_equal(
        _flag_of(db, reactor, String("r-hit-1")), Int64(1), "r-hit-1 is stamped"
    )
    assert_equal(
        _flag_of(db, reactor, String("r-hit-2")), Int64(1), "r-hit-2 is stamped"
    )
    assert_equal(
        _version_of(db, reactor, String("r-hit-1")),
        Int64(2),
        "each matched row gets its OWN version bump",
    )
    _ = db^
    print("    [PASS] a non-PK guard updates every matching document")


# =============================================================================
# (b) THE WRONG-ROW CASE. A document that satisfies a WEAKER prefix of the guard
#     (the first equality alone) must NOT be written.
# =============================================================================
def test_a_row_matching_only_the_first_equality_is_never_written() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _seed(db, reactor)

    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("flag"), DbValue.int4(Int32(1))))
    _ = db.conditional_update[_Rt](
        reactor,
        _TABLE,
        Filter.all_of(_scope_guard(Int32(7), String("db"))),
        updates,
        False,
        Optional[String](String("version")),
        List[String](),
    )

    assert_equal(
        _flag_of(db, reactor, String("r-decoy")),
        Int64(0),
        (
            "the decoy matches owner_id (the guard's first equality) and NOTHING"
            " else — it must not be written"
        ),
    )
    assert_equal(
        _version_of(db, reactor, String("r-decoy")),
        Int64(1),
        "an unmatched row is not even version-bumped",
    )
    assert_equal(
        _flag_of(db, reactor, String("r-other-owner")),
        Int64(0),
        "another owner's row is unreachable",
    )
    assert_equal(
        _version_of(db, reactor, String("r-other-owner")),
        Int64(1),
        "another owner's row is not version-bumped",
    )
    _ = db^
    print("    [PASS] a row matching only the first equality is never written")


# =============================================================================
# (c) THE PK FAST PATH IS UNCHANGED — a guard naming the PK issues NO query at
#     all, and still CASes exactly one document.
# =============================================================================
def test_pk_guard_still_takes_the_direct_get_path() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var t = MockFirestore()
    var probe = t.share()
    var db = _fs_db(t^)
    _seed(db, reactor)

    var before = probe.run_query_count()

    var g = List[Pred]()
    g.append(Pred.eq(String("id"), DbValue.text(String("r-hit-1"))))
    g.append(Pred.eq(String("kind"), DbValue.int4(Int32(7))))
    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("flag"), DbValue.int4(Int32(1))))

    var n = db.conditional_update[_Rt](
        reactor,
        _TABLE,
        Filter.all_of(g^),
        updates,
        False,
        Optional[String](String("version")),
        List[String](),
    )
    assert_equal(n, UInt64(1), "a PK-guarded CAS still updates exactly one row")
    assert_equal(
        probe.run_query_count(),
        before,
        (
            "the PK fast path issues NO :runQuery — a point update must not"
            " become a collection query"
        ),
    )
    assert_equal(
        _flag_of(db, reactor, String("r-hit-2")),
        Int64(0),
        "the sibling row sharing the same scope is untouched by a PK-guarded CAS",
    )
    _ = db^
    print("    [PASS] the PK fast path issues no query and updates exactly one row")


# =============================================================================
# (d) A STALE guard still loses. Multi-row semantics must not cost the CAS.
# =============================================================================
def test_a_guard_no_row_satisfies_affects_zero_rows() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _seed(db, reactor)

    var updates = List[DbColVal]()
    updates.append(DbColVal.bind(String("flag"), DbValue.int4(Int32(1))))
    var n = db.conditional_update[_Rt](
        reactor,
        _TABLE,
        Filter.all_of(_scope_guard(Int32(99), String("nope"))),
        updates,
        False,
        Optional[String](String("version")),
        List[String](),
    )
    assert_equal(n, UInt64(0), "a guard no row satisfies affects zero rows")
    _ = db^
    print("    [PASS] a guard no row satisfies affects zero rows")


# =============================================================================
# (e) `put` REFUSES to mint a random document id for a table whose primary key is
#     DECLARED (`TableKeys`) as something other than `id` and is missing from the
#     projection.
#
#     A minted doc-id names no column, so a second write of the same logical key
#     creates a SECOND document and every PK-addressed read / CAS / delete then
#     resolves an arbitrary one of them. Once a table's key is declared, a stale
#     projection says so BY NAME instead of quietly giving the table TWO doc-id
#     schemes.
# =============================================================================
def test_put_refuses_a_minted_doc_id_for_a_declared_table() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var keys = TableKeys()
    keys.declare(String("owner_settings"), String("owner_id"))
    var client = FirestoreClient[_MockT](
        MockFirestore().connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var db = _FsDb(client^, DeclaredIndexSet(), keys^)

    # `owner_settings` is declared with PK `owner_id` (it has no `id` column at all).
    # A projection that omits it is exactly the disagreement the refusal names.
    var cols = List[String]()
    cols.append(String("settings_json"))
    cols.append(String("version"))
    var vals = List[DbValue]()
    vals.append(DbValue.text(String("{}")))
    vals.append(DbValue.int8(Int64(1)))
    with assert_raises(contains="REFUSED a random document id"):
        _ = db.put[_Rt](reactor, String("owner_settings"), cols, vals)

    # The SAME projection on an UNDECLARED table still mints, deliberately: a
    # caller that never declared its keys must not turn into a hard failure.
    var n = db.put[_Rt](reactor, String("some_unregistered_table"), cols, vals)
    assert_equal(
        n,
        UInt64(1),
        (
            "an UNDECLARED table still mints: a caller that never declared its"
            " keys is not turned into a hard failure"
        ),
    )
    _ = db^
    print(
        "    [PASS] put refuses a minted doc-id for a declared table, and"
        " still mints for an undeclared one"
    )




# =============================================================================
# §2 — THE LITERAL RAW_EXPR. A `DbColVal.raw_expr` whose expression is a scalar
#      SQL LITERAL (`true` / `false` / `null` / an integer) must LAND, and an
#      expression the backend cannot evaluate must be REFUSED BY NAME.
#
# WHY. `SessionStore.revoke` / `.revoke_all_for_user` / `ApiKeyStore.revoke` /
# `.revoke_by_id` set `revoked` through `DbColVal.raw_expr("revoked", "true")`
# (the SQL bool literal, so the column is a real bool on pg and an integer 1 on
# sqlite). A document backend that skipped the term would commit a document
# whose `revoked` field never changed, bump `version` and return a NON-ZERO
# rows_affected: a user revoking every session after a password change would be
# told it worked, and no session would be revoked.
#
# The table below is the `session` row shape: the guard names `user_id` (NOT the
# PK), so this is the multi-row arm — the same resolver `revoke_all_for_user`
# reaches.
# =============================================================================

comptime _SESS: String = "gizmo_session"
comptime _USER_A: String = "11111111-1111-7111-8111-111111111111"
comptime _USER_B: String = "22222222-2222-7222-8222-222222222222"


def _sess_cols() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("user_id"))
    out.append(String("revoked"))
    out.append(String("version"))
    out.append(String("last_seen_at"))
    return out^


def _sess_row(
    id: String, user: String, revoked: String, last_seen: Int64
) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(id))
    out.append(DbValue.text(user))
    out.append(DbValue.text(revoked))
    out.append(DbValue.int8(Int64(1)))
    out.append(DbValue.timestamptz_micros(last_seen))
    return out^


def _sess_text(
    mut db: _FsDb, mut reactor: Reactor[NoopSink], id: String, col: String
) raises -> String:
    var got = db.get_by_key[_Rt](
        reactor, _SESS, _sess_cols(), String("id"), DbValue.text(id)
    )
    if not got:
        raise Error(String("session ") + id + String(" vanished"))
    var row = got.take()
    return row.get_text(row.column_index(col))


def _sess_is_null(
    mut db: _FsDb, mut reactor: Reactor[NoopSink], id: String, col: String
) raises -> Bool:
    var got = db.get_by_key[_Rt](
        reactor, _SESS, _sess_cols(), String("id"), DbValue.text(id)
    )
    if not got:
        raise Error(String("session ") + id + String(" vanished"))
    var row = got.take()
    return row.is_null(row.column_index(col))


def _seed_sessions(mut db: _FsDb, mut reactor: Reactor[NoopSink]) raises:
    """THREE live sessions for user A (the "signed in on three devices" shape)
    plus one for a DIFFERENT user, which must never be reachable."""
    _ = db.put[_Rt](
        reactor,
        _SESS,
        _sess_cols(),
        _sess_row(String("s-a1"), _USER_A, String("false"), Int64(10)),
    )
    _ = db.put[_Rt](
        reactor,
        _SESS,
        _sess_cols(),
        _sess_row(String("s-a2"), _USER_A, String("false"), Int64(20)),
    )
    _ = db.put[_Rt](
        reactor,
        _SESS,
        _sess_cols(),
        _sess_row(String("s-a3"), _USER_A, String("false"), Int64(30)),
    )
    _ = db.put[_Rt](
        reactor,
        _SESS,
        _sess_cols(),
        _sess_row(String("s-b1"), _USER_B, String("false"), Int64(40)),
    )


def _revoked_true_updates() raises -> List[DbColVal]:
    """BYTE-FOR-BYTE the two SET terms `SessionStore._revoked_true_updates` and
    `ApiKeyStore._revoked_true_updates` emit. Both are RAW_EXPR: the bool LITERAL
    `true` and the `version + 1` increment."""
    var out = List[DbColVal]()
    out.append(DbColVal.raw_expr(String("revoked"), String("true")))
    out.append(DbColVal.raw_expr(String("version"), String("version + 1")))
    return out^


# =============================================================================
# (f) ⭐ THE DEFECT. The exact `revoked = true, version = version + 1` update the
#     four revocation call sites emit reaches EVERY session of the user, and the
#     `revoked` field ACTUALLY CHANGES on each one.
# =============================================================================
def test_a_bool_literal_raw_expr_lands_on_every_matching_document() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _seed_sessions(db, reactor)

    var n = db.conditional_update[_Rt](
        reactor,
        _SESS,
        Filter.just(Pred.eq(String("user_id"), DbValue.text(_USER_A))),
        _revoked_true_updates(),
        False,
        Optional[String](),
        List[String](),
    )
    assert_equal(n, UInt64(3), "every one of the user's three sessions is CASed")

    # ⭐ THE ASSERTION THAT WAS MISSING. rows_affected was already non-zero before
    # the fix — the write committed, with the `revoked` term silently dropped.
    assert_equal(
        _sess_text(db, reactor, String("s-a1"), String("revoked")),
        String("true"),
        "the `revoked = true` bool LITERAL is written, not dropped",
    )
    assert_equal(
        _sess_text(db, reactor, String("s-a2"), String("revoked")),
        String("true"),
        "session 2 of 3 is revoked",
    )
    assert_equal(
        _sess_text(db, reactor, String("s-a3"), String("revoked")),
        String("true"),
        "session 3 of 3 is revoked",
    )
    # The increment in the SAME update list still lands — no regression.
    assert_equal(
        _sess_text(db, reactor, String("s-a1"), String("version")),
        String("2"),
        "the `version + 1` RAW_EXPR in the same SET list still increments",
    )
    # Another user's session is untouched, revoked flag included.
    assert_equal(
        _sess_text(db, reactor, String("s-b1"), String("revoked")),
        String("false"),
        "another user's session is never revoked",
    )
    assert_equal(
        _sess_text(db, reactor, String("s-b1"), String("version")),
        String("1"),
        "another user's session is not even version-bumped",
    )
    # An untouched column survives the full-doc write.
    assert_equal(
        _sess_text(db, reactor, String("s-a2"), String("last_seen_at")),
        String("20"),
        "a column the update does not name is preserved",
    )
    _ = db^
    print("    [PASS] a bool-literal RAW_EXPR lands on every matching document")


# =============================================================================
# (g) THE SAME TERM ON THE PK FAST PATH. `SessionStore.revoke` and
#     `ApiKeyStore.revoke_by_id` reach the single-document arm; the literal must
#     land there too — it is a SEPARATE code path through `_apply_updates`.
# =============================================================================
def test_a_bool_literal_raw_expr_lands_on_the_pk_fast_path() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _seed_sessions(db, reactor)

    var n = db.conditional_update[_Rt](
        reactor,
        _SESS,
        Filter.just(Pred.eq(String("id"), DbValue.text(String("s-a2")))),
        _revoked_true_updates(),
        False,
        Optional[String](),
        List[String](),
    )
    assert_equal(n, UInt64(1), "the PK-guarded revoke CASes exactly one document")
    assert_equal(
        _sess_text(db, reactor, String("s-a2"), String("revoked")),
        String("true"),
        "the PK fast path writes the bool literal too",
    )
    assert_equal(
        _sess_text(db, reactor, String("s-a1"), String("revoked")),
        String("false"),
        "a sibling session of the same user is untouched by a PK-guarded revoke",
    )
    _ = db^
    print("    [PASS] a bool-literal RAW_EXPR lands on the PK fast path")


# =============================================================================
# (h) THE REST OF THE CLOSED LITERAL VOCABULARY — `false`, `null`, an integer.
#     Each is a scalar with exactly one meaning on a document backend.
# =============================================================================
def test_the_false_null_and_integer_literals_land() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _seed_sessions(db, reactor)

    # Start from a revoked row so `false` is a real change, not a no-op.
    var to_true = List[DbColVal]()
    to_true.append(DbColVal.raw_expr(String("revoked"), String("TRUE")))
    _ = db.conditional_update[_Rt](
        reactor,
        _SESS,
        Filter.just(Pred.eq(String("id"), DbValue.text(String("s-a1")))),
        to_true,
        False,
        Optional[String](),
        List[String](),
    )
    assert_equal(
        _sess_text(db, reactor, String("s-a1"), String("revoked")),
        String("true"),
        "the literal is case-insensitive — `TRUE` is the same token as `true`",
    )

    var mixed = List[DbColVal]()
    mixed.append(DbColVal.raw_expr(String("revoked"), String("false")))
    mixed.append(DbColVal.raw_expr(String("last_seen_at"), String("-7")))
    mixed.append(DbColVal.raw_expr(String("version"), String("version + 1")))
    var n = db.conditional_update[_Rt](
        reactor,
        _SESS,
        Filter.just(Pred.eq(String("id"), DbValue.text(String("s-a1")))),
        mixed,
        False,
        Optional[String](),
        List[String](),
    )
    assert_equal(n, UInt64(1), "the mixed literal + increment update commits")
    assert_equal(
        _sess_text(db, reactor, String("s-a1"), String("revoked")),
        String("false"),
        "the `false` literal is written (un-revoke is a real state change)",
    )
    assert_equal(
        _sess_text(db, reactor, String("s-a1"), String("last_seen_at")),
        String("-7"),
        "a SIGNED integer literal is written as an integerValue",
    )
    # The first update in this case carried NO version term, so the row is still
    # at 1 when `mixed` runs: 1 -> 2 is the increment landing alongside the two
    # literals in the SAME SET list.
    assert_equal(
        _sess_text(db, reactor, String("s-a1"), String("version")),
        String("2"),
        "the increment alongside two literals still increments",
    )

    var to_null = List[DbColVal]()
    to_null.append(DbColVal.raw_expr(String("last_seen_at"), String("NULL")))
    _ = db.conditional_update[_Rt](
        reactor,
        _SESS,
        Filter.just(Pred.eq(String("id"), DbValue.text(String("s-a1")))),
        to_null,
        False,
        Optional[String](),
        List[String](),
    )
    assert_true(
        _sess_is_null(db, reactor, String("s-a1"), String("last_seen_at")),
        "the `NULL` literal nulls the field (it does not leave the old value)",
    )
    _ = db^
    print("    [PASS] the false / null / integer literals land")


# =============================================================================
# (i) ⛔ AN EXPRESSION THE BACKEND CANNOT EVALUATE IS REFUSED BY NAME.
#
#     A document backend has no SQL evaluator. A backend that drops what it
#     does not understand cannot be told apart from one that applied it; one
#     that refuses by name says so.
# =============================================================================
def test_an_unevaluable_raw_expr_is_refused_by_name() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db(MockFirestore())
    _seed_sessions(db, reactor)

    var bad = List[DbColVal]()
    bad.append(DbColVal.raw_expr(String("last_seen_at"), String("NOW()")))
    with assert_raises(contains="REFUSED raw SQL expression"):
        _ = db.conditional_update[_Rt](
            reactor,
            _SESS,
            Filter.just(Pred.eq(String("id"), DbValue.text(String("s-a1")))),
            bad,
            False,
            Optional[String](),
            List[String](),
        )

    # A `<other col> + 1` is NOT the increment shape either — the increment arm
    # reads the column it is assigning, so a cross-column bump has no meaning
    # here and must not be silently applied to the wrong column.
    var cross = List[DbColVal]()
    cross.append(DbColVal.raw_expr(String("version"), String("last_seen_at + 1")))
    with assert_raises(contains="REFUSED raw SQL expression"):
        _ = db.conditional_update[_Rt](
            reactor,
            _SESS,
            Filter.just(Pred.eq(String("id"), DbValue.text(String("s-a1")))),
            cross,
            False,
            Optional[String](),
            List[String](),
        )

    # The refusal happens BEFORE any document is written: the row is unchanged.
    assert_equal(
        _sess_text(db, reactor, String("s-a1"), String("version")),
        String("1"),
        "a refused update commits NOTHING — not even the terms it understood",
    )
    _ = db^
    print("    [PASS] an unevaluable raw expression is refused by name")


def main() raises:
    test_non_pk_guard_updates_every_matching_document()
    test_a_row_matching_only_the_first_equality_is_never_written()
    test_pk_guard_still_takes_the_direct_get_path()
    test_a_guard_no_row_satisfies_affects_zero_rows()
    test_put_refuses_a_minted_doc_id_for_a_declared_table()
    test_a_bool_literal_raw_expr_lands_on_every_matching_document()
    test_a_bool_literal_raw_expr_lands_on_the_pk_fast_path()
    test_the_false_null_and_integer_literals_land()
    test_an_unevaluable_raw_expr_is_refused_by_name()
    print(
        "PASS test_firestore_conditional_update_multirow (conditional_update is"
        " an UPDATE ... WHERE on the DOCUMENT backend)"
    )
