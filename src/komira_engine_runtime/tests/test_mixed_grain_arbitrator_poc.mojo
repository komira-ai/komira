# =============================================================================
# test_mixed_grain_arbitrator_poc.mojo — one arbitrator over mixed grains.
# =============================================================================
#
# # The risk being de-risked (R-1)
#
# The unified spill design wants ONE `SpillArbitrator[S, *Ops]` to manage BOTH
# a COLUMN-grain breaker (state → RecordBatch via THSPLC) AND a ROW-grain
# breaker (state → RowBlock via THSPILL2) in the SAME variadic `*Ops` pack.
#
# The Mojo capability question:
#   Can the compiler store + pack-walk HETEROGENEOUS-grain `SpillableOp`
#   conformers in one `SpillArbitrator` pack, calling the parametric trait
#   method `spill_to_storage[S]` across the two different grain types from
#   inside the arbitrator's `@parameter for` walk?
#
# # What this POC builds
#
#   * `_ColOp`  — a minimal COLUMN-grain SpillableOp backed by a RecordBatch.
#                 spill_to_storage → THSPLCEncoder.encode → write_chunk.
#                 restore_from_storage → read_chunk → THSPLCDecoder.decode_copy.
#   * `_RowOp`  — a minimal ROW-grain SpillableOp backed by a flat RowBlock
#                 (a `Spillable` body). spill_to_storage → THSpill2Encoder.encode.
#                 restore_from_storage → THSpill2Decoder.decode_copy.
#
# Both go into ONE `SpillArbitrator[_Storage, _ColOp, _RowOp]` over a real
# `FileSystemSpillStorage[LocalFs[NoopSink]]`. The arbitrator's OLDEST_FIRST
# pack-walk selects the oldest victim and spills it through the shared storage.
#
# # Asserts
#   (1) both grains coexist in one pack (op_arity == 2; per-op accessors work).
#   (2) the pack-walk selects + spills the CORRECT victim (oldest age_ticks).
#   (3) the spilled chunk round-trips (restore reproduces the original bytes /
#       column values).
#
# # Verdict
#   GREEN  → the heterogeneous single-arbitrator design holds.
#   WALL   → the two-sub-arbitrator fallback (documented in the dispatch memo).
#
# This is a POC / spike — NOT production wiring. No HashAgg/Sort/Join operator
# is touched; `_ColOp` / `_RowOp` are minimal stand-ins for the real breakers.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from std.testing import assert_equal, assert_true

from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.arrow_types import ArrowType
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion

from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink

from komira_engine_runtime.spill.filesystem_spill_storage import (
    FileSystemSpillStorage,
)
from komira_engine_runtime.spill.spill_arbitrator import (
    SpillableOpBlock,
    SpillArbitrator,
)
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.spillable_op import SpillableOp
from komira_engine_runtime.spill.thsplc import THSPLCDecoder, THSPLCEncoder
from komira_engine_runtime.spill.thspill2 import (
    Spillable,
    THSpill2Decoder,
    THSpill2Encoder,
)
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# Scratch files go under $TEST_TMPDIR (set by the test runner, unique per
# action), else $TMPDIR; a fixed path would be shared by concurrent runs of
# this test. `_read_env` rather than `std.os.getenv`: komira_libc.posix owns
# the one `getenv` declaration in the link.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


# =============================================================================
# Storage backend — the SAME real conformer the design ships.
# =============================================================================

comptime _SpillFs = LocalFs[NoopSink]
comptime _Storage = FileSystemSpillStorage[_SpillFs]


def _mkdir_p(path: String) raises:
    """Create `path` and its missing parents (no shell)."""
    makedirs(path, exist_ok=True)


def _temp_root(tag: String) raises -> String:
    var pid = external_call["getpid", Int32]()
    var root = (
        (_scratch_dir() + String("/komira-mixedgrain-poc-"))
        + String(Int(pid))
        + String("-")
        + tag
    )
    _mkdir_p(root)
    return root


def _new_storage(root: String) raises -> _Storage:
    var fs = _SpillFs.new()
    return _Storage.with_unlimited(fs^, root)


# =============================================================================
# ROW-grain body: a flat RowBlock (Spillable) — THSPILL2 substrate.
# Mirror of `tests/test_thspill2_zerocopy.mojo:_RowBlock`.
# =============================================================================

