# =============================================================================
# src/tests/e2e/broker_e2e/tests/test_broker_lifecycle_e2e.mojo
#   The broker lifecycle over a real on-disk store, phase by phase.
# =============================================================================
#
# One topic of 6 partitions, three broker nodes, one `LocalFsConditionalStore`
# root under $TEST_TMPDIR. Every phase opens FRESH store handles on that root,
# so data-plane state reaches a later phase only through the files. The
# coordinator (with its own store handle) and the three node states are the
# long-lived objects: they are the control plane, and a coordinator restart (an
# empty registry re-learning membership one heartbeat at a time) is a different
# scenario.
#
#   1. ASSIGN   Three `BrokerNodeState`s heartbeat the coordinator; the spread
#               is even (2/2/2), every partition has exactly one owner, and the
#               persisted assignment read back through a fresh handle names the
#               same owners and the lease generations the nodes hold.
#   2. PRODUCE  Each owner opens a `BrokerCore` per partition and flushes three
#               batches under its lease (writer epoch == current epoch). Keys
#               and values are deterministic, include non-ASCII text, and some
#               values are empty (an empty value is not a null).
#   3. REPLAY   Every data-plane handle is dropped. A fresh `ConsumeCore` per
#               partition returns offsets 0..n-1 with no gap and the exact bytes
#               produced; the persisted assignment, re-read cold, equals the one
#               kept from phase 1.
#   4. FENCE    Node 3 stops heartbeating while holding unflushed batches for
#               both its partitions. The coordinator reassigns only those
#               (sticky, no copy: nodes 1 and 2 keep theirs at unchanged
#               generations); the new owner produces. Then two late flushes:
#                 * FENCED: node 3 flushes with its old writer epoch and the
#                   live generation, which THE TEST reads from the persisted
#                   assignment and passes in. `BrokerCore.flush` must refuse
#                   it as `lease_fenced` BEFORE its segment PUT: no chunk,
#                   offsets unchanged, and no `.seg` left behind.
#                 * NOT FENCED (pinned residual): node 3 flushes with what its
#                   own `BrokerNodeState` reports (old, old). No product code
#                   reads the live generation at flush; cas_manifest documents
#                   this fence as best-effort and caller-supplied. The late
#                   append commits at the next free offset. When a product
#                   change fences it, this assertion flips on purpose.
#   5. RETAIN   On the reassigned partition: time retention retires the oldest
#               chunk and advances log_start to its successor's base; the
#               reaper deletes it, leaving one segment per live chunk; the
#               offline `LogCleaner` with zero tombstone grace writes a
#               survivor sidecar holding the latest offset per key, including a
#               key whose latest value is empty; a consumer asking for offset 0
#               is told it was truncated and starts at log_start. The offline
#               cleaner rewrites manifest bodies only (the `.seg` stays), so
#               this phase does not prove what a consumer of a compacted topic
#               reads.
#
# What each phase would catch (the planted mutants are in the change notes):
#   * an assignment that is not persisted, or is read back wrong (phase 1, 3);
#   * a lost, reordered or altered record across a restart (phase 3);
#   * a `BrokerCore.flush` that does not refuse a writer below the caller's
#     current lease epoch (phase 4);
#   * a log_start that is not the base of the first live chunk (phase 5);
#   * a cleaner that keeps a superseded offset, or drops an empty value as if
#     it were a tombstone (phase 5).
# Not exercised here: a coordinator restarting from the persisted assignment
# (the coordinator stays up from phase 1 to phase 4; the coordinator package's
# relay test restarts one over an in-memory store).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow_ipc.ipc_decoder_dispatch import decode_record_batch_message
from komira_arrow_ipc.ipc_flatbuf import (
    flatbuf_reader_over,
    read_message,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
)
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_broker import (
    Assignment,
    BrokerCore,
    BrokerNodeState,
    ClusterAssignmentStore,
    CompactionConfig,
    ConsumeCore,
    LogCleaner,
    ManifestBody,
    ReconcileDelta,
    RetentionPolicy,
    decode_compacted_survivor_offsets,
)
from komira_broker_coordinator import BrokerHeartbeatCoordinator
from komira_broker_proto.broker import NodeLoad as PbNodeLoad
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    is_lease_fenced,
)
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_supervisor_proto.supervisor import (
    JobPhase as PbJobPhase,
    SupervisorHeartbeat as PbSupervisorHeartbeat,
)
from komira_runtime_paths import test_tmpdir


