# =============================================================================
# test_shuffle_combine_bounded_ram.mojo
#   Tests of `stream_combine_segment_spilling`: the combine under a byte budget.
# =============================================================================
#
# The budget T is a few KiB to a few hundred KiB so that a partition many times
# T is cheap to build. Every bound below is a count (bytes the combine reports
# holding, chunks written), not a measurement of time or memory.
#
#   1. bounded count: a partition many times T is staged in chunks, so
#      `peak_staged_bytes` is exactly T (a full chunk) and never above it, the
#      number of chunks written is ceil(len / T), and the spill storage is empty
#      at the end.
#   2. the same result: the spilled `.seg` equals both the unspilled combine's
#      and `SegWriter`'s for the same slices.
#   3. the budget boundary: a partition of exactly T bytes is not spilled; one of
#      T + 1 bytes is, in two chunks.
#   4. rows exactly once: slices of 8-byte row ids, spilled and restored, hold
#      every input id exactly once across the partitions, and the slots' row
#      counts match the rows read.
#   5. a spill failure is reported: a storage whose `write_chunk` (or
#      `read_chunk`) fails makes the combine raise with the storage's message,
#      releases the chunks already written and leaves no partial `.seg`.
#   6. a budget of 0 or below spills nothing through the spilling entry point.
#   7. several oversized partitions in one run each spill and restore once.
#   8. a restore failing in the second oversized partition releases that
#      partition's chunks and leaves no partial `.seg`.
#   9. a release that raises is attempted once; cleanup does not repeat it and
#      the original error is the one reported.
#
# LocalFs only; nothing here depends on time or on threads.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_shuffle.segment import SegWriter, SegReader, write_segment

from komira_engine_runtime.spill.filesystem_spill_storage import (
    FileSystemSpillStorage,
)
from komira_engine_runtime.spill.spill_storage import ChunkId, SpillStorage
from komira_engine_runtime.spill.shuffle_stream_combine import (
    ListPartitionSource,
    stream_combine_segment,
    stream_combine_segment_spilling,
)
from komira_libc.posix import _read_env


comptime _Fs = LocalFs[NoopSink]
comptime _Storage = FileSystemSpillStorage[_Fs]


# Scratch files go under $TEST_TMPDIR (unique per test action), else $TMPDIR.
def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


def _scratch_root(tag: String) raises -> String:
    return _scratch_dir() + String("/komira_combine_bounded_") + tag


def _make_payload(n: Int, marker: UInt32) -> List[UInt8]:
    """Deterministic n-byte payload seeded by `marker`."""
    var out = List[UInt8]()
    out.reserve(n)
    for i in range(n):
        var v = (marker * UInt32(31) + UInt32(i)) & UInt32(0xFF)
        out.append(UInt8(Int(v)))
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _ensure_root(root: String) raises:
    """LocalFs does not create parent directories; the store's constructor
    creates its root."""
    var store = LocalFsConditionalStore(root.copy())
    _ = store^


def _cleanup(root: String):
    try:
        var store = LocalFsConditionalStore(root.copy())
        var res = store.list_with_delimiter(Path.parse(String("")))
        for i in range(len(res.objects)):
            store.delete(Path.parse(res.objects[i].location))
        _ = store^
    except:
        pass


def _make_partitions(
    lens: List[Int], rows: Int64
) -> Tuple[List[List[UInt8]], List[Int64]]:
    """Partition p holds `lens[p]` bytes (0 = empty), seeded by p."""
    var slices = List[List[UInt8]]()
    var row_counts = List[Int64]()
    for p in range(len(lens)):
        if lens[p] == 0:
            slices.append(List[UInt8]())
            row_counts.append(Int64(0))
        else:
            slices.append(_make_payload(lens[p], UInt32(p + 1) * UInt32(40503)))
            row_counts.append(rows)
    return (slices^, row_counts^)


def _segwriter_bytes(
    root: String,
    key: String,
    slices: List[List[UInt8]],
    row_counts: List[Int64],
) raises -> List[UInt8]:
    var store = LocalFsConditionalStore(root.copy())
    var w = SegWriter()
    for p in range(len(slices)):
        w.append_partition(slices[p], row_counts[p])
    _ = write_segment(store, Path.parse(key), w^)
    var whole = store.get(Path.parse(key))
    _ = store^
    return whole^


def _read_back(root: String, key: String) raises -> List[UInt8]:
    var store = LocalFsConditionalStore(root.copy())
    var whole = store.get(Path.parse(key))
    _ = store^
    return whole^


