# =============================================================================
# test_firestore_index_guard.mojo — THE UNDECLARED-COMPOSITE-INDEX FALSIFIER:
#   the Firestore driver must REFUSE a query whose shape Firestore will not serve
#   off automatic single-field indexes and for which NO composite index has been
#   declared to it.
# =============================================================================
#
# THE LIVE OUTAGE THIS ENCODES (measured on every deployed database). Two list
# endpoints of a service, `repo` and `api_key` by workspace, both returned 500
# FAILED_PRECONDITION. Both are the same shape:
#
#     FROM repo WHERE workspace_id == <wid> ORDER BY name ASC
#
# — one equality plus an ORDER BY on a DIFFERENT field. Firestore serves
# multi-EQUALITY-with-no-ordering off its automatic single-field indexes (zigzag
# merge join), but the moment an ORDER BY lands on a non-equality field (or an
# inequality appears) it demands a COMPOSITE index and 400/500s
# FAILED_PRECONDITION until one exists.
#
# ★ WHY NO TEST SAW IT. The store tests for BOTH broken queries EXIST and are
# GREEN — they run against SQLite, the one backend that never asks for a
# composite index. The suite passed because the backend under test cannot
# reproduce the failure. That is a structural blind spot, not a missing test:
# every ordered list scan in the repo is exposed to it and none of them are
# covered.
#
# WHAT THIS FILE ASSERTS. That the driver itself — not the cloud, not a reviewer
# — is the thing that refuses. The check lives at `_build_structured_query`,
# which is the single site where a neutral (Filter, Order) becomes a Firestore
# structuredQuery, and which receives the PUSHED filter, so the shape it judges
# is the true WIRE shape rather than what the caller believed it asked for.
#
# THE FALSIFIERS (each FAILS on the pre-fix driver, which builds and runs the
# query silently and returns rows from the mock):
#   1. REPO LIST (the exact live 500): workspace_id EQUAL + ORDER BY name ASC,
#      driver told about NO indexes -> must RAISE.
#   2. API-KEY LIST (the second live 500): the same shape on `api_key`.
#   3. INEQUALITY: an inequality with no ordering at all still needs a composite
#      index once it is paired with an equality on another field -> must RAISE.
#   4. THE NEGATIVE ARM (this is what keeps the predicate honest): a query
#      Firestore genuinely serves off automatic indexes must NOT be refused —
#      pure multi-equality with no ORDER BY, a single-field equality, an ORDER BY
#      on the SAME field as the only equality-free filter, and an unfiltered
#      ordered scan. A guard that refuses these would be a guard that had been
#      widened until it stopped meaning anything.
#   5. DECLARED-SHAPE ACCEPTANCE: the SAME repo query, with the composite index
#      DECLARED to the driver, must go through. This is the arm that proves the
#      fix is a lookup against a declaration and not a blanket ban on ORDER BY.
#   6. FIELD SENSITIVITY: a declared (workspace_id, name) index does NOT serve
#      (workspace_id, created_at). A composite index IS its ordered field list; a
#      guard that matched on collection name alone would pass shapes the cloud
#      rejects. ⚠ THIS ARM USED TO CARRY A "deliberate omission" SAYING AN
#      ASCENDING INDEX SERVES `ORDER BY name DESC` "because Firestore scans an
#      index in either direction". THAT WAS FALSE whenever the query has an
#      equality prefix, and live Firestore falsified it (see FALSIFIER 10). The reversal
#      is only available with NO prefix to flip; arm 10 owns the prefixed case.
#
# ZERO network, ZERO GCP: everything lands on the in-process mock transport.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import (
    DbValue,
    Pred,
    Filter,
    Order,
)

from komira_gcp_firestore.firestore_client import FirestoreClient

from komira_gcp_firestore_db import (
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
    DeclaredIndexSet,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]

comptime _WID: String = "ws-0001"


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _fs_db() -> _FsDb:
    """A driver that has been told about NO composite indexes at all — the
    state a database starts in until its caller declares any."""
    var client = FirestoreClient[_MockT](
        MockFirestore().connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    return _FsDb(client^, DeclaredIndexSet())


def _repo_cols() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("workspace_id"))
    out.append(String("name"))
    out.append(String("created_at"))
    return out^


