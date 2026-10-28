# =============================================================================
# test_cdc_apply_failure_and_order.mojo — failed commits, replay and ordering.
# =============================================================================
#
# Runs `apply_batch` over a store that refuses the table-metadata conditional
# write a scripted number of times.
#
# What each test proves:
#   - a commit that raises leaves the caller's `ShardPositions` unchanged, so the
#     same batch applied again commits instead of being skipped as a replay;
#   - a failed commit leaves the table's committed summary and rows unchanged;
#   - replaying an older batch is skipped and the position never moves back;
#     numeric order is used ("10" is after "9"); a MODIFY or REMOVE of a key
#     committed in an earlier batch masks the earlier row; a key removed and
#     inserted again later is live;
#   - an insert and a remove of one key in one batch commit no row;
#   - a record that is not full-schema-width raises and commits nothing;
#   - an empty batch commits nothing, and `seq_gt` ignores leading zeros;
#   - an error on one shard in `run_ingest_pass` leaves the shards that already
#     committed in the table, and the next pass resumes from the table.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_true, assert_equal, assert_false

from komira_objectstore import SharedInMemoryConditionalStore
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy, ListResult, ObjectMeta, WritePrecondition,
)
from komira_snapshotter.change_stream_trait import (
    MultiShardChangeStreamListener, ChangeRecord, ChangeBatch, make_insert_record, make_modify_record,
    make_remove_record,
)
from komira_iceberg import (
    ICE_T_LONG, ICE_T_STRING, IcebergSchema, IcebergTableWriter, RowCell,
    make_long_cell, make_string_cell, gen_table_uuid, SummaryKV,
)
from komira_cdc_ingest import (
    CdcApplyConfig, ShardPositions, apply_batch, seq_gt,
    derive_positions_from_table, run_ingest_pass,
)


struct Fail(Movable):
    var n: Int
    var seen: Int
    def __init__(out self, n: Int):
        self.n = n
        self.seen = 0


struct FaultyStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    var inner: SharedInMemoryConditionalStore
    var f: ArcPointer[Fail]
    def __init__(out self, var inner: SharedInMemoryConditionalStore, f: ArcPointer[Fail]):
        self.inner = inner^
        self.f = f
    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)
    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)
    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()
    def conditional_put(self, path: Path, bytes: List[UInt8], precond: WritePrecondition) raises -> ObjectMeta:
        var s = path.raw()
        if s.endswith(".metadata.json"):
            self.f[].seen += 1
            if self.f[].n > 0:
                self.f[].n -= 1
                raise Error("scripted: commit refused")
        return self.inner.conditional_put(path, bytes, precond)
    def compare_and_swap(self, path: Path, bytes: List[UInt8], expected_version: String) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)
    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)
    def get_range(self, path: Path, start: Int64, length: Int64) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)
    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)
    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("name"), ICE_T_STRING, required=True)
    return s^

def _config() -> CdcApplyConfig:
    var ids = List[Int]()
    ids.append(1)
    return CdcApplyConfig(_schema(), ids^)

