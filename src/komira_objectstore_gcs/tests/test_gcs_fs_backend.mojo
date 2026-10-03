# =============================================================================
# tests/test_gcs_fs_backend.mojo
#   GcsFs over a test-local GcsStorageBackend: the FileSystem read surface,
#   with no credentials and no network.
# =============================================================================
#
#   (A) bucket / open / read_at / read_footer / file_size / capabilities ride
#       the backend seam.
#   (B) the traps a GCS read conformer must get right:
#       1. the listing fold: list_dir_shallow maps common prefixes to
#          directories and objects to files, skips the directory placeholder,
#          and drains every page;
#       2. a short response from the backend makes read_at raise;
#       3. a read ending exactly at EOF returns the exact tail bytes;
#       4. clone() builds an independent backend through the factory;
#       5. a zero-length read issues no request, a negative range is
#          refused, and a footer window inside the object reads its tail.
#
# The backend wraps FakeGcsStorageBackend, so the listing fold, the name order
# and the paging under test are the public fake's; the wrapper adds only a
# forced short read.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_fs.footer_region import FOOTER_SPECULATIVE_WINDOW
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.io.heap_region import HeapRegion

from komira_objectstore_gcs import (
    FakeGcsStorageBackend,
    GcsFs,
    GcsStorageBackend,
    ListPageRaw,
    ObjectMetaRaw,
)


def _buf_len(imm buf: SharedAlignedBuffer[HeapRegion]) -> Int:
    return buf.len()


def _buf_u8(imm buf: SharedAlignedBuffer[HeapRegion], offset: Int) -> UInt8:
    var v = buf.view_ro()
    return v.read_u8_at(offset)


# =============================================================================
# §1 — the public fake, seeded, plus a short-read knob.
# =============================================================================


@fieldwise_init
struct _Obj(Movable, Copyable, Deinitable):
    var key: String
    var bytes: List[UInt8]


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _seed_objects() -> List[_Obj]:
    """The fixture every backend build starts from, in this (unsorted) write
    order:

        data/a.parquet       12 bytes "AAAABBBBCCCC"
        data/b.parquet       4 bytes  "DDDD"
        data/sub/c.parquet   folded under data/sub/ at delimiter "/"
        data/sub/d.parquet   folded under data/sub/
        data/                zero-byte directory placeholder
        other/e.parquet
    """
    var out = List[_Obj]()
    out.append(_Obj(String("data/a.parquet"), _b(String("AAAABBBBCCCC"))))
    out.append(_Obj(String("data/b.parquet"), _b(String("DDDD"))))
    out.append(_Obj(String("data/sub/c.parquet"), _b(String("CCC"))))
    out.append(_Obj(String("data/sub/d.parquet"), _b(String("DDD"))))
    out.append(_Obj(String("data/"), List[UInt8]()))
    out.append(_Obj(String("other/e.parquet"), _b(String("EE"))))
    return out^


struct _ProbeBackend(GcsStorageBackend, Movable, Deinitable):
    """`FakeGcsStorageBackend` (so the listing fold and paging are the public
    fake's), seeded with `_seed_objects()`. `short_read` makes the next
    read_range return one byte fewer than asked."""

    var _inner: FakeGcsStorageBackend
    var short_read: Bool

    def __init__(out self) raises:
        self = Self(_seed_objects(), False, 0)

    def __init__(
        out self, var objects: List[_Obj], short_read: Bool, page_size: Int
    ) raises:
        var inner = FakeGcsStorageBackend(page_size=page_size)
        for i in range(len(objects)):
            _ = inner.conditional_create(
                String("test-bucket"), objects[i].key, objects[i].bytes
            )
        self._inner = inner^
        self.short_read = short_read

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        return self._inner.conditional_create(bucket, key, data)

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        return self._inner.compare_and_swap(
            bucket, key, data, expected_generation
        )

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        var out = self._inner.read_range(bucket, key, read_offset, read_limit)
        if self.short_read and len(out) > 0:
            self.short_read = False
            _ = out.pop()
        return out^

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        return self._inner.get_object(bucket, key)

    def delete_object(mut self, bucket: String, key: String) raises:
        self._inner.delete_object(bucket, key)

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        return self._inner.list_objects(bucket, prefix, page_token, delimiter)