def _eq(col: String, val: String) raises -> Filter:
    return Filter.just(Pred.eq(String(col), DbValue.text(val)))


def _order_asc(col: String) -> List[Order]:
    var out = List[Order]()
    out.append(Order.asc(String(col)))
    return out^


def _no_order() -> List[Order]:
    return List[Order]()


# =============================================================================
# FALSIFIER 1 — THE REPO LIST. The exact live-500 shape, on a driver with no
# declared indexes: `workspace_id == <wid> ORDER BY name ASC`.
#
# FAILS ON THE PRE-FIX DRIVER: `_build_structured_query` renders the orderBy and
# `run_query` returns happily off the mock, so no error is raised and the
# `assert_true(refused)` below is RED. On a live database the same code path reaches
# Firestore and comes back 500 FAILED_PRECONDITION.
# =============================================================================
def test_bug_repo_list_undeclared_composite_index_is_refused() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db()
    var refused = False
    var msg = String("")
    try:
        _ = db.query_rows[_Rt](
            reactor,
            String("repo"),
            _repo_cols(),
            _eq(String("workspace_id"), _WID),
            _order_asc(String("name")),
            Optional[UInt32](),
        )
    except e:
        refused = True
        msg = String(e)
    assert_true(
        refused,
        String(
            "FirestoreDatabase.query_rows built `FROM repo WHERE workspace_id =="
            " ... ORDER BY name ASC` with NO declared composite index. Firestore"
            " answers that shape 500 FAILED_PRECONDITION — the driver must"
            " refuse it here, where the shape is known, instead of shipping it"
            " to the cloud."
        ),
    )
    # The refusal has to be actionable: it must name the collection AND the
    # shape, because the whole failure mode is that nobody could tell which of
    # ~181 store call sites needed a declaration.
    assert_true(
        msg.find(String("repo")) >= 0,
        String("refusal must name the collection; got: ") + msg,
    )
    assert_true(
        msg.find(String("workspace_id")) >= 0,
        String("refusal must name the filter field; got: ") + msg,
    )
    assert_true(
        msg.find(String("name")) >= 0,
        String("refusal must name the ordered field; got: ") + msg,
    )


# =============================================================================
# FALSIFIER 2 — THE API-KEY LIST. The second live 500, same shape.
# =============================================================================
def test_bug_api_key_list_undeclared_composite_index_is_refused() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db()
    var refused = False
    try:
        _ = db.query_rows[_Rt](
            reactor,
            String("api_key"),
            _repo_cols(),
            _eq(String("workspace_id"), _WID),
            _order_asc(String("id")),
            Optional[UInt32](),
        )
    except e:
        refused = True
    assert_true(
        refused,
        String(
            "`FROM api_key WHERE workspace_id == ... ORDER BY id ASC` with no"
            " declared index must be refused (a live 500 otherwise)."
        ),
    )


# =============================================================================
# FALSIFIER 3 — INEQUALITY. An inequality on one field paired with an equality on
# another needs a composite index even with no ORDER BY at all.
# =============================================================================
def test_bug_inequality_plus_equality_undeclared_is_refused() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db()
    var preds = List[Pred]()
    preds.append(Pred.eq(String("workspace_id"), DbValue.text(_WID)))
    preds.append(Pred.lt(String("created_at"), DbValue.int8(Int64(99))))
    var refused = False
    try:
        _ = db.query_rows[_Rt](
            reactor,
            String("repo"),
            _repo_cols(),
            Filter.all_of(preds^),
            _no_order(),
            Optional[UInt32](),
        )
    except e:
        refused = True
    assert_true(
        refused,
        String(
            "an equality + an inequality on a DIFFERENT field needs a composite"
            " index on Firestore; it must be refused when undeclared."
        ),
    )


