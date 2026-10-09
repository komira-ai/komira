# =============================================================================
# FFI-BOUNDARY: a stand-in C connector of the scan vtable. The test owns the
# connector state (`_Script`, allocated by `_make`, freed by `_free` after the
# source is dropped) and its scratch buffers; the engine borrows them through
# the `abi("C")` thunks below, so they are reached through MutUntrackedOrigin
# pointers, as a foreign connector's would be.
# VTableMorselSource: the refusal and failure paths of the C seam, driven by a
# scripted connector.
# =============================================================================
#
# What these tests prove (oracles from the docstrings of `vtable_source.mojo`):
#
#   * `open` returning non-zero refuses the source at construction, with the
#     status in the message.
#   * `next` returning a status other than OK / EOF raises with the status and
#     the worker id; no buffer was handed out, so `release` is not called; the
#     serialising lock is released (a later pull proceeds); morsel ids count
#     only delivered morsels.
#   * EOF is sticky: after EOF the source returns `None` without calling the
#     connector again.
#   * A connector reporting more columns than the schema declares is refused
#     after the buffers are handed back (`release` runs on the error path) and
#     the lock is released.
#   * Projection is not pushed for an empty list or one wider than 256
#     columns; a connector refusing it leaves the schema as it was; one
#     accepting it narrows the schema to the projected columns (256 is still
#     pushed).
#
# Deterministic: one thread, the connector plays a fixed script of statuses
# in program order. The lock is read directly after each failure instead of
# being probed by a second pull, so a lock left held fails an assertion
# rather than spinning.
# =============================================================================

from std.memory import alloc, UnsafePointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_morsel.vtable_source import (
    CScanBatchPtr,
    CScanI32Ptr,
    CScanI64Ptr,
    CScanOpaque,
    KOMIRA_SCAN_CAP_MT_SAFE,
    KOMIRA_SCAN_CAP_PROJECTION,
    KOMIRA_SCAN_EOF,
    KOMIRA_SCAN_ERR,
    KOMIRA_SCAN_ERR_UNSUPPORTED,
    KOMIRA_SCAN_OK,
    KOMIRA_SCAN_VTABLE_ABI_VERSION,
    KomiraScanVTable,
    VTableMorselSource,
)

comptime _MAX_SCRIPT = 8
comptime _ROWS = 2
comptime _MAX_COLS = 4


struct _Script:
    var open_rc: Int32
    var caps: Int64
    var codes: UnsafePointer[Int32, MutUntrackedOrigin]
    var n_codes: Int
    var pos: Int
    var report_cols: Int64
    var proj_rc: Int32
    var proj_calls: Int
    var proj_n: Int
    var next_calls: Int
    var release_calls: Int
    var data: UnsafePointer[Int64, MutUntrackedOrigin]
    var colp: UnsafePointer[CScanI64Ptr, MutUntrackedOrigin]


comptime _SPtr = UnsafePointer[_Script, MutUntrackedOrigin]


@always_inline
def _st(h: CScanOpaque) -> _SPtr:
    # SAFETY: the handle is the `_Script*` minted by `_make`; it outlives the
    # source (each test frees it after the source is dropped).
    return h.bitcast[_Script]()


@export
def _vsc_open(h: CScanOpaque) abi("C") -> Int32:
    return _st(h)[].open_rc


@export
def _vsc_caps(h: CScanOpaque) abi("C") -> Int64:
    return _st(h)[].caps


@export
def _vsc_rows_hint(h: CScanOpaque) abi("C") -> Int64:
    return Int64(4242)


@export
def _vsc_set_projection(h: CScanOpaque, cols: CScanI32Ptr, n: Int32) abi("C") -> Int32:
    var s = _st(h)
    s[].proj_calls += 1
    s[].proj_n = Int(n)
    return s[].proj_rc


@export
def _vsc_set_predicate(h: CScanOpaque, col: Int32, op: Int32, val: Int64) abi("C") -> Int32:
    return KOMIRA_SCAN_OK


@export
def _vsc_next(h: CScanOpaque, wid: Int32, b: CScanBatchPtr) abi("C") -> Int32:
    """Plays the next scripted status; on OK fills `_ROWS` rows of
    `report_cols` columns with value `call*10 + c*100 + r`."""
    var s = _st(h)
    s[].next_calls += 1
    if s[].pos >= s[].n_codes:
        return KOMIRA_SCAN_EOF
    var call = s[].pos
    var rc = s[].codes[call]
    s[].pos += 1
    if rc != KOMIRA_SCAN_OK:
        return rc
    var nc = Int(s[].report_cols)
    for c in range(nc):
        for r in range(_ROWS):
            s[].data[c * _ROWS + r] = Int64(call * 10 + c * 100 + r)
        s[].colp[c] = s[].data + c * _ROWS
    b[].n_rows = Int64(_ROWS)
    b[].n_cols = Int64(nc)
    b[].col_ptrs = s[].colp
    b[].token = Int64(call)
    return KOMIRA_SCAN_OK


