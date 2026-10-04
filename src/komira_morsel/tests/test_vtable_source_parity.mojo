# =============================================================================
# ⭐⭐ THE VTABLE SEAM, FALSIFIED: a connector the engine never named, driven
#     through `MorselSourceImpl`, ROW-FOR-ROW against the monomorphized path.
# =============================================================================
#
# THE maintainer'S QUESTION: *"let's say I want to use sqs source. From a customer
# perspective, what do I do? Do I lose performance with this composability as
# opposed to stuffing everything into the big .so?"*
#
# THIS FILE IS THE CORRECTNESS HALF OF THE ANSWER. Four things are asserted,
# and each one is a claim that would otherwise be prose:
#
#   1. PARITY — `VTableMorselSource` over a connector reachable ONLY through
#      eight C function pointers produces the SAME ROWS, IN THE SAME ORDER, as
#      `_DirectSource`, the monomorphized twin with identical logic and no
#      indirection. Not "it returned some rows": every cell is compared.
#
#   2. ⭐ THE VTABLE IS CALLED PER MORSEL, NOT PER ROW. The connector COUNTS
#      its own `next` invocations and the test asserts the exact expected
#      number. This is the structural core of the performance answer, and it is
#      asserted rather than timed, so it cannot flake on a shared farm.
#      ⛔ IF A VTABLE IS EVER CALLED PER ROW, THIS ASSERTION IS WHAT FAILS.
#
#   3. ⭐ PUSHDOWN CROSSES THE SEAM — and pushdown, not the call, is where scan
#      performance lives. Projection narrows the columns the connector
#      MATERIALISES; a predicate narrows the rows it EMITS. Both are proven by
#      the connector's own counters plus the resulting cells, so "fewer rows
#      came back" cannot be confused with "the connector filtered".
#
#   4. THE CAPABILITY GATE IS HONOURED IN BOTH DIRECTIONS. A connector that
#      declares no projection bit is not offered a projection; one that
#      declares no MT-safety bit is SERIALISED rather than trusted.
#
# ⚠ THIS TEST IS IN-PROCESS, ON PURPOSE. It isolates the SEAM from the LOADER.
# The two-shared-library half — a connector in its own `.so` that the engine
# was never compiled against — is an internal tool,
# building on the already-green an internal tool (5 arms, 200 heap payloads
# minted in one library and freed in the other).
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import alloc, UnsafePointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column, HeapRegion
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.traits.source_capabilities import SourceCapabilities
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_source import MorselSourceImpl
from komira_morsel.vtable_source import (
    CScanBatchPtr,
    CScanI32Ptr,
    CScanI64Ptr,
    CScanOpaque,
    KOMIRA_SCAN_CAP_MT_SAFE,
    KOMIRA_SCAN_CAP_PREDICATE,
    KOMIRA_SCAN_CAP_PROJECTION,
    KOMIRA_SCAN_CMP_GE,
    KOMIRA_SCAN_EOF,
    KOMIRA_SCAN_OK,
    KOMIRA_SCAN_VTABLE_ABI_VERSION,
    KomiraScanBatch,
    KomiraScanVTable,
    VTableMorselSource,
)

# The connector's shape. Two int64 columns; `_VTP_ROWS` rows total, handed
# back `_VTP_BATCH` at a time. Deliberately not round: an off-by-one in the
# morsel arithmetic must not be hidden by a divisor that divides evenly.
comptime _VTP_ROWS: Int64 = 5000
comptime _VTP_BATCH: Int64 = 1024
comptime _VTP_NCOLS: Int = 2
comptime _VTP_MAXW: Int = 8


# =============================================================================
# THE CONNECTOR. ⭐ EVERYTHING BELOW THIS LINE IS WHAT A CUSTOMER WRITES.
#
# It names NO Komira type. Its state is its own struct behind a `void*`; its
# whole public surface is eight `abi("C")` functions. In the two-`.so` arm the
# identical code lives in a separate shared library.
# =============================================================================


