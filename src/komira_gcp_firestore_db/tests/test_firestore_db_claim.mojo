# =============================================================================
# test_firestore_db_claim.mojo — claim_rows, the FIFO claim loop: oldest
#   first, the claim's terms on every claimed row, a lost CAS skipped, and the
#   phase and count re-checked client-side.
# =============================================================================
#
# Runs on the in-process `MockFirestore`. The loop re-checks each candidate's
# phase and stops at n client-side; those checks only act when the backend
# returns MORE than the query asked for, which the mock never does. `_Lax` is
# a test exchange that forwards to the mock with the query's `where` and
# `limit` removed, standing in for a backend that answers a stale or
# over-long result.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_clock import now_unix_ms

from komira_db import (
    DbValue,
    DbColVal,
    DbRows,
    Pred,
    Filter,
    Order,
    PodNameMinter,
    derive_pod_name,
)

from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore.firestore_fake import (
    ExchangeAnswer,
    ExchangeConnector,
    HttpExchange,
)
from komira_gcp_firestore_v1.firestore import RunQueryRequest
from komira_proto_codec.codec import decode_json, encode_json

from komira_gcp_firestore_db import (
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]
comptime _LaxT = ExchangeConnector[_Lax]
comptime _LaxDb = FirestoreDatabase[_LaxT]

comptime _TABLE: String = "job"
comptime _STALE: String = (
    '{"error":{"code":400,"status":"FAILED_PRECONDITION","message":"stale"}}'
)


struct _Lax(HttpExchange, Movable, Deinitable):
    """The mock, answering every RunQuery as if it had no `where` and no
    `limit`: the whole collection (still ordered)."""

    var inner: MockFirestore

    def __init__(out self, var inner: MockFirestore):
        self.inner = inner^

    def answer(
        mut self, method: String, target: String, body: String
    ) raises -> ExchangeAnswer:
        if target.endswith(":runQuery"):
            var req = decode_json[RunQueryRequest](body)
            var q = req.structured_query.value().copy()
            q.where = None
            q.limit = None
            req.structured_query = q^
            return self.inner.answer(method, target, encode_json(req))
        return self.inner.answer(method, target, body)


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _fs_db(mock: MockFirestore) -> _FsDb:
    var client = FirestoreClient[_MockT](
        mock.connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    return _FsDb(client^)


def _lax_db(mock: MockFirestore) -> _LaxDb:
    var conn = _LaxT(ArcPointer[_Lax](_Lax(mock.share())))
    var client = FirestoreClient[_LaxT](
        conn^,
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    return _LaxDb(client^)


def _cols() -> List[String]:
    var out = List[String]()
    out.append(String("id"))
    out.append(String("phase"))
    out.append(String("created_at"))
    out.append(String("version"))
    return out^


def _row(id: String, phase: String, created: Int64) -> List[DbValue]:
    var out = List[DbValue]()
    out.append(DbValue.text(id))
    out.append(DbValue.text(phase))
    out.append(DbValue.int8(created))
    out.append(DbValue.int8(Int64(1)))
    return out^


def _seed(mut db: _FsDb, mut reactor: Reactor[NoopSink]) raises:
    """Three PENDING jobs whose creation order differs from their id order,
    and one RUNNING job created first."""
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("job-c", "PENDING", 30))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("job-a", "PENDING", 10))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("job-b", "PENDING", 20))
    _ = db.put[_Rt](reactor, _TABLE, _cols(), _row("job-r", "RUNNING", 5))


def _now_cols() -> List[String]:
    var out = List[String]()
    out.append(String("updated_at"))
    return out^


def _ids(rows: DbRows) raises -> String:
    var out = String("")
    var c = rows.column_index("id")
    for i in range(rows.__len__()):
        if i > 0:
            out += ","
        out += rows.row(i).get_text(c)
    return out^


def _phase_of(mut db: _FsDb, mut reactor: Reactor[NoopSink], id: String) raises -> String:
    var got = db.get_by_key[_Rt](reactor, _TABLE, _cols(), String("id"), DbValue.text(id))
    var row = got.take()
    return row.get_text(row.column_index("phase"))