def _make_probe_backend() raises -> _ProbeBackend:
    return _ProbeBackend()


def _make_fs() raises -> GcsFs[_ProbeBackend]:
    return GcsFs[_ProbeBackend](
        bucket=String("test-bucket"),
        backend=_make_probe_backend(),
        mk_backend=_make_probe_backend,
    )


# =============================================================================
# §A — the FileSystem surface.
# =============================================================================


def test_bucket_and_open() raises:
    var fs = _make_fs()
    assert_equal(fs.bucket(), String("test-bucket"))
    var h = fs.open(String("data/a.parquet"))
    assert_equal(h.key(), String("data/a.parquet"))


def test_capability_queries() raises:
    var fs = _make_fs()
    assert_equal(fs.prefetch_depth(), 64)
    assert_true(fs.supports_random_read())
    assert_true(GcsFs[_ProbeBackend].SUPPORTS_LAZY_HIVE)
    assert_equal(Int(GcsFs[_ProbeBackend].SCHEME), 2)
    assert_false(GcsFs[_ProbeBackend].SUPPORTS_PARALLEL_WRITES)


def test_read_at_returns_exact_bytes() raises:
    var fs = _make_fs()
    var h = fs.open(String("data/a.parquet"))
    var buf = fs.read_at(h, Int64(4), Int64(4))
    assert_equal(_buf_len(buf), 4)
    assert_equal(_buf_u8(buf, 0), UInt8(ord("B")))
    assert_equal(_buf_u8(buf, 3), UInt8(ord("B")))


def test_file_size_via_get_object() raises:
    var fs = _make_fs()
    assert_equal(fs.file_size(String("data/a.parquet")), 12)
    assert_equal(fs.file_size(String("data/b.parquet")), 4)


def test_file_size_not_found_raises() raises:
    var fs = _make_fs()
    var raised = False
    try:
        _ = fs.file_size(String("data/nope.parquet"))
    except e:
        raised = True
        assert_true(String(e).find(String("status=404")) >= 0)
    assert_true(raised)


# =============================================================================
# §B.1 — the listing fold.
# =============================================================================


def test_list_dir_shallow_folds_common_prefixes_and_skips_placeholder() raises:
    """Under `data`: data/sub/{c,d} fold to ONE directory `sub`; a and b are
    files; the `data/` placeholder is skipped; data/sub/ is not entered."""
    var fs = _make_fs()
    var entries = fs.list_dir_shallow(String("data"))

    var n_dirs = 0
    var n_files = 0
    var saw_sub_dir = False
    var saw_a = False
    var saw_b = False
    var saw_placeholder = False
    var saw_c_or_d = False
    for i in range(len(entries)):
        ref e = entries[i]
        if e.is_dir:
            n_dirs += 1
            if e.name == String("sub"):
                saw_sub_dir = True
        else:
            n_files += 1
            if e.name == String("a.parquet"):
                saw_a = True
            if e.name == String("b.parquet"):
                saw_b = True
            if e.name == String("c.parquet") or e.name == String("d.parquet"):
                saw_c_or_d = True
        if e.name == String("data/") or e.name == String(""):
            saw_placeholder = True

    assert_true(saw_sub_dir, "common prefix data/sub/ must fold to dir sub")
    assert_equal(n_dirs, 1)
    assert_true(saw_a, "data/a.parquet must be file a.parquet")
    assert_true(saw_b, "data/b.parquet must be file b.parquet")
    assert_equal(n_files, 2)
    assert_false(saw_c_or_d, "a shallow listing must not enter data/sub/")
    assert_false(saw_placeholder, "the data/ placeholder must be skipped")