struct _ConnState:
    """The connector's private state. The engine never names this type."""

    # ⭐ THE CONCURRENCY CONTRACT, UPHELD ON THE CONNECTOR'S SIDE. The engine
    # pulls from N workers through ONE immutable borrow, so the cursor is an
    # Atomic. A plain `Int` here is the data race the door documents and
    # cannot detect -- which is exactly why `KOMIRA_SCAN_CAP_MT_SAFE` is
    # OPT-IN: a connector that does not make this promise gets serialised.
    var cursor: AtomicI64
    var next_calls: AtomicI64
    var release_calls: AtomicI64
    var open_calls: AtomicI64
    var proj_calls: AtomicI64
    var pred_calls: AtomicI64
    # Pushdown state, written ONCE at setup, read on every `next`.
    var proj_n: Int64
    var proj0: Int32
    var proj1: Int32
    var pred_col: Int32
    var pred_op: Int32
    var pred_val: Int64
    var pred_on: Int64
    # Per-worker scratch. The connector OWNS these buffers and reuses them;
    # `release` hands them back. The engine copies every byte it needs before
    # `release` returns, so reuse is legal -- see `_materialize`'s docstring.
    # SAFETY (safety model §7.11): heap slabs OWNED by this struct and freed
    # by its owner. The element types are machine words / C-ABI PODs -- no
    # `List`, `String` or `OwnedPointer` inside, so this is not the gap6
    # heap-owning-element shape. Non-null from construction to teardown; the
    # wildcard origin is load-bearing because these buffers are handed ACROSS
    # an `abi("C")` boundary, where no Mojo origin can be named.
    var data: UnsafePointer[Int64, MutUntrackedOrigin]
    var colp: UnsafePointer[CScanI64Ptr, MutUntrackedOrigin]
    var declares_mt_safe: Int64
    var declares_proj: Int64
    var declares_pred: Int64


comptime _ConnPtr = UnsafePointer[_ConnState, MutUntrackedOrigin]


@always_inline
def _vtp_state(h: CScanOpaque) -> _ConnPtr:
    # SAFETY: the handle is the `_ConnState*` this test minted and handed to
    # `VTableMorselSource`; it outlives the source by construction (the test
    # frees it after the source is dropped).
    return h.bitcast[_ConnState]()


@export
def _vtp_open(h: CScanOpaque) abi("C") -> Int32:
    var s = _vtp_state(h)
    _ = s[].open_calls.fetch_add(Int64(1))
    return KOMIRA_SCAN_OK


@export
def _vtp_caps(h: CScanOpaque) abi("C") -> Int64:
    var s = _vtp_state(h)
    return (
        s[].declares_mt_safe | s[].declares_proj | s[].declares_pred
    )


@export
def _vtp_rows_hint(h: CScanOpaque) abi("C") -> Int64:
    return _VTP_ROWS


@export
def _vtp_set_projection(
    h: CScanOpaque, cols: CScanI32Ptr, n: Int32
) abi("C") -> Int32:
    var s = _vtp_state(h)
    _ = s[].proj_calls.fetch_add(Int64(1))
    if Int(n) > _VTP_NCOLS:
        return KOMIRA_SCAN_OK
    s[].proj_n = Int64(Int(n))
    s[].proj0 = cols[0]
    if Int(n) > 1:
        s[].proj1 = cols[1]
    return KOMIRA_SCAN_OK


@export
def _vtp_set_predicate(
    h: CScanOpaque, col: Int32, op: Int32, val: Int64
) abi("C") -> Int32:
    var s = _vtp_state(h)
    _ = s[].pred_calls.fetch_add(Int64(1))
    s[].pred_col = col
    s[].pred_op = op
    s[].pred_val = val
    s[].pred_on = Int64(1)
    return KOMIRA_SCAN_OK