# =============================================================================
# 1. claim_rows claims the OLDEST n PENDING rows, moves each to the new phase,
#    applies the extra terms, bumps the version, stamps now_cols, and derives
#    pod_name from the row's id; the result carries every field.
# =============================================================================
def test_claim_rows_claims_oldest_first() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _seed(db, reactor)
    var extra = List[DbColVal]()
    extra.append(DbColVal.bind(String("worker"), DbValue.text("w-1")))
    var t0 = now_unix_ms() * 1000

    var rows = db.claim_rows[_Rt](
        reactor, _TABLE, 2, Filter(), List[Order](), String("phase"),
        String("PENDING"), String("RUNNING"), extra, PodNameMinter(String("pod")),
        Optional[String](String("version")), _now_cols(),
    )
    assert_equal(_ids(rows), String("job-a,job-b"), "the two OLDEST pending, oldest first")
    var phase = rows.column_index("phase")
    var worker = rows.column_index("worker")
    var version = rows.column_index("version")
    var pod = rows.column_index("pod_name")
    var updated = rows.column_index("updated_at")
    assert_true(worker >= 0 and pod >= 0 and updated >= 0, "every field comes back")
    for i in range(rows.__len__()):
        ref r = rows.row(i)
        assert_equal(r.get_text(phase), String("RUNNING"))
        assert_equal(r.get_text(worker), String("w-1"), "the extra term lands")
        assert_equal(r.get_int8(version), Int64(2), "the version is bumped once")
        assert_equal(
            r.get_text(pod),
            derive_pod_name(String("pod"), r.get_text(rows.column_index("id"))),
            "pod_name is derived from THIS row's id",
        )
        assert_true(r.get_int8(updated) >= t0, "now_cols carry the claim's clock")
    assert_equal(
        rows.row(0).get_int8(updated),
        rows.row(1).get_int8(updated),
        "one clock reading per claim",
    )
    assert_equal(_phase_of(db, reactor, "job-c"), String("PENDING"), "the third is left")
    assert_equal(_phase_of(db, reactor, "job-r"), String("RUNNING"))

    # The next claim, with no minter, takes what is left and writes no pod_name.
    var rest = db.claim_rows[_Rt](
        reactor, _TABLE, 5, Filter(), List[Order](), String("phase"),
        String("PENDING"), String("RUNNING"), List[DbColVal](), PodNameMinter(),
        Optional[String](), List[String](),
    )
    assert_equal(_ids(rest), String("job-c"))
    assert_true(rest.column_index("pod_name") < 0, "an inactive minter writes no pod_name")
    assert_equal(
        rest.row(0).get_int8(rest.column_index("version")),
        Int64(1),
        "no version column named -> no bump",
    )

    # Nothing pending: an empty result with no columns.
    var none = db.claim_rows[_Rt](
        reactor, _TABLE, 5, Filter(), List[Order](), String("phase"),
        String("PENDING"), String("RUNNING"), List[DbColVal](), PodNameMinter(),
        Optional[String](), List[String](),
    )
    assert_equal(none.__len__(), 0)
    _ = db^
    print("    [PASS] claim_rows claims the oldest n pending rows")


# =============================================================================
# 2. A claim whose CAS loses (a racer moved the row) SKIPS that row and claims
#    the next one.
# =============================================================================
def test_claim_rows_skips_a_row_whose_cas_lost() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _seed(db, reactor)
    var fault = mock.share()
    fault.fail_next_commit(400, String(_STALE))
    var rows = db.claim_rows[_Rt](
        reactor, _TABLE, 1, Filter(), List[Order](), String("phase"),
        String("PENDING"), String("RUNNING"), List[DbColVal](), PodNameMinter(),
        Optional[String](String("version")), List[String](),
    )
    # n = 1 queries one row; its CAS lost, so this claim returns nothing ...
    assert_equal(rows.__len__(), 0, "a lost CAS is skipped, not returned")
    assert_equal(_phase_of(db, reactor, "job-a"), String("PENDING"), "and not written")
    # ... and the next claim gets it.
    var again = db.claim_rows[_Rt](
        reactor, _TABLE, 1, Filter(), List[Order](), String("phase"),
        String("PENDING"), String("RUNNING"), List[DbColVal](), PodNameMinter(),
        Optional[String](String("version")), List[String](),
    )
    assert_equal(_ids(again), String("job-a"))

    # n = 2 with the first CAS lost: the second row is still claimed.
    fault.fail_next_commit(400, String(_STALE))
    var two = db.claim_rows[_Rt](
        reactor, _TABLE, 2, Filter(), List[Order](), String("phase"),
        String("PENDING"), String("RUNNING"), List[DbColVal](), PodNameMinter(),
        Optional[String](String("version")), List[String](),
    )
    assert_equal(_ids(two), String("job-c"), "the lost row is skipped, the next claimed")
    assert_equal(_phase_of(db, reactor, "job-b"), String("PENDING"))
    _ = db^
    print("    [PASS] claim_rows skips a row whose CAS lost")


# =============================================================================
# 3. Against a backend that answers MORE than the query asked for, the driver
#    still claims only rows at from_phase, and at most n of them.
# =============================================================================
def test_claim_rows_rechecks_phase_and_count_client_side() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var db = _fs_db(mock)
    _seed(db, reactor)
    var lax = _lax_db(mock)
    # The lax backend answers all four jobs, the RUNNING one first.
    var rows = lax.claim_rows[_Rt](
        reactor, _TABLE, 2, Filter(), List[Order](), String("phase"),
        String("PENDING"), String("DONE"), List[DbColVal](), PodNameMinter(),
        Optional[String](String("version")), List[String](),
    )
    assert_equal(_ids(rows), String("job-a,job-b"))
    assert_equal(_phase_of(db, reactor, "job-r"), String("RUNNING"), "not at from_phase: skipped")
    assert_equal(_phase_of(db, reactor, "job-c"), String("PENDING"), "past n: not claimed")
    _ = lax^
    _ = db^
    print("    [PASS] claim_rows re-checks the phase and the count")


def main() raises:
    test_claim_rows_claims_oldest_first()
    test_claim_rows_skips_a_row_whose_cas_lost()
    test_claim_rows_rechecks_phase_and_count_client_side()
    print("PASS test_firestore_db_claim")