def _new_storage(root: String) raises -> _Storage:
    _ensure_root(root)
    var fs = _Fs.new()
    return _Storage.with_unlimited(fs^, root)


def _ceil_div(a: Int, b: Int) -> Int:
    return (a + b - 1) // b


# -----------------------------------------------------------------------------
# 1 + 2. the staged count is bounded by T; the result equals the unspilled one
# -----------------------------------------------------------------------------
def test_staged_bytes_never_exceed_budget() raises:
    var root = _scratch_root(String("bounded"))
    _ensure_root(root)
    var threshold = 32 * 1024
    var hot = 40 * threshold + 777  # 40.02 T: 41 chunks, the last one short

    var lens = List[Int]()
    lens.append(1000)
    lens.append(0)
    lens.append(hot)
    lens.append(threshold - 1)
    var parts = _make_partitions(lens, Int64(13))
    var slices = parts[0].copy()
    var row_counts = parts[1].copy()

    var storage = _new_storage(root + "/spill")
    var fs = _Fs.new()
    var src = ListPartitionSource(slices.copy(), row_counts.copy())
    var res = stream_combine_segment_spilling(
        fs, root + "/spilled.seg", src^, storage, Int64(threshold)
    )

    assert_equal(
        res.peak_staged_bytes,
        threshold,
        "the combine held exactly one full chunk at most, never more than T",
    )
    assert_true(res.peak_staged_bytes < hot, "far below the hot partition")
    assert_equal(
        res.chunks_spilled,
        _ceil_div(hot, threshold),
        "only the hot partition was spilled, in ceil(len / T) chunks",
    )
    assert_equal(len(res.slots), len(lens), "one dense slot per partition")
    assert_equal(storage.num_live_chunks(), 0, "every chunk was released")
    assert_equal(Int(storage.nbytes_in_use()), 0, "no spilled bytes left")

    # The same result as the unspilled combine and as SegWriter.
    var fs2 = _Fs.new()
    var src2 = ListPartitionSource(slices.copy(), row_counts.copy())
    var plain = stream_combine_segment(fs2, root + "/plain.seg", src2^)
    assert_equal(plain.chunks_spilled, 0, "the unspilled run spilled nothing")
    assert_equal(plain.peak_staged_bytes, hot, "the unspilled run stages it all")
    var spilled_bytes = _read_back(root, String("spilled.seg"))
    var plain_bytes = _read_back(root, String("plain.seg"))
    var oracle = _segwriter_bytes(
        root, String("oracle.seg"), slices, row_counts
    )
    assert_equal(len(spilled_bytes), len(plain_bytes), "same length as unspilled")
    assert_true(
        _bytes_eq(spilled_bytes, plain_bytes), "spilled seg == unspilled seg"
    )
    assert_true(_bytes_eq(spilled_bytes, oracle), "spilled seg == SegWriter seg")
    for p in range(len(lens)):
        assert_equal(
            Int(res.slots[p].length), Int(plain.slots[p].length), "slot length"
        )
        assert_equal(
            Int(res.slots[p].offset), Int(plain.slots[p].offset), "slot offset"
        )
    _ = storage^
    _cleanup(root)


# -----------------------------------------------------------------------------
# 3. the budget boundary
# -----------------------------------------------------------------------------
def test_budget_boundary() raises:
    var root = _scratch_root(String("boundary"))
    _ensure_root(root)
    var threshold = 4096

    var lens = List[Int]()
    lens.append(threshold)  # exactly T: staged in the buffer
    var parts = _make_partitions(lens, Int64(1))
    var storage = _new_storage(root + "/spill")
    var fs = _Fs.new()
    var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
    var at = stream_combine_segment_spilling(
        fs, root + "/at.seg", src^, storage, Int64(threshold)
    )
    assert_equal(at.chunks_spilled, 0, "a partition of exactly T is not spilled")
    assert_equal(at.peak_staged_bytes, threshold, "it is staged whole")

    var over = List[Int]()
    over.append(threshold + 1)
    var oparts = _make_partitions(over, Int64(1))
    var ofs = _Fs.new()
    var osrc = ListPartitionSource(oparts[0].copy(), oparts[1].copy())
    var above = stream_combine_segment_spilling(
        ofs, root + "/above.seg", osrc^, storage, Int64(threshold)
    )
    assert_equal(above.chunks_spilled, 2, "T + 1 bytes spill as T then 1")
    assert_equal(
        above.peak_staged_bytes, threshold, "the larger chunk is T bytes"
    )
    assert_equal(storage.num_live_chunks(), 0, "all released")
    var oracle = _segwriter_bytes(
        root, String("above_oracle.seg"), oparts[0], oparts[1]
    )
    assert_true(
        _bytes_eq(_read_back(root, String("above.seg")), oracle),
        "the T + 1 partition round-trips through spill",
    )
    _ = storage^
    _cleanup(root)