def _row(id: Int64, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    return r^

def _ins(id: Int64, var n: String, var seq: String) -> ChangeRecord:
    return make_insert_record(_row(id, String("k")), _row(id, n^), seq^)
def _mod(id: Int64, var o: String, var n: String, var seq: String) -> ChangeRecord:
    return make_modify_record(_row(id, String("k")), _row(id, o^), _row(id, n^), seq^)
def _rm(id: Int64, var n: String, var seq: String) -> ChangeRecord:
    return make_remove_record(_row(id, String("k")), _row(id, n^), seq^)

def _b1(var r: ChangeRecord) -> ChangeBatch:
    var l = List[ChangeRecord]()
    l.append(r^)
    return ChangeBatch(l^, String("n"), False)

def _name(rows: List[List[RowCell]], id: Int64) raises -> String:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return rows[i][1].as_string()
    return String("<absent>")

def _writer(f: ArcPointer[Fail], inner: SharedInMemoryConditionalStore, uuid: String) raises -> IcebergTableWriter[FaultyStore]:
    return IcebergTableWriter[FaultyStore](
        FaultyStore(inner.clone(), f), String("w/db/t"), _schema(), uuid.copy())


def test_failed_commit_leaves_position_and_retry_applies() raises:
    var inner = SharedInMemoryConditionalStore()
    var f = ArcPointer[Fail](Fail(1))
    var uuid = gen_table_uuid()
    var w = _writer(f, inner, uuid)
    var cfg = _config()
    var pos = ShardPositions()
    var raised = False
    try:
        _ = apply_batch(w, cfg, String("s"), _b1(_ins(Int64(1), String("a"), String("100"))), pos)
    except e:
        raised = True
    assert_true(raised, "commit failure propagates")
    # retry same batch with same positions object
    var st = apply_batch(w, cfg, String("s"), _b1(_ins(Int64(1), String("a"), String("100"))), pos)
    assert_true(st.committed, "retry commits (not skipped as replay)")
    assert_equal(_name(w.read_live_rows(), Int64(1)), String("a"))
    assert_equal(pos.get(String("s")), String("100"))

def test_failed_commit_table_summary_unchanged() raises:
    var inner = SharedInMemoryConditionalStore()
    var f = ArcPointer[Fail](Fail(0))
    var uuid = gen_table_uuid()
    var w = _writer(f, inner, uuid)
    var cfg = _config()
    var pos = ShardPositions()
    _ = apply_batch(w, cfg, String("s"), _b1(_ins(Int64(1), String("a"), String("100"))), pos)
    f[].n = 1
    try:
        _ = apply_batch(w, cfg, String("s"), _b1(_mod(Int64(1), String("a"), String("b"), String("101"))), pos)
    except e:
        pass
    var w2 = _writer(ArcPointer[Fail](Fail(0)), inner, uuid)
    var p2 = ShardPositions.from_summary_kvs(w2.read_current_summary())
    assert_equal(p2.get(String("s")), String("100"))
    assert_equal(_name(w2.read_live_rows(), Int64(1)), String("a"))

def test_replay_and_order_across_batches() raises:
    var inner = SharedInMemoryConditionalStore()
    var f = ArcPointer[Fail](Fail(0))
    var uuid = gen_table_uuid()
    var w = _writer(f, inner, uuid)
    var cfg = _config()
    var pos = ShardPositions()
    _ = apply_batch(w, cfg, String("s"), _b1(_ins(Int64(1), String("a"), String("9"))), pos)
    _ = apply_batch(w, cfg, String("s"), _b1(_mod(Int64(1), String("a"), String("b"), String("10"))), pos)
    # replay older batch (seq 9 < 10 numerically; "9" > "10" lexically)
    var st = apply_batch(w, cfg, String("s"), _b1(_ins(Int64(1), String("a"), String("9"))), pos)
    assert_false(st.committed)
    assert_equal(st.skipped, 1)
    assert_equal(pos.get(String("s")), String("10"), "monotonic")
    var live = w.read_live_rows()
    assert_equal(len(live), 1)
    assert_equal(_name(live, Int64(1)), String("b"))
    # mixed batch: one old, one new
    var l = List[ChangeRecord]()
    l.append(_mod(Int64(1), String("a"), String("zzz"), String("10")))
    l.append(_mod(Int64(1), String("b"), String("c"), String("11")))
    var st2 = apply_batch(w, cfg, String("s"), ChangeBatch(l^, String("n"), False), pos)
    assert_equal(st2.skipped, 1)
    assert_equal(_name(w.read_live_rows(), Int64(1)), String("c"))
    assert_equal(pos.get(String("s")), String("11"))
    # remove then reinsert within later batches
    _ = apply_batch(w, cfg, String("s"), _b1(_rm(Int64(1), String("c"), String("12"))), pos)
    assert_equal(len(w.read_live_rows()), 0)
    _ = apply_batch(w, cfg, String("s"), _b1(_ins(Int64(1), String("d"), String("13"))), pos)
    assert_equal(_name(w.read_live_rows(), Int64(1)), String("d"))

def test_in_batch_insert_remove_insert() raises:
    var inner = SharedInMemoryConditionalStore()
    var w = _writer(ArcPointer[Fail](Fail(0)), inner, gen_table_uuid())
    var cfg = _config()
    var pos = ShardPositions()
    var l = List[ChangeRecord]()
    l.append(_ins(Int64(1), String("a"), String("1")))
    l.append(_rm(Int64(1), String("a"), String("2")))
    var st = apply_batch(w, cfg, String("s"), ChangeBatch(l^, String("n"), False), pos)
    assert_true(st.committed)
    assert_equal(st.appended, 0)
    assert_equal(len(w.read_live_rows()), 0)
    assert_equal(pos.get(String("s")), String("2"))

def test_bad_record_raises_no_commit() raises:
    var inner = SharedInMemoryConditionalStore()
    var w = _writer(ArcPointer[Fail](Fail(0)), inner, gen_table_uuid())
    var cfg = _config()
    var pos = ShardPositions()
    var short = List[RowCell]()
    short.append(make_long_cell(Int64(1)))
    var rec = make_insert_record(short.copy(), short.copy(), String("5"))
    var raised = False
    try:
        _ = apply_batch(w, cfg, String("s"), _b1(rec^), pos)
    except e:
        raised = True
    assert_true(raised)
    assert_equal(pos.get(String("s")), String(""))
    assert_equal(len(w.read_current_summary()), 0)

def test_empty_batch_and_zero_padded() raises:
    var inner = SharedInMemoryConditionalStore()
    var w = _writer(ArcPointer[Fail](Fail(0)), inner, gen_table_uuid())
    var cfg = _config()
    var pos = ShardPositions()
    var st = apply_batch(w, cfg, String("s"), ChangeBatch(List[ChangeRecord](), String("n"), False), pos)
    assert_false(st.committed)
    assert_equal(len(w.read_current_summary()), 0)
    assert_true(seq_gt(String("0010"), String("9")))
    assert_false(seq_gt(String("0009"), String("9")))
    assert_false(seq_gt(String("9"), String("9")))
    assert_true(seq_gt(String("1"), String("0")))
    assert_false(seq_gt(String("0"), String("00")))
    assert_true(seq_gt(String("1"), String("")))
    assert_false(seq_gt(String(""), String("1")))

def test_positions_roundtrip() raises:
    var p = ShardPositions()
    p.set(String("shardId-0001.x"), String("5"))
    p.set(String("b"), String("6"))
    p.set(String("b"), String("7"))
    assert_equal(p.num_shards(), 2)
    var kvs = p.to_summary_kvs()
    kvs.append(SummaryKV(String("total-records"), String("3")))
    var q = ShardPositions.from_summary_kvs(kvs)
    assert_equal(q.num_shards(), 2)
    assert_equal(q.get(String("shardId-0001.x")), String("5"))
    assert_equal(q.get(String("b")), String("7"))
    assert_false(q.has(String("total-records")))

def test_other_shard_position_preserved_in_stamp() raises:
    var inner = SharedInMemoryConditionalStore()
    var w = _writer(ArcPointer[Fail](Fail(0)), inner, gen_table_uuid())
    var cfg = _config()
    var pos = ShardPositions()
    _ = apply_batch(w, cfg, String("A"), _b1(_ins(Int64(1), String("a"), String("5"))), pos)
    _ = apply_batch(w, cfg, String("B"), _b1(_ins(Int64(2), String("b"), String("7"))), pos)
    var fs = FaultyStore(inner.clone(), ArcPointer[Fail](Fail(0)))
    var p = derive_positions_from_table(fs, String("w/db/t"))
    assert_equal(p.get(String("A")), String("5"))
    assert_equal(p.get(String("B")), String("7"))


struct TwoShardListener(MultiShardChangeStreamListener, Movable, Deinitable):
    """Returns shard "A" then shard "B", each with its scripted batch."""
    var _a: ChangeBatch
    var _b: ChangeBatch
    def __init__(out self, var a: ChangeBatch, var b: ChangeBatch):
        self._a = a^
        self._b = b^
    def list_shard_ids(mut self) raises -> List[String]:
        var out = List[String]()
        out.append(String("A"))
        out.append(String("B"))
        return out^
    def open_shard(mut self, shard_id: String, after_sequence_number: String) raises -> String:
        return shard_id.copy()
    def poll(mut self, cursor: String) raises -> ChangeBatch:
        if cursor == "A":
            return self._a.copy()
        return self._b.copy()


def _bad_batch() -> ChangeBatch:
    var short = List[RowCell]()
    short.append(make_long_cell(Int64(1)))
    var l = List[ChangeRecord]()
    l.append(make_insert_record(short.copy(), short.copy(), String("7")))
    return ChangeBatch(l^, String("n"), False)


def test_error_on_second_shard_keeps_first_shard_and_resumes() raises:
    var inner = SharedInMemoryConditionalStore()
    var uuid = gen_table_uuid()
    var w = _writer(ArcPointer[Fail](Fail(0)), inner, uuid)
    var cfg = _config()
    var l1 = TwoShardListener(_b1(_ins(Int64(1), String("a"), String("9"))), _bad_batch())
    var raised = False
    try:
        _ = run_ingest_pass(l1, w, cfg)
    except e:
        raised = True
    assert_true(raised, "the bad batch on shard B propagates")
    var w2 = _writer(ArcPointer[Fail](Fail(0)), inner, uuid)
    var p = ShardPositions.from_summary_kvs(w2.read_current_summary())
    assert_equal(p.get(String("A")), String("9"))
    assert_equal(p.get(String("B")), String(""))
    assert_equal(_name(w2.read_live_rows(), Int64(1)), String("a"))
    # The next pass: shard A is replayed (skipped), shard B now carries a good batch.
    var l2 = TwoShardListener(
        _b1(_ins(Int64(1), String("a"), String("9"))),
        _b1(_ins(Int64(2), String("b"), String("100"))),
    )
    var st = run_ingest_pass(l2, w2, cfg)
    assert_equal(st.commits, 1)
    assert_equal(st.skipped, 1)
    assert_equal(len(w2.read_live_rows()), 2)
    assert_equal(_name(w2.read_live_rows(), Int64(2)), String("b"))


def main() raises:
    test_failed_commit_leaves_position_and_retry_applies()
    test_failed_commit_table_summary_unchanged()
    test_replay_and_order_across_batches()
    test_in_batch_insert_remove_insert()
    test_bad_record_raises_no_commit()
    test_empty_batch_and_zero_padded()
    test_positions_roundtrip()
    test_other_shard_position_preserved_in_stamp()
    test_error_on_second_shard_keeps_first_shard_and_resumes()
    print("test_cdc_apply_failure_and_order: ALL PASS")