# =============================================================================
# FALSIFIER 4 — THE NEGATIVE ARM. Shapes Firestore genuinely serves off its
# automatic single-field indexes must NOT be refused. This is the arm that stops
# the guard from being widened into a ban on ordered queries.
# =============================================================================
def test_serveable_shapes_are_not_refused() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var db = _fs_db()

    # (a) single-field equality, no ordering — the auto single-field index.
    _ = db.query_rows[_Rt](
        reactor,
        String("repo"),
        _repo_cols(),
        _eq(String("workspace_id"), _WID),
        _no_order(),
        Optional[UInt32](),
    )

    # (b) MULTI-equality, no ordering — the zigzag merge join. No composite index.
    var preds = List[Pred]()
    preds.append(Pred.eq(String("workspace_id"), DbValue.text(_WID)))
    preds.append(Pred.eq(String("name"), DbValue.text(String("alpha"))))
    _ = db.query_rows[_Rt](
        reactor,
        String("repo"),
        _repo_cols(),
        Filter.all_of(preds^),
        _no_order(),
        Optional[UInt32](),
    )

    # (c) no filter at all, ordered by one field — a single-field index serves it.
    _ = db.query_rows[_Rt](
        reactor,
        String("repo"),
        _repo_cols(),
        Filter.none(),
        _order_asc(String("name")),
        Optional[UInt32](),
    )

    # (d) equality and ordering on the SAME field — the auto index serves it.
    _ = db.query_rows[_Rt](
        reactor,
        String("repo"),
        _repo_cols(),
        _eq(String("name"), String("alpha")),
        _order_asc(String("name")),
        Optional[UInt32](),
    )