comptime _Store = LocalFsConditionalStore
comptime _CLUSTER = "e2e"
comptime _TOPIC = "orders"
comptime _P = 6
comptime _BATCHES = 3
comptime _ROWS = 4
# Sample clocks decode to dates in 2096: nothing here is a real past date.
comptime _T0_MS: Int64 = 4_000_000_000_000
comptime _T0_US: Int64 = 4_000_000_000_000_000
comptime _STALE_US: Int64 = 1_000_000
comptime _STEP_US: Int64 = 100_000
# Time retention for phase 5: chunks are flushed at T0, T0+1s, T0+2s, T0+3s,
# so at T0+10.5s only the first is older than 10s.
comptime _RETENTION_MS: Int64 = 10_000
comptime _RETAIN_AT_MS: Int64 = _T0_MS + 10_500


# =============================================================================
# The model: what was produced, per partition, in offset order.
# =============================================================================


@fieldwise_init
struct _Rec(Copyable, Movable):
    var key: String
    var value: String


def _key(pid: Int, offset: Int) -> String:
    """A key schedule with repeats inside and across chunks, so compaction has
    something to drop in every cleanable chunk of phase 5."""
    var schedule: List[Int] = [0, 1, 0, 2, 1, 2, 3, 1, 3, 3, 2, 0, 1, 0, 3, 2]
    var k = schedule[offset % len(schedule)]
    var suffix = String("-") + String(pid)
    if k == 0:
        return String("clé") + suffix
    if k == 1:
        return String("ключ") + suffix
    if k == 2:
        return String("鍵") + suffix
    return String("key") + suffix


def _value(pid: Int, offset: Int, tag: String) -> String:
    # Offset 10 is the latest of its key in phase 5's cleanable range (4..11),
    # so an empty value must survive compaction there; phase 5 asserts it does.
    if offset % 5 == 0:
        return String("")  # empty, and valid: not a tombstone
    if offset % 2 == 0:
        return tag + "-värde-" + String(pid) + "-" + String(offset)
    return tag + "-値-" + String(pid) + "-" + String(offset)


def _kv_schema() raises -> Schema:
    return Schema(
        names=[String("key"), String("value")],
        arrow_types=[ArrowType.STRING.type_id, ArrowType.STRING.type_id],
        dtypes=[DType.uint8, DType.uint8],
        nullables=[False, True],
    )


def _batch(recs: List[_Rec]) raises -> RecordBatch:
    var keys = List[String]()
    var values = List[String]()
    var valid = List[Bool]()
    for i in range(len(recs)):
        keys.append(recs[i].key)
        values.append(recs[i].value)
        valid.append(True)
    var kcol = Column.from_string(StringArray.from_strings(keys))
    var vcol = Column.from_string(StringArray.from_strings_with_validity(values, valid))
    return RecordBatch.from_typed_columns_2(_kv_schema(), kcol^, vcol^)


def _append_records(
    mut model: List[_Rec], pid: Int, count: Int, tag: String
) -> List[_Rec]:
    """Extend the partition's model by `count` records and return them."""
    var out = List[_Rec]()
    for _ in range(count):
        var offset = len(model)
        var rec = _Rec(key=_key(pid, offset), value=_value(pid, offset, tag))
        out.append(rec.copy())
        model.append(rec^)
    return out^


# =============================================================================
# Fresh handles on the one root.
# =============================================================================


def _root() raises -> String:
    return test_tmpdir() + "/broker_e2e"


def _open(root: String) raises -> _Store:
    return _Store(root.copy())


def _manifest(root: String, pid: Int) raises -> CasManifestStore[_Store]:
    var prefix = String(_CLUSTER) + "/_meta/topics/" + _TOPIC + "/" + String(pid)
    return CasManifestStore[_Store](
        store=_open(root), prefix=prefix^, retry=RetryPolicy.fast_test()
    )


def _broker(root: String, pid: Int, node: Int) raises -> BrokerCore[_Store]:
    return BrokerCore[_Store](
        segment_store=_open(root),
        manifest=_manifest(root, pid),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=Int64(pid),
        broker_id=String("broker-") + String(node),
    )


def _consumer(root: String, pid: Int) raises -> ConsumeCore[_Store]:
    return ConsumeCore[_Store](
        segment_store=_open(root),
        manifest=_manifest(root, pid),
        cluster=String(_CLUSTER),
        topic=String(_TOPIC),
        partition=Int64(pid),
    )