def test_is_dir_probes_with_delimiter() raises:
    var fs = _make_fs()
    assert_true(fs.is_dir(String("data")))
    assert_true(fs.is_dir(String("data/sub")))
    assert_false(fs.is_dir(String("data/a.parquet")))
    assert_false(fs.is_dir(String("nonexistent")))


def test_list_recursive_flat_no_fold() raises:
    """list is recursive: every key under the prefix, unfolded. Under data/
    that is a, b, sub/c, sub/d and the placeholder: 5 keys."""
    var fs = _make_fs()
    var keys = fs.list(String("data/"))
    var saw_deep = False
    for i in range(len(keys)):
        if keys[i] == String("data/sub/c.parquet"):
            saw_deep = True
    assert_true(saw_deep, "a recursive list must include data/sub/c.parquet")
    assert_equal(len(keys), 5)
    # Name (byte) order, as ListObjects returns it, whatever the write order.
    assert_equal(keys[0], String("data/"))
    assert_equal(keys[1], String("data/a.parquet"))
    assert_equal(keys[4], String("data/sub/d.parquet"))


def test_list_dir_shallow_paginates() raises:
    """With one object per page, list_dir_shallow still collects both files
    by following the page token to the end."""
    var backend = _ProbeBackend(_seed_objects(), False, 1)
    var fs = GcsFs[_ProbeBackend](
        bucket=String("test-bucket"),
        backend=backend^,
        mk_backend=_make_probe_backend,
    )
    var entries = fs.list_dir_shallow(String("data"))
    var n_files = 0
    var n_dirs = 0
    for i in range(len(entries)):
        if entries[i].is_dir:
            n_dirs += 1
        else:
            n_files += 1
    assert_equal(n_files, 2)
    assert_equal(n_dirs, 1)
    # One entry per page, so arrival order is name order.
    assert_equal(entries[0].name, String("a.parquet"))
    assert_equal(entries[1].name, String("b.parquet"))
    assert_equal(entries[2].name, String("sub"))


# =============================================================================
# §B.2 — a short read raises.
# =============================================================================


def test_read_at_short_read_raises() raises:
    var backend = _ProbeBackend(_seed_objects(), True, 1000)
    var fs = GcsFs[_ProbeBackend](
        bucket=String("test-bucket"),
        backend=backend^,
        mk_backend=_make_probe_backend,
    )
    var h = fs.open(String("data/a.parquet"))
    var raised = False
    try:
        _ = fs.read_at(h, Int64(0), Int64(12))
    except e:
        raised = True
        assert_true(String(e).find(String("short read")) >= 0)
    assert_true(raised, "read_at must raise on a short response")


# =============================================================================
# §B.3 — range edges.
# =============================================================================


def test_read_at_range_edge_to_eof() raises:
    """[8, 12) of the 12-byte object is its last four bytes, CCCC."""
    var fs = _make_fs()
    var h = fs.open(String("data/a.parquet"))
    var buf = fs.read_at(h, Int64(8), Int64(4))
    assert_equal(_buf_len(buf), 4)
    assert_equal(_buf_u8(buf, 0), UInt8(ord("C")))
    assert_equal(_buf_u8(buf, 3), UInt8(ord("C")))


def test_read_footer_reads_trailing_region() raises:
    """A 12-byte object is smaller than the window, so the footer read is the
    whole object at offset 0, with its size."""
    var fs = _make_fs()
    var footer = fs.read_footer(
        String("data/a.parquet"), FOOTER_SPECULATIVE_WINDOW
    )
    assert_equal(footer.len(), 12)
    assert_equal(footer.offset, 0)
    assert_equal(footer.file_size, 12)
    assert_equal(footer.bytes[0], UInt8(ord("A")))
    assert_equal(footer.bytes[11], UInt8(ord("C")))


def test_read_footer_too_small_raises() raises:
    var fs = _make_fs()
    var raised = False
    try:
        _ = fs.read_footer(String("data/b.parquet"), FOOTER_SPECULATIVE_WINDOW)
    except e:
        raised = True
        assert_true(String(e).find(String("too small")) >= 0)
    assert_true(raised)


