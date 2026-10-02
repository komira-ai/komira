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
#       4. clone() builds an independent backend through the factory.
#
# The backend here is test-local rather than FakeGcsStorageBackend because it
# needs knobs the fake does not have: a forced short read and a page size.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.fs.footer_region import FOOTER_SPECULATIVE_WINDOW
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.io.heap_region import HeapRegion

from komira_objectstore_gcs import (
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
# §1 — a test-local GcsStorageBackend with a fixed object set and knobs.
# =============================================================================


@fieldwise_init
struct _Obj(Movable, Copyable, Deinitable):
    var key: String
    var bytes: List[UInt8]
    var generation: Int64


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _seed_objects() -> List[_Obj]:
    """The fixture every backend build starts from:

        data/a.parquet       12 bytes "AAAABBBBCCCC"
        data/b.parquet       4 bytes  "DDDD"
        data/sub/c.parquet   folded under data/sub/ at delimiter "/"
        data/sub/d.parquet   folded under data/sub/
        data/                zero-byte directory placeholder
        other/e.parquet
    """
    var out = List[_Obj]()
    out.append(_Obj(String("data/a.parquet"), _b(String("AAAABBBBCCCC")), Int64(101)))
    out.append(_Obj(String("data/b.parquet"), _b(String("DDDD")), Int64(102)))
    out.append(_Obj(String("data/sub/c.parquet"), _b(String("CCC")), Int64(103)))
    out.append(_Obj(String("data/sub/d.parquet"), _b(String("DDD")), Int64(104)))
    out.append(_Obj(String("data/"), List[UInt8](), Int64(105)))
    out.append(_Obj(String("other/e.parquet"), _b(String("EE")), Int64(106)))
    return out^


def _starts_with(s: String, prefix: String) -> Bool:
    if prefix.byte_length() == 0:
        return True
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(sb) < len(pb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def _find_slash_after(s: String, start: Int) -> Int:
    var sb = s.as_bytes()
    var i = start
    while i < len(sb):
        if sb[i] == UInt8(ord("/")):
            return i
        i += 1
    return -1


def _contains(items: List[String], needle: String) -> Bool:
    for i in range(len(items)):
        if items[i] == needle:
            return True
    return False


def _prefix_bytes(s: String, n: Int) -> String:
    """The first `n` bytes of `s`, byte for byte."""
    var bs = s.as_bytes()
    var lim = n if n < len(bs) else len(bs)
    var buf = List[UInt8]()
    for i in range(lim):
        buf.append(bs[i])
    return String(unsafe_from_utf8=Span(buf))


struct _ProbeBackend(GcsStorageBackend, Movable, Deinitable):
    """`short_read` makes the next read_range return one byte fewer than
    asked; `_page_size` splits listings into pages."""

    var _objects: List[_Obj]
    var short_read: Bool
    var _page_size: Int

    def __init__(out self):
        self._objects = _seed_objects()
        self.short_read = False
        self._page_size = 1000

    def __init__(
        out self, var objects: List[_Obj], short_read: Bool, page_size: Int
    ):
        self._objects = objects^
        self.short_read = short_read
        self._page_size = page_size

    def _find(self, key: String) -> Int:
        for i in range(len(self._objects)):
            if self._objects[i].key == key:
                return i
        return -1

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        if self._find(key) >= 0:
            raise Error(
                String("StoreError[PRECONDITION] WriteObject gs://")
                + bucket
                + "/"
                + key
                + " status=412"
            )
        self._objects.append(_Obj(key, data.copy(), Int64(900)))
        return Int64(900)

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        var idx = self._find(key)
        if idx < 0 or self._objects[idx].generation != expected_generation:
            raise Error(
                String("StoreError[PRECONDITION] WriteObject gs://")
                + bucket
                + "/"
                + key
                + " status=412"
            )
        self._objects[idx].bytes = data.copy()
        self._objects[idx].generation += Int64(1)
        return self._objects[idx].generation

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        var idx = self._find(key)
        if idx < 0:
            raise Error(
                String("StoreError[NOT_FOUND] ReadObject gs://")
                + bucket
                + "/"
                + key
                + " status=404"
            )
        ref e = self._objects[idx]
        var n = len(e.bytes)
        var start = Int(read_offset)
        if start < 0:
            start = 0
        if start > n:
            start = n
        var end = n
        if read_limit > Int64(0):
            var lim_end = start + Int(read_limit)
            if lim_end < end:
                end = lim_end
        var out = List[UInt8]()
        for i in range(start, end):
            out.append(e.bytes[i])
        if self.short_read and len(out) > 0:
            self.short_read = False
            _ = out.pop()
        return out^

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        var idx = self._find(key)
        if idx < 0:
            raise Error(
                String("StoreError[NOT_FOUND] GetObject gs://")
                + bucket
                + "/"
                + key
                + " status=404"
            )
        ref e = self._objects[idx]
        return ObjectMetaRaw(
            key=e.key,
            size=Int64(len(e.bytes)),
            generation=e.generation,
            etag=String(""),
        )

    def delete_object(mut self, bucket: String, key: String) raises:
        var keep = List[_Obj]()
        for i in range(len(self._objects)):
            if self._objects[i].key != key:
                keep.append(self._objects[i].copy())
        self._objects = keep^

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        """The service's listing, paged: `page_token` is the decimal index of
        the first object of the page; the common prefixes come whole on the
        first page."""
        var use_delim = delimiter.byte_length() > 0
        var matched_obj = List[ObjectMetaRaw]()
        var common = List[String]()
        for i in range(len(self._objects)):
            ref e = self._objects[i]
            if not _starts_with(e.key, prefix):
                continue
            if use_delim:
                var fold = _find_slash_after(e.key, prefix.byte_length())
                if fold >= 0:
                    var cp = _prefix_bytes(e.key, fold + 1)
                    if not _contains(common, cp):
                        common.append(cp^)
                    continue
            matched_obj.append(
                ObjectMetaRaw(
                    key=e.key,
                    size=Int64(len(e.bytes)),
                    generation=e.generation,
                    etag=String(""),
                )
            )
        var start = 0
        if page_token.byte_length() > 0:
            start = Int(atol(page_token))
        var page_objs = List[ObjectMetaRaw]()
        var end = start + self._page_size
        var actual_end = end if end < len(matched_obj) else len(matched_obj)
        for i in range(start, actual_end):
            page_objs.append(matched_obj[i].copy())
        var next_token = String("")
        if actual_end < len(matched_obj):
            next_token = String(actual_end)
        var page_common = List[String]()
        if start == 0:
            page_common = common^
        return ListPageRaw(page_objs^, page_common^, next_token^)


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
    print("PASS test_gcs_fs_backend")