def _segment_objects(root: String, pid: Int) raises -> Int:
    """How many `.seg` objects the store holds for `pid`, committed or not."""
    var prefix = (
        String(_CLUSTER) + "/topics/" + _TOPIC + "/" + String(pid) + "/segments/"
    )
    return len(_open(root).list_with_delimiter(Path.parse(prefix)).objects)


def _read_persisted(root: String) raises -> Assignment:
    """The assignment as a fresh process would see it: a new store handle, a
    new ClusterAssignmentStore, one read."""
    var store = ClusterAssignmentStore[_Store](_open(root), String(_CLUSTER))
    var got = store.read_assignment(String(_TOPIC))
    if not got:
        raise Error("no persisted assignment for topic " + String(_TOPIC))
    return Assignment.decode_binary(got.value().body)


# =============================================================================
# Heartbeats: one node's round trip through the coordinator.
# =============================================================================


def _heartbeat(node: BrokerNodeState) -> PbSupervisorHeartbeat:
    var load = PbNodeLoad(
        UInt64(0), UInt32(node.partition_count()), Optional[UInt32]()
    )
    return PbSupervisorHeartbeat(
        String("00000000-0000-0000-0000-000000000000"),
        PbJobPhase(PbJobPhase.JOB_PHASE_RUNNING),
        String("broker-node-") + node.node_id(),
        None,
        None,
        None,
        Optional[String](node.node_id()),
        Optional[PbNodeLoad](load^),
        node.owned_partitions(),
        Optional[String](),  # advertised host: the coordinator's default
        Optional[UInt32](),  # advertised port: the coordinator's default
    )


def _beat(
    mut coord: BrokerHeartbeatCoordinator[_Store],
    mut node: BrokerNodeState,
    now_us: Int64,
) raises -> ReconcileDelta:
    var resp = coord.handle_broker_heartbeat(_heartbeat(node), now_us)
    var assigned = List[UInt32]()
    for i in range(len(resp.assigned_partitions)):
        assigned.append(resp.assigned_partitions[i])
    var gens = List[Int64]()
    for i in range(len(resp.assigned_generations)):
        gens.append(resp.assigned_generations[i])
    return node.apply_assignment(assigned, gens)


def _owner(
    pid: Int, n1: BrokerNodeState, n2: BrokerNodeState, n3: BrokerNodeState
) raises -> Int:
    """Which node (1..3) serves `pid`; exactly one must."""
    var who = 0
    var count = 0
    if n1.owns(UInt32(pid)):
        who = 1
        count += 1
    if n2.owns(UInt32(pid)):
        who = 2
        count += 1
    if n3.owns(UInt32(pid)):
        who = 3
        count += 1
    assert_equal(count, 1, "partition " + String(pid) + " has exactly one owner")
    return who


def _writer_epoch(
    who: Int, pid: Int, n1: BrokerNodeState, n2: BrokerNodeState, n3: BrokerNodeState
) -> Int64:
    if who == 1:
        return n1.writer_lease_epoch_of(UInt32(pid))
    if who == 2:
        return n2.writer_lease_epoch_of(UInt32(pid))
    return n3.writer_lease_epoch_of(UInt32(pid))


def _current_epoch(
    who: Int, pid: Int, n1: BrokerNodeState, n2: BrokerNodeState, n3: BrokerNodeState
) -> Int64:
    if who == 1:
        return n1.current_lease_epoch_of(UInt32(pid))
    if who == 2:
        return n2.current_lease_epoch_of(UInt32(pid))
    return n3.current_lease_epoch_of(UInt32(pid))


def _contains(xs: List[UInt32], x: UInt32) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _assert_same_assignment(got: Assignment, want: Assignment, label: String) raises:
    assert_equal(got.num_partitions, want.num_partitions, label + ": P")
    for pid in range(want.num_partitions):
        var at = label + ": partition " + String(pid)
        assert_equal(got.owner_of(pid), want.owner_of(pid), at + " owner")
        assert_equal(got.generation_of(pid), want.generation_of(pid), at + " generation")


def _assert_matches_nodes(
    a: Assignment,
    n1: BrokerNodeState,
    n2: BrokerNodeState,
    n3: BrokerNodeState,
    label: String,
) raises:
    """The persisted assignment names each partition's serving node, and its
    generation is the lease that node stamps."""
    assert_equal(a.num_partitions, _P, label + ": P")
    for pid in range(_P):
        var who = _owner(pid, n1, n2, n3)
        var at = label + ": partition " + String(pid)
        assert_equal(a.owner_of(pid), String(who), at + " owner")
        assert_equal(
            a.generation_of(pid),
            _writer_epoch(who, pid, n1, n2, n3),
            at + " generation == the owner's writer epoch",
        )