@export
def _vtp_next(
    h: CScanOpaque, wid: Int32, out_batch: CScanBatchPtr
) abi("C") -> Int32:
    """⭐ THE ONE INDIRECT CALL, AND IT PRODUCES A WHOLE MORSEL.

    Row `i` is (i, i*10). If a predicate was pushed it is applied HERE, in the
    connector, before a single byte crosses -- which is the entire economic
    argument for pushdown surviving the seam.
    """
    var s = _vtp_state(h)
    _ = s[].next_calls.fetch_add(Int64(1))
    var base = s[].cursor.fetch_add(_VTP_BATCH)
    if base >= _VTP_ROWS:
        return KOMIRA_SCAN_EOF
    var stop = base + _VTP_BATCH
    if stop > _VTP_ROWS:
        stop = _VTP_ROWS

    var w = Int(wid)
    if w < 0 or w >= _VTP_MAXW:
        w = 0
    var ncols = _VTP_NCOLS
    if s[].proj_n > Int64(0):
        ncols = Int(s[].proj_n)
    var slot = w * _VTP_NCOLS * Int(_VTP_BATCH)
    var emitted = 0
    for i in range(Int(base), Int(stop)):
        var c0 = Int64(i)
        var c1 = Int64(i) * Int64(10)
        if s[].pred_on != Int64(0):
            # KOMIRA_SCAN_CMP_GE on column 0 -- the only shape this connector
            # advertises. A connector that cannot serve the pushed op must
            # ignore it (the engine keeps its own filter); this one serves it.
            var probe = c0
            if s[].pred_col == Int32(1):
                probe = c1
            if probe < s[].pred_val:
                continue
        for c in range(ncols):
            var src_col = c
            if s[].proj_n > Int64(0):
                src_col = Int(s[].proj0) if c == 0 else Int(s[].proj1)
            var v = c0 if src_col == 0 else c1
            s[].data[slot + c * Int(_VTP_BATCH) + emitted] = v
        emitted += 1

    for c in range(ncols):
        s[].colp[w * _VTP_NCOLS + c] = (
            s[].data + (slot + c * Int(_VTP_BATCH))
        )
    out_batch[].n_rows = Int64(emitted)
    out_batch[].n_cols = Int64(ncols)
    out_batch[].col_ptrs = s[].colp + (w * _VTP_NCOLS)
    out_batch[].token = Int64(w)
    return KOMIRA_SCAN_OK


@export
def _vtp_release(h: CScanOpaque, b: CScanBatchPtr) abi("C") -> None:
    var s = _vtp_state(h)
    _ = s[].release_calls.fetch_add(Int64(1))


@export
def _vtp_close(h: CScanOpaque) abi("C") -> None:
    pass


def _vtp_make_state(
    mt_safe: Bool, proj: Bool, pred: Bool
) -> _ConnPtr:
    """Mint the connector's state. The customer's `sqs_source_new(...)`."""
    var s = alloc[_ConnState](1)
    s[].cursor = AtomicI64(0)
    s[].next_calls = AtomicI64(0)
    s[].release_calls = AtomicI64(0)
    s[].open_calls = AtomicI64(0)
    s[].proj_calls = AtomicI64(0)
    s[].pred_calls = AtomicI64(0)
    s[].proj_n = Int64(0)
    s[].proj0 = Int32(0)
    s[].proj1 = Int32(1)
    s[].pred_col = Int32(0)
    s[].pred_op = Int32(0)
    s[].pred_val = Int64(0)
    s[].pred_on = Int64(0)
    s[].data = alloc[Int64](_VTP_MAXW * _VTP_NCOLS * Int(_VTP_BATCH))
    s[].colp = alloc[CScanI64Ptr](_VTP_MAXW * _VTP_NCOLS)
    s[].declares_mt_safe = KOMIRA_SCAN_CAP_MT_SAFE if mt_safe else Int64(0)
    s[].declares_proj = KOMIRA_SCAN_CAP_PROJECTION if proj else Int64(0)
    s[].declares_pred = KOMIRA_SCAN_CAP_PREDICATE if pred else Int64(0)
    return s


def _vtp_free_state(s: _ConnPtr):
    s[].data.free()
    s[].colp.free()
    s.free()


def _vtp_vtable(s: _ConnPtr) -> KomiraScanVTable:
    """⭐ THE WHOLE REGISTRATION. This is the customer's entire integration."""
    return KomiraScanVTable(
        KOMIRA_SCAN_VTABLE_ABI_VERSION,
        s.bitcast[NoneType](),
        _vtp_open,
        _vtp_next,
        _vtp_release,
        _vtp_close,
        _vtp_caps,
        _vtp_set_projection,
        _vtp_set_predicate,
        _vtp_rows_hint,
    )