@export
def _vsc_release(h: CScanOpaque, b: CScanBatchPtr) abi("C") -> None:
    _st(h)[].release_calls += 1


@export
def _vsc_close(h: CScanOpaque) abi("C") -> None:
    pass


def _make(codes: List[Int32], caps: Int64, open_rc: Int32 = KOMIRA_SCAN_OK) -> _SPtr:
    var s = alloc[_Script](1)
    s[].open_rc = open_rc
    s[].caps = caps
    s[].codes = alloc[Int32](_MAX_SCRIPT)
    for i in range(len(codes)):
        s[].codes[i] = codes[i]
    s[].n_codes = len(codes)
    s[].pos = 0
    s[].report_cols = Int64(2)
    s[].proj_rc = KOMIRA_SCAN_OK
    s[].proj_calls = 0
    s[].proj_n = 0
    s[].next_calls = 0
    s[].release_calls = 0
    s[].data = alloc[Int64](_MAX_COLS * _ROWS)
    s[].colp = alloc[CScanI64Ptr](_MAX_COLS)
    return s


def _free(s: _SPtr):
    s[].codes.free()
    s[].data.free()
    s[].colp.free()
    s.free()


def _vt(s: _SPtr) -> KomiraScanVTable:
    return KomiraScanVTable(
        KOMIRA_SCAN_VTABLE_ABI_VERSION,
        s.bitcast[NoneType](),
        _vsc_open,
        _vsc_next,
        _vsc_release,
        _vsc_close,
        _vsc_caps,
        _vsc_set_projection,
        _vsc_set_predicate,
        _vsc_rows_hint,
    )


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("id"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, False))
    return sb.build()


def _lock_held(src: VTableMorselSource) -> Bool:
    return src._counters[].lock.load() != Int8(0)


def test_open_failure_is_refused() raises:
    var s = _make(List[Int32](), Int64(0), open_rc=Int32(-7))
    var msg = String("no error")
    try:
        var src = VTableMorselSource(_vt(s), _schema())
        _ = src.row_count_hint()
    except e:
        msg = String(e)
    assert_equal(msg, "VTableMorselSource: connector open() returned -7")
    _free(s)


def _next_status_error(caps: Int64) raises:
    var s = _make(
        [KOMIRA_SCAN_OK, KOMIRA_SCAN_ERR, KOMIRA_SCAN_OK], caps
    )
    var src = VTableMorselSource(_vt(s), _schema())
    var m0 = src.next_morsel(3)
    assert_equal(m0.value().morsel_id, 0)
    assert_equal(m0.value().partition_id, 3)
    assert_equal(m0.value().num_rows(), 2)
    assert_equal(s[].release_calls, 1)

    var msg = String("no error")
    try:
        _ = src.next_morsel(3)
    except e:
        msg = String(e)
    assert_equal(msg, "VTableMorselSource: connector next() returned status -1 (worker 3)")
    assert_false(_lock_held(src), "lock released on the next() error path")
    assert_equal(s[].release_calls, 1, "no buffer was handed out, none released")

    # The source keeps working; the failed pull took no morsel id.
    var m2 = src.next_morsel(0)
    assert_equal(m2.value().morsel_id, 1)
    # Third scripted call (index 2): column 1 row 1 = 2*10 + 100 + 1.
    assert_equal(
        m2.value().column_at(1).as_primitive[DType.int64]().get(1), Int64(121)
    )
    assert_equal(s[].release_calls, 2)

    # EOF, then EOF again without calling the connector.
    assert_false(Bool(src.next_morsel(0)))
    assert_equal(s[].next_calls, 4)
    assert_false(Bool(src.next_morsel(0)))
    assert_false(Bool(src.next_morsel(1)))
    assert_equal(s[].next_calls, 4, "EOF is sticky")
    assert_false(_lock_held(src))
    _ = src^
    _free(s)


def test_next_error_status_serialised_connector() raises:
    _next_status_error(Int64(0))


def test_next_error_status_mt_safe_connector() raises:
    _next_status_error(KOMIRA_SCAN_CAP_MT_SAFE)