# =============================================================================
# Reading a segment back: the Arrow IPC stream decoded with komira_arrow_ipc.
# =============================================================================


def _decode_batches(stream: List[UInt8]) raises -> Slab[RecordBatch]:
    """Decode a segment's stream (Schema, RecordBatch*, EOS) against the topic
    schema. A frame that is neither schema nor record batch is refused."""
    var schema = _kv_schema()
    var types = List[ArrowType]()
    for i in range(schema.num_columns()):
        types.append(schema.field_arrow_type(i))
    var n = len(stream)
    var src = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    src.copy_from_bytes_list(stream)
    var out = Slab[RecordBatch]()
    var cursor = 0
    var saw_eos = False
    while cursor + 8 <= n:
        assert_equal(
            src.read_u32_le_at(cursor), UInt32(0xFFFFFFFF), "continuation marker"
        )
        var meta_size = Int(src.read_u32_le_at(cursor + 4))
        if meta_size == 0:
            saw_eos = True
            break
        assert_true(cursor + 8 + meta_size <= n, "metadata inside the stream")
        var fb = SharedAlignedBuffer[HeapRegion].heap_owned(meta_size)
        fb.copy_from_view_at(0, src.view_range_ro(cursor + 8, meta_size))
        fb.set_length(meta_size)
        var reader = flatbuf_reader_over(fb)
        var msg = read_message(reader, reader.read_root_offset())
        var frame_size = 8 + meta_size + Int(msg.body_length)
        assert_true(cursor + frame_size <= n, "frame inside the stream")
        if msg.header_tag == MESSAGE_HEADER_SCHEMA:
            cursor += frame_size
            continue
        assert_equal(
            Int(msg.header_tag), Int(MESSAGE_HEADER_RECORD_BATCH), "a record batch"
        )
        var frame = SharedAlignedBuffer[HeapRegion].heap_owned(frame_size)
        frame.copy_from_view_at(0, src.view_range_ro(cursor, frame_size))
        frame.set_length(frame_size)
        var cols = decode_record_batch_message(frame^, types)
        var builder = RecordBatchBuilder.with_capacity(len(cols))
        while len(cols) > 0:
            builder.add_column(cols.take_at(0))
        out.append(builder.build(schema.copy()))
        cursor += frame_size
    assert_true(saw_eos, "the stream ends with EOS")
    return out^


def _rows(stream: List[UInt8]) raises -> List[_Rec]:
    var batches = _decode_batches(stream)
    var out = List[_Rec]()
    for b in range(len(batches)):
        var keys = batches[b].column_as_string(0)
        var values = batches[b].column_as_string(1)
        for r in range(batches[b].num_rows()):
            assert_false(values.is_null(r), "no value read back is null")
            out.append(_Rec(key=keys.get(r), value=values.get(r)))
    return out^


def _assert_log_equals_model(
    root: String, pid: Int, model: List[_Rec], label: String
) raises:
    """A fresh consumer reads the whole partition: offsets 0..n-1, segment by
    segment with no gap or overlap, and every key and value byte-equal to what
    was produced at that offset."""
    var at = label + ": partition " + String(pid)
    var consumer = _consumer(root, pid)
    assert_equal(consumer.next_offset(), Int64(len(model)), at + " next_offset")
    var segments = consumer.read_from(Int64(0))
    var expect = 0
    for i in range(len(segments)):
        var base = Int(segments[i].base_offset)
        var last = Int(segments[i].last_offset)
        assert_equal(base, expect, at + " segment " + String(i) + " starts at the next offset")
        var rows = _rows(segments[i].stream_bytes)
        assert_equal(len(rows), last - base + 1, at + " segment row count == its offset span")
        assert_equal(Int64(len(rows)), segments[i].record_count, at + " record_count")
        for r in range(len(rows)):
            var o = base + r
            assert_true(o < len(model), at + " offset " + String(o) + " was produced")
            assert_equal(rows[r].key, model[o].key, at + " key bytes @" + String(o))
            assert_equal(rows[r].value, model[o].value, at + " value bytes @" + String(o))
        expect = last + 1
    assert_equal(expect, len(model), at + " the log ends at the last produced offset")