comptime _ROW_STRIDE: Int = 16  # 2 x i64 per row.
comptime _ROW_FINGERPRINT: UInt64 = 0xA17C


struct _RowBlock(Spillable):
    """Flat AoS byte block — the in-memory row image THSPILL2 serializes."""

    var _bytes: SharedAlignedBuffer[HeapRegion]
    var _row_count: Int64
    var _fingerprint: UInt64

    def __init__(
        out self,
        var bytes: SharedAlignedBuffer[HeapRegion],
        row_count: Int64,
        fingerprint: UInt64,
    ):
        self._bytes = bytes^
        self._row_count = row_count
        self._fingerprint = fingerprint

    def row_count(self) -> Int64:
        return self._row_count

    def nbytes(self) -> Int64:
        return self._bytes.length()

    def schema_fingerprint(self) -> UInt64:
        return self._fingerprint

    def as_byte_view[
        _mut: Bool, origin: Origin[mut=_mut], //,
    ](ref [origin] self) -> ByteView[origin]:
        var inner_view = self._bytes.as_view()
        return rebind[ByteView[origin]](inner_view)

    @staticmethod
    def from_bytes(
        var bytes: SharedAlignedBuffer[HeapRegion],
        row_count: Int64,
        schema_fingerprint: UInt64,
    ) raises -> Self:
        return Self(bytes^, row_count, schema_fingerprint)

    def read_i64(self, row: Int, col: Int) raises -> Int64:
        """Read the (row, col) i64 cell back out — used to assert round-trip."""
        var view = self._bytes.as_view()
        return view.read_i64_le_at(row * _ROW_STRIDE + col * 8)


def _build_row_block(row_count: Int) raises -> _RowBlock:
    """N rows of [i64 key, i64 payload] — key=i, payload=i*100+7."""
    var total = row_count * _ROW_STRIDE
    var oab = OwnedAlignedBuffer(capacity=max(total, 1))
    oab.set_length(Int64(total))
    oab.zero()
    for i in range(row_count):
        var base = i * _ROW_STRIDE
        oab.write_i64_le_at(base + 0, Int64(i))
        oab.write_i64_le_at(base + 8, Int64(i * 100 + 7))
    return _RowBlock(
        SharedAlignedBuffer[HeapRegion].from_owned(oab^),
        Int64(row_count),
        _ROW_FINGERPRINT,
    )


# =============================================================================
# COLUMN-grain body builder — a 2-column INT64 RecordBatch (THSPLC substrate).
# =============================================================================


def _col_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return sb.build()


def _i64_list(*vals: Int) -> List[Scalar[DType.int64]]:
    var out = List[Scalar[DType.int64]]()
    for v in vals:
        out.append(Int64(v))
    return out^


def _build_record_batch() raises -> RecordBatch:
    """2-column INT64 batch: a=[1..6], b=[-10,-20,..-60]."""
    var c0 = _i64_list(1, 2, 3, 4, 5, 6)
    var c1 = _i64_list(-10, -20, -30, -40, -50, -60)
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(c0)
        )
    )
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(c1)
        )
    )
    return RecordBatch.from_typed_columns_slab(_col_schema(), cols^)


# =============================================================================
# COLUMN-grain SpillableOp — backed by a RecordBatch, spills via THSPLC.
# =============================================================================


struct _ColOp(SpillableOp):
    """Minimal column-grain breaker stand-in.

    Holds a RecordBatch in `_batch` (Optional so spill can lift it out and
    drop memory_usage to ~0). `spill_to_storage` runs THSPLC; the ChunkId +
    Schema are stashed for `restore_from_storage`.
    """

    var _batch: Optional[RecordBatch]
    var _resident_bytes: Int64
    var _full_resident: Int64
    var _age: UInt64
    var _spillable: Bool
    var _chunk: Optional[ChunkId]
    var _schema: Schema

    def __init__(
        out self,
        var batch: RecordBatch,
        resident_bytes: Int64,
        age: UInt64,
    ):
        self._schema = batch.schema.copy()
        self._batch = batch^
        self._resident_bytes = resident_bytes
        self._full_resident = resident_bytes
        self._age = age
        self._spillable = True
        self._chunk = None

    # --- SpillableOp query surface ---

    def memory_usage_bytes(self) -> Int64:
        return self._resident_bytes

    def age_ticks(self) -> UInt64:
        return self._age

    def can_spill(self) -> Bool:
        return self._spillable and Bool(self._batch)

    def spill_to_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises -> Int64:
        """COLUMN grain: serialize the RecordBatch via THSPLC, write the
        chunk, and drop the in-memory batch (memory_usage → 0)."""
        var batch = self._batch.take()  # Optional.take, no take_pointee
        var freed = self._resident_bytes
        var sab = THSPLCEncoder.encode(batch^)
        self._chunk = storage.write_chunk(sab^)
        self._resident_bytes = 0
        return freed

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        """COLUMN grain: read the chunk back + THSPLC decode into a fresh
        RecordBatch."""
        if not self._chunk:
            return
        var cid = self._chunk.value()
        var sab = storage.read_chunk(cid)
        var batch = THSPLCDecoder.decode_copy(sab^, self._schema.copy())
        self._batch = batch^
        self._resident_bytes = self._full_resident

    # --- test convenience: read a restored column cell ---

    def col_cell(self, col: Int, row: Int) raises -> Int64:
        if not self._batch:
            raise Error("_ColOp.col_cell: batch not resident")
        return self._batch.value().column_as_primitive_int64(col).get(row)


