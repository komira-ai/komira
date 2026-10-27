# =============================================================================
# test_shuffle_stream_combine.mojo
#   Tests of `stream_combine_segment` (the unspilled streaming combine).
# =============================================================================
#
# Each test names what it proves:
#
#   1. byte identity: the combined `.seg` equals the one `SegWriter` builds for
#      the same slices (an empty middle partition included).
#   2. rows exactly once: slices of 8-byte row ids, read back partition by
#      partition through `SegReader`, hold every input id exactly once, and the
#      slots' row counts match the rows read.
#   3. staged-byte count: the combine's own staged bytes are the largest single
#      slice, never the sum of the slices.
#   4. failure is reported: a source that raises mid-way surfaces its message to
#      the caller and leaves no partial `.seg` behind.
#
# LocalFs only; nothing here depends on time or on threads.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_shuffle.segment import SegWriter, SegReader, write_segment

from komira_engine_runtime.spill.shuffle_stream_combine import (
    ListPartitionSource,
    PartitionSliceSource,
    stream_combine_segment,
)
from komira_libc.posix import _read_env


# Scratch files go under $TEST_TMPDIR (unique per test action), else $TMPDIR.
def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


def _scratch_root(tag: String) raises -> String:
    return _scratch_dir() + String("/komira_stream_combine_") + tag


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
    """The `.seg` bytes `SegWriter` builds for the same slices."""
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


# -----------------------------------------------------------------------------
# 1. byte identity with SegWriter
# -----------------------------------------------------------------------------
def test_byte_identical_to_segwriter() raises:
    var root = _scratch_root(String("identity"))
    _ensure_root(root)
    var lens = List[Int]()
    lens.append(7000)
    lens.append(0)  # empty middle partition
    lens.append(7000)
    lens.append(123)
    var parts = _make_partitions(lens, Int64(13))
    var slices = parts[0].copy()
    var row_counts = parts[1].copy()

    var fs = LocalFs[NoopSink].new()
    var src = ListPartitionSource(slices.copy(), row_counts.copy())
    var res = stream_combine_segment(fs, root + "/combined.seg", src^)
    assert_equal(len(res.slots), len(lens), "one dense slot per partition")
    assert_equal(res.chunks_spilled, 0, "the unspilled combine spills nothing")

    var combined = _read_back(root, String("combined.seg"))
    var oracle = _segwriter_bytes(root, String("oracle.seg"), slices, row_counts)
    assert_equal(len(combined), len(oracle), "same length as the SegWriter seg")
    assert_true(
        _bytes_eq(combined, oracle), "bytes equal the SegWriter seg"
    )
    assert_equal(Int(res.slots[1].length), 0, "the empty slot has length 0")
    assert_equal(
        Int(res.slots[2].offset),
        Int(res.slots[1].offset),
        "the empty slot leaves the running offset unchanged",
    )
    _cleanup(root)


# -----------------------------------------------------------------------------
# 2. every row exactly once
# -----------------------------------------------------------------------------
def _row_partition(id: Int) -> Int:
    """The partition row `id` belongs to: skewed (70% in partition 2), with
    partition 4 left empty."""
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
    """Slices of 8-byte little-endian row ids 0..n_rows-1, routed by
    `_row_partition`."""
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