# =============================================================================
# §B.4 — clone() builds its own backend.
# =============================================================================


def test_clone_mints_fresh_independent_backend() raises:
    """The original's backend is put into short-read mode; a clone, built
    from the factory, does not inherit it and reads in full. The original
    then trips its own short read, so the two backends are distinct."""
    var backend = _ProbeBackend(_seed_objects(), True, 1000)
    var fs = GcsFs[_ProbeBackend](
        bucket=String("test-bucket"),
        backend=backend^,
        mk_backend=_make_probe_backend,
    )

    var fs2 = fs.clone()
    var h2 = fs2.open(String("data/a.parquet"))
    var cloned = fs2.read_at(h2, Int64(0), Int64(12))
    assert_equal(_buf_len(cloned), 12)
    assert_equal(_buf_u8(cloned, 0), UInt8(ord("A")))

    var h = fs.open(String("data/a.parquet"))
    var raised = False
    try:
        _ = fs.read_at(h, Int64(0), Int64(12))
    except e:
        raised = True
    assert_true(raised, "the original keeps its own backend state")

    var h3 = fs.open(String("data/b.parquet"))
    var again = fs.read_at(h3, Int64(0), Int64(4))
    assert_equal(_buf_len(again), 4)
    assert_equal(_buf_u8(again, 0), UInt8(ord("D")))


# =============================================================================
# §B.5 — zero-length and negative ranges, and a window inside the object.
# =============================================================================


def test_read_at_zero_length_issues_no_request() raises:
    """A zero-length read returns an empty buffer without a request: on the
    wire `read_limit = 0` means "to the end", so sending it would download the
    rest of the object. The key is absent, so a request would raise 404."""
    var fs = _make_fs()
    var h = fs.open(String("data/absent.parquet"))
    var buf = fs.read_at(h, Int64(3), Int64(0))
    assert_equal(_buf_len(buf), 0)


def test_read_at_refuses_negative_offset_or_length() raises:
    var fs = _make_fs()
    var h = fs.open(String("data/a.parquet"))
    var raised_offset = False
    try:
        _ = fs.read_at(h, Int64(-4), Int64(4))
    except e:
        raised_offset = True
        assert_true(String(e).find(String("negative")) >= 0)
    assert_true(raised_offset, "a negative offset must be refused")
    var raised_length = False
    try:
        _ = fs.read_at(h, Int64(0), Int64(-1))
    except e:
        raised_length = True
        assert_true(String(e).find(String("negative")) >= 0)
    assert_true(raised_length, "a negative length must be refused")


def test_read_footer_window_inside_object() raises:
    """An 8-byte window over the 12-byte object starts at offset 4."""
    var fs = _make_fs()
    var footer = fs.read_footer(String("data/a.parquet"), 8)
    assert_equal(footer.offset, 4)
    assert_equal(footer.file_size, 12)
    assert_equal(footer.len(), 8)
    var want = String("BBBBCCCC").as_bytes()
    for i in range(8):
        assert_equal(footer.bytes[i], want[i])


def main() raises:
    test_bucket_and_open()
    test_capability_queries()
    test_read_at_returns_exact_bytes()
    test_file_size_via_get_object()
    test_file_size_not_found_raises()
    test_list_dir_shallow_folds_common_prefixes_and_skips_placeholder()
    test_is_dir_probes_with_delimiter()
    test_list_recursive_flat_no_fold()
    test_list_dir_shallow_paginates()
    test_read_at_short_read_raises()
    test_read_at_range_edge_to_eof()
    test_read_footer_reads_trailing_region()
    test_read_footer_too_small_raises()
    test_clone_mints_fresh_independent_backend()
    test_read_at_zero_length_issues_no_request()
    test_read_at_refuses_negative_offset_or_length()
    test_read_footer_window_inside_object()
    print("PASS test_gcs_fs_backend")