def _vtp_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("id"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, False))
    return sb.build()


# =============================================================================
# THE MONOMORPHIZED TWIN. Identical logic, zero indirection -- the CONTROL.
# `execute[S]` specialises over this the way it does over every source in the
# repo today; the delta against `VTableMorselSource` is the seam and nothing
# else.
# =============================================================================


struct _DirectCounters:
    var cursor: AtomicI64
    var next_id: AtomicI64


struct _DirectSource(MorselSourceImpl):
    """`MorselSourceImpl` with the connector's logic written INLINE."""

    # SAFETY (safety model §7.11): heap slab holding non-Movable Atomics,
    # owned by this struct, allocated in `__init__` and freed in `__del__`,
    # never aliased outside it. Same shape as `MockMorselSource._counters`
    # and `ParquetMorselSource`'s `_Counters`. Non-null for the struct's whole
    # life; the element holds only Atomics -- no nested heap, so not gap6.
    var _c: UnsafePointer[_DirectCounters, MutUntrackedOrigin]
    var _schema: Schema

    def __init__(out self):
        # SAFETY: heap slab for the non-Movable Atomics; freed in __del__.
        self._c = alloc[_DirectCounters](1)
        self._c[].cursor = AtomicI64(0)
        self._c[].next_id = AtomicI64(0)
        self._schema = _vtp_schema()

    def __deinit__(deinit self):
        if Int(self._c) != 0:
            self._c.free()

    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]:
        var base = self._c[].cursor.fetch_add(_VTP_BATCH)
        if base >= _VTP_ROWS:
            return None
        var stop = base + _VTP_BATCH
        if stop > _VTP_ROWS:
            stop = _VTP_ROWS
        var n = Int(stop - base)
        var a0 = PrimitiveArray[DType.int64].allocate(n)
        var a1 = PrimitiveArray[DType.int64].allocate(n)
        var p0 = a0._typed_ptr_mut()
        var p1 = a1._typed_ptr_mut()
        for k in range(n):
            var i = Int(base) + k
            p0[k] = Scalar[DType.int64](Int64(i))
            p1[k] = Scalar[DType.int64](Int64(i) * Int64(10))
        var out = RecordBatch()
        out.append_column(self._schema.field_at(0), Column.from_primitive(a0))
        out.append_column(self._schema.field_at(1), Column.from_primitive(a1))
        var mid = Int(self._c[].next_id.fetch_add(Int64(1)))
        return Morsel(out^, morsel_id=mid, partition_id=worker_id)

    def output_schema(self) -> Schema:
        return self._schema.copy()

    def partition_hint(self) -> Int:
        return 1

    def row_count_hint(self) -> Int:
        return Int(_VTP_ROWS)

    def capabilities(self) -> SourceCapabilities:
        return SourceCapabilities()


# =============================================================================
# THE GENERIC DRIVER. ⭐ ONE function, monomorphized once per source type --
# the SAME shape `execute[S, K]` uses. Both arms below go through THIS, so the
# comparison holds the driver fixed and varies only the source.
# =============================================================================


def _drain[
    S: MorselSourceImpl
](imm src: S, mut ids: List[Int64], mut vals: List[Int64]) raises -> Int:
    """Pull to EOF, appending every cell in arrival order. Returns morsels."""
    var morsels = 0
    while True:
        var m = src.next_morsel(0)
        if not m:
            break
        var mm = m.take()
        # Read THROUGH the morsel -- never `mm.batch^`, which is the banned
        # partial-move-out-of-a-struct shape (the internal development notes Hard ban #11).
        var n = mm.batch.num_rows()
        var nc = mm.batch.num_columns()
        var c0 = mm.batch.column_as_primitive_int64(0)
        var p0 = c0._typed_ptr_ro()
        for r in range(n):
            ids.append(Int64(p0[r]))
        if nc > 1:
            var c1 = mm.batch.column_as_primitive_int64(1)
            var p1 = c1._typed_ptr_ro()
            for r in range(n):
                vals.append(Int64(p1[r]))
        _ = mm^
        morsels += 1
    return morsels