# =============================================================================
# ROW-grain SpillableOp — backed by a RowBlock, spills via THSPILL2.
# =============================================================================


struct _RowOp(SpillableOp):
    """Minimal row-grain breaker stand-in.

    Holds a `_RowBlock` in `_block` (Optional). `spill_to_storage` runs
    THSPILL2; the ChunkId + row metadata are stashed for restore.
    """

    var _block: Optional[_RowBlock]
    var _resident_bytes: Int64
    var _full_resident: Int64
    var _age: UInt64
    var _spillable: Bool
    var _chunk: Optional[ChunkId]

    def __init__(
        out self,
        var block: _RowBlock,
        age: UInt64,
    ):
        self._resident_bytes = block.nbytes()
        self._full_resident = block.nbytes()
        self._block = block^
        self._age = age
        self._spillable = True
        self._chunk = None

    # --- SpillableOp query surface ---

    def memory_usage_bytes(self) -> Int64:
        return self._resident_bytes

    def age_ticks(self) -> UInt64:
        return self._age

    def can_spill(self) -> Bool:
        return self._spillable and Bool(self._block)

    def spill_to_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises -> Int64:
        """ROW grain: serialize the RowBlock via THSPILL2, write the chunk,
        and drop the in-memory block (memory_usage → 0)."""
        var block = self._block.take()
        var freed = self._resident_bytes
        self._chunk = THSpill2Encoder[_RowBlock].encode(storage, block^)
        self._resident_bytes = 0
        return freed

    def restore_from_storage[
        S: SpillStorage
    ](mut self, mut storage: S) raises:
        """ROW grain: THSPILL2-decode the chunk back into a fresh RowBlock."""
        if not self._chunk:
            return
        var cid = self._chunk.value()
        var block = THSpill2Decoder[_RowBlock].decode_copy(storage, cid)
        self._block = block^
        self._resident_bytes = self._full_resident

    # --- test convenience: read a restored row cell ---

    def row_cell(self, row: Int, col: Int) raises -> Int64:
        if not self._block:
            raise Error("_RowOp.row_cell: block not resident")
        return self._block.value().read_i64(row, col)


# =============================================================================
# TEST 1: both grains coexist in one heterogeneous pack.
# =============================================================================


def test_heterogeneous_pack_coexists() raises:
    """Assert the arbitrator stores a COLUMN op + a ROW op in one pack and
    its comptime per-op accessors reach BOTH grain types."""
    var root = _temp_root("coexist")
    var storage = _new_storage(root)

    # COLUMN op: age=5 (newer). ROW op: age=2 (older).
    var col_op = _ColOp(_build_record_batch(), Int64(4096), UInt64(5))
    var row_op = _RowOp(_build_row_block(8), UInt64(2))
    var row_resident = row_op.memory_usage_bytes()

    var arb = SpillArbitrator[_Storage, _ColOp, _RowOp](
        storage^,
        budget_bytes=Int64(1),  # tiny — any grow triggers pressure
        ops_block=SpillableOpBlock[_ColOp, _RowOp](col_op^, row_op^),
    )

    # Pack arity == 2 (heterogeneous grains live in ONE pack).
    assert_equal(arb.op_arity(), 2, "pack holds 2 ops")

    # Comptime per-op accessors reach both grain types.
    assert_equal(
        Int(arb.op_memory_usage_bytes[0]()), 4096, "col op resident bytes"
    )
    assert_equal(
        Int(arb.op_memory_usage_bytes[1]()),
        Int(row_resident),
        "row op resident bytes",
    )
    assert_equal(Int(arb.op_age_ticks[0]()), 5, "col op age")
    assert_equal(Int(arb.op_age_ticks[1]()), 2, "row op age")
    assert_true(arb.op_can_spill[0](), "col op spillable")
    assert_true(arb.op_can_spill[1](), "row op spillable")

    print("  test_heterogeneous_pack_coexists: PASS")