# =============================================================================
# Phase 1 — assignment over heartbeats, persisted.
# =============================================================================


def phase1_assign(
    root: String,
    mut n1: BrokerNodeState,
    mut n2: BrokerNodeState,
    mut n3: BrokerNodeState,
    mut now_us: Int64,
    mut kept: Optional[Assignment],
) raises -> BrokerHeartbeatCoordinator[_Store]:
    print("[phase 1] assign 6 partitions over 3 nodes")
    var coord = BrokerHeartbeatCoordinator[_Store](
        ClusterAssignmentStore[_Store](_open(root), String(_CLUSTER)),
        String(_CLUSTER),
        String(_TOPIC),
        _P,
        stale_threshold_us=_STALE_US,
    )
    # Two rounds: the first lets membership grow node by node, the second
    # delivers the settled spread to the nodes that joined early.
    for _round in range(2):
        _ = _beat(coord, n1, now_us)
        now_us += _STEP_US
        _ = _beat(coord, n2, now_us)
        now_us += _STEP_US
        _ = _beat(coord, n3, now_us)
        now_us += _STEP_US
    assert_equal(coord.live_node_count(now_us), 3, "3 live nodes")
    assert_equal(n1.partition_count(), 2, "node 1 serves 2")
    assert_equal(n2.partition_count(), 2, "node 2 serves 2")
    assert_equal(n3.partition_count(), 2, "node 3 serves 2")
    for pid in range(_P):
        var who = _owner(pid, n1, n2, n3)
        assert_equal(
            _writer_epoch(who, pid, n1, n2, n3),
            _current_epoch(who, pid, n1, n2, n3),
            "a node that has owned a partition throughout is not fenced",
        )
    var persisted = _read_persisted(root)
    assert_true(persisted.is_even(), "persisted assignment is even")
    for node in range(1, 4):
        assert_equal(persisted.count_for(String(node)), 2, "persisted count")
    _assert_matches_nodes(persisted, n1, n2, n3, "phase 1 persisted")
    kept = Optional[Assignment](persisted^)
    return coord^


# =============================================================================
# Phase 2 — the owners produce under their leases.
# =============================================================================


def phase2_produce(
    root: String,
    n1: BrokerNodeState,
    n2: BrokerNodeState,
    n3: BrokerNodeState,
    mut model: List[List[_Rec]],
) raises:
    print("[phase 2] owners produce under their leases")
    for pid in range(_P):
        var who = _owner(pid, n1, n2, n3)
        var writer = _writer_epoch(who, pid, n1, n2, n3)
        var current = _current_epoch(who, pid, n1, n2, n3)
        var broker = _broker(root, pid, who)
        for b in range(_BATCHES):
            var recs = _append_records(model[pid], pid, _ROWS, String("p2"))
            var ts = _T0_MS + Int64(1000 * b)
            broker.buffer_batch(_batch(recs), ts)
            var res = broker.flush(ts, writer, current)
            var at = "partition " + String(pid) + " batch " + String(b)
            assert_equal(res.base_offset, Int64(b * _ROWS), at + " base")
            assert_equal(res.last_offset, Int64(b * _ROWS + _ROWS - 1), at + " last")
            assert_equal(res.record_count, Int64(_ROWS), at + " count")
            assert_equal(res.chunk_seq, Int64(b), at + " chunk")
        _ = broker^


# =============================================================================
# Phase 3 — drop everything, reopen, replay.
# =============================================================================


def phase3_replay(
    root: String,
    n1: BrokerNodeState,
    n2: BrokerNodeState,
    n3: BrokerNodeState,
    model: List[List[_Rec]],
    kept: Assignment,
) raises:
    print("[phase 3] reopen and replay every partition")
    for pid in range(_P):
        _assert_log_equals_model(root, pid, model[pid], "phase 3")
    # Nothing rewrites the assignment between phase 1 and here: this is a cold
    # re-read of a file that must still hold exactly what phase 1 read.
    var reread = _read_persisted(root)
    _assert_same_assignment(reread, kept, "phase 3 reopened")
    _assert_matches_nodes(reread, n1, n2, n3, "phase 3 reopened")


# =============================================================================
# Phase 4 — node 3 goes stale; sticky reassignment; its late append is fenced.
# =============================================================================