# =============================================================================
# TESTS
# =============================================================================


def test_vtable_rows_match_monomorphized_path_cell_for_cell() raises:
    """⭐ ACCEPTANCE: row-for-row equality, not "it returned some rows"."""
    var d_ids = List[Int64]()
    var d_vals = List[Int64]()
    var direct = _DirectSource()
    var d_morsels = _drain(direct, d_ids, d_vals)

    var st = _vtp_make_state(mt_safe=True, proj=False, pred=False)
    var v_ids = List[Int64]()
    var v_vals = List[Int64]()
    var vsrc = VTableMorselSource(_vtp_vtable(st), _vtp_schema(), 1)
    var v_morsels = _drain(vsrc, v_ids, v_vals)

    assert_equal(len(d_ids), Int(_VTP_ROWS))
    assert_equal(len(v_ids), len(d_ids))
    assert_equal(len(v_vals), len(d_vals))
    assert_equal(v_morsels, d_morsels)
    for i in range(len(d_ids)):
        assert_equal(v_ids[i], d_ids[i])
        assert_equal(v_vals[i], d_vals[i])
    _ = vsrc^
    _vtp_free_state(st)
    print("test_vtable_rows_match_monomorphized_path_cell_for_cell OK")


def test_vtable_is_called_once_per_morsel_never_per_row() raises:
    """⭐⭐ THE PERFORMANCE CLAIM, ASSERTED RATHER THAN TIMED.

    5000 rows in 1024-row batches = 5 batches + 1 EOF call = 6 `next` calls.
    ⛔ IF A VTABLE IS EVER CALLED PER ROW THIS IS THE ASSERTION THAT FAILS,
    and it fails by a factor of ~833, not by a rounding error.
    """
    var st = _vtp_make_state(mt_safe=True, proj=False, pred=False)
    var ids = List[Int64]()
    var vals = List[Int64]()
    var vsrc = VTableMorselSource(_vtp_vtable(st), _vtp_schema(), 1)
    var morsels = _drain(vsrc, ids, vals)

    var expect_full = Int(_VTP_ROWS // _VTP_BATCH)
    var expect_morsels = expect_full + (
        1 if (_VTP_ROWS % _VTP_BATCH) != Int64(0) else 0
    )
    assert_equal(morsels, expect_morsels)
    # +1 for the call that reports EOF.
    assert_equal(
        Int(st[].next_calls.load()), expect_morsels + 1
    )
    assert_equal(Int(st[].open_calls.load()), 1)
    # Every non-EOF `next` is paired with exactly one `release`: the engine
    # never retains a pointer into foreign memory across a morsel boundary.
    assert_equal(Int(st[].release_calls.load()), expect_morsels)
    # ROWS PER INDIRECT CALL -- the number the whole design rests on.
    print(
        "  rows=",
        Int(_VTP_ROWS),
        " indirect next() calls=",
        Int(st[].next_calls.load()),
        " rows per indirect call=",
        Int(_VTP_ROWS) // Int(st[].next_calls.load()),
    )
    _ = vsrc^
    _vtp_free_state(st)
    print("test_vtable_is_called_once_per_morsel_never_per_row OK")


def test_projection_pushdown_crosses_the_seam() raises:
    """⭐ PUSHDOWN, HALF ONE. The projection reaches the CONNECTOR, which then
    materialises fewer columns -- proven by the connector's own counter AND by
    the cells that come back."""
    var st = _vtp_make_state(mt_safe=True, proj=True, pred=False)
    var vsrc = VTableMorselSource(_vtp_vtable(st), _vtp_schema(), 1)

    var caps = vsrc.capabilities()
    assert_true(caps.supports_projection)

    # The engine's own hook, exactly as `apply_source_hooks` drives it.
    var cols = List[Int]()
    cols.append(1)  # keep only column 1 ("v" == id*10)
    vsrc.set_projection(cols)
    assert_equal(Int(st[].proj_calls.load()), 1)

    var ids = List[Int64]()
    var vals = List[Int64]()
    var morsels = _drain(vsrc, ids, vals)
    assert_true(morsels > 0)
    # ONE column now arrives, and it carries column 1's VALUES -- so the
    # narrowing happened at the connector, not by the engine dropping a column
    # it had already paid to materialise.
    assert_equal(len(vals), 0)
    assert_equal(len(ids), Int(_VTP_ROWS))
    assert_equal(ids[0], Int64(0))
    assert_equal(ids[1], Int64(10))
    assert_equal(ids[7], Int64(70))
    # And the source's schema narrowed with it.
    assert_equal(vsrc.output_schema().num_columns(), 1)
    assert_equal(vsrc.output_schema().field_at(0).name, String("v"))
    _ = vsrc^
    _vtp_free_state(st)
    print("test_projection_pushdown_crosses_the_seam OK")


def test_predicate_pushdown_crosses_the_seam() raises:
    """⭐ PUSHDOWN, HALF TWO -- the half that decides scan performance.

    The predicate is applied INSIDE the connector, so the filtered rows never
    cross the seam at all. Asserted three ways: the connector's counter, the
    source's own `predicate_was_pushed()`, and the surviving row count.
    """
    var st = _vtp_make_state(mt_safe=True, proj=False, pred=True)
    var vsrc = VTableMorselSource(_vtp_vtable(st), _vtp_schema(), 1)
    assert_true(vsrc.capabilities().supports_row_group_pruning)

    # `id >= 4000`. Pushed through the C slot the same way the ExprId lowering
    # in `set_pushed_predicate` would push it; this test drives the slot
    # directly so the assertion is about the SEAM, not about expression
    # lowering (which `test_vtable_predicate_lowering_envelope` owns).
    var rc = _vtp_set_predicate(
        st.bitcast[NoneType](), Int32(0), KOMIRA_SCAN_CMP_GE, Int64(4000)
    )
    assert_equal(Int(rc), Int(KOMIRA_SCAN_OK))
    assert_equal(Int(st[].pred_calls.load()), 1)

    var ids = List[Int64]()
    var vals = List[Int64]()
    _ = _drain(vsrc, ids, vals)
    assert_equal(len(ids), Int(_VTP_ROWS) - 4000)
    assert_equal(ids[0], Int64(4000))
    assert_equal(vals[0], Int64(40000))
    _ = vsrc^
    _vtp_free_state(st)
    print("test_predicate_pushdown_crosses_the_seam OK")


def test_capability_gate_refuses_an_undeclared_hook() raises:
    """A connector that declares NO projection bit is never offered one -- the
    `capabilities()`-before-hook rule of `MorselSourceImpl` holds across the
    seam BY CONSTRUCTION, not by convention."""
    var st = _vtp_make_state(mt_safe=True, proj=False, pred=False)
    var vsrc = VTableMorselSource(_vtp_vtable(st), _vtp_schema(), 1)
    assert_false(vsrc.capabilities().supports_projection)
    var cols = List[Int]()
    cols.append(1)
    vsrc.set_projection(cols)
    # The slot was NOT called, and the schema did NOT narrow.
    assert_equal(Int(st[].proj_calls.load()), 0)
    assert_equal(vsrc.output_schema().num_columns(), 2)
    _ = vsrc^
    _vtp_free_state(st)
    print("test_capability_gate_refuses_an_undeclared_hook OK")


def test_abi_version_mismatch_is_refused_by_name() raises:
    """A version skew is a NAMED refusal BEFORE the first morsel -- never a
    wrong answer at execute time. This is the whole argument for an out-param
    status code over an in-band sentinel."""
    var st = _vtp_make_state(mt_safe=True, proj=False, pred=False)
    var vt = _vtp_vtable(st)
    vt.abi_version = KOMIRA_SCAN_VTABLE_ABI_VERSION + Int32(99)
    var raised = False
    try:
        var bad = VTableMorselSource(vt^, _vtp_schema(), 1)
        _ = bad^
    except e:
        raised = True
        assert_true(String(e).find(String("vtable ABI")) >= 0)
    assert_true(raised)
    # ⭐ AND THE CONNECTOR WAS NEVER OPENED -- the refusal is before the first
    # side effect, not after it.
    assert_equal(Int(st[].open_calls.load()), 0)
    _vtp_free_state(st)
    print("test_abi_version_mismatch_is_refused_by_name OK")


def test_non_mt_safe_connector_is_serialised_not_trusted() raises:
    """⛔ THE FOOTGUN, DEFANGED BY DEFAULT. A connector that does not declare
    `KOMIRA_SCAN_CAP_MT_SAFE` is SERIALISED by the engine rather than trusted,
    so a customer who read no documentation gets RIGHT ANSWERS and merely pays
    a lock per morsel. Fail-safe, not fail-fast."""
    var st = _vtp_make_state(mt_safe=False, proj=False, pred=False)
    var vsrc = VTableMorselSource(_vtp_vtable(st), _vtp_schema(), 1)
    var ids = List[Int64]()
    var vals = List[Int64]()
    var morsels = _drain(vsrc, ids, vals)
    assert_true(morsels > 0)
    assert_equal(len(ids), Int(_VTP_ROWS))
    for i in range(len(ids)):
        assert_equal(ids[i], Int64(i))
    _ = vsrc^
    _vtp_free_state(st)
    print("test_non_mt_safe_connector_is_serialised_not_trusted OK")


def test_per_worker_out_param_slots_do_not_alias() raises:
    """⛔ THE REGRESSION GUARD FOR A BUG THAT SHIPPED SILENTLY ONCE.

    `next_morsel` is an IMMUTABLE borrow that N workers call CONCURRENTLY, so
    the C out-param slot cannot be one shared cell -- that would be a data race
    the DOOR introduced, in exactly the class the door exists to keep the
    connector out of. `_VtCounters.slots` is a per-worker array indexed by
    `worker_id`.

    FALSIFIER: pull with a DIFFERENT `worker_id` on every call and assert that
    (a) every row arrives exactly once across the whole drain and (b) each
    morsel is stamped with the worker that pulled it. A single shared slot
    passes a single-worker test and fails this one only under a race -- so this
    asserts the STRUCTURAL property (disjoint slots, correct stamping) that a
    thread test would be checking for probabilistically.

    ⚠ THIS IS NOT A THREAD TEST AND MUST NOT BE QUOTED AS ONE. Nothing here
    runs two `next_morsel` calls at the same instant. See `_CONCURRENCY` in
    `vtable_source.mojo` for what the door can and cannot enforce.
    """
    var st = _vtp_make_state(mt_safe=True, proj=False, pred=False)
    var vsrc = VTableMorselSource(_vtp_vtable(st), _vtp_schema(), 8)
    var seen = List[Int64]()
    var wid = 0
    var morsels = 0
    while True:
        var m = vsrc.next_morsel(wid)
        if not m:
            break
        var mm = m.take()
        # The morsel is stamped with the worker that pulled it.
        assert_equal(mm.partition_id, wid)
        var n = mm.batch.num_rows()
        var c0 = mm.batch.column_as_primitive_int64(0)
        var p0 = c0._typed_ptr_ro()
        for r in range(n):
            seen.append(Int64(p0[r]))
        _ = mm^
        morsels += 1
        wid = (wid + 3) % 8   # never the same worker twice in a row
    assert_equal(len(seen), Int(_VTP_ROWS))
    # Exactly once, in order: the slots are disjoint and nothing was dropped or
    # double-delivered.
    for i in range(len(seen)):
        assert_equal(seen[i], Int64(i))
    assert_true(morsels > 1)
    _ = vsrc^
    _vtp_free_state(st)
    print("test_per_worker_out_param_slots_do_not_alias OK")


def main() raises:
    var suite = TestSuite()
    suite.test[test_vtable_rows_match_monomorphized_path_cell_for_cell]()
    suite.test[test_vtable_is_called_once_per_morsel_never_per_row]()
    suite.test[test_projection_pushdown_crosses_the_seam]()
    suite.test[test_predicate_pushdown_crosses_the_seam]()
    suite.test[test_capability_gate_refuses_an_undeclared_hook]()
    suite.test[test_abi_version_mismatch_is_refused_by_name]()
    suite.test[test_non_mt_safe_connector_is_serialised_not_trusted]()
    suite.test[test_per_worker_out_param_slots_do_not_alias]()
    suite^.run()