def _too_many_columns(caps: Int64) raises:
    var s = _make([KOMIRA_SCAN_OK, KOMIRA_SCAN_OK], caps)
    s[].report_cols = Int64(3)
    var src = VTableMorselSource(_vt(s), _schema(), partitions=3)
    # The connector's row hint is read once at open; partitions as given.
    assert_equal(src.row_count_hint(), 4242)
    assert_equal(src.partition_hint(), 3)
    var msg = String("no error")
    try:
        _ = src.next_morsel(0)
    except e:
        msg = String(e)
    assert_equal(msg, "VTableMorselSource: connector returned 3 columns; schema declares 2")
    assert_equal(s[].release_calls, 1, "release runs on the materialize error path")
    assert_false(_lock_held(src))
    # Equal to the schema is accepted.
    s[].report_cols = Int64(2)
    var m = src.next_morsel(0)
    assert_equal(m.value().num_columns(), 2)
    assert_equal(m.value().morsel_id, 0)
    assert_equal(s[].release_calls, 2)
    _ = src^
    _free(s)


def test_too_many_columns_serialised_connector() raises:
    _too_many_columns(Int64(0))


def test_too_many_columns_mt_safe_connector() raises:
    _too_many_columns(KOMIRA_SCAN_CAP_MT_SAFE)


def test_projection_not_pushed_or_refused() raises:
    var s = _make(List[Int32](), KOMIRA_SCAN_CAP_PROJECTION)
    var src = VTableMorselSource(_vt(s), _schema())

    src.set_projection(List[Int]())
    assert_equal(s[].proj_calls, 0, "empty projection is not pushed")

    var wide = List[Int]()
    for i in range(257):
        wide.append(i % 2)
    src.set_projection(wide)
    assert_equal(s[].proj_calls, 0, "257 columns are not pushed")

    s[].proj_rc = KOMIRA_SCAN_ERR_UNSUPPORTED
    src.set_projection([1])
    assert_equal(s[].proj_calls, 1)
    assert_equal(s[].proj_n, 1)
    var sch = src.output_schema()
    assert_equal(sch.num_columns(), 2, "a refused projection keeps the schema")
    assert_equal(sch.field_at(0).name, "id")

    # Accepted: the schema narrows to the projected columns in the order
    # asked for. Only in-range indices: what an out-of-range index should do
    # is not defined yet, so this test does not pin it.
    s[].proj_rc = KOMIRA_SCAN_OK
    src.set_projection([1, 0])
    assert_equal(s[].proj_calls, 2)
    assert_equal(s[].proj_n, 2)
    var sch1 = src.output_schema()
    assert_equal(sch1.num_columns(), 2)
    assert_equal(sch1.field_at(0).name, "v")
    assert_equal(sch1.field_at(1).name, "id")
    _ = src^
    _free(s)

    s = _make(List[Int32](), KOMIRA_SCAN_CAP_PROJECTION)
    src = VTableMorselSource(_vt(s), _schema())
    var w256 = List[Int]()
    for i in range(256):
        w256.append(1 - i % 2)
    src.set_projection(w256)
    assert_equal(s[].proj_calls, 1, "256 columns are pushed")
    assert_equal(s[].proj_n, 256)
    var sch2 = src.output_schema()
    assert_equal(sch2.num_columns(), 256)
    assert_equal(sch2.field_at(0).name, "v")
    assert_equal(sch2.field_at(1).name, "id")
    _ = src^
    _free(s)


def test_worker_id_outside_the_slot_table() raises:
    # Serialised connector (no MT-safe bit): calls are serialised, so a
    # worker id below 0 or at/above the slot table size can borrow slot 0
    # and still gets a morsel; the morsel keeps the id it was asked with.
    # Not pinned for an MT-safe connector, where two workers would share
    # slot 0.
    var s = _make([KOMIRA_SCAN_OK, KOMIRA_SCAN_OK, KOMIRA_SCAN_OK], Int64(0))
    var src = VTableMorselSource(_vt(s), _schema())
    var a = src.next_morsel(-1)
    assert_equal(a.value().partition_id, -1)
    assert_equal(a.value().column_at(0).as_primitive[DType.int64]().get(1), Int64(1))
    var b = src.next_morsel(128)
    assert_equal(b.value().partition_id, 128)
    assert_equal(b.value().column_at(0).as_primitive[DType.int64]().get(0), Int64(10))
    var c = src.next_morsel(127)
    assert_equal(c.value().partition_id, 127)
    assert_equal(c.value().morsel_id, 2)
    assert_equal(s[].release_calls, 3)
    _ = src^
    _free(s)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