def _count_rows_once(
    root: String, key: String, n_rows: Int, r: Int, slots_rows: List[Int64]
) raises:
    """Read every partition back and assert each id in 0..n_rows-1 appears in
    exactly one partition, exactly once, and that each slot's row count equals
    the rows read from its partition."""
    var seen = List[Int](length=n_rows, fill=0)
    var store = LocalFsConditionalStore(root.copy())
    var reader = SegReader[LocalFsConditionalStore](
        store.clone(), Path.parse(key)
    )
    var total = 0
    for p in range(r):
        var back = reader.read_partition(p)
        assert_equal(len(back) % 8, 0, "partition bytes are whole rows")
        var rows_here = len(back) // 8
        assert_equal(
            Int(slots_rows[p]), rows_here, "slot row count == rows read back"
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
    _ = reader^
    _ = store^


def test_every_row_exactly_once() raises:
    var root = _scratch_root(String("rows"))
    _ensure_root(root)
    var n_rows = 20000
    var r = 5
    var parts = _make_row_partitions(n_rows, r)
    var fs = LocalFs[NoopSink].new()
    var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
    var res = stream_combine_segment(fs, root + "/rows.seg", src^)
    var slot_rows = List[Int64]()
    for p in range(r):
        slot_rows.append(res.slots[p].row_count)
    assert_equal(Int(slot_rows[4]), 0, "partition 4 is empty")
    _count_rows_once(root, String("rows.seg"), n_rows, r, slot_rows)
    _cleanup(root)


# -----------------------------------------------------------------------------
# 3. staged-byte count
# -----------------------------------------------------------------------------
def test_staged_bytes_are_one_slice_not_the_sum() raises:
    var root = _scratch_root(String("staged"))
    _ensure_root(root)

    var lens = List[Int]()
    for _ in range(32):
        lens.append(8192)
    var parts = _make_partitions(lens, Int64(1))
    var fs = LocalFs[NoopSink].new()
    var src = ListPartitionSource(parts[0].copy(), parts[1].copy())
    var res = stream_combine_segment(fs, root + "/uniform.seg", src^)
    assert_equal(res.peak_staged_bytes, 8192, "uniform: one slice staged")
    assert_equal(res.high_water, 8192, "uniform: buffer peak is one slice")
    assert_true(res.peak_staged_bytes < 32 * 8192, "far below the sum")

    # One hot partition: the count follows the largest slice.
    var skew = List[Int]()
    for p in range(32):
        skew.append(65536 if p == 16 else 256)
    var sparts = _make_partitions(skew, Int64(1))
    var sfs = LocalFs[NoopSink].new()
    var ssrc = ListPartitionSource(sparts[0].copy(), sparts[1].copy())
    var sres = stream_combine_segment(sfs, root + "/skew.seg", ssrc^)
    assert_equal(sres.peak_staged_bytes, 65536, "skewed: the hot slice")
    assert_equal(sres.high_water, 65536, "skewed: buffer peak is the hot slice")
    var oracle = _segwriter_bytes(
        root, String("skew_oracle.seg"), sparts[0], sparts[1]
    )
    assert_true(
        _bytes_eq(_read_back(root, String("skew.seg")), oracle),
        "skewed combine equals SegWriter",
    )
    _cleanup(root)


# -----------------------------------------------------------------------------
# 4. a failure is reported, and no partial seg is left
# -----------------------------------------------------------------------------
struct _FailingSource(PartitionSliceSource, Movable, Deinitable):
    """Serves `ok` good partitions of 1000 bytes, then raises."""

    var ok: Int
    var r: Int

    def __init__(out self, ok: Int, r: Int):
        self.ok = ok
        self.r = r

    def partition_count(self) -> Int:
        return self.r

    def slice_bytes(mut self, p: Int) raises -> List[UInt8]:
        if p >= self.ok:
            raise Error("source exploded at partition " + String(p))
        return _make_payload(1000, UInt32(p + 1))

    def slice_row_count(self, p: Int) -> Int64:
        return Int64(1)


def test_source_failure_is_reported_and_seg_aborted() raises:
    var root = _scratch_root(String("failure"))
    _ensure_root(root)
    var fs = LocalFs[NoopSink].new()
    var raised = False
    var message = String("")
    try:
        _ = stream_combine_segment(
            fs, root + "/failed.seg", _FailingSource(2, 4)
        )
    except e:
        raised = True
        message = String(e)
    assert_true(raised, "a source failure must raise")
    assert_true(
        "source exploded at partition 2" in message,
        "the raised error carries the source's message: " + message,
    )

    var left_behind = True
    try:
        _ = _read_back(root, String("failed.seg"))
    except:
        left_behind = False
    assert_true(not left_behind, "the aborted write leaves no seg behind")
    _cleanup(root)


def main() raises:
    test_byte_identical_to_segwriter()
    test_every_row_exactly_once()
    test_staged_bytes_are_one_slice_not_the_sum()
    test_source_failure_is_reported_and_seg_aborted()
    print("test_shuffle_stream_combine: all 4 tests PASS")