def phase4_fence(
    root: String,
    mut coord: BrokerHeartbeatCoordinator[_Store],
    mut n1: BrokerNodeState,
    mut n2: BrokerNodeState,
    mut n3: BrokerNodeState,
    mut model: List[List[_Rec]],
    mut now_us: Int64,
    mut new_owner: Int,
) raises -> Int:
    """Returns the reassigned partition; `new_owner` gets the node serving it.
    Node 3's own state is never updated (it is partitioned away), so from here
    on ownership is read from the persisted assignment, not the node states."""
    print("[phase 4] node 3 goes stale; caller-supplied fence and its residual")
    var before = _read_persisted(root)
    var kept1 = n1.owned_partitions()
    var kept2 = n2.owned_partitions()
    var lost3 = n3.owned_partitions()
    assert_equal(len(lost3), 2, "node 3 serves two partitions")
    var victim = Int(lost3[0])
    var pinned = Int(lost3[1])
    var old_writer = n3.writer_lease_epoch_of(UInt32(victim))

    # Node 3 holds an unflushed batch for each of its partitions when it stops
    # heartbeating. `victim`'s batch is refused below; `pinned`'s commits (the
    # documented residual), so it goes into the model now.
    var zombie = _broker(root, victim, 3)
    var late = List[_Rec]()
    late.append(_Rec(key=_key(victim, 0), value=String("late-ゾンビ")))
    late.append(_Rec(key=_key(victim, 1), value=String("")))
    zombie.buffer_batch(_batch(late), _T0_MS + Int64(3_500))
    var residual = _broker(root, pinned, 3)
    var residual_base = len(model[pinned])
    var late2 = _append_records(model[pinned], pinned, 2, String("ゾンビ"))
    residual.buffer_batch(_batch(late2), _T0_MS + Int64(3_500))

    # Nodes 1 and 2 keep heartbeating; node 3 does not. After the stale window
    # the coordinator drops node 3 and reassigns its partitions.
    var started = List[UInt32]()
    var stopped = 0
    for _round in range(4):
        now_us += Int64(400_000)
        var d1 = _beat(coord, n1, now_us)
        var d2 = _beat(coord, n2, now_us + Int64(1))
        for i in range(len(d1.started)):
            started.append(d1.started[i])
        for i in range(len(d2.started)):
            started.append(d2.started[i])
        stopped += len(d1.stopped) + len(d2.stopped)
    assert_equal(coord.live_node_count(now_us + Int64(1)), 2, "node 3 is stale")
    assert_equal(stopped, 0, "no survivor gave up a partition")
    assert_equal(len(started), len(lost3), "only node 3's partitions moved")
    for i in range(len(lost3)):
        assert_true(_contains(started, lost3[i]), "a node 3 partition was taken over")

    var after = _read_persisted(root)
    assert_true(after.is_even(), "3/3 after the reassignment")
    assert_equal(after.count_for(String("3")), 0, "node 3 owns nothing")
    for i in range(len(kept1)):
        var pid = Int(kept1[i])
        assert_equal(after.owner_of(pid), String("1"), "node 1 kept its partition")
        assert_equal(after.generation_of(pid), before.generation_of(pid), "kept lease unchanged")
    for i in range(len(kept2)):
        var pid = Int(kept2[i])
        assert_equal(after.owner_of(pid), String("2"), "node 2 kept its partition")
        assert_equal(after.generation_of(pid), before.generation_of(pid), "kept lease unchanged")
    for i in range(len(lost3)):
        var pid = Int(lost3[i])
        assert_true(
            after.generation_of(pid) > before.generation_of(pid),
            "a moved partition's lease generation was bumped",
        )

    # The new owner produces at the new lease, contiguously after phase 2.
    new_owner = Int(after.owner_of(victim).as_bytes()[0] - UInt8(0x30))
    var new_gen = after.generation_of(victim)
    var nw = _writer_epoch(new_owner, victim, n1, n2, n3)
    if new_owner == 3:
        raise Error("the stale node was given back a partition")
    assert_equal(nw, new_gen, "the new owner's writer epoch is the new generation")
    var successor = _broker(root, victim, new_owner)
    var base = len(model[victim])
    var recs = _append_records(model[victim], victim, _ROWS, String("p4"))
    successor.buffer_batch(_batch(recs), _T0_MS + Int64(3_000))
    var res = successor.flush(
        _T0_MS + Int64(3_000), nw, _current_epoch(new_owner, victim, n1, n2, n3)
    )
    assert_equal(res.base_offset, Int64(base), "the new owner appends contiguously")
    _ = successor^

    # Node 3 comes back and flushes. It has seen no heartbeat reply, so its own
    # node state still reports its old lease as current.
    assert_equal(
        n3.current_lease_epoch_of(UInt32(victim)), old_writer,
        "the stale node has not observed the takeover",
    )

    # (a) FENCED, with the live generation supplied by THE TEST. No product
    # path reads the persisted generation at flush; this proves only that
    # `BrokerCore.flush` refuses below the `current_lease_epoch` it is given.
    var live_gen = _read_persisted(root).generation_of(victim)
    assert_true(old_writer < live_gen, "the stale lease is below the live one")
    var probe = _consumer(root, victim)
    var offsets_before = probe.next_offset()
    var chunks_before = probe.num_chunks()
    _ = probe^
    var segs_before = _segment_objects(root, victim)
    var refused = False
    try:
        _ = zombie.flush(_T0_MS + Int64(3_500), old_writer, live_gen)
    except e:
        var msg = String(e)
        assert_true(is_lease_fenced(msg), "refused as lease_fenced, got: " + msg)
        refused = True
    assert_true(refused, "a late append below the supplied live lease was refused")
    _ = zombie^
    var check = _consumer(root, victim)
    assert_equal(check.next_offset(), offsets_before, "offsets unchanged by the fenced append")
    assert_equal(check.num_chunks(), chunks_before, "no chunk committed by the fenced append")
    _ = check^
    # `BrokerCore.flush` refuses a writer below `current_lease_epoch` before
    # its segment PUT, so the refused flush leaves no `.seg` behind (nothing
    # would ever delete one: komira-ai/komira#488).
    assert_equal(
        _segment_objects(root, victim), segs_before,
        "the fenced flush PUT no segment (refused before the PUT)",
    )
    _assert_log_equals_model(root, victim, model[victim], "phase 4 fenced")

    # (b) NOT FENCED, pinned residual: node 3 flushes `pinned` with the epochs
    # its own node state reports (old, old). The fence compares only what the
    # caller passes (cas_manifest: best-effort, caller-supplied), so the late
    # append commits at the next free offset of the new owner's partition.
    var w3 = n3.writer_lease_epoch_of(UInt32(pinned))
    var c3 = n3.current_lease_epoch_of(UInt32(pinned))
    assert_equal(w3, c3, "the stale node sees itself as the current writer")
    assert_true(
        w3 < _read_persisted(root).generation_of(pinned),
        "while the persisted lease for that partition has moved on",
    )
    var res2 = residual.flush(_T0_MS + Int64(3_500), w3, c3)
    assert_equal(
        res2.base_offset, Int64(residual_base),
        "known residual: a stale node using its own epochs is not fenced",
    )
    _ = residual^
    _assert_log_equals_model(root, pinned, model[pinned], "phase 4 residual")
    return victim