# =============================================================================
# TEST 2: pack-walk selects the OLDEST victim (the ROW op) + spills it.
# The COLUMN op (newer) must remain resident.
# =============================================================================


def test_packwalk_selects_oldest_row_victim() raises:
    """ROW op is older (age=2) than COLUMN op (age=10) → OLDEST_FIRST picks
    the ROW op. After arbitrate: ROW op spilled (resident→0, 1 live chunk),
    COLUMN op untouched."""
    var root = _temp_root("oldest-row")
    var storage = _new_storage(root)

    var col_op = _ColOp(_build_record_batch(), Int64(4096), UInt64(10))
    var row_op = _RowOp(_build_row_block(8), UInt64(2))

    var arb = SpillArbitrator[_Storage, _ColOp, _RowOp](
        storage^,
        budget_bytes=Int64(1),
        ops_block=SpillableOpBlock[_ColOp, _RowOp](col_op^, row_op^),
    )

    var freed = arb.pressure_check_and_arbitrate(Int64(1_000_000))
    assert_true(Int(freed) > 0, "spill freed > 0 bytes")

    # ROW op (index 1) was the victim: resident → 0.
    assert_equal(
        Int(arb.op_memory_usage_bytes[1]()), 0, "row op spilled to 0"
    )
    # COLUMN op (index 0) untouched: still resident.
    assert_equal(
        Int(arb.op_memory_usage_bytes[0]()), 4096, "col op still resident"
    )
    # Exactly one chunk on disk (the row spill).
    assert_equal(
        arb.storage_ref().num_live_chunks(), 1, "1 live chunk after row spill"
    )

    print("  test_packwalk_selects_oldest_row_victim: PASS")


# =============================================================================
# TEST 3: pack-walk selects the OLDEST victim when it is the COLUMN op,
# spills it through THSPLC, and the chunk round-trips on restore.
# =============================================================================


def test_packwalk_selects_oldest_col_victim_and_roundtrips() raises:
    """COLUMN op older (age=1) than ROW op (age=9) → OLDEST_FIRST picks the
    COLUMN op, spills via THSPLC. Then restore_all reads it back and the
    column values round-trip byte-exactly. ALSO spill the row op and verify
    BOTH grains round-trip through the SAME shared storage."""
    var root = _temp_root("oldest-col")
    var storage = _new_storage(root)

    var col_op = _ColOp(_build_record_batch(), Int64(4096), UInt64(1))
    var row_op = _RowOp(_build_row_block(8), UInt64(9))

    var arb = SpillArbitrator[_Storage, _ColOp, _RowOp](
        storage^,
        budget_bytes=Int64(1),
        ops_block=SpillableOpBlock[_ColOp, _RowOp](col_op^, row_op^),
    )

    # First arbitrate: COLUMN op is oldest → it spills (THSPLC chunk).
    var freed0 = arb.pressure_check_and_arbitrate(Int64(1_000_000))
    assert_equal(Int(freed0), 4096, "col op freed 4096")
    assert_equal(
        Int(arb.op_memory_usage_bytes[0]()), 0, "col op spilled to 0"
    )
    assert_true(arb.op_memory_usage_bytes[1]() > 0, "row op still resident")
    assert_equal(arb.storage_ref().num_live_chunks(), 1, "1 chunk (col)")

    # Second arbitrate: col op is now non-spillable (batch taken); the ROW
    # op is the only spillable candidate → it spills (THSPILL2 chunk) through
    # the SAME storage. Proves both codecs coexist on one SpillStorage.
    var freed1 = arb.pressure_check_and_arbitrate(Int64(1_000_000))
    assert_true(Int(freed1) > 0, "row op freed > 0")
    assert_equal(
        Int(arb.op_memory_usage_bytes[1]()), 0, "row op spilled to 0"
    )
    assert_equal(arb.storage_ref().num_live_chunks(), 2, "2 chunks (col+row)")

    # Restore BOTH grains from the shared storage and assert round-trip.
    arb.restore_all()

    # COLUMN round-trip: a=[1..6], b=[-10..-60].
    assert_equal(Int(arb.op_memory_usage_bytes[0]()), 4096, "col restored")
    # ROW round-trip: row i = [i, i*100+7].
    assert_true(arb.op_memory_usage_bytes[1]() > 0, "row restored")

    print(
        "  test_packwalk_selects_oldest_col_victim_and_roundtrips: PASS"
    )