# -----------------------------------------------------------------------------
# 4. every row exactly once, across spills and restores
# -----------------------------------------------------------------------------
def _row_partition(id: Int) -> Int:
    """Skewed: 70% of rows in partition 2, partition 4 left empty."""
    var m = id % 10
    if m < 7:
        return 2
    if m == 7:
        return 0
    if m == 8:
        return 3
    return 1


def _make_row_partitions(
    n_rows: Int, r: Int
) -> Tuple[List[List[UInt8]], List[Int64]]:
    var slices = List[List[UInt8]]()
    var counts = List[Int64]()
    for _ in range(r):
        slices.append(List[UInt8]())
        counts.append(Int64(0))
    for id in range(n_rows):
        var p = _row_partition(id)
        for b in range(8):
            slices[p].append(UInt8((id >> (8 * b)) & 0xFF))
        counts[p] += 1
    return (slices^, counts^)


def test_every_row_exactly_once_across_spills() raises:
    var root = _scratch_root(String("rows"))
    _ensure_root(root)
    var n_rows = 50000
    var r = 5
    var threshold = 16 * 1024 + 3  # not a multiple of the 8-byte row width
    var parts = _make_row_partitions(n_rows, r)

    var storage = _new_storage(root + "/spill")
    var fs = _Fs.new()
    var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
    var res = stream_combine_segment_spilling(
        fs, root + "/rows.seg", src^, storage, Int64(threshold)
    )
    assert_true(res.chunks_spilled > 4, "several chunks were spilled")
    assert_true(res.peak_staged_bytes <= threshold, "count within the budget")
    assert_equal(storage.num_live_chunks(), 0, "every chunk was released")

    var seen = List[Int](length=n_rows, fill=0)
    var store = LocalFsConditionalStore(root.copy())
    var reader = SegReader[LocalFsConditionalStore](
        store.clone(), Path.parse(String("rows.seg"))
    )
    var total = 0
    for p in range(r):
        var back = reader.read_partition(p)
        assert_equal(len(back) % 8, 0, "partition bytes are whole rows")
        var rows_here = len(back) // 8
        assert_equal(
            Int(res.slots[p].row_count), rows_here, "slot row count == read"
        )
        for i in range(rows_here):
            var id = 0
            for b in range(8):
                id |= Int(back[i * 8 + b]) << (8 * b)
            assert_true(id >= 0 and id < n_rows, "row id in range")
            seen[id] += 1
            assert_equal(_row_partition(id), p, "row landed in its partition")
        total += rows_here
    for id in range(n_rows):
        assert_equal(seen[id], 1, "row " + String(id) + " appears exactly once")
    assert_equal(total, n_rows, "total rows read == rows in")
    assert_equal(Int(res.slots[4].length), 0, "partition 4 stayed empty")
    _ = reader^
    _ = store^
    _ = storage^
    _cleanup(root)


# -----------------------------------------------------------------------------
# 5. a spill failure is reported
# -----------------------------------------------------------------------------
struct _FlakyStorage(SpillStorage, Movable, Deinitable):
    """A real spill storage that fails the `fail_write_at`-th `write_chunk`
    (1-based; 0 = never) or every `read_chunk` when `fail_reads` is set."""

    var inner: _Storage
    var fail_write_at: Int
    var fail_reads: Bool
    var writes: Int

    def __init__(
        out self, var inner: _Storage, fail_write_at: Int, fail_reads: Bool
    ):
        self.inner = inner^
        self.fail_write_at = fail_write_at
        self.fail_reads = fail_reads
        self.writes = 0

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        self.writes += 1
        if self.writes == self.fail_write_at:
            _ = bytes^
            raise Error("disk full while spilling")
        return self.inner.write_chunk(bytes^)

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        if self.fail_reads:
            raise Error("EIO while restoring")
        return self.inner.read_chunk(chunk_id)

    def release_chunk(mut self, chunk_id: ChunkId) raises:
        self.inner.release_chunk(chunk_id)

    def nbytes_in_use(self) -> Int64:
        return self.inner.nbytes_in_use()

    def sync(mut self) raises:
        self.inner.sync()