# =============================================================================
# FALSIFIER 5 — DECLARED-SHAPE ACCEPTANCE. The same repo query goes through once
# the driver has been told the (workspace_id ASC, name ASC) composite index
# exists. Without this arm the fix could be "refuse everything ordered".
# =============================================================================
def test_declared_composite_index_admits_the_repo_list() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var declared = DeclaredIndexSet()
    declared.declare_asc(
        String("repo"), String("workspace_id"), String("name")
    )
    var client = FirestoreClient[_MockT](
        MockFirestore().connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var db = _FsDb(client^, declared^)
    # No `try` — this MUST NOT raise.
    _ = db.query_rows[_Rt](
        reactor,
        String("repo"),
        _repo_cols(),
        _eq(String("workspace_id"), _WID),
        _order_asc(String("name")),
        Optional[UInt32](),
    )


# =============================================================================
# FALSIFIER 6 — FIELD SENSITIVITY. A composite index IS its ordered field list.
# A declaration of (workspace_id, name) does not serve an ORDER BY created_at.
# =============================================================================
def test_declared_index_does_not_serve_a_different_shape() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var declared = DeclaredIndexSet()
    declared.declare_asc(
        String("repo"), String("workspace_id"), String("name")
    )
    var client = FirestoreClient[_MockT](
        MockFirestore().connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var db = _FsDb(client^, declared^)

    var refused_other_col = False
    try:
        _ = db.query_rows[_Rt](
            reactor,
            String("repo"),
            _repo_cols(),
            _eq(String("workspace_id"), _WID),
            _order_asc(String("created_at")),
            Optional[UInt32](),
        )
    except e:
        refused_other_col = True
    assert_true(
        refused_other_col,
        String(
            "a declared (workspace_id, name) index must NOT admit an ORDER BY"
            " created_at — that is a different composite index."
        ),
    )


# FALSIFIER 7 — THE LENIENT PARSE IS NOT QUIETLY SHORT. A caller that must not
# raise arms a driver with `parse_table_lenient`, which SKIPS a malformed line
# instead. On a well-formed table the two parses must agree line for line; on a
# malformed one the STRICT parse must raise, so a caller that can raise is never
# handed a silently shorter set.
# =============================================================================
comptime _TABLE: String = """# a comment line is skipped
task|list_id:A|archived_at:A|id:A
task|workspace_id:A|depends_on:C|id:A
review_comment|review_id:A|created_at:A|id:A
event|stream_id:A|seq:D
"""


def test_table_parses_strictly_and_leniently_alike() raises:
    var strict = DeclaredIndexSet.parse_table(_TABLE)
    var lenient = DeclaredIndexSet.parse_table_lenient(_TABLE)
    assert_equal(strict.__len__(), 4)
    assert_equal(lenient.__len__(), strict.__len__())
    for i in range(strict.__len__()):
        assert_equal(lenient.indexes[i].collection, strict.indexes[i].collection)
        assert_equal(len(lenient.indexes[i].fields), len(strict.indexes[i].fields))
    # The modes land where the table put them.
    assert_true(strict.indexes[1].fields[1].array_contains)
    assert_true(strict.indexes[3].fields[1].desc)

    var bad = String("task|list_id:A|id:X\nok|a:A|b:A\n")
    var raised = False
    try:
        _ = DeclaredIndexSet.parse_table(bad)
    except e:
        raised = True
        assert_true(String(e).find(String("unknown mode")) >= 0)
    assert_true(raised, String("the strict parse must refuse an unknown mode"))
    # The lenient parse keeps the good line and drops the bad one, which is why
    # a caller that can raise must use the strict one.
    assert_equal(DeclaredIndexSet.parse_table_lenient(bad).__len__(), 1)


# =============================================================================
# FALSIFIER 8 — THE ONE-ARGUMENT DRIVER DECLARES NOTHING. A driver built without
# a `DeclaredIndexSet` refuses a composite shape; the same driver built with
# that shape declared admits it. So the default is neither "allow everything"
# nor a set nobody can see.
# =============================================================================
def test_default_arming_refuses_and_a_declaration_admits() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var client = FirestoreClient[_MockT](
        MockFirestore().connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var db = _FsDb(client^)  # the ONE-argument form: nothing declared

    var refused = False
    try:
        _ = db.query_rows[_Rt](
            reactor,
            String("repo"),
            _repo_cols(),
            _eq(String("workspace_id"), _WID),
            _order_asc(String("name")),
            Optional[UInt32](),
        )
    except e:
        refused = True
    assert_true(
        refused,
        String("a driver with no declared indexes must refuse a composite shape"),
    )

    var declared = DeclaredIndexSet()
    declared.declare_asc(String("repo"), String("workspace_id"), String("name"))
    var client2 = FirestoreClient[_MockT](
        MockFirestore().connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var db2 = _FsDb(client2^, declared^)
    # Declared -> goes through. No `try`.
    _ = db2.query_rows[_Rt](
        reactor,
        String("repo"),
        _repo_cols(),
        _eq(String("workspace_id"), _WID),
        _order_asc(String("name")),
        Optional[UInt32](),
    )


# =============================================================================
# FALSIFIER 10 — ⛔ ORDER-BY **DIRECTION** IS PART OF THE INDEX, AND LIVE
# FIRESTORE PROVED IT. THIS ARM REPLACES A DELIBERATE OMISSION THAT WAS WRONG.
#
# Arm 6's header note and this module's §"DIRECTIONS" paragraph both once stated
# that "Firestore scans an index in either direction ... a single-term ORDER BY
# is therefore always direction-agnostic". That is FALSE when the query carries
# an EQUALITY PREFIX, and a live database is the falsifier.
#
# MEASURED on a deployed service, every minute, HTTP 500 on a scheduled job:
#
#   FirestoreDatabasePrecondition: run_query: :runQuery
#   (HTTP 400 [FAILED_PRECONDITION]): The query requires an index.
#   ... collectionGroups/run/indexes/_
#       status ASC, updated_at DESC, __name__ DESC
#
# ★ IT IS A CONTROLLED DIFFERENTIAL, NOT AN INFERENCE. The job issues TWO shapes
# over `run` that differ in the ORDER BY DIRECTION AND IN NOTHING ELSE — same
# collection, same equality, same inequality column:
#     silent runs:      status == R AND updated_at <  cutoff  ORDER BY updated_at ASC   -> 200
#     first-step runs:  status == R AND updated_at >= since   ORDER BY updated_at DESC  -> 500
# Only ONE composite index is declared, (status ASC, updated_at ASC). The ASC
# arm is served by it; the DESC arm is not, and its 500 took the whole job run
# down with it.
#
# ⛔ DO NOT "FIX" THIS BY DELETING THE ASSERTION. The guard is permitted to accept
# a full reversal only when there is NO equality prefix to flip; with a prefix,
# the directions of the ordered suffix must MATCH the declared index.
# =============================================================================
def test_equality_prefix_makes_order_by_direction_load_bearing() raises:
    var rt = _rt()
    ref reactor = rt.reactor()

    # The ONE composite index the measured database declared for this
    # collection, and the only `run` index either arm can be served by.
    var declared = DeclaredIndexSet()
    declared.declare_asc(
        String("run"), String("status"), String("updated_at")
    )
    var client = FirestoreClient[_MockT](
        MockFirestore().connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var db = _FsDb(client^, declared^)

    var cols = List[String]()
    cols.append(String("id"))
    cols.append(String("status"))
    cols.append(String("updated_at"))

    # ---- CONTROL: the SILENT arm (ASC) is served, and must NOT be refused -----
    var asc_preds = List[Pred]()
    asc_preds.append(Pred.eq(String("status"), DbValue.int4(Int32(0))))
    asc_preds.append(
        Pred.lt(String("updated_at"), DbValue.int8(Int64(1_000_000)))
    )
    var asc = List[Order]()
    asc.append(Order.asc(String("updated_at")))
    var asc_refused = False
    try:
        _ = db.query_rows[_Rt](
            reactor,
            String("run"),
            cols.copy(),
            Filter.all_of(asc_preds^),
            asc^,
            Optional[UInt32](UInt32(64)),
        )
    except e:
        asc_refused = True
    assert_false(
        asc_refused,
        String(
            "the SILENT arm (ORDER BY updated_at ASC) IS served by the declared"
            " (status ASC, updated_at ASC) index and returns 200 live —"
            " refusing it would make this guard reject a working query."
        ),
    )

    # ---- THE FALSIFIER: the FIRST-STEP arm (DESC) is NOT served --------------
    var desc_preds = List[Pred]()
    desc_preds.append(Pred.eq(String("status"), DbValue.int4(Int32(0))))
    desc_preds.append(
        Pred.gte(String("updated_at"), DbValue.int8(Int64(1_000_000)))
    )
    var desc = List[Order]()
    desc.append(Order.descending(String("updated_at")))
    var desc_refused = False
    try:
        _ = db.query_rows[_Rt](
            reactor,
            String("run"),
            cols^,
            Filter.all_of(desc_preds^),
            desc^,
            Optional[UInt32](UInt32(16)),
        )
    except e:
        desc_refused = True
    assert_true(
        desc_refused,
        String(
            "a declared (status ASC, updated_at ASC) index must NOT admit"
            " `status == R AND updated_at >= s ORDER BY updated_at DESC`."
            " Firestore refuses it: measured on example-project,"
            " HTTP 400 FAILED_PRECONDITION demanding a SEPARATE composite"
            " (status ASC, updated_at DESC, __name__ DESC). The equality"
            " prefix is what makes the direction load-bearing — the full"
            " reversal Firestore does serve would have to flip `status` too."
        ),
    )


# =============================================================================
# FALSIFIER 11 — ⛔ TWO RANGE FIELDS AND **NO** ORDER BY: THEIR RELATIVE ORDER IN
# THE INDEX IS NOT THE QUERY'S TO DICTATE. MEASURED AGAINST LIVE FIRESTORE.
#
# THE OUTAGE. A job reconciler's stale-job scan — the ONLY path that moves a
# job out of ASSIGNED — was dark continuously, logging every ~8-18s:
#
#   reconciler: find_stale_jobs failed — the scan is SKIPPED this pass:
#   firestore: UNDECLARED COMPOSITE INDEX for collection 'jobs'. The query
#   `FROM jobs WHERE phase == AND updated_at <range> AND pod_name <range>`
#   cannot be served ...
#
# It was THIS GUARD refusing, client-side, before Firestore was ever asked.
# The scan appends its predicates in the order
# [phase(eq), updated_at(lt), pod_name(gte), pod_name(lt)], so the derivation
# demanded (phase, updated_at, pod_name) — while the declaration and the LIVE
# index both say (phase, pod_name, updated_at).
#
# ★ FIRESTORE ITSELF SETTLED IT, READ-ONLY. A `:runQuery` carrying
# EXACTLY this shape, against a database where (phase, pod_name, updated_at)
# was the ONLY three-field `jobs` index in existence:
#
#   HTTP 200, 5 rows — and returned ordered by `pod_name` ASC, which is the
#   signature of that index serving the scan. There is NO (phase, updated_at, pod_name)
#   index in that database, so nothing else could have served it.
#
# THE RULE THAT FOLLOWS. A query with NO `orderBy` imposes NO ordering
# constraint, so the inequality fields after the equality prefix may appear in
# the index in ANY order — Firestore picks an index and the implicit result
# ordering follows it. That is the same reasoning that already matches the
# EQUALITY prefix as a SET, applied to the one other block the query does not
# order.
#
# ⛔ THIS DOES NOT LOOSEN FALSIFIER 10, AND MUST NOT BE READ AS DOING SO. That
# arm is about ORDER BY **DIRECTION** under an equality prefix, and it stays
# exactly as strict: the carve-out here applies ONLY when `order_fields` is
# EMPTY. A query that names an ORDER BY is still matched position-and-direction
# sensitively, which is what the measured live 500 proved it must be.
# =============================================================================
def test_two_ranges_without_order_by_match_the_index_in_either_order() raises:
    """⛔ A job reconciler's stale-job scan, against the index it was declared
    with.

    A refusal here is a reconciler that never moves a job out of ASSIGNED. The
    shape is one a `find_stale_jobs` query emits verbatim: its predicates
    appended in the order [phase(eq), updated_at(lt), pod_name(gte),
    pod_name(lt)], against an index declared (phase, pod_name, updated_at)."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var client = FirestoreClient[_MockT](
        MockFirestore().connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var declared = DeclaredIndexSet.parse_table(
        String("jobs|phase:A|pod_name:A|updated_at:A")
    )
    var db = _FsDb(client^, declared^)

    var cols = List[String]()
    cols.append(String("id"))
    cols.append(String("phase"))
    cols.append(String("pod_name"))
    cols.append(String("updated_at"))

    # `phase == ASSIGNED AND updated_at < cutoff AND pod_name >= 'job-'
    #  AND pod_name < 'job.'`, appended in the scan's own order.
    var preds = List[Pred]()
    preds.append(Pred.eq(String("phase"), DbValue.text(String("ASSIGNED"))))
    preds.append(
        Pred.lt(String("updated_at"), DbValue.int8(Int64(1_789_000_000_000_000)))
    )
    preds.append(
        Pred.gte(String("pod_name"), DbValue.text(String("job-")))
    )
    preds.append(
        Pred.lt(String("pod_name"), DbValue.text(String("job.")))
    )

    # RAISES on the pre-fix guard: the derivation demands (phase, updated_at,
    # pod_name) and the declaration is (phase, pod_name, updated_at).
    _ = db.query_rows[_Rt](
        reactor,
        String("jobs"),
        cols^,
        Filter.all_of(preds^),
        _no_order(),
        Optional[UInt32](UInt32(512)),
    )


def main() raises:
    test_bug_repo_list_undeclared_composite_index_is_refused()
    test_bug_api_key_list_undeclared_composite_index_is_refused()
    test_bug_inequality_plus_equality_undeclared_is_refused()
    test_serveable_shapes_are_not_refused()
    test_declared_composite_index_admits_the_repo_list()
    test_declared_index_does_not_serve_a_different_shape()
    test_table_parses_strictly_and_leniently_alike()
    test_default_arming_refuses_and_a_declaration_admits()
    test_equality_prefix_makes_order_by_direction_load_bearing()
    test_two_ranges_without_order_by_match_the_index_in_either_order()
    print("OK test_firestore_index_guard")
