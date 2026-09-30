# =============================================================================
# column_native.mojo — column-native foundation: ColumnNativeBatch +
# Builder + Header + Descriptor + Appendix + UnifiedColumnFormat[T, lo].
# =============================================================================
#
# SoA native column batch. The in-memory body shares the THSPLC column-chunk
# layout so the in-memory batch and the spill
# body share descriptors:
#
#     [96 B THSPLC header][n_cols × 48 B descriptors][per-column regions][magic]
#
# ColumnNativeBatch <-> RecordBatch bridges through the EXISTING THSPLC spill
# codec in the engine runtime; this CONSUMES THSPLC, it does NOT rebuild it.
# The engine-side shim layer owns the codec bridge.
#
# STORAGE (semantics-preserving):
#   Rather than `_buffers: Slab[SharedAlignedBuffer]` (one SAB per column
#   buffer) + `_selection` + `_appendix`, the contiguous mode stores the SoA column
#   data as ONE contiguous `_body: SharedAlignedBuffer[HeapRegion]` in the
#   THSPLC layout (header + descriptors + per-column regions), addressed by the
#   `_descriptors` slab. This is the SAME SoA layout (each column's payload is a
#   contiguous byte region inside `_body`, located by `ColumnDescriptor`), but
#   one allocation instead of N — which is exactly what THSPLC produces and what
#   the spill/shuffle path consumes. Keeping ONE body means the round-trip is genuinely byte-identical
#   to a THSPLC chunk and zero codec work happens in the foundation. The public
#   `column_unified[T]` / refinement-trait surface is IDENTICAL either way — it
#   addresses cells via descriptor offsets, not via the storage split — so the
#   storage split is field-internal and does not touch any consumer.
#
# ZERO-COPY WRAPPED MODE
# ---------------------------------------------------------------------------
#   `ColumnNativeBatch` has TWO field-internal storage modes; the public
#   surface (BatchFormat + `column_unified[T]` + nested traits + the bridge
#   shim signatures) is IDENTICAL across both — consumers are untouched:
#
#     (1) CONTIGUOUS-BODY mode: one THSPLC
#         body SAB + descriptors. Produced by a THSPLC spill restore and by
#         every hand-built / nested test fixture. `_columns` is None.
#
#     (2) WRAPPED (per-column) mode: the batch holds the source
#         RecordBatch's `Slab[Column[HeapRegion]]` DIRECTLY — moved in with no
#         copy (each Column's `_data` / `_offsets` / `_validity` are
#         Arc-refcounted `SharedAlignedBuffer`s). `_body` / `_descriptors` are
#         empty. This is what `column_native_from_record_batch` produces (a
#         `take_columns` move = zero encode copy), and what
#         `record_batch_from_column_native` consumes (move the slab back into a
#         RecordBatch = zero decode copy). The contiguous THSPLC body is built
#         on demand ONLY for the spill/shuffle path
#         (`THSPLCEncoder.encode_column_native`).
#
#   `column_unified[T]` reads fixed-width cells in wrapped mode directly off the
#   shared column `_data` buffer (zero-copy). A wrapped batch that needs the
#   contiguous descriptor surface (varlen `column_unified`, nested cell access,
#   `body_view`, `take_body`) materializes a contiguous body once via
#   `_ensure_body` — those paths are NOT on the gated zero-copy hot path.
# =============================================================================

from std.collections import Optional
from std.sys import size_of

from komira_core.batch_format import BatchFormat, FormatKind

from std.sys import size_of as _size_of

from .arrow_types import ArrowType
from .column import Column
from .column_native_nested import ListColumnFormat, StructColumnFormat
from .schema import Schema
from .shared_aligned_buffer import SharedAlignedBuffer
from ..collections import Slab
from ..collections.byte_view import ByteView
from komira_core.io.heap_region import HeapRegion