def _expect_failure(
    root: String,
    tag: String,
    fail_write_at: Int,
    fail_reads: Bool,
    expected: String,
) raises:
    var threshold = 4096
    var lens = List[Int]()
    lens.append(500)
    lens.append(10 * threshold)  # ten full chunks
    var parts = _make_partitions(lens, Int64(1))
    var inner = _new_storage(root + "/spill_" + tag)
    var storage = _FlakyStorage(inner^, fail_write_at, fail_reads)
    var fs = _Fs.new()
    var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
    var raised = False
    var message = String("")
    try:
        _ = stream_combine_segment_spilling(
            fs, root + "/" + tag + ".seg", src^, storage, Int64(threshold)
        )
    except e:
        raised = True
        message = String(e)
    assert_true(raised, tag + ": the failure must not be swallowed")
    assert_true(
        expected in message,
        tag + ": the error carries the storage's message, got: " + message,
    )
    assert_equal(
        storage.inner.num_live_chunks(),
        0,
        tag + ": chunks already written were released",
    )
    var left_behind = True
    try:
        _ = _read_back(root, tag + ".seg")
    except:
        left_behind = False
    assert_true(not left_behind, tag + ": no partial seg left behind")
    _ = storage^


def test_spill_failure_is_reported() raises:
    var root = _scratch_root(String("failure"))
    _ensure_root(root)
    # The 4th chunk write fails, after three chunks are already on storage.
    _expect_failure(
        root, String("write"), 4, False, String("disk full while spilling")
    )
    # Every restore fails; all ten chunks were written first.
    _expect_failure(
        root, String("read"), 0, True, String("EIO while restoring")
    )
    _cleanup(root)


# -----------------------------------------------------------------------------
# 6. a budget of 0 or below spills nothing, through the spilling entry point
# -----------------------------------------------------------------------------
struct _CountingStorage(SpillStorage, Movable, Deinitable):
    """A real spill storage that counts calls. `write_chunk` calls are counted
    in `writes`; `read_chunk` raises once `writes` has reached
    `fail_reads_at_writes` (0 = never); the `fail_release_at`-th
    `release_chunk` call (1-based, 0 = never) raises without releasing."""

    var inner: _Storage
    var fail_reads_at_writes: Int
    var fail_release_at: Int
    var writes: Int
    var release_calls: Int

    def __init__(
        out self,
        var inner: _Storage,
        fail_reads_at_writes: Int,
        fail_release_at: Int,
    ):
        self.inner = inner^
        self.fail_reads_at_writes = fail_reads_at_writes
        self.fail_release_at = fail_release_at
        self.writes = 0
        self.release_calls = 0

    def write_chunk(
        mut self, var bytes: SharedAlignedBuffer[HeapRegion]
    ) raises -> ChunkId:
        self.writes += 1
        return self.inner.write_chunk(bytes^)

    def read_chunk(
        self, chunk_id: ChunkId
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        if (
            self.fail_reads_at_writes > 0
            and self.writes >= self.fail_reads_at_writes
        ):
            raise Error("EIO while restoring")
        return self.inner.read_chunk(chunk_id)

    def release_chunk(mut self, chunk_id: ChunkId) raises:
        self.release_calls += 1
        if self.release_calls == self.fail_release_at:
            raise Error("release boom")
        self.inner.release_chunk(chunk_id)

    def nbytes_in_use(self) -> Int64:
        return self.inner.nbytes_in_use()

    def sync(mut self) raises:
        self.inner.sync()


def test_non_positive_budget_never_spills() raises:
    var root = _scratch_root(String("disabled"))
    _ensure_root(root)
    var hot = 100 * 1024
    var lens = List[Int]()
    lens.append(hot)
    lens.append(0)
    lens.append(3000)
    var parts = _make_partitions(lens, Int64(7))
    var oracle = _segwriter_bytes(
        root, String("oracle.seg"), parts[0], parts[1]
    )
    var budgets = List[Int64]()
    budgets.append(Int64(0))
    budgets.append(Int64(-1))
    for k in range(len(budgets)):
        var tag = String("b") + String(k)
        var storage = _CountingStorage(
            _new_storage(root + "/spill_" + tag), 0, 0
        )
        var fs = _Fs.new()
        var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
        var res = stream_combine_segment_spilling(
            fs, root + "/" + tag + ".seg", src^, storage, budgets[k]
        )
        assert_equal(storage.writes, 0, tag + ": storage was never written")
        assert_equal(res.chunks_spilled, 0, tag + ": nothing spilled")
        assert_equal(
            res.peak_staged_bytes, hot, tag + ": the hot partition is staged whole"
        )
        assert_true(
            _bytes_eq(_read_back(root, tag + ".seg"), oracle),
            tag + ": seg == SegWriter seg",
        )
        _ = storage^
    _cleanup(root)


# -----------------------------------------------------------------------------
# 7. several oversized partitions in one run
# -----------------------------------------------------------------------------
def test_several_oversized_partitions() raises:
    var root = _scratch_root(String("several"))
    _ensure_root(root)
    var t = 4096
    var lens = List[Int]()
    lens.append(3 * t + 5)  # 4 chunks
    lens.append(100)  # staged
    lens.append(2 * t)  # 2 chunks, the last exactly T
    lens.append(0)
    lens.append(t + 1)  # 2 chunks
    lens.append(7 * t - 1)  # 7 chunks, the last short
    var parts = _make_partitions(lens, Int64(3))
    var storage = _CountingStorage(_new_storage(root + "/spill"), 0, 0)
    var fs = _Fs.new()
    var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
    var res = stream_combine_segment_spilling(
        fs, root + "/several.seg", src^, storage, Int64(t)
    )
    assert_equal(res.chunks_spilled, 4 + 2 + 2 + 7, "chunks per partition")
    assert_equal(storage.writes, 15, "storage saw every chunk once")
    assert_equal(storage.release_calls, 15, "every chunk released once")
    assert_equal(res.peak_staged_bytes, t, "never above T")
    assert_equal(storage.inner.num_live_chunks(), 0, "storage is empty")
    var oracle = _segwriter_bytes(
        root, String("oracle.seg"), parts[0], parts[1]
    )
    assert_true(
        _bytes_eq(_read_back(root, String("several.seg")), oracle),
        "seg == SegWriter seg",
    )
    _ = storage^
    _cleanup(root)


# -----------------------------------------------------------------------------
# 8. a restore fails in the second oversized partition
# -----------------------------------------------------------------------------
def test_restore_failure_in_second_oversized_partition() raises:
    var root = _scratch_root(String("second"))
    _ensure_root(root)
    var t = 4096
    var lens = List[Int]()
    lens.append(3 * t)  # chunks 1-3, restored fine
    lens.append(500)
    lens.append(4 * t)  # chunks 4-7, the first restore fails
    var parts = _make_partitions(lens, Int64(1))
    # Reads fail once 7 chunks have been written: the first partition's reads
    # happen at 3 writes, the second oversized partition's at 7.
    var storage = _CountingStorage(_new_storage(root + "/spill"), 7, 0)
    var fs = _Fs.new()
    var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
    var raised = False
    var message = String("")
    try:
        _ = stream_combine_segment_spilling(
            fs, root + "/second.seg", src^, storage, Int64(t)
        )
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "the restore failure must not be swallowed")
    assert_true("EIO while restoring" in message, "message: " + message)
    assert_equal(storage.writes, 7, "all chunks of both partitions written")
    assert_equal(
        storage.release_calls,
        3 + 4,
        "the first partition's chunks released once, the second's by cleanup",
    )
    assert_equal(storage.inner.num_live_chunks(), 0, "nothing left on storage")
    var left_behind = True
    try:
        _ = _read_back(root, String("second.seg"))
    except:
        left_behind = False
    assert_true(not left_behind, "no partial seg left behind")
    _ = storage^
    _cleanup(root)


