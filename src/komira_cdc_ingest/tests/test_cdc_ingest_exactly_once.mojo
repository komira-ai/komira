# =============================================================================
# test_cdc_ingest_exactly_once.mojo — apply correctness and exactly-once resume.
# =============================================================================
#
# The apply-correctness and exactly-once-across-a-crash behaviour of the CDC
# ingest, over a scripted multi-shard listener and an on-disk Iceberg store. No
# cloud and no network.
#
# What each test proves:
#   (1) Apply correctness. A scripted batch of INSERT/MODIFY/REMOVE is read back
#       from Iceberg exactly (the MODIFY shows the new value, the REMOVE is gone).
#   (2) Exactly-once across a crash. Apply a batch and commit; simulate a crash by
#       dropping the in-memory position and re-instantiating the ingest over the
#       SAME committed table; replay the SAME batch. The table is unchanged (no
#       duplicate rows, no wrongly masked rows). The resume position is read from
#       the committed snapshot summary.
#   (3) Crash before commit. A batch that never committed (its position was never
#       stamped) is re-applied on restart and produces the correct table; the
#       resume derives from the last committed position.
#   (4) Multi-shard. A change on shard 2 is applied (a single-shard tail would
#       miss it). Each shard's position is stamped and resumed independently.
#
# The scripted listener, `ScriptedMultiShardListener`, conforms to
# `MultiShardChangeStreamListener` and returns a canned per-shard batch. It
# records the `after_sequence_number` passed to `open_shard` so a test can assert
# the resume point was read from the committed summary and not from in-process
# state.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_true, assert_equal, assert_false

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)

from komira_snapshotter.change_stream_trait import (
    MultiShardChangeStreamListener,
    ChangeRecord,
    ChangeBatch,
    make_insert_record,
    make_modify_record,
    make_remove_record,
)

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    IcebergSchema,
    IcebergTableWriter,
    RowCell,
    make_long_cell,
    make_string_cell,
    gen_table_uuid,
)

from komira_cdc_ingest import (
    CdcApplyConfig,
    ShardPositions,
    apply_batch,
    run_ingest_pass,
)
from komira_libc.posix import _read_env


# The scratch directory is the test action's own TEST_TMPDIR; a run without one
# fails rather than falling back to a path other runs share.
def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set: the test needs its own scratch directory")
    return d


# =============================================================================
# The MOCK multi-shard listener (scripted per-shard batches; no wire).
# =============================================================================


struct ScriptedMultiShardListener(
    MultiShardChangeStreamListener, Movable, Deinitable
):
    """A `MultiShardChangeStreamListener` that returns a canned batch per shard.

    Construct with parallel `shard_ids` + `batches` (batch i is shard i's).
    `open_shard` returns the shard id AS the cursor (so `poll` maps cursor ->
    shard -> batch) and RECORDS the `after_sequence_number` it was called with —
    a test asserts the resume point came from the committed summary.

    A plain owned-field struct (List[String] / List[ChangeBatch]) with no
    pointer field."""

    var _shard_ids: List[String]
    var _batches: List[ChangeBatch]
    var _opened_after: List[String]  # recorded after_seq per open_shard call

    def __init__(
        out self, var shard_ids: List[String], var batches: List[ChangeBatch]
    ):
        self._shard_ids = shard_ids^
        self._batches = batches^
        self._opened_after = List[String]()

    def list_shard_ids(mut self) raises -> List[String]:
        var out = List[String]()
        for i in range(len(self._shard_ids)):
            out.append(String(self._shard_ids[i]))
        return out^

    def open_shard(
        mut self, shard_id: String, after_sequence_number: String
    ) raises -> String:
        self._opened_after.append(String(after_sequence_number))
        return String(shard_id)  # the cursor IS the shard id (mock)

    def poll(mut self, cursor: String) raises -> ChangeBatch:
        # cursor == shard id -> return that shard's scripted batch.
        for i in range(len(self._shard_ids)):
            if _seq_str_eq(self._shard_ids[i], cursor):
                return self._batches[i].copy()
        return ChangeBatch.empty_live(String(cursor))

    def opened_after_at(self, i: Int) -> String:
        """The `after_sequence_number` recorded for the i-th `open_shard`."""
        return String(self._opened_after[i])

    def open_count(self) -> Int:
        return len(self._opened_after)


# a ChangeBatch is Movable but not Copyable in the seam; give the mock a copy.
# (ChangeBatch has no copy(); we rebuild instead — see _batch_of below.)


# =============================================================================
# Fixtures: schema (id long PK + name string) + row/record builders.
# =============================================================================


def _schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("name"), ICE_T_STRING, required=True)
    return s^