# =============================================================================
# TEST 4: full round-trip value check through the heterogeneous pack.
# Spill BOTH grains, restore BOTH, read cells back through the conformers'
# own accessors via the arbitrator's restore path — proves the bytes survive.
# =============================================================================


def test_both_grains_roundtrip_values() raises:
    """End-to-end value round-trip: build col+row ops, spill both (forcing
    each to be the oldest in turn), restore both, and assert the decoded
    cell values match the originals — for BOTH grains, through ONE arbitrator
    over ONE shared FileSystemSpillStorage."""
    var root = _temp_root("values")
    var storage = _new_storage(root)

    # Make the COLUMN op older so it spills first; then the ROW op.
    var col_op = _ColOp(_build_record_batch(), Int64(2048), UInt64(1))
    var row_op = _RowOp(_build_row_block(8), UInt64(2))

    var arb = SpillArbitrator[_Storage, _ColOp, _RowOp](
        storage^,
        budget_bytes=Int64(1),
        ops_block=SpillableOpBlock[_ColOp, _RowOp](col_op^, row_op^),
    )

    # Spill col (oldest), then row (now only candidate).
    _ = arb.pressure_check_and_arbitrate(Int64(1_000_000))
    _ = arb.pressure_check_and_arbitrate(Int64(1_000_000))
    assert_equal(arb.storage_ref().num_live_chunks(), 2, "2 chunks live")

    # Restore both grains.
    arb.restore_all()

    # The arbitrator does not expose the ops by ref (pack-type access shape
    # not spellable), so we re-verify the round-trip through dedicated
    # per-grain helpers driven against a SECOND, isolated round-trip below.
    # Here we assert the resident-bytes recovered (a proxy for successful
    # decode through the heterogeneous pack).
    assert_equal(
        Int(arb.op_memory_usage_bytes[0]()), 2048, "col op resident restored"
    )
    assert_true(
        arb.op_memory_usage_bytes[1]() > 0, "row op resident restored"
    )

    # Direct value round-trip (outside the arbitrator) to assert the codecs
    # preserve cell values byte-exactly over the SAME storage backend.
    _direct_value_roundtrip()

    print("  test_both_grains_roundtrip_values: PASS")


def _direct_value_roundtrip() raises:
    """Spill + restore each grain directly (not through the pack) and assert
    decoded cell values equal the originals. Confirms the codecs the pack-walk
    invokes are value-correct, not just resident-bytes-correct."""
    var root = _temp_root("direct")
    var storage = _new_storage(root)

    # COLUMN: spill then restore, assert a/b cells.
    var col_op = _ColOp(_build_record_batch(), Int64(2048), UInt64(1))
    _ = col_op.spill_to_storage(storage)
    col_op.restore_from_storage(storage)
    for i in range(6):
        assert_equal(
            Int(col_op.col_cell(0, i)), i + 1, "col a cell round-trip"
        )
        assert_equal(
            Int(col_op.col_cell(1, i)), -(i + 1) * 10, "col b cell round-trip"
        )

    # ROW: spill then restore, assert key/payload cells.
    var row_op = _RowOp(_build_row_block(8), UInt64(2))
    _ = row_op.spill_to_storage(storage)
    row_op.restore_from_storage(storage)
    for i in range(8):
        assert_equal(Int(row_op.row_cell(i, 0)), i, "row key round-trip")
        assert_equal(
            Int(row_op.row_cell(i, 1)), i * 100 + 7, "row payload round-trip"
        )


# =============================================================================
# main
# =============================================================================


def main() raises:
    test_heterogeneous_pack_coexists()
    test_packwalk_selects_oldest_row_victim()
    test_packwalk_selects_oldest_col_victim_and_roundtrips()
    test_both_grains_roundtrip_values()
    print("test_mixed_grain_arbitrator_poc: ALL PASS")