# =============================================================================
# ColumnNativeBatchHeader — fixed register-pass header.
# =============================================================================
@fieldwise_init
struct ColumnNativeBatchHeader(
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Fixed in-memory header. Mirrors THSPLC's header semantics so the
    in-memory body and the spill body share descriptors (THSPLC consumes
    RecordBatch; the shim bridges ColumnNativeBatch -> RecordBatch
    -> THSPLC).

    POD / register-pass-shaped (no String, no List, no OwnedPointer)."""

    var n_cols: UInt32
    var row_count: UInt64
    var schema_fingerprint: UInt64
    var has_selection_vector: UInt8
    var flags: UInt8  # bit0 = is_extension (EXTENSION column kind)


# =============================================================================
# ColumnDescriptor — 24 B-class POD per-column descriptor.
# =============================================================================
@fieldwise_init
struct ColumnDescriptor(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """Per-column descriptor. Arrow-type tag + buffer offsets/lengths into the
    batch body. TrivialRegisterPassable-shaped (POD: no String, no List, no
    OwnedPointer).

    NOTE: the type tag is a `UInt16` enum value (`ArrowType.type_id`), NOT an
    interned String — no heap field, and it passes in a register.

    `data_off` / `validity_off` / `offsets_off` are ABSOLUTE byte offsets from
    the start of the batch body (the same coordinate space THSPLC's
    `region_offset` + per-region sub-offsets use). `offsets_off == 0` means the
    column is flat fixed-width (no Int32/Int64 offsets buffer); `validity_off ==
    0` means no validity bitmap.
    """

    var arrow_type: UInt16
    var data_off: UInt32
    var data_len: UInt32
    var offsets_off: UInt32  # 0 = none (flat fixed-width)
    var validity_off: UInt32  # 0 = none (all-valid)
    var null_count: UInt32

    @always_inline
    def arrow_type_enum(self) -> ArrowType:
        return ArrowType(UInt8(Int(self.arrow_type)))

    @always_inline
    def has_offsets(self) -> Bool:
        return self.offsets_off != 0

    @always_inline
    def has_validity(self) -> Bool:
        return self.validity_off != 0


# =============================================================================
# ColumnAppendix — variable-length tail (dictionaries, nested child descriptors,
# EXTENSION metadata). Heap-owned via SharedAlignedBuffer (NOT a wildcard
# field). Optional on the batch — only present for dictionary / nested columns.
# =============================================================================
struct ColumnAppendix(Movable, Deinitable):
    """Variable-length tail: dictionary payloads, nested child descriptors,
    EXTENSION metadata. Heap-owned via SharedAlignedBuffer (NOT a wildcard
    field; SAB's Arc keeps the storage pinned with a tracked origin)."""

    var _bytes: SharedAlignedBuffer[HeapRegion]

    def __init__(out self, var bytes: SharedAlignedBuffer[HeapRegion]):
        self._bytes = bytes^

    @always_inline
    def len(self) -> Int:
        return self._bytes.len()

    def view[lo: Origin[mut=False], //](ref [lo] self) -> ByteView[lo]:
        """Borrow the appendix bytes as a tracked (immutable) ByteView."""
        # SAFETY: `self` is borrowed at `lo`; the SAB's Arc keeps the bytes
        # pinned while `self` is alive. Widen the field's intrinsic sub-origin
        # to the named `lo` via the confined pointer cast (same widen
        # SharedAlignedBuffer.as_view performs; repeated here because as_view's
        # origin param is inferred-only).
        var v = self._bytes.as_view()
        return ByteView[lo](v._unsafe_ptr().unsafe_origin_cast[lo](), v.len())


# =============================================================================
# UnifiedColumnFormat[T, lo] — typed read view over one column.
# =============================================================================
struct UnifiedColumnFormat[T: DType, lo: Origin](
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Typed read view over one column. If the parent batch has a selection
    vector, `get(i)` maps `i` through the selection; else direct index. The
    driver monomorphizes per `T`; zero per-row dispatch. Replaces 469
    `_typed_ptr_*[DType]` call sites  — those become
    `batch.column_unified[T](c).get(r)`.

    Construction is via `ColumnNativeBatch.column_unified[T]`; the data view is
    a sub-range of the batch body addressed by the column's `ColumnDescriptor`.
    """

    var _data: ByteView[Self.lo]
    var _selection: Optional[ByteView[Self.lo]]  # Int32 indices, None = dense
    var _len: Int

    def __init__(
        out self,
        var data: ByteView[Self.lo],
        var selection: Optional[ByteView[Self.lo]],
        len: Int,
    ):
        self._data = data^
        self._selection = selection^
        self._len = len

    @always_inline
    def _phys_index(self, i: Int) -> Int:
        # Map logical index i through the selection vector if present.
        if self._selection:
            return Int(self._selection.value().read_i32_le_at(i * 4))
        return i

    @always_inline
    def get_dense(self, i: Int) -> Scalar[Self.T]:
        """Read element `i` with NO selection-vector indirection (direct index).

        Zero-overhead dense read: the hot dense loop (C.2.a's dense filter, the
        agg-feed dense ingress) calls this so the dense path carries no per-row
        `if self._selection` branch at all. Callers MUST have established
        `is_dense()` (no selection) — the index is used directly as the physical
        index. For the sel-vector path use `get` (which applies the selection)."""
        return self._data.load_simd[Self.T, 1](i * size_of[Self.T]())[0]

    @always_inline
    def get(self, i: Int) -> Scalar[Self.T]:
        """Read element `i` (applies selection if present). Monomorphizes per
        `T`; the typed load is an unaligned native-endian scalar read out of
        the column's contiguous data region.

        Dense hot loops should prefer `get_dense` (no per-row selection branch);
        `get` is the selection-aware accessor used by the sel-vector pipeline,
        where the indirection IS the work."""
        var phys = self._phys_index(i)
        return self._data.load_simd[Self.T, 1](phys * size_of[Self.T]())[0]

    @always_inline
    def is_dense(self) -> Bool:
        return not Bool(self._selection)

    @always_inline
    def len(self) -> Int:
        return self._len


# =============================================================================
# ColumnNativeBatch — the SoA native column batch (BatchFormat conformer).
# =============================================================================
struct ColumnNativeBatch(BatchFormat, ListColumnFormat, StructColumnFormat):
    """SoA native column batch. One header + N descriptors + one contiguous
    body (THSPLC layout) + optional selection vector + optional appendix +
    the Schema.

    Movable-only (NOT Copyable) — same constraint as RecordBatch. Carrier is
    `Slab[ColumnNativeBatch]` / `Slab[Morsel[ColumnNativeBatch]]`.

    See the file header for the one-body-vs-N-buffers storage choice —
    semantics + public surface are identical.

    Conforms BatchFormat AND the two nested refinement traits
    (ListColumnFormat / StructColumnFormat). For a flat-only batch the nested
    methods are never called; for a nested batch the child columns live as
    additional descriptors in `_child_descriptors`, addressed via the parent
    column's descriptor (see the nested-layout note on the trait methods).
    """

    var _header: ColumnNativeBatchHeader
    var _descriptors: Slab[ColumnDescriptor]
    # Child descriptors for nested (List child-values / Struct fields). For a
    # List column the child-values column is _child_descriptors[col's child
    # base]; for a Struct column the field columns are a contiguous run. The
    # parent column's descriptor records the child base index in `data_off`
    # (re-purposed for nested parents: it is the index into _child_descriptors,
    # not a body byte offset) and the field count in `data_len`.
    var _child_descriptors: Slab[ColumnDescriptor]
    # SoA body in THSPLC layout: header + descriptors + per-column regions.
    # Optional-wrapped so `take_body` can `.take()` it out of the struct
    # cleanly (the struct has custom __init__ overloads, so it is not field-wise
    # decomposable for a bare partial-move; Optional.take is the project-
    # sanctioned replacement). It is ALWAYS Some for a
    # live batch; the accessors below `.value()` it unconditionally.
    var _body: Optional[SharedAlignedBuffer[HeapRegion]]
    # WRAPPED (per-column zero-copy) mode. When Some, the batch holds
    # the source RecordBatch's columns DIRECTLY (Arc-refcounted buffers, moved
    # in with no copy) and `_body` is None / `_descriptors` is empty. When None,
    # the batch is in contiguous-body mode. A live batch
    # has exactly ONE of (`_body` Some, `_columns` Some). The wrapped mode is a
    # field-internal storage refinement — the public surface is identical.
    var _columns: Optional[Slab[Column[HeapRegion]]]
    var _selection: Optional[SharedAlignedBuffer[HeapRegion]]  # Int32 sel indices
    var _appendix: Optional[ColumnAppendix]
    var _schema: Schema

    def __init__(
        out self,
        var header: ColumnNativeBatchHeader,
        var descriptors: Slab[ColumnDescriptor],
        var body: SharedAlignedBuffer[HeapRegion],
        var selection: Optional[SharedAlignedBuffer[HeapRegion]],
        var appendix: Optional[ColumnAppendix],
        var schema: Schema,
    ):
        self._header = header
        self._descriptors = descriptors^
        self._child_descriptors = Slab[ColumnDescriptor]()
        self._body = Optional(body^)
        self._columns = None
        self._selection = selection^
        self._appendix = appendix^
        self._schema = schema^

    def __init__(
        out self,
        var header: ColumnNativeBatchHeader,
        var descriptors: Slab[ColumnDescriptor],
        var child_descriptors: Slab[ColumnDescriptor],
        var body: SharedAlignedBuffer[HeapRegion],
        var selection: Optional[SharedAlignedBuffer[HeapRegion]],
        var appendix: Optional[ColumnAppendix],
        var schema: Schema,
    ):
        self._header = header
        self._descriptors = descriptors^
        self._child_descriptors = child_descriptors^
        self._body = Optional(body^)
        self._columns = None
        self._selection = selection^
        self._appendix = appendix^
        self._schema = schema^

    @staticmethod
    def wrap_columns(
        var header: ColumnNativeBatchHeader,
        var columns: Slab[Column[HeapRegion]],
        var schema: Schema,
    ) -> ColumnNativeBatch:
        """Build a WRAPPED (per-column, zero-copy) ColumnNativeBatch
        that holds `columns` DIRECTLY — no THSPLC encode, no buffer copy. The
        moved-in column slab's Arc-refcounted buffers ARE the batch's column
        data. `_body` is None and `_descriptors` is empty until a contiguous
        body is materialized on demand (`_ensure_body`, spill path only).

        This is the encode-side zero-copy bridge: `column_native_from_record_
        batch` calls `RecordBatch.take_columns()` and feeds the slab here. The
        reverse bridge (`record_batch_from_column_native`) moves the slab back
        out via `take_columns_wrapped` and reconstructs the RecordBatch — both
        directions are a struct move, zero buffer copy.
        """
        return ColumnNativeBatch(
            _header=header,
            _descriptors=Slab[ColumnDescriptor](),
            _child_descriptors=Slab[ColumnDescriptor](),
            _body=None,
            _columns=Optional(columns^),
            _selection=None,
            _appendix=None,
            _schema=schema^,
        )

    # Field-wise constructor (file-internal) — used by `wrap_columns` and the
    # body-materialization path to build a batch with an explicit storage mode.
    def __init__(
        out self,
        *,
        var _header: ColumnNativeBatchHeader,
        var _descriptors: Slab[ColumnDescriptor],
        var _child_descriptors: Slab[ColumnDescriptor],
        var _body: Optional[SharedAlignedBuffer[HeapRegion]],
        var _columns: Optional[Slab[Column[HeapRegion]]],
        var _selection: Optional[SharedAlignedBuffer[HeapRegion]],
        var _appendix: Optional[ColumnAppendix],
        var _schema: Schema,
    ):
        self._header = _header
        self._descriptors = _descriptors^
        self._child_descriptors = _child_descriptors^
        self._body = _body^
        self._columns = _columns^
        self._selection = _selection^
        self._appendix = _appendix^
        self._schema = _schema^

    # NOTE: no hand-written __moveinit__. Mojo auto-synthesizes a field-wise
    # (decomposable) move for an all-Movable-field struct, which is what lets
    # `take_body` fully decompose the struct via per-field moves. A custom
    # __moveinit__ would mark the struct non-decomposable and block that.

    # ---- BatchFormat trait surface ----
    @staticmethod
    def format_kind() -> FormatKind:
        return FormatKind.COLUMN

    def num_rows(self) -> Int:
        """Logical row count. When a selection vector is present, the column
        buffers are UN-filtered and the selection lists the selected rows, so
        the logical row count is the selection length (not the physical body
        row count). Dense batches (no selection) return the physical count
        directly — zero overhead, no allocation."""
        if self._selection:
            return self._selection.value().len() // 4
        return Int(self._header.row_count)

    @always_inline
    def physical_row_count(self) -> Int:
        """The physical (un-filtered) row count of the body — i.e. how many rows
        the column buffers actually hold, ignoring any selection vector. For a
        dense batch this equals `num_rows()`. For a selection-bearing batch this
        is the larger un-filtered count the selection indexes into."""
        return Int(self._header.row_count)

    def schema_fingerprint(self) -> UInt64:
        return self._header.schema_fingerprint

    @staticmethod
    def supports_zero_copy_export_to_arrow() -> Bool:
        return True

    # ---- structural accessors ----
    @always_inline
    def num_columns(self) -> Int:
        return Int(self._header.n_cols)

    @always_inline
    def has_selection(self) -> Bool:
        return Bool(self._selection)

    def descriptor_at(self, col_idx: Int) -> ColumnDescriptor:
        if self._columns:
            # WRAPPED mode: synthesize a descriptor from the source column. The
            # byte offsets are NOT meaningful (there is no contiguous body); the
            # presence bits (`has_offsets` / `has_validity`) and the arrow type
            # ARE — those are what descriptor consumers in this mode read. A
            # non-zero sentinel marks "buffer present" (the contiguous-body
            # descriptor uses a real body offset; here the buffer lives in the
            # column directly).
            ref col = self._columns.value()[col_idx]
            return ColumnDescriptor(
                arrow_type=UInt16(Int(col.arrow_type.type_id)),
                data_off=0,
                data_len=0,
                offsets_off=UInt32(1) if col.has_offsets_buffer() else UInt32(0),
                validity_off=UInt32(1) if col.has_validity_buffer() else UInt32(
                    0
                ),
                null_count=UInt32(col.null_count()),
            )
        return self._descriptors[col_idx]

    def schema_ref(ref self) -> ref [self._schema] Schema:
        return self._schema

    def body_view[lo: Origin[mut=False], //](ref [lo] self) -> ByteView[lo]:
        """Borrow the contiguous SoA body (immutable). Internal/shim use — the
        body is the THSPLC chunk bytes."""
        # SAFETY: widen the field's intrinsic sub-origin to the named `lo` via
        # the confined pointer cast (the SAB Arc keeps the bytes pinned while
        # `self` is alive; `as_view`'s origin param is inferred-only so cannot
        # be forced to `lo` at the call site).
        var v = self._body.value().as_view()
        return ByteView[lo](v._unsafe_ptr().unsafe_origin_cast[lo](), v.len())

    def schema_copy(self) -> Schema:
        """Return a copy of the decode-side Schema (Schema is Copyable). The
        boundary shim copies the schema BEFORE consuming the batch for its
        body (avoiding a non-copyable tuple return)."""
        return self._schema.copy()

    @always_inline
    def is_wrapped(self) -> Bool:
        """True iff this batch is in WRAPPED (per-column zero-copy) storage
        mode — it holds the source columns directly rather than a contiguous
        THSPLC body."""
        return Bool(self._columns)

    def take_columns_wrapped(var self) -> Slab[Column[HeapRegion]]:
        """Consume a WRAPPED batch and move out its column slab (zero-copy).
        The reverse zero-copy bridge: `record_batch_from_column_native` moves
        these columns straight back into a RecordBatch. Caller MUST have
        checked `is_wrapped()`; the contiguous-body mode has no column slab.
        """
        return self._columns.take()

    def take_body(var self) -> SharedAlignedBuffer[HeapRegion]:
        """Consume the batch and return the THSPLC body bytes. The boundary
        shim uses this to hand the body to the decoder. `self` is owned
        (`var self`) and the struct is field-wise decomposable (no custom
        __moveinit__), so the body field moves out and the remaining fields
        drop normally.

        WRAPPED-mode batches have no contiguous body; calling `take_body` on
        one is a programming error (the bridge routes wrapped batches through
        `take_columns_wrapped`). The `.take()` on a None `_body` would itself
        fault, so this is only reached in contiguous-body mode by construction.
        """
        return self._body.take()

    # ---- concrete (NON-trait) typed cell access, consumed inside the driver ----
    def column_unified[
        lo: Origin[mut=False], //, T: DType
    ](ref [lo] self, col_idx: Int) -> UnifiedColumnFormat[T, lo]:
        """Return a typed unified view over column `col_idx`. Handles the
        selection-vector indirection transparently (§7). The data view is the
        column's contiguous values region inside the batch body, addressed by
        the column's `ColumnDescriptor`. The receiver is an IMMUTABLE borrow
        (`lo: ImmutableOrigin`) — the returned views are read-only, so two
        views into the same `self` (data + selection) cannot alias-conflict.

        In WRAPPED (per-column zero-copy) mode the data view is the
        source column's `_data` buffer (shared, no copy); the typed accessor
        honors the column's element `_offset`. The contiguous-body mode (below)
        addresses the column's region inside the THSPLC body. Both return an
        identical `UnifiedColumnFormat[T, lo]`.
        """
        if self._columns:
            return self._column_unified_wrapped[T](col_idx)
        var d = self._descriptors[col_idx]
        # SAFETY: `self` is borrowed at `lo`; `self._body`'s bytes are live for
        # `lo` (the SAB's Arc keeps storage pinned while `self` is alive). The
        # field's intrinsic view origin is a sub-origin of `lo`; we widen it to
        # the named immutable `lo` via the confined cast on the ByteView
        # pointer. This mirrors the widen `SharedAlignedBuffer.as_view` performs
        # internally; we repeat it here only because `as_view`'s origin param is
        # inferred-only, so it cannot be forced to `lo` at the call site.
        var body_v = self._body.value().as_view()
        var data_v = body_v.sub(Int(d.data_off), Int(d.data_len))
        var data = ByteView[lo](
            data_v._unsafe_ptr().unsafe_origin_cast[lo](), data_v.len()
        )

        var sel: Optional[ByteView[lo]] = None
        if self._selection:
            var sel_v = self._selection.value().as_view()
            sel = Optional(
                ByteView[lo](
                    sel_v._unsafe_ptr().unsafe_origin_cast[lo](), sel_v.len()
                )
            )

        # logical length = selection length when present, else descriptor rows.
        var n: Int
        if self._selection:
            n = self._selection.value().len() // 4
        else:
            n = Int(self._header.row_count)

        return UnifiedColumnFormat[T, lo](data^, sel^, n)

    def _column_unified_wrapped[
        lo: Origin[mut=False], //, T: DType
    ](ref [lo] self, col_idx: Int) -> UnifiedColumnFormat[T, lo]:
        """WRAPPED-mode `column_unified[T]`: read a fixed-width column's typed
        cells directly off the shared `Column._data` buffer (zero-copy), honoring
        the column's element `_offset`.

        Only the flat fixed-width column shape is read this way (the gated
        zero-copy path's predicate / agg columns are fixed-width numeric). A
        var-width / nested `column_unified` over a wrapped batch is not on the
        zero-copy hot path; such callers densify-through-RecordBatch first.
        """
        ref col = self._columns.value()[col_idx]
        comptime elem = _size_of[Scalar[T]]()
        # SAFETY: the column's `_data` SAB Arc keeps its bytes pinned while
        # `self` (which owns the column slab) is alive at `lo`. The column ref is
        # borrowed at a sub-origin of `lo`; widen the values view's pointer to
        # the named `lo` via the confined cast (mirrors `body_view`). Slice off
        # the column's element offset so logical index 0 maps to the first live
        # element.
        var full_v = col.values_view_native()
        var base = col.offset() * elem
        var sliced = full_v.sub(base, full_v.len() - base)
        var data = ByteView[lo](
            sliced._unsafe_ptr().unsafe_origin_cast[lo](), sliced.len()
        )

        var sel: Optional[ByteView[lo]] = None
        if self._selection:
            var sel_v = self._selection.value().as_view()
            sel = Optional(
                ByteView[lo](
                    sel_v._unsafe_ptr().unsafe_origin_cast[lo](), sel_v.len()
                )
            )

        var n: Int
        if self._selection:
            n = self._selection.value().len() // 4
        else:
            n = Int(self._header.row_count)

        return UnifiedColumnFormat[T, lo](data^, sel^, n)

    def with_selection(
        var self, var selection: SharedAlignedBuffer[HeapRegion]
    ) -> ColumnNativeBatch:
        """Attach a selection vector to this (dense) batch, returning a
        selection-bearing batch over the SAME un-filtered body.

        ADDITIVE. The column buffers are NOT touched — they stay the
        un-filtered originals; `selection` is the Int32-LE list of selected
        physical row indices. Reads through `column_unified[T].get(i)` map `i`
        through the selection transparently; `num_rows()` returns the selection
        length. `physical_row_count()` still reports the un-filtered body count.

        This is the no-compaction filter emit: a filter that produces a
        selection vector instead of physically gathering survivors.

        `selection`: Int32-LE physical row indices of the selected rows. Each
        index MUST be in `[0, physical_row_count())`.
        """
        self._header.has_selection_vector = 1
        self._selection = Optional(selection^)
        return self^

    def selection_indices(self) -> List[Int]:
        """Read the selection vector into a `List[Int]` of physical row indices
        (empty when the batch is dense / has no selection). Used by the densify
        path to feed the shared `gather_batch` kernel."""
        var out = List[Int]()
        if self._selection:
            ref sel = self._selection.value()
            var n = sel.len() // 4
            out.reserve(n)
            for i in range(n):
                out.append(Int(sel.read_i32_le_at(i * 4)))
        return out^

    def materialize_dense(var self) raises -> ColumnNativeBatch:
        """Produce a fresh dense batch (selection applied). Called only where
        the next op physically requires dense input (hash-join build; sort;
        agg-feed ingress).

        If the batch is already dense (no selection vector), this is the
        identity — returning self is correct and zero-cost.

        The selection-bearing densify (gather every column through the
        selection into a fresh compacted body) reuses the shared byte-exact
        `gather_batch` kernel and therefore lives in the engine layer
        (`komira_engine_dispatch.column_pipeline.materialize_dense_native`),
        for the SAME acyclic-package reason the THSPLC codec shim does: core
        cannot import the engine-side THSPLC codec / gather glue. So a
        selection-bearing batch routes through that engine entry, NOT this
        core method. Calling this core method on a selection-bearing batch
        raises (the engine `materialize_dense_native` is the densify path).
        """
        if self._selection:
            raise Error(
                "ColumnNativeBatch.materialize_dense: a selection-bearing batch"
                " densifies via komira_engine_dispatch.column_pipeline."
                "materialize_dense_native (the gather kernel lives in the engine"
                " layer; core cannot import it). This core method is the"
                " dense-identity only."
            )
        return self^

    # ---- nested cell access: ListColumnFormat / StructColumnFormat ----
    #
    # Nested layout convention:
    #   List<T>   parent descriptor: validity_off -> outer validity bitmap;
    #             offsets_off -> Int32 outer offsets (n_rows+1 entries);
    #             data_off (re-purposed) -> child base INDEX into
    #             _child_descriptors (the child-values column). The child-values
    #             column descriptor carries data_off/data_len for the flat child
    #             values region in the body.
    #   Struct{}  parent descriptor: validity_off -> outer validity bitmap;
    #             data_off (re-purposed) -> child base INDEX; data_len -> field
    #             count. Each field column is _child_descriptors[base + f] with
    #             its own data_off/data_len into the body.

    @always_inline
    def _validity_bit(self, validity_off: Int, i: Int) -> Bool:
        # LSB-first 1-bit-per-element validity bitmap (Arrow spec). 1 = valid.
        if validity_off == 0:
            return True  # no bitmap => all-valid
        var body = self._body.value().as_view()
        var byte = body.read_u8_at(validity_off + (i >> 3))
        return ((Int(byte) >> (i & 7)) & 1) == 1

    def cell_is_valid(self, col_idx: Int, i: Int) -> Bool:
        var d = self._descriptors[col_idx]
        return self._validity_bit(Int(d.validity_off), i)

    def cell_offset_begin(self, col_idx: Int, i: Int) -> Int:
        var d = self._descriptors[col_idx]
        var body = self._body.value().as_view()
        return Int(body.read_i32_le_at(Int(d.offsets_off) + i * 4))

    def cell_offset_end(self, col_idx: Int, i: Int) -> Int:
        var d = self._descriptors[col_idx]
        var body = self._body.value().as_view()
        return Int(body.read_i32_le_at(Int(d.offsets_off) + (i + 1) * 4))

    def child_at[T: DType](self, col_idx: Int, child_pos: Int) -> Scalar[T]:
        # List child-values column = _child_descriptors[parent.data_off].
        var parent = self._descriptors[col_idx]
        var child = self._child_descriptors[Int(parent.data_off)]
        var body = self._body.value().as_view()
        return body.load_simd[T, 1](
            Int(child.data_off) + child_pos * size_of[T]()
        )[0]

    def struct_field_count(self, col_idx: Int) -> Int:
        var d = self._descriptors[col_idx]
        return Int(d.data_len)

    def struct_child_at[
        T: DType
    ](self, col_idx: Int, field_idx: Int, i: Int) -> Scalar[T]:
        var parent = self._descriptors[col_idx]
        var child = self._child_descriptors[Int(parent.data_off) + field_idx]
        var body = self._body.value().as_view()
        return body.load_simd[T, 1](Int(child.data_off) + i * size_of[T]())[0]


# =============================================================================
# ColumnNativeBatchBuilder — write API.
# =============================================================================
@fieldwise_init
struct ColumnNativeBatchBuilder(Movable):
    """Write API for a ColumnNativeBatch.

    Foundation: the canonical construction path is via the shim
    (`column_native_from_record_batch`) which routes through THSPLC's encoder
    — that is the single byte-exact column-encoding kernel and the foundation must not
    duplicate it. This builder is the thin assembler used by the shim to wrap
    a finished THSPLC body + descriptors + schema into a batch; it does NOT
    re-implement the column encoder.
    """

    var _header: ColumnNativeBatchHeader
    var _descriptors: Slab[ColumnDescriptor]
    var _selection: Optional[SharedAlignedBuffer[HeapRegion]]
    var _appendix: Optional[ColumnAppendix]

    @staticmethod
    def create(var header: ColumnNativeBatchHeader) -> ColumnNativeBatchBuilder:
        # Factory (NOT a custom __init__) so the struct stays field-wise
        # decomposable — `build` partial-moves fields out of `self`, which a
        # custom __init__ would block.
        var sel: Optional[SharedAlignedBuffer[HeapRegion]] = None
        var app: Optional[ColumnAppendix] = None
        return ColumnNativeBatchBuilder(
            header^, Slab[ColumnDescriptor](), sel^, app^
        )

    def add_descriptor(mut self, d: ColumnDescriptor):
        self._descriptors.append(d)

    def set_selection(mut self, var sel: SharedAlignedBuffer[HeapRegion]):
        self._header.has_selection_vector = 1
        self._selection = Optional(sel^)

    def set_appendix(mut self, var appendix: ColumnAppendix):
        self._appendix = Optional(appendix^)

    def build(
        mut self, var body: SharedAlignedBuffer[HeapRegion], var schema: Schema
    ) raises -> ColumnNativeBatch:
        # Swap each non-POD field out with an empty default (NOT a partial-move-
        # via-UnsafePointer; both sides are valid before/after, leaving `self`
        # destructor-safe — the take_columns pattern).
        var header = self._header  # POD, plain copy
        var descriptors = Slab[ColumnDescriptor]()
        swap(self._descriptors, descriptors)
        var selection: Optional[SharedAlignedBuffer[HeapRegion]] = None
        swap(self._selection, selection)
        var appendix: Optional[ColumnAppendix] = None
        swap(self._appendix, appendix)
        return ColumnNativeBatch(
            header^, descriptors^, body^, selection^, appendix^, schema^
        )