def _config() -> CdcApplyConfig:
    var ids = List[Int]()
    ids.append(1)  # equality-delete on id (field-id 1)
    return CdcApplyConfig(_schema(), ids^)


def _full_row(id: Int64, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    return r^


def _insert(id: Int64, var name: String, var seq: String) -> ChangeRecord:
    return make_insert_record(_full_row(id, String("k")), _full_row(id, name^), seq^)


def _modify(
    id: Int64, var old_name: String, var new_name: String, var seq: String
) -> ChangeRecord:
    return make_modify_record(
        _full_row(id, String("k")),
        _full_row(id, old_name^),
        _full_row(id, new_name^),
        seq^,
    )


def _remove(id: Int64, var name: String, var seq: String) -> ChangeRecord:
    return make_remove_record(
        _full_row(id, String("k")), _full_row(id, name^), seq^
    )


def _has_id(rows: List[List[RowCell]], id: Int64) -> Bool:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return True
    return False


def _name_of(rows: List[List[RowCell]], id: Int64) raises -> String:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return rows[i][1].as_string()
    raise Error("id " + String(id) + " not found")


def _count_id(rows: List[List[RowCell]], id: Int64) -> Int:
    var c = 0
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            c += 1
    return c


@always_inline
def _seq_str_eq(a: String, b: String) -> Bool:
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    for i in range(len(ab)):
        if ab[i] != bb[i]:
            return False
    return True


# =============================================================================
# (1) APPLY CORRECTNESS.
# =============================================================================
def test_apply_insert_modify_remove_correctness() raises:
    """A scripted INSERT/MODIFY/REMOVE batch -> the Iceberg read-back reflects
    them exactly: the INSERT+MODIFY row shows the NEW value, the REMOVE row is
    gone."""
    var root = (_scratch_dir() + String("/cdc_apply_")) + String(
        Int(external_call["getpid", Int32]())
    )
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var store = LocalFsConditionalStore(root.copy())
    var writer = IcebergTableWriter[LocalFsConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )
    var config = _config()

    # Batch: insert 1(alice), insert 2(bob), insert 3(carol), then modify
    # 1(alice->alicia), remove 2. Net live: 1=alicia, 3=carol.
    var recs = List[ChangeRecord]()
    recs.append(_insert(Int64(1), String("alice"), String("8")))
    recs.append(_insert(Int64(2), String("bob"), String("9")))
    recs.append(_insert(Int64(3), String("carol"), String("10")))
    recs.append(
        _modify(Int64(1), String("alice"), String("alicia"), String("11"))
    )
    recs.append(_remove(Int64(2), String("bob"), String("12")))
    var batch = ChangeBatch(recs^, String("next"), False)

    var positions = ShardPositions()
    var stats = apply_batch(
        writer, config, String("shardId-A"), batch^, positions
    )
    assert_true(stats.committed, "batch committed")

    var live = writer.read_live_rows()
    assert_equal(len(live), 2, "exactly 2 live rows (1=alicia, 3=carol)")
    assert_true(_has_id(live, Int64(1)), "id 1 present")
    assert_equal(_name_of(live, Int64(1)), String("alicia"), "MODIFY shows NEW value")
    assert_false(_has_id(live, Int64(2)), "id 2 REMOVEd -> gone")
    assert_true(_has_id(live, Int64(3)), "id 3 present")
    assert_equal(_name_of(live, Int64(3)), String("carol"), "id 3 unchanged")

    # the position advanced to the batch's max sequence.
    assert_equal(
        positions.get(String("shardId-A")),
        String("12"),
        "position advanced to the batch's last applied sequence",
    )


# =============================================================================
# (2) EXACTLY-ONCE ACROSS A CRASH (the crux).
# =============================================================================
def test_exactly_once_across_a_crash() raises:
    """Apply a batch + commit; simulate a crash by DROPPING the in-memory
    position AND re-instantiating the ingest over the SAME committed table;
    replay the SAME batch -> the table is UNCHANGED (no double-apply), and the
    resume position is read FROM the committed snapshot summary.

    FAILS if the position were NOT stamped into the commit (the
    replay would re-append every INSERT row -> duplicates) OR if the resume read
    did not consult the committed summary (the second ingest would cold-start and
    re-apply everything)."""
    var root = (_scratch_dir() + String("/cdc_x1_")) + String(
        Int(external_call["getpid", Int32]())
    )
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var config = _config()

    # A batch of 3 inserts + 1 modify.
    def _make_batch() raises -> ChangeBatch:
        var recs = List[ChangeRecord]()
        recs.append(_insert(Int64(1), String("a"), String("8")))
        recs.append(_insert(Int64(2), String("b"), String("9")))
        recs.append(_insert(Int64(3), String("c"), String("10")))
        recs.append(
            _modify(Int64(1), String("a"), String("A"), String("11"))
        )
        return ChangeBatch(recs^, String("next"), False)

    var table_uuid = gen_table_uuid()

    # ---- INGEST #1: apply + commit (positions stamped into the summary) ----
    var store1 = LocalFsConditionalStore(root.copy())
    var writer1 = IcebergTableWriter[LocalFsConditionalStore](
        store1^, location, schema.copy(), String(table_uuid)
    )
    # Derive resume from the (empty) table -> cold start.
    var pos1 = ShardPositions.from_summary_kvs(writer1.read_current_summary())
    assert_equal(pos1.get(String("shardId-A")), String(""), "cold start: no position")
    _ = apply_batch(writer1, config, String("shardId-A"), _make_batch(), pos1)

    var live1 = writer1.read_live_rows()
    assert_equal(len(live1), 3, "ingest #1: 3 live rows (1=A,2=b,3=c)")
    assert_equal(_name_of(live1, Int64(1)), String("A"), "1 modified to A")

    # ---- CRASH: drop writer1 + pos1 (out of scope). Re-instantiate ingest ----
    # ---- INGEST #2: SAME committed table, FRESH handle, REPLAY the SAME batch.
    var store2 = LocalFsConditionalStore(root.copy())
    var writer2 = IcebergTableWriter[LocalFsConditionalStore](
        store2^, location, schema.copy(), String(table_uuid)
    )
    # Derive resume from the COMMITTED table's snapshot summary (NOT in-process).
    var pos2 = ShardPositions.from_summary_kvs(writer2.read_current_summary())
    assert_equal(
        pos2.get(String("shardId-A")),
        String("11"),
        "resume position DERIVED from committed snapshot summary",
    )
    var replay_stats = apply_batch(
        writer2, config, String("shardId-A"), _make_batch(), pos2
    )
    # Every record in the replay is <= the committed position -> all skipped, no
    # commit.
    assert_equal(replay_stats.skipped, 4, "all 4 replayed records skipped")
    assert_false(replay_stats.committed, "no commit on a fully-replayed batch")

    # The table is UNCHANGED — no duplicate rows, no wrongly-masked rows.
    var live2 = writer2.read_live_rows()
    assert_equal(len(live2), 3, "table UNCHANGED after replay (no double-apply)")
    assert_equal(_count_id(live2, Int64(1)), 1, "id 1 not duplicated")
    assert_equal(_count_id(live2, Int64(2)), 1, "id 2 not duplicated")
    assert_equal(_count_id(live2, Int64(3)), 1, "id 3 not duplicated")
    assert_equal(_name_of(live2, Int64(1)), String("A"), "id 1 still = A (not re-masked)")


# =============================================================================
# (3) CRASH BEFORE COMMIT.
# =============================================================================
def test_crash_before_commit_reapplies() raises:
    """A batch that never committed (position never stamped) is re-applied on
    restart and produces the correct table (no drop).

    We model "crash before commit" by applying a batch to a FRESH ingest whose
    resume derives from the LAST committed position (an EARLIER batch). The new
    batch's records are all > that position, so they ALL apply — proving the
    un-committed work is not lost."""
    var root = (_scratch_dir() + String("/cdc_precommit_")) + String(
        Int(external_call["getpid", Int32]())
    )
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var config = _config()
    var table_uuid = gen_table_uuid()

    # ---- batch 1: insert id=1 (committed) ----
    var store1 = LocalFsConditionalStore(root.copy())
    var writer1 = IcebergTableWriter[LocalFsConditionalStore](
        store1^, location, schema.copy(), String(table_uuid)
    )
    var pos1 = ShardPositions.from_summary_kvs(writer1.read_current_summary())
    var recs1 = List[ChangeRecord]()
    recs1.append(_insert(Int64(1), String("a"), String("8")))
    _ = apply_batch(
        writer1, config, String("shardId-A"), ChangeBatch(recs1^, String("n"), False), pos1
    )

    # ---- "crash before commit" of batch 2: a NEW ingest, resume from committed.
    var store2 = LocalFsConditionalStore(root.copy())
    var writer2 = IcebergTableWriter[LocalFsConditionalStore](
        store2^, location, schema.copy(), String(table_uuid)
    )
    var pos2 = ShardPositions.from_summary_kvs(writer2.read_current_summary())
    assert_equal(
        pos2.get(String("shardId-A")),
        String("8"),
        "resume from batch-1's committed position",
    )
    # batch 2 (id=2, id=3) — all sequences > the committed position, so all apply.
    var recs2 = List[ChangeRecord]()
    recs2.append(_insert(Int64(2), String("b"), String("9")))
    recs2.append(_insert(Int64(3), String("c"), String("10")))
    var stats2 = apply_batch(
        writer2, config, String("shardId-A"), ChangeBatch(recs2^, String("n"), False), pos2
    )
    assert_equal(stats2.appended, 2, "batch-2 fully applied (no drop)")
    assert_true(stats2.committed, "batch-2 committed")

    var live = writer2.read_live_rows()
    assert_equal(len(live), 3, "all 3 rows present (batch-1 + re-applied batch-2)")
    assert_true(_has_id(live, Int64(1)), "id 1")
    assert_true(_has_id(live, Int64(2)), "id 2 (un-committed work not lost)")
    assert_true(_has_id(live, Int64(3)), "id 3")


# =============================================================================
# (4) MULTI-SHARD — a change on shard-2 is applied; per-shard positions resume.
# =============================================================================
def test_multishard_applies_all_shards() raises:
    """Two shards each carry a batch; the driver tails BOTH. A change on shard-2
    is applied (a single-shard tail would MISS it -> the RED). Each shard's
    position is stamped + resumed independently."""
    var root = (_scratch_dir() + String("/cdc_ms_")) + String(
        Int(external_call["getpid", Int32]())
    )
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var config = _config()
    var store = LocalFsConditionalStore(root.copy())
    var writer = IcebergTableWriter[LocalFsConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    # shard-A: insert id=1; shard-B: insert id=2 (the change a single-shard tail
    # would miss).
    var shard_ids = List[String]()
    shard_ids.append(String("shardId-A"))
    shard_ids.append(String("shardId-B"))
    var batches = List[ChangeBatch]()
    var ra = List[ChangeRecord]()
    ra.append(_insert(Int64(1), String("a"), String("9")))
    batches.append(ChangeBatch(ra^, String("na"), False))
    var rb = List[ChangeRecord]()
    rb.append(_insert(Int64(2), String("b"), String("100")))
    batches.append(ChangeBatch(rb^, String("nb"), False))

    var listener = ScriptedMultiShardListener(shard_ids^, batches^)
    var stats = run_ingest_pass(listener, writer, config)
    assert_equal(stats.shards_polled, 2, "both shards polled")
    assert_equal(stats.appended, 2, "one row per shard appended")

    var live = writer.read_live_rows()
    assert_equal(len(live), 2, "both shards' rows present")
    assert_true(_has_id(live, Int64(1)), "shard-A change applied")
    assert_true(_has_id(live, Int64(2)), "shard-B change applied (NOT missed)")

    # Both shards' positions independently stamped into the current summary.
    var summary = ShardPositions.from_summary_kvs(writer.read_current_summary())
    assert_equal(
        summary.get(String("shardId-A")),
        String("9"),
        "shard-A position stamped",
    )
    assert_equal(
        summary.get(String("shardId-B")),
        String("100"),
        "shard-B position stamped (independent per-shard)",
    )

    # ---- resume: a second pass re-derives BOTH positions from the summary and
    # replays the SAME batches -> nothing new (both shards skip).
    var shard_ids2 = List[String]()
    shard_ids2.append(String("shardId-A"))
    shard_ids2.append(String("shardId-B"))
    var batches2 = List[ChangeBatch]()
    var ra2 = List[ChangeRecord]()
    ra2.append(_insert(Int64(1), String("a"), String("9")))
    batches2.append(ChangeBatch(ra2^, String("na"), False))
    var rb2 = List[ChangeRecord]()
    rb2.append(_insert(Int64(2), String("b"), String("100")))
    batches2.append(ChangeBatch(rb2^, String("nb"), False))
    var listener2 = ScriptedMultiShardListener(shard_ids2^, batches2^)
    var stats2 = run_ingest_pass(listener2, writer, config)
    assert_equal(stats2.commits, 0, "no new commits on a full replay of both shards")

    # open_shard was called with the DERIVED per-shard positions (resume read
    # from the committed summary).
    assert_equal(
        listener2.opened_after_at(0),
        String("9"),
        "shard-A opened AFTER its committed position",
    )
    assert_equal(
        listener2.opened_after_at(1),
        String("100"),
        "shard-B opened AFTER its committed position",
    )

    var live2 = writer.read_live_rows()
    assert_equal(len(live2), 2, "table unchanged after the replay pass")


def main() raises:
    test_apply_insert_modify_remove_correctness()
    test_exactly_once_across_a_crash()
    test_crash_before_commit_reapplies()
    test_multishard_applies_all_shards()
    print("test_cdc_ingest_exactly_once: ALL PASS")