# =============================================================================
# Phase 5 — retention and log compaction on the reassigned partition.
# =============================================================================


def phase5_retain_and_compact(
    root: String,
    victim: Int,
    owner: Int,
    model: List[_Rec],
) raises:
    print("[phase 5] retention, reap and log compaction")
    var first_live = _ROWS  # chunk 0 is the only one past retention
    var broker = _broker(root, victim, owner)
    var ret = broker.retention_pass_on_partition(
        RetentionPolicy.time_based(_RETENTION_MS), _RETAIN_AT_MS
    )
    assert_equal(ret.tombstoned_count, Int64(1), "one chunk past retention")
    assert_equal(ret.new_log_start_seq, Int64(1), "log_start moves to chunk 1")
    assert_equal(ret.new_log_start_offset, Int64(first_live), "log_start offset")
    assert_true(ret.advanced_log_start, "log_start advanced")
    var reaped = broker.reap_partition(_RETAIN_AT_MS, grace_ms=Int64(0))
    assert_equal(reaped.reaped_count, Int64(1), "the retired chunk is reaped")
    assert_equal(
        reaped.skipped_live_count, Int64(0), "no tombstone on a live chunk"
    )
    _ = broker^

    var consumer = _consumer(root, victim)
    assert_equal(consumer.log_start_offset(), Int64(first_live), "persisted log_start")
    var index = consumer.resolve_index()
    assert_true(len(index) >= 2, "a cleanable chunk and the active chunk")
    var head_seq = index[len(index) - 1].chunk_seq
    # The reaper deleted the retired chunk's segment, and the refused phase-4
    # flush PUT none, so exactly the live chunks' segments remain.
    assert_equal(
        _segment_objects(root, victim), len(index),
        "one segment per live chunk",
    )

    # Compact the cleanable chunks [log_start_seq, head): decode each one.
    var batches = Slab[RecordBatch]()
    var bases = List[Int64]()
    var seqs = List[Int64]()
    for i in range(len(index)):
        if index[i].chunk_seq >= head_seq:
            continue
        var seg = consumer.read_segment(index[i].copy())
        var decoded = _decode_batches(seg.stream_bytes)
        assert_equal(len(decoded), 1, "one batch per flushed chunk")
        batches.append(decoded.take_at(0))
        bases.append(index[i].base_offset)
        seqs.append(index[i].chunk_seq)
    var cleanable_end = Int(index[len(index) - 1].base_offset)
    var manifest = _manifest(root, victim)
    # Zero tombstone grace: a record the cleaner took for a tombstone would be
    # dropped outright, so an empty value mistaken for a null goes missing.
    var cleaner = LogCleaner[_Store](
        CompactionConfig.compact(Int64(0)), key_col=0, value_col=1
    )
    var clean = cleaner.run(manifest, batches^, bases, seqs, _RETAIN_AT_MS)
    assert_true(clean.ran, "the cleaner ran")
    assert_equal(
        clean.records_scanned, Int64(cleanable_end - first_live), "scanned the cleanable range"
    )
    _ = manifest^

    # The latest offset of every key in the cleanable range, from the model.
    var latest = List[Bool]()
    for o in range(len(model)):
        var is_latest = o >= first_live and o < cleanable_end
        if is_latest:
            for later in range(o + 1, cleanable_end):
                if model[later].key == model[o].key:
                    is_latest = False
        latest.append(is_latest)

    var check = _consumer(root, victim)
    var read = check.read_from_checked(Int64(0))
    assert_true(read.truncated, "a read from 0 is told it was truncated")
    assert_equal(read.effective_start_offset, Int64(first_live), "a read from 0 starts at log_start")
    assert_equal(read.segments[0].base_offset, Int64(first_live), "first segment is at log_start")
    var expect = first_live
    var survivors_seen = 0
    var empty_survivors = 0
    for i in range(len(read.segments)):
        ref seg = read.segments[i]
        var base = Int(seg.base_offset)
        assert_equal(base, expect, "segments contiguous after retention")
        # The contract is the MANIFEST record_count; the physical segment's
        # count may shrink once a compacted segment is rewritten sparse.
        var body = check.read_chunk_body(seg.chunk_seq)
        assert_equal(
            ManifestBody.decode(body).record_count, Int64(_ROWS),
            "manifest record_count preserved by compaction",
        )
        var survivors = decode_compacted_survivor_offsets(body)
        if base >= cleanable_end:
            assert_equal(len(survivors), 0, "the active chunk is not compacted")
        else:
            var want = List[Int]()
            for o in range(base, base + _ROWS):
                if latest[o]:
                    want.append(o)
            assert_equal(len(survivors), len(want), "survivors of chunk " + String(seg.chunk_seq))
            for s in range(len(want)):
                var o = want[s]
                assert_equal(Int(survivors[s]), o, "survivor at its original offset")
                if model[o].value.byte_length() == 0:
                    empty_survivors += 1
                survivors_seen += 1
        expect = Int(seg.last_offset) + 1
    assert_equal(expect, len(model), "the log still ends at the last produced offset")
    assert_equal(Int64(survivors_seen), clean.survivors, "every survivor checked")
    assert_true(clean.dropped > Int64(0), "compaction dropped superseded records")
    assert_true(
        empty_survivors > 0, "a key whose latest value is empty survives compaction"
    )


def main() raises:
    var root = _root()
    var n1 = BrokerNodeState(String("1"))
    var n2 = BrokerNodeState(String("2"))
    var n3 = BrokerNodeState(String("3"))
    var now_us = _T0_US
    var model = List[List[_Rec]]()
    for _ in range(_P):
        model.append(List[_Rec]())

    var kept = Optional[Assignment]()
    var coord = phase1_assign(root, n1, n2, n3, now_us, kept)
    phase2_produce(root, n1, n2, n3, model)
    phase3_replay(root, n1, n2, n3, model, kept.value())
    var owner = 0
    var victim = phase4_fence(root, coord, n1, n2, n3, model, now_us, owner)
    _ = coord^
    phase5_retain_and_compact(root, victim, owner, model[victim])
    print("test_broker_lifecycle_e2e: ALL PHASES PASS")