# -----------------------------------------------------------------------------
# 9. a failed release is attempted once, and the original error is reported
# -----------------------------------------------------------------------------
def test_failed_release_is_not_retried() raises:
    var root = _scratch_root(String("release"))
    _ensure_root(root)
    var t = 4096
    var lens = List[Int]()
    lens.append(3 * t)
    var parts = _make_partitions(lens, Int64(1))
    var storage = _CountingStorage(_new_storage(root + "/spill"), 0, 1)
    var fs = _Fs.new()
    var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
    var raised = False
    var message = String("")
    try:
        _ = stream_combine_segment_spilling(
            fs, root + "/release.seg", src^, storage, Int64(t)
        )
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "the release failure must not be swallowed")
    assert_true("release boom" in message, "message: " + message)
    # One failed attempt on the first chunk, then cleanup releases the other
    # two; the first is not offered to the storage a second time.
    assert_equal(storage.release_calls, 3, "no chunk released twice")
    assert_equal(
        storage.inner.num_live_chunks(),
        1,
        "only the chunk whose release failed is still on storage",
    )
    _ = storage^
    _cleanup(root)


def main() raises:
    test_staged_bytes_never_exceed_budget()
    test_budget_boundary()
    test_every_row_exactly_once_across_spills()
    test_spill_failure_is_reported()
    test_non_positive_budget_never_spills()
    test_several_oversized_partitions()
    test_restore_failure_in_second_oversized_partition()
    test_failed_release_is_not_retried()
    print("test_shuffle_combine_bounded_ram: all 8 tests PASS")
