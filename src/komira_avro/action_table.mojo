# =============================================================================
# action_table.mojo — runtime ResolutionTable + ActionTableInterpreter.
# =============================================================================
#
# This is the PRIMARY decode path (arrow-rs's column-direct pattern). Under
# IDENTITY resolution (strict mode) the writer schema == reader schema == the
# schema embedded in the OCF header, so the resolution-rewriter is a no-op:
# every reader field reads its writer field at the same wire offset, in order.
# Full reader-schema resolution emits the other action arms.
#
# Architecture:
#   - `FieldAction` is a runtime tagged-union (explicit Int8 tag + Optional
#     payload-per-arm), matching the core packages' logical-plan
#     tagged-union precedent. NO byte-erased fn-ptr dispatch (no
#     trampolines). Identity resolution emits only the `ReadField` arm; full
#     resolution adds the 6 resolution arms (SynthesizeDefault / ReadAndPromote /
#     SkipBytes / SelectBranch / RemapEnumSymbol / ReadAndReorder).
#   - `ResolutionTable.identity(schema)` walks the top-level record's fields
#     once and emits one `FieldAction` per field.
#   - `ActionTableInterpreter` walks the action list per record, dispatching
#     via `match action.kind` (Mojo if/elif on the Int8 tag) into the
#     direct-to-Arrow column builders. NO intermediate `Value` enum.
#
# Encapsulation: no UnsafePointer crosses any module boundary. Column builders
# accumulate into owned List storage; the interpreter consumes a borrowed
# block-payload Span via the AvroByteReader cursor.
# =============================================================================

from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.bitmap import Bitmap, bytes_for_bits
from komira_buffer.heap_region import HeapRegion
from komira_simd.validity_pack import pack_validity_from_null_flags
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.string_builder import ArrowStringBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_collections.slab import Slab

from .avro_schema import (
    AvroSchema,
    AvroNode,
    AvroDefault,
    avro_node_to_arrow,
    avro_kind_name,
    AVRO_DEFAULT_NONE,
    AVRO_DEFAULT_NULL,
    AVRO_DEFAULT_BOOL,
    AVRO_DEFAULT_INT,
    AVRO_DEFAULT_DOUBLE,
    AVRO_DEFAULT_STRING,
    AVRO_DEFAULT_BYTES,
    AVRO_KIND_NULL,
    AVRO_KIND_BOOLEAN,
    AVRO_KIND_INT,
    AVRO_KIND_LONG,
    AVRO_KIND_FLOAT,
    AVRO_KIND_DOUBLE,
    AVRO_KIND_BYTES,
    AVRO_KIND_STRING,
    AVRO_KIND_RECORD,
    AVRO_KIND_ENUM,
    AVRO_KIND_ARRAY,
    AVRO_KIND_MAP,
    AVRO_KIND_UNION,
    AVRO_KIND_FIXED,
)
# A SIMD single-varint decoder is a NEGATIVE result: it measured ~0.39x (a
# 2.5x REGRESSION) vs this scalar reader on Avro's small-magnitude-dominated
# data — the scalar byte-at-a-time loop early-exits after 1 byte on the
# common 1-byte varint, beating fixed-8-byte SIMD work. Production stays on
# the scalar reader.
#
# ⚠ Do not write a second decoder behind this reader's API. A second decoder
# for the same wire format is a second attack surface that has to be hardened
# twice (overflow-safe length guards, a validated cursor constructor) and
# stays hardened only by memory — for a path that is slower.
from .varint_decode_scalar import AvroByteReader
from .json_string import utf8_to_string
# The arrow.* override-aware Avro->Arrow mapper. The identity read path
# consults the override table (BEFORE the standard mapping) so a column the
# writer stamped with an arrow.* annotation (e.g. arrow.date64 over `long`)
# round-trips back to its exact Arrow type, not the underlying physical type.
# The mapper falls back silently to the standard mapping on a missing /
# physical-mismatched annotation, so non-annotated schemas are unaffected.
from .avro_logical_arrow import avro_node_to_arrow_with_override


# =============================================================================
# FieldAction kind tags.
# =============================================================================

comptime FA_READ_FIELD: Int8 = 0
comptime FA_SYNTHESIZE_DEFAULT: Int8 = 1  # full resolution
comptime FA_READ_AND_PROMOTE: Int8 = 2  # full resolution
comptime FA_SKIP_BYTES: Int8 = 3  # full resolution
comptime FA_SELECT_BRANCH: Int8 = 4  # full resolution
comptime FA_REMAP_ENUM_SYMBOL: Int8 = 5  # full resolution
comptime FA_READ_AND_REORDER: Int8 = 6  # full resolution


# =============================================================================
# Nullability ordering inside a union[null, T] / union[T, null].
# =============================================================================
#
# Avro encodes nullability ONLY via a 2-branch union. The wire tag is a zigzag
# `long`: tag 0 selects branch 0, tag 1 selects branch 1. Get the ordering
# wrong and every nullable field becomes garbage (a load-bearing decoder
# invariant).

comptime NULL_NONE: Int8 = 0  # not a nullable union; field is always present
comptime NULL_FIRST: Int8 = 1  # union[null, T] — tag 0 == null, tag 1 == T
comptime NULL_SECOND: Int8 = 2  # union[T, null] — tag 0 == T, tag 1 == null


# =============================================================================
# ReadFieldData — the per-field decode descriptor.
# =============================================================================
#
# Describes how to decode one reader-field at its wire offset (identity
# resolution). Carries the underlying Avro physical kind + the target Arrow
# type + logical-type info + nullable-union ordering. The interpreter
# dispatches on `avro_kind` into the matching column builder.

@fieldwise_init
struct ReadFieldData(Copyable, Movable):
    var avro_kind: Int  # AVRO_KIND_* of the (un-unioned) value type (WIRE kind)
    var arrow_type: ArrowType  # target Arrow column type (accumulator selector)
    var nullability: Int8  # NULL_NONE / NULL_FIRST / NULL_SECOND
    var fixed_size: Int  # for AVRO_KIND_FIXED (and decimal-over-fixed)
    var precision: Int  # decimal logical type
    var scale: Int  # decimal logical type
    var logical_type: String  # "decimal" / "date" / "timestamp-micros" / ...
    # Type promotion (type-promotion rule). When `promote_to != PROMOTE_NONE`
    # the value is read off the wire as `avro_kind` then widened to the
    # accumulator's wider type (int→long/float/double, long→float/double,
    # float→double, string↔bytes). PROMOTE_NONE means identity (no widening).
    var promote_to: Int8


# =============================================================================
# Type-promotion tags (type-promotion rule). The reader's target *physical*
# accumulator family; the value is read as `ReadFieldData.avro_kind` then
# widened. string↔bytes is a reinterpret (UTF-8 round-trip), not a numeric
# widen.
# =============================================================================

comptime PROMOTE_NONE: Int8 = 0
comptime PROMOTE_TO_LONG: Int8 = 1     # int → long
comptime PROMOTE_TO_FLOAT: Int8 = 2    # int/long → float
comptime PROMOTE_TO_DOUBLE: Int8 = 3   # int/long/float → double
comptime PROMOTE_STRING_TO_BYTES: Int8 = 4
comptime PROMOTE_BYTES_TO_STRING: Int8 = 5


@fieldwise_init
struct SynthesizeDefaultData(Copyable, Movable):
    """Defaults rule. The reader field is absent in
    the writer schema; every record gets the reader's declared default."""

    var default: AvroDefault
    var arrow_type: ArrowType


@fieldwise_init
struct SkipBytesData(Copyable, Movable):
    """Field-skip rule. The writer field is absent
    from the reader schema; decode-and-discard it (advance the cursor). Carries
    the writer-side wire shape needed to advance past the value."""

    var avro_kind: Int  # WIRE kind to skip
    var nullability: Int8  # the writer field's nullable-union ordering
    var fixed_size: Int  # for AVRO_KIND_FIXED


@fieldwise_init
struct SelectBranchData(Copyable, Movable):
    """Union resolution (union rule). Two shapes are handled:
      - writer-union → reader-non-union: read the writer's union tag, select the
        matching branch, read it as `branch_kind`.
      - writer-non-union → reader-union: read the writer's single value as
        `branch_kind` (no tag on the wire); the reader's nullable union just
        widens it to a nullable column.
    """

    var writer_is_union: Bool
    var reader_is_union: Bool
    var branch_kind: Int  # WIRE kind of the resolved (non-null) branch value
    var nullability: Int8  # reader-side nullable-union ordering for the column
    var fixed_size: Int


@fieldwise_init
struct RemapEnumSymbolData(Copyable, Movable):
    """Enum resolution (enum rule). The writer encodes an enum
    as a zigzag `int` index into the WRITER's symbol list. The reader maps that
    writer index → the reader's symbol string (via `writer_to_reader_symbol`),
    falling back to `enum_default` if the writer symbol is absent from the
    reader. A writer index with no reader mapping AND no default raises."""

    var writer_symbols: List[String]
    var reader_symbols: List[String]
    var enum_default: String  # reader's declared enum default (empty if none)
    var has_default: Bool


# =============================================================================
# FieldAction — runtime tagged-union over the resolution-rule action kinds.
# =============================================================================

@fieldwise_init
struct FieldAction(Copyable, Movable):
    """One per OUTPUT column (reader-field) PLUS one per writer-only field that
    must be skipped. Dispatch is `match action.kind` (if/elif on the Int8 tag)
    — NO byte-erased fn-ptr.

    The 7 resolution rules fold into these arms:
      0. FA_READ_FIELD        — identity / alias / reorder (read at wire offset).
      1. FA_SYNTHESIZE_DEFAULT — reader field absent in writer; synth default.
      2. FA_READ_AND_PROMOTE   — read + type-promote (folded into ReadFieldData
                                 via `promote_to`; this arm is the explicit one).
      3. FA_SKIP_BYTES         — writer field absent in reader; decode-and-skip.
      4. FA_SELECT_BRANCH      — union resolution.
      5. FA_REMAP_ENUM_SYMBOL  — enum resolution.
      6. FA_READ_AND_REORDER   — reorder is handled by emitting actions in
                                 READER order while reading writer fields by
                                 wire position; see ResolutionTable.resolve.
    """

    var kind: Int8
    var field_name: String
    var read_field: Optional[ReadFieldData]
    var synthesize_default: Optional[SynthesizeDefaultData]
    var skip_bytes: Optional[SkipBytesData]
    var select_branch: Optional[SelectBranchData]
    var remap_enum_symbol: Optional[RemapEnumSymbolData]
    # The OUTPUT column index this action writes to (for reorder + skip:
    # FA_SKIP_BYTES has out_index == -1 because it produces no column).
    var out_index: Int

    @staticmethod
    def _base(kind: Int8, name: String, out_index: Int) -> FieldAction:
        return FieldAction(
            kind=kind,
            field_name=name,
            read_field=None,
            synthesize_default=None,
            skip_bytes=None,
            select_branch=None,
            remap_enum_symbol=None,
            out_index=out_index,
        )

    @staticmethod
    def read(name: String, var data: ReadFieldData, out_index: Int = -1) -> FieldAction:
        var fa = FieldAction._base(FA_READ_FIELD, name, out_index)
        fa.read_field = Optional(data^)
        return fa^

    @staticmethod
    def promote(name: String, var data: ReadFieldData, out_index: Int) -> FieldAction:
        var fa = FieldAction._base(FA_READ_AND_PROMOTE, name, out_index)
        fa.read_field = Optional(data^)
        return fa^

    @staticmethod
    def synth_default(name: String, var data: SynthesizeDefaultData, out_index: Int) -> FieldAction:
        var fa = FieldAction._base(FA_SYNTHESIZE_DEFAULT, name, out_index)
        fa.synthesize_default = Optional(data^)
        return fa^

    @staticmethod
    def skip(name: String, var data: SkipBytesData) -> FieldAction:
        var fa = FieldAction._base(FA_SKIP_BYTES, name, -1)
        fa.skip_bytes = Optional(data^)
        return fa^

    @staticmethod
    def select_branch_action(name: String, var data: SelectBranchData, out_index: Int) -> FieldAction:
        var fa = FieldAction._base(FA_SELECT_BRANCH, name, out_index)
        fa.select_branch = Optional(data^)
        return fa^

    @staticmethod
    def remap_enum(name: String, var data: RemapEnumSymbolData, out_index: Int) -> FieldAction:
        var fa = FieldAction._base(FA_REMAP_ENUM_SYMBOL, name, out_index)
        fa.remap_enum_symbol = Optional(data^)
        return fa^


# =============================================================================
# ResolutionTable — the action list for a (writer, reader) schema pair.
# =============================================================================

@fieldwise_init
struct ResolutionTable(Movable):
    """Holds one FieldAction per reader-field + the Arrow output schema.

    Identity resolution: `identity(schema)` walks the top-level
    record's fields and emits one FA_READ_FIELD action per field. The output
    Arrow Schema is derived from the same walk so the RecordBatch builder has a
    matching field list.
    """

    var actions: List[FieldAction]
    var out_schema: Schema
    # Per-output-column accumulator spec, in READER (output) order. Carries the
    # arrow_type + precision/scale the accumulator needs. Length ==
    # len(out_schema fields). For identity this is one entry per action (1:1);
    # for full resolution the action list may be longer than out_specs (skips
    # produce no column) or shorter (defaults add columns with no wire read).
    var out_specs: List[ReadFieldData]

    @staticmethod
    def identity(schema: AvroSchema) raises -> ResolutionTable:
        """Build an identity-resolution action table from an Avro schema whose
        root is a record. Raises if the root is not a record (the reader reads
        record-rooted OCF files only)."""
        var root = schema.node(schema.root())
        if root.kind != AVRO_KIND_RECORD:
            raise Error(
                "AvroDecodeError.NOT_A_RECORD: the reader requires a"
                " record-rooted Avro schema"
            )
        var actions = List[FieldAction]()
        var out_specs = List[ReadFieldData]()
        var sb = SchemaBuilder()
        for i in range(len(root.children)):
            var fname = root.field_names[i]
            var child_idx = root.children[i]
            var rfd = _build_read_field(schema, child_idx)
            var arrow_type = rfd.arrow_type
            var nullable = rfd.nullability != NULL_NONE
            sb.add_field(Field(fname, arrow_type, nullable))
            out_specs.append(rfd.copy())
            # Identity: action i writes output column i, read in wire order.
            actions.append(FieldAction.read(fname, rfd^, i))
        return ResolutionTable(
            actions=actions^, out_schema=sb.build(), out_specs=out_specs^
        )

    @staticmethod
    def resolve(writer: AvroSchema, reader: AvroSchema) raises -> ResolutionTable:
        """Build a full-resolution action table from a (writer, reader) schema
        pair (the Avro schema-resolution rules). The wire is laid out in
        WRITER field order; the output Arrow batch is in READER field order.

        Algorithm:
          1. Validate both roots are records.
          2. For each WRITER field (in wire order): find the matching READER
             field by name OR alias. If found, emit a read/promote/union/enum
             action targeting the reader's output column index. If absent from
             the reader, emit FA_SKIP_BYTES (decode-and-discard).
          3. For each READER field NOT matched by any writer field: emit
             FA_SYNTHESIZE_DEFAULT (raises if no default declared).
        The interpreter walks the action list in WIRE order (so the cursor
        advances correctly) and routes each value to its out_index column.
        """
        return _resolve_schemas(writer, reader)


def _build_read_field(schema: AvroSchema, idx: Int) raises -> ReadFieldData:
    """Build the per-field decode descriptor for the field-type node at `idx`.

    Collapses union[null, T] / union[T, null] into a nullable scalar
    descriptor; otherwise the field is NULL_NONE.
    """
    var n = schema.node(idx)
    if n.kind == AVRO_KIND_UNION:
        # Nullable union collapse (the only union shape identity resolution handles).
        if len(n.children) == 2:
            var c0 = schema.node(n.children[0])
            var c1 = schema.node(n.children[1])
            if c0.kind == AVRO_KIND_NULL:
                var inner = _build_read_field(schema, n.children[1])
                inner.nullability = NULL_FIRST
                return inner^
            elif c1.kind == AVRO_KIND_NULL:
                var inner = _build_read_field(schema, n.children[0])
                inner.nullability = NULL_SECOND
                return inner^
        raise Error(
            "AvroDecodeError.UNSUPPORTED_UNION: identity resolution handles only"
            " union[null, T] / union[T, null] (n>=3 / no-null unions are"
            " not supported)"
        )

    # Non-union scalar / fixed / logical. The override-aware mapper consults
    # the arrow.* table first (so arrow.date64 over `long` -> DATE64, etc.) and
    # silently falls back to avro_node_to_arrow on a missing / mismatched
    # annotation. The arrow_type is carried as Column metadata over the SAME
    # physical accumulator the avro_kind dispatch selects (DATE64 is Int64-
    # backed, UINT16 is Int32-backed, ...), so the wire-read stays correct.
    var arrow_type = avro_node_to_arrow_with_override(schema, idx)
    # The accumulator + the wire-read MUST agree. avro_node_to_arrow maps uuid
    # (physical `string`) → BINARY per the type lattice, but the reader reads it
    # off the wire as a `string` (length-prefixed UTF-8). Keep it a STRING
    # column so the accumulator picked by `arrow_type` matches the `avro_kind`
    # dispatch. (A FixedSizeBinary(16) re-parse is not implemented.)
    if n.kind == AVRO_KIND_STRING and arrow_type == ArrowType.BINARY:
        arrow_type = ArrowType.STRING
    # Enum: the wire is a zigzag int INDEX into the
    # writer's symbol list; the resolution interpreter remaps it to the
    # reader's symbol STRING. Surface it as a STRING column (avro_node_to_arrow
    # maps enum -> DICTIONARY which has no accumulator). A true
    # dictionary-encoded enum output is not implemented.
    if n.kind == AVRO_KIND_ENUM:
        arrow_type = ArrowType.STRING
    return ReadFieldData(
        avro_kind=n.kind,
        arrow_type=arrow_type,
        nullability=NULL_NONE,
        fixed_size=n.size,
        precision=n.precision,
        scale=n.scale,
        logical_type=n.logical_type,
        promote_to=PROMOTE_NONE,
    )


# =============================================================================
# Per-column accumulators (direct-to-Arrow typed arrays).
# =============================================================================
#
# A parallel `nulls: List[Bool]` double-appended on every push, plus values
# materialized into a `List[T]` that is copied into a `List[Scalar[T]]` and
# then into a PrimitiveArray at build() time, costs 2 List.append per row + a
# 2× redundant copy at finalize. Instead, for the numeric arms (Int32, Int64,
# Float32, Float64, Bool), each accumulator:
#   1. Stores values DIRECTLY in a pre-allocated PrimitiveArray buffer via
#      `set_typed`, with an `_len: Int` write-cursor. NO intermediate List[T];
#      NO final copy. `build()` just trims `length`.
#   2. Drops the parallel `nulls: List[Bool]`. Tracks `_null_count: Int`
#      inline; lazy-allocates a validity Bitmap only on first `push_null()`
#      (initialized to all-valid up to the current cursor, then clear bit).
#   3. Exposes `reserve(n: Int)` so the OCF reader can pre-allocate from the
#      block's `object_count` once per block (no incremental realloc).
#
# The String/Binary arms stream into Arrow offsets/data buffers (see
# `_StringAcc` / `_BinaryAcc`); the Decimal arm keeps a 128-bit pair list.

# =============================================================================
# Accumulator capacity ceiling — the attacker-controlled-allocation backstop.
# =============================================================================
#
# UNTRUSTED INPUT. Every accumulator's `reserve(n)`
# ultimately reaches `PrimitiveArray.allocate(length)`, whose body is
#
#     OwnedAlignedBuffer(max(length, 1) * elem_size)
#
# — an UNCHECKED Int multiply. `length` derives from an OCF block's
# `object_count`, a zigzag varint straight off the wire, so a file can name a
# value where the multiply WRAPS: object_count = 2^61 + 8 makes
# `(2^61 + 8) * 8 == 2^64 + 64`, which wraps to **64**. The result is a 64-byte
# heap buffer whose accumulator records `_capacity = 2^61 + 8`, so
# `_ensure_capacity` — the only per-push gate — never trips and every
# subsequent `push(v)` stores straight past the end of the allocation with a
# fully wire-controlled Int64/Int32/Float payload, one per record.
#
# At ASSERT=safe `set_typed`'s debug_assert stops this at the 9th push. At
# ASSERT=none it is a linear heap overflow (a SIGSEGV once the write
# run is long enough to leave the mapped heap; a SHORT run corrupts
# neighbouring heap objects and reports nothing at all, which is worse).
#
# The ceiling below is deliberately far above anything real — 2^34 elements is
# ~17 billion rows, four orders of magnitude past any batch this decoder
# produces — because its job is to make the multiply unrepresentable, not to
# impose a product limit. 2^34 * 16 (the widest element, Decimal128) is 2^38,
# nowhere near overflow.
comptime MAX_ACC_ELEMS: Int = 1 << 34

# Largest byte offset representable in Arrow's 32-bit STRING/BINARY offset
# encoding. Beyond this a string column must be LARGE_STRING; silently
# truncating into Int32 produces negative offsets that StringArray.get does
# not validate. See `_StringAcc.build`.
comptime _INT32_OFFSET_MAX: Int = (1 << 31) - 1


@always_inline
def _check_acc_capacity(target: Int) raises:
    """Reject an accumulator capacity that cannot be a real row count.

    Called once per `reserve()` — i.e. once per column per block, never per
    row — so this is a boundary check, not a hot-path tax.
    """
    if target < 0 or target > MAX_ACC_ELEMS:
        raise Error(
            String("AvroDecodeError.ROW_COUNT_OUT_OF_RANGE: a block asked for ")
            + String(target)
            + " accumulator elements; the ceiling is "
            + String(MAX_ACC_ELEMS)
            + " (the file's declared record count is not credible)"
        )


@fieldwise_init
struct _I32Acc(Movable):
    """Typed numeric accumulator over Int32, direct-to-Arrow.

    Hot path: `push(v)` writes one `Int32` into a pre-allocated MmapAlignedBuffer
    at the next cursor position. NO List[Int32] back-store, NO parallel
    `nulls` list — `_null_count` is tracked inline, validity Bitmap is lazy-
    allocated on first null."""

    var _data: PrimitiveArray[DType.int32]  # writable backing store
    var _len: Int  # write-cursor (logical length so far)
    var _capacity: Int  # backing-store element capacity
    var _null_count: Int
    var _has_validity: Bool  # True iff _data.validity has been initialized
    var arrow_type: ArrowType

    @staticmethod
    def create(arrow_type: ArrowType) raises -> _I32Acc:
        return _I32Acc(
            _data=PrimitiveArray[DType.int32].allocate(1),
            _len=0,
            _capacity=1,
            _null_count=0,
            _has_validity=False,
            arrow_type=arrow_type,
        )

    def reserve(mut self, n: Int) raises:
        """Pre-allocate at least `n` elements (idempotent if already large).

        Preserves the existing validity bitmap (if any) — grows it to the
        new capacity, with all newly-reserved bits initialized as VALID
        (downstream push_null clears them; downstream push leaves them as
        valid). Without this preservation, a realloc after the first
        push_null would drop the bitmap and silently lose null markers.

        Direct-buffer copy: bypasses PrimitiveArray.get/set (which check
        `arr.length`, a field this accumulator doesn't keep in sync with
        the cursor `_len` until build() time) and goes straight to the
        MmapAlignedBuffer's set_typed/get_typed."""
        if n <= self._capacity:
            return
        # GEOMETRIC growth. The OCF reader calls reserve(cur + object_count)
        # once PER BLOCK. A file of tens of thousands of small blocks would,
        # reserving to the EXACT cur+oc every block, re-copy all prior
        # elements each time — O(blocks^2). Growing to max(n, capacity*2)
        # makes the per-block reserve a no-op until capacity doubles →
        # amortized O(n).
        var target = max(n, self._capacity * 2)
        _check_acc_capacity(target)
        # Move self._data out into a local so the compiler stops tracking
        # field-level moves; restore after the copy completes.
        var old_arr = self._data^
        var new_arr = PrimitiveArray[DType.int32].allocate(target)
        for i in range(self._len):
            var v = old_arr.data.get_typed[Scalar[DType.int32]](i)
            new_arr.data.set_typed[Scalar[DType.int32]](i, v)
        # Preserve validity bitmap if one was previously allocated.
        if self._has_validity:
            var new_bm = Bitmap.create_all_valid(target)
            for i in range(self._len):
                if not old_arr.validity.value().test(i):
                    new_bm.clear(i)
            new_arr.validity = new_bm^
        self._data = new_arr^
        self._capacity = target

    @always_inline
    def _ensure_capacity(mut self) raises:
        if self._len >= self._capacity:
            var new_cap = self._capacity * 2
            self.reserve(new_cap)

    @always_inline
    def push(mut self, v: Int32) raises:
        self._ensure_capacity()
        # Direct store into the buffer at the cursor (offset=0 for accumulator).
        self._data.data.set_typed[Scalar[DType.int32]](self._len, v)
        self._len += 1

    @always_inline
    def push_null(mut self) raises:
        self._ensure_capacity()
        # Lazy-allocate validity bitmap at first null (sized to current _len).
        if not self._has_validity:
            self._data.validity = Bitmap.create_all_valid(self._capacity)
            self._has_validity = True
        # Place a zero at the slot, mark invalid.
        self._data.data.set_typed[Scalar[DType.int32]](self._len, Int32(0))
        self._data.validity.value().clear(self._len)
        self._null_count += 1
        self._len += 1

    def build(var self) raises -> Column[HeapRegion]:
        # Trim the buffer's logical length to the actual write cursor.
        comptime elem_size = size_of[Scalar[DType.int32]]()
        self._data.length = self._len
        self._data.data.set_length(self._len * elem_size)

        if self._has_validity:
            self._data.null_count = self._null_count
            # If the validity bitmap was allocated larger than _len, the
            # downstream Column doesn't read past `length`, so it's fine.
        else:
            self._data.null_count = 0
            self._data.validity = None
        return Column.from_primitive_with_arrow_type[DType.int32](
            self._data^, self.arrow_type
        )


@fieldwise_init
struct _I64Acc(Movable):
    """Typed numeric accumulator over Int64, direct-to-Arrow.

    Hot path: see _I32Acc — same shape, dtype=int64."""

    var _data: PrimitiveArray[DType.int64]
    var _len: Int
    var _capacity: Int
    var _null_count: Int
    var _has_validity: Bool
    var arrow_type: ArrowType

    @staticmethod
    def create(arrow_type: ArrowType) raises -> _I64Acc:
        return _I64Acc(
            _data=PrimitiveArray[DType.int64].allocate(1),
            _len=0,
            _capacity=1,
            _null_count=0,
            _has_validity=False,
            arrow_type=arrow_type,
        )

    def reserve(mut self, n: Int) raises:
        if n <= self._capacity:
            return
        # GEOMETRIC growth — see _I32Acc.reserve (the ~52K-block O(n^2) fix).
        var target = max(n, self._capacity * 2)
        _check_acc_capacity(target)
        var old_arr = self._data^
        var new_arr = PrimitiveArray[DType.int64].allocate(target)
        for i in range(self._len):
            var v = old_arr.data.get_typed[Scalar[DType.int64]](i)
            new_arr.data.set_typed[Scalar[DType.int64]](i, v)
        if self._has_validity:
            var new_bm = Bitmap.create_all_valid(target)
            for i in range(self._len):
                if not old_arr.validity.value().test(i):
                    new_bm.clear(i)
            new_arr.validity = new_bm^
        self._data = new_arr^
        self._capacity = target

    @always_inline
    def _ensure_capacity(mut self) raises:
        if self._len >= self._capacity:
            var new_cap = self._capacity * 2
            self.reserve(new_cap)

    @always_inline
    def push(mut self, v: Int64) raises:
        self._ensure_capacity()
        self._data.data.set_typed[Scalar[DType.int64]](self._len, v)
        self._len += 1

    @always_inline
    def push_null(mut self) raises:
        self._ensure_capacity()
        if not self._has_validity:
            self._data.validity = Bitmap.create_all_valid(self._capacity)
            self._has_validity = True
        self._data.data.set_typed[Scalar[DType.int64]](self._len, Int64(0))
        self._data.validity.value().clear(self._len)
        self._null_count += 1
        self._len += 1

    def build(var self) raises -> Column[HeapRegion]:
        comptime elem_size = size_of[Scalar[DType.int64]]()
        self._data.length = self._len
        self._data.data.set_length(self._len * elem_size)

        if self._has_validity:
            self._data.null_count = self._null_count
        else:
            self._data.null_count = 0
            self._data.validity = None
        return Column.from_primitive_with_arrow_type[DType.int64](
            self._data^, self.arrow_type
        )


@fieldwise_init
struct _F32Acc(Movable):
    """Typed numeric accumulator over Float32 — same shape as _I32Acc."""

    var _data: PrimitiveArray[DType.float32]
    var _len: Int
    var _capacity: Int
    var _null_count: Int
    var _has_validity: Bool

    @staticmethod
    def create() raises -> _F32Acc:
        return _F32Acc(
            _data=PrimitiveArray[DType.float32].allocate(1),
            _len=0,
            _capacity=1,
            _null_count=0,
            _has_validity=False,
        )

    def reserve(mut self, n: Int) raises:
        if n <= self._capacity:
            return
        # GEOMETRIC growth — see _I32Acc.reserve (the ~52K-block O(n^2) fix).
        var target = max(n, self._capacity * 2)
        _check_acc_capacity(target)
        var old_arr = self._data^
        var new_arr = PrimitiveArray[DType.float32].allocate(target)
        for i in range(self._len):
            var v = old_arr.data.get_typed[Scalar[DType.float32]](i)
            new_arr.data.set_typed[Scalar[DType.float32]](i, v)
        if self._has_validity:
            var new_bm = Bitmap.create_all_valid(target)
            for i in range(self._len):
                if not old_arr.validity.value().test(i):
                    new_bm.clear(i)
            new_arr.validity = new_bm^
        self._data = new_arr^
        self._capacity = target

    @always_inline
    def _ensure_capacity(mut self) raises:
        if self._len >= self._capacity:
            var new_cap = self._capacity * 2
            self.reserve(new_cap)

    @always_inline
    def push(mut self, v: Float32) raises:
        self._ensure_capacity()
        self._data.data.set_typed[Scalar[DType.float32]](self._len, v)
        self._len += 1

    @always_inline
    def push_null(mut self) raises:
        self._ensure_capacity()
        if not self._has_validity:
            self._data.validity = Bitmap.create_all_valid(self._capacity)
            self._has_validity = True
        self._data.data.set_typed[Scalar[DType.float32]](self._len, Float32(0))
        self._data.validity.value().clear(self._len)
        self._null_count += 1
        self._len += 1

    def build(var self) raises -> Column[HeapRegion]:
        comptime elem_size = size_of[Scalar[DType.float32]]()
        self._data.length = self._len
        self._data.data.set_length(self._len * elem_size)

        if self._has_validity:
            self._data.null_count = self._null_count
        else:
            self._data.null_count = 0
            self._data.validity = None
        return Column.from_primitive[DType.float32](self._data^)


@fieldwise_init
struct _F64Acc(Movable):
    """Typed numeric accumulator over Float64 — same shape as _I64Acc."""

    var _data: PrimitiveArray[DType.float64]
    var _len: Int
    var _capacity: Int
    var _null_count: Int
    var _has_validity: Bool

    @staticmethod
    def create() raises -> _F64Acc:
        return _F64Acc(
            _data=PrimitiveArray[DType.float64].allocate(1),
            _len=0,
            _capacity=1,
            _null_count=0,
            _has_validity=False,
        )

    def reserve(mut self, n: Int) raises:
        if n <= self._capacity:
            return
        # GEOMETRIC growth — see _I32Acc.reserve (the ~52K-block O(n^2) fix).
        var target = max(n, self._capacity * 2)
        _check_acc_capacity(target)
        var old_arr = self._data^
        var new_arr = PrimitiveArray[DType.float64].allocate(target)
        for i in range(self._len):
            var v = old_arr.data.get_typed[Scalar[DType.float64]](i)
            new_arr.data.set_typed[Scalar[DType.float64]](i, v)
        if self._has_validity:
            var new_bm = Bitmap.create_all_valid(target)
            for i in range(self._len):
                if not old_arr.validity.value().test(i):
                    new_bm.clear(i)
            new_arr.validity = new_bm^
        self._data = new_arr^
        self._capacity = target

    @always_inline
    def _ensure_capacity(mut self) raises:
        if self._len >= self._capacity:
            var new_cap = self._capacity * 2
            self.reserve(new_cap)

    @always_inline
    def push(mut self, v: Float64) raises:
        self._ensure_capacity()
        self._data.data.set_typed[Scalar[DType.float64]](self._len, v)
        self._len += 1

    @always_inline
    def push_null(mut self) raises:
        self._ensure_capacity()
        if not self._has_validity:
            self._data.validity = Bitmap.create_all_valid(self._capacity)
            self._has_validity = True
        self._data.data.set_typed[Scalar[DType.float64]](self._len, Float64(0))
        self._data.validity.value().clear(self._len)
        self._null_count += 1
        self._len += 1

    def build(var self) raises -> Column[HeapRegion]:
        comptime elem_size = size_of[Scalar[DType.float64]]()
        self._data.length = self._len
        self._data.data.set_length(self._len * elem_size)

        if self._has_validity:
            self._data.null_count = self._null_count
        else:
            self._data.null_count = 0
            self._data.validity = None
        return Column.from_primitive[DType.float64](self._data^)


@fieldwise_init
struct _BoolAcc(Movable):
    """Typed Bool accumulator — stores into a List[Bool] for cursor simplicity,
    builds into a BooleanArray with separate validity Bitmap.

    Bool can't use the same PrimitiveArray pre-alloc shape as the numeric
    arms because BooleanArray.set does its own validity bookkeeping; the
    accumulator could lower this to direct Bitmap bit-twiddling; it keeps a
    `_nulls: List[Bool]`."""

    var values: List[Bool]
    var nulls: List[Bool]

    @staticmethod
    def create() -> _BoolAcc:
        return _BoolAcc(values=List[Bool](), nulls=List[Bool]())

    def reserve(mut self, n: Int):
        self.values.reserve(n)
        self.nulls.reserve(n)

    def push(mut self, v: Bool):
        self.values.append(v)
        self.nulls.append(False)

    def push_null(mut self):
        self.values.append(False)
        self.nulls.append(True)

    def build(var self) raises -> Column[HeapRegion]:
        var n = len(self.values)
        var arr = BooleanArray.allocate(n)
        for i in range(n):
            arr.set(i, self.values[i])
        for i in range(n):
            if self.nulls[i]:
                arr._set_null(i)
        return Column.from_boolean(arr)


@fieldwise_init
struct _StringAcc(Copyable, Movable):
    """Arrow-native streaming string accumulator.

    A `List[String]` (one heap String per row) + a parallel `List[Bool] nulls`,
    with `build()` re-scanning every String twice (sum-lengths pass +
    per-string memcpy) into the Arrow offsets/data buffers, dominates the
    decode of a string-heavy file.

    This shape streams directly into Arrow's variable-length layout:
      - `data: List[UInt8]` — contiguous UTF-8 bytes (grows preserving content,
        amortized O(1) append; built into the data MmapAlignedBuffer via ONE
        `copy_from_bytes_list` memcpy at finalize).
      - `offsets: List[Int32]` — N+1 cumulative byte offsets.
      - `_null_count` inline + a lazy `nulls` List only allocated on first null
        (the all-non-null hot path never touches it).
    `push_bytes(span)` copies the raw value bytes once with NO intermediate
    String allocation. `push(String)` (runtime/promotion callers) routes
    through the same byte buffer."""

    var data: List[UInt8]
    var offsets: List[Int32]
    var nulls: List[Bool]  # lazy: empty until first null
    var _null_count: Int
    var _has_validity: Bool

    @staticmethod
    def create() -> _StringAcc:
        var offs = List[Int32]()
        offs.append(Int32(0))  # offsets[0] == 0
        return _StringAcc(
            data=List[UInt8](),
            offsets=offs^,
            nulls=List[Bool](),
            _null_count=0,
            _has_validity=False,
        )

    def reserve(mut self, n: Int):
        # NOTE: do NOT reserve to the exact per-block `cur+oc` here — List.reserve
        # grows to the exact requested size (no geometric overshoot), so calling
        # it once per ~52K blocks with a slowly-growing target would re-copy the
        # whole buffer each block (the O(n^2) trap the numeric arms hit). The
        # List's own append-doubling already gives amortized O(n) growth; the
        # per-block reserve is intentionally a no-op for the streaming buffers.
        pass

    @always_inline
    def _append_offset(mut self):
        self.offsets.append(Int32(len(self.data)))

    @always_inline
    def _mark_present(mut self):
        # Keep the lazy nulls list aligned to row count once it exists.
        if self._has_validity:
            self.nulls.append(False)

    @always_inline
    def push_bytes(mut self, v: Span[UInt8, _]):
        # Bulk-extend the contiguous byte buffer (not a per-byte append loop).
        # List.extend(Span)
        # routes through a single grow + memcpy.
        self.data.extend(v)
        self._append_offset()
        self._mark_present()

    def push(mut self, var v: String):
        var sb = v.as_bytes()
        for i in range(len(sb)):
            self.data.append(sb[i])
        self._append_offset()
        self._mark_present()

    def push_null(mut self):
        # First null: back-fill the nulls list to all-present for prior rows.
        if not self._has_validity:
            self._has_validity = True
            var prior = len(self.offsets) - 1  # rows pushed so far
            self.nulls.reserve(prior + 1)
            for _i in range(prior):
                self.nulls.append(False)
        self._append_offset()  # zero-length value
        self.nulls.append(True)
        self._null_count += 1

    def build(var self) raises -> Column[HeapRegion]:
        from komira_arrow.string_array import StringArray

        comptime int32_size = size_of[Int32]()
        var num_strings = len(self.offsets) - 1
        var total_bytes = len(self.data)

        # UNTRUSTED INPUT. `_append_offset` stores
        # `Int32(len(self.data))`, which SILENTLY TRUNCATES once a string
        # column's cumulative bytes pass 2^31. Nothing bounds either the
        # per-value length (a wire varint) or the total, and the resulting
        # NEGATIVE Int32 offsets go straight into StringArray, whose `get`
        # reads start/end with no validation and calls
        # `copy_to(scratch, start, str_len)` with a negative start and a
        # negative-or-huge length — and here it is reachable from a FILE.
        #
        # Checked HERE and not in `_append_offset`: the byte total only ever
        # grows, so no intermediate offset can exceed the final total, which
        # makes one comparison at build() exactly equivalent to one per value
        # — at zero cost in the per-value hot path. The truncated offsets have
        # been written into the List by this point but no StringArray has been
        # constructed from them, so nothing downstream can observe them.
        if total_bytes > _INT32_OFFSET_MAX:
            raise Error(  # cov: unreachable needs a decoded string column over 2 GiB
                String(  # cov: unreachable needs a decoded string column over 2 GiB
                    "AvroDecodeError.STRING_COLUMN_TOO_LARGE: decoded string"
                    " column holds "
                )
                + String(total_bytes)  # cov: unreachable needs a decoded string column over 2 GiB
                + " bytes, which overflows Arrow's 32-bit offset encoding"  # cov: unreachable needs a decoded string column over 2 GiB
                + " (limit "  # cov: unreachable needs a decoded string column over 2 GiB
                + String(_INT32_OFFSET_MAX)  # cov: unreachable needs a decoded string column over 2 GiB
                + "); this column needs LARGE_STRING"  # cov: unreachable needs a decoded string column over 2 GiB
            )

        var offsets_buf = OwnedAlignedBuffer((num_strings + 1) * int32_size)
        # ONE memcpy of the cumulative-offset List[Int32] into the Arrow offsets
        # buffer (not a per-element set_typed loop).
        offsets_buf.copy_from_int32_list(self.offsets)
        offsets_buf.set_length(Int64((num_strings + 1) * int32_size))


        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
        # ONE memcpy from the streamed byte List into the Arrow data buffer.
        data_buf.copy_from_bytes_list(self.data)

        var arr = StringArray(
            offsets=offsets_buf^,
            data=data_buf^,
            validity=None,
            length=num_strings,
            data_length=total_bytes,
            null_count=0,
        )
        if self._has_validity:
            var bm = _bitmap_from_nulls(self.nulls)
            if bm:
                arr.validity = bm^
                arr.null_count = self._null_count
        return Column.from_string(arr)


struct _BinaryAcc(Copyable, Movable):
    """Arrow-native streaming binary accumulator.

    Not a `List[List[UInt8]]` (one heap `List[UInt8]` alloc per value) + a
    parallel `List[Bool] nulls` re-serialized through
    `BinaryArray.from_bytes_list` at `build()` (a sum-lengths pass + a
    per-value memcpy pass into the Arrow buffers) — the same anti-pattern
    `_StringAcc` avoids for strings.

    This shape wraps the shared `ArrowStringBuilder` byte accumulator (binary is
    string without the UTF-8 guarantee), streaming raw value bytes directly into
    Arrow's `(offsets, data)` layout with NO per-value `List[UInt8]` and NO
    re-serialize pass — `build()` adopts the two Lists via one bulk memcpy each
    through `BinaryArray.from_buffers` (the `build_binary()` finalizer)."""

    var builder: ArrowStringBuilder

    def __init__(out self):
        self.builder = ArrowStringBuilder()

    @always_inline
    def n_values(self) -> Int:
        return self.builder.n_values()

    def reserve(mut self, n: Int):
        self.builder.reserve_rows(n)

    @always_inline
    def push_bytes(mut self, v: Span[UInt8, _]):
        # Stream the raw value bytes straight into the Arrow data buffer
        # (one memcpy/value), no intermediate List[UInt8] alloc.
        self.builder.push_bytes(v)

    def push(mut self, var v: List[UInt8]):
        # Owned-List entry point (promotion / default-synthesis callers). Routes
        # through the same byte buffer; the temporary List is dropped after the
        # span copy (no per-value List retained in the accumulator).
        self.builder.push_bytes(Span(v))

    def push_null(mut self):
        self.builder.push_null()

    def build(var self) raises -> Column[HeapRegion]:
        # Move the builder out via `swap` with a fresh empty builder so the
        # consumed `self.builder` field is left in a destructor-safe state
        # (avoids the "field destroyed out of the middle of a value" partial-move
        # diagnostic that a bare `self.builder^` triggers on a single-field
        # wrapper). The empty stand-in is dropped with `self` at scope end.
        var b = ArrowStringBuilder()
        swap(self.builder, b)
        return b^.build_binary()


@fieldwise_init
struct _DecimalAcc(Copyable, Movable):
    var lows: List[Int64]
    var highs: List[Int64]
    var nulls: List[Bool]
    var precision: Int
    var scale: Int

    def reserve(mut self, n: Int):
        self.lows.reserve(n)
        self.highs.reserve(n)
        self.nulls.reserve(n)

    def push(mut self, low: Int64, high: Int64):
        self.lows.append(low)
        self.highs.append(high)
        self.nulls.append(False)

    def push_null(mut self):
        self.lows.append(Int64(0))
        self.highs.append(Int64(0))
        self.nulls.append(True)

    def build(var self) raises -> Column[HeapRegion]:
        var n = len(self.lows)
        var nc = _null_count(self.nulls)
        if nc > 0:
            var arr = Decimal128Array.allocate_nullable(
                n, self.precision, self.scale
            )
            for i in range(n):
                arr.set_raw(i, self.lows[i], self.highs[i])
            # set_raw re-validates each bit; clear nulls afterward. Decimal128Array
            # has no _set_null helper — mutate the validity bitmap directly.
            for i in range(n):
                if self.nulls[i]:
                    arr.validity.value().clear(i)
            arr.null_count = nc
            return Column.from_decimal128(arr)
        var arr2 = Decimal128Array.allocate(n, self.precision, self.scale)
        for i in range(n):
            arr2.set_raw(i, self.lows[i], self.highs[i])
        return Column.from_decimal128(arr2)


# =============================================================================
# Null-bitmap helpers (like komira_json's columnar materializer).
# =============================================================================


def _null_count(nulls: List[Bool]) -> Int:
    var c = 0
    for i in range(len(nulls)):
        if nulls[i]:
            c += 1
    return c


def _bitmap_from_nulls(nulls: List[Bool]) raises -> Optional[Bitmap[HeapRegion]]:
    """Return a validity Bitmap iff any row is null; else None (all-valid).

    Packs with the shared `komira_simd.validity_pack` movemask packer
    (16 rows/iteration, an order of magnitude faster than a bit-by-bit
    `create_all_valid + per-null clear` scalar pack). Output is bit-for-bit
    identical to the scalar pack. Cold on all-present columns (this
    helper is only reached once `_has_validity` is set, i.e. at least one null
    was observed); the win materializes on high-null-density Avro columns.
    """
    var n = len(nulls)
    # Cheap any-null early-out (preserves the all-valid -> None contract).
    var any_null = False
    for i in range(n):
        if nulls[i]:
            any_null = True
            break
    if not any_null:
        return None
    # Allocate a sized validity buffer and pack it via the shared SIMD movemask
    # primitive. The packer writes bit i == 1 iff row i is VALID (not null).
    var num_bytes = bytes_for_bits(n)
    var bm = Bitmap[HeapRegion]()
    # Bitmap.buffer is SAB; promote OAB via from_owned.
    bm.buffer = SharedAlignedBuffer.from_owned(
        OwnedAlignedBuffer(num_bytes)
    )
    var dst = bm.buffer.into_span_capacity()
    _ = pack_validity_from_null_flags(Span(nulls), dst)
    bm.buffer.set_length(num_bytes)

    bm.length = n
    return bm^


# =============================================================================
# ColumnAccVariant — tagged-union over the per-column accumulators.
# =============================================================================
#
# One slot per output column. The interpreter dispatches per-field-per-record
# into the active arm. Avoids trait-object indirection (Mojo cannot
# dispatch trait methods across a tagged-union without devirtualization —
# same constraint SourceVariant documents).

comptime ACC_I32: Int8 = 0
comptime ACC_I64: Int8 = 1
comptime ACC_F32: Int8 = 2
comptime ACC_F64: Int8 = 3
comptime ACC_BOOL: Int8 = 4
comptime ACC_STRING: Int8 = 5
comptime ACC_BINARY: Int8 = 6
comptime ACC_DECIMAL: Int8 = 7


@fieldwise_init
struct ColumnAccVariant(Movable):
    var tag: Int8
    var i32: Optional[_I32Acc]
    var i64: Optional[_I64Acc]
    var f32: Optional[_F32Acc]
    var f64: Optional[_F64Acc]
    var boolean: Optional[_BoolAcc]
    var string: Optional[_StringAcc]
    var binary: Optional[_BinaryAcc]
    var decimal: Optional[_DecimalAcc]

    @staticmethod
    def create(rfd: ReadFieldData) raises -> ColumnAccVariant:
        """Pick the accumulator arm for a field's Arrow output type."""
        var at = rfd.arrow_type
        # int-backed: bare INT32 + standard int logicals + the int-backed
        # arrow.* lossy logicals (INT8/16, UINT8/16, TIME32_S — recovered from
        # an arrow.* annotation over an Avro `int`). The Arrow type is carried
        # as Column metadata over Int32 physical storage.
        if (
            at == ArrowType.INT32
            or at == ArrowType.DATE32
            or at == ArrowType.TIME32_MS
            or at == ArrowType.INT8
            or at == ArrowType.INT16
            or at == ArrowType.UINT8
            or at == ArrowType.UINT16
            or at == ArrowType.TIME32_S
        ):
            return ColumnAccVariant._with_i32(_I32Acc.create(at))
        # long-backed: bare INT64 + standard long logicals + the long-backed
        # arrow.* lossy logicals (UINT32/DATE64/TIMESTAMP_S/TIMESTAMP_NS/
        # TIME64_NS/DURATION_* over an Avro `long`). Int64 physical storage.
        elif (
            at == ArrowType.INT64
            or at == ArrowType.TIME64_US
            or at == ArrowType.TIMESTAMP_MS
            or at == ArrowType.TIMESTAMP_US
            or at == ArrowType.UINT32
            or at == ArrowType.DATE64
            or at == ArrowType.TIMESTAMP_S
            or at == ArrowType.TIMESTAMP_NS
            or at == ArrowType.TIME64_NS
            or at == ArrowType.DURATION_S
            or at == ArrowType.DURATION_MS
            or at == ArrowType.DURATION_US
            or at == ArrowType.DURATION_NS
        ):
            return ColumnAccVariant._with_i64(_I64Acc.create(at))
        elif at == ArrowType.FLOAT32:
            return ColumnAccVariant._with_f32(_F32Acc.create())
        elif at == ArrowType.FLOAT64:
            return ColumnAccVariant._with_f64(_F64Acc.create())
        elif at == ArrowType.BOOL:
            return ColumnAccVariant._with_bool(_BoolAcc.create())
        elif at == ArrowType.STRING:
            return ColumnAccVariant._with_string(_StringAcc.create())
        elif at == ArrowType.BINARY:
            return ColumnAccVariant._with_binary(_BinaryAcc())
        elif at == ArrowType.DECIMAL128:
            return ColumnAccVariant._with_decimal(
                _DecimalAcc(
                    List[Int64](),
                    List[Int64](),
                    List[Bool](),
                    rfd.precision,
                    rfd.scale,
                )
            )
        raise Error(
            "AvroDecodeError.UNSUPPORTED_COLUMN_TYPE: Arrow type "
            + String(at.type_id)
            + " has no column builder"
        )

    @staticmethod
    def _with_i32(var a: _I32Acc) -> ColumnAccVariant:
        return ColumnAccVariant(
            tag=ACC_I32, i32=Optional(a^), i64=None, f32=None, f64=None,
            boolean=None, string=None, binary=None, decimal=None,
        )

    @staticmethod
    def _with_i64(var a: _I64Acc) -> ColumnAccVariant:
        return ColumnAccVariant(
            tag=ACC_I64, i32=None, i64=Optional(a^), f32=None, f64=None,
            boolean=None, string=None, binary=None, decimal=None,
        )

    @staticmethod
    def _with_f32(var a: _F32Acc) -> ColumnAccVariant:
        return ColumnAccVariant(
            tag=ACC_F32, i32=None, i64=None, f32=Optional(a^), f64=None,
            boolean=None, string=None, binary=None, decimal=None,
        )

    @staticmethod
    def _with_f64(var a: _F64Acc) -> ColumnAccVariant:
        return ColumnAccVariant(
            tag=ACC_F64, i32=None, i64=None, f32=None, f64=Optional(a^),
            boolean=None, string=None, binary=None, decimal=None,
        )

    @staticmethod
    def _with_bool(var a: _BoolAcc) -> ColumnAccVariant:
        return ColumnAccVariant(
            tag=ACC_BOOL, i32=None, i64=None, f32=None, f64=None,
            boolean=Optional(a^), string=None, binary=None, decimal=None,
        )

    @staticmethod
    def _with_string(var a: _StringAcc) -> ColumnAccVariant:
        return ColumnAccVariant(
            tag=ACC_STRING, i32=None, i64=None, f32=None, f64=None,
            boolean=None, string=Optional(a^), binary=None, decimal=None,
        )

    @staticmethod
    def _with_binary(var a: _BinaryAcc) -> ColumnAccVariant:
        return ColumnAccVariant(
            tag=ACC_BINARY, i32=None, i64=None, f32=None, f64=None,
            boolean=None, string=None, binary=Optional(a^), decimal=None,
        )

    @staticmethod
    def _with_decimal(var a: _DecimalAcc) -> ColumnAccVariant:
        return ColumnAccVariant(
            tag=ACC_DECIMAL, i32=None, i64=None, f32=None, f64=None,
            boolean=None, string=None, binary=None, decimal=Optional(a^),
        )

    def push_null(mut self) raises:
        if self.tag == ACC_I32:
            self.i32.value().push_null()
        elif self.tag == ACC_I64:
            self.i64.value().push_null()
        elif self.tag == ACC_F32:
            self.f32.value().push_null()
        elif self.tag == ACC_F64:
            self.f64.value().push_null()
        elif self.tag == ACC_BOOL:
            self.boolean.value().push_null()
        elif self.tag == ACC_STRING:
            self.string.value().push_null()
        elif self.tag == ACC_BINARY:
            self.binary.value().push_null()
        elif self.tag == ACC_DECIMAL:
            self.decimal.value().push_null()

    def reserve(mut self, n: Int) raises:
        """Pre-allocate at least `n` TOTAL element slots in the active arm.

        The OCF reader calls this
        once per block — passing `<current_len> + block.object_count` as the
        absolute target capacity — so the inner per-row push path is
        realloc-free for the bulk of a typical batch. For the primary
        numeric arms (I32/I64/F32/F64) this collapses an O(log n) realloc
        cascade into one allocation. String/Binary/Decimal use the
        List-style reserve (still a win — no double-bookkeeping)."""
        if self.tag == ACC_I32:
            self.i32.value().reserve(n)
        elif self.tag == ACC_I64:
            self.i64.value().reserve(n)
        elif self.tag == ACC_F32:
            self.f32.value().reserve(n)
        elif self.tag == ACC_F64:
            self.f64.value().reserve(n)
        elif self.tag == ACC_BOOL:
            self.boolean.value().reserve(n)
        elif self.tag == ACC_STRING:
            self.string.value().reserve(n)
        elif self.tag == ACC_BINARY:
            self.binary.value().reserve(n)
        elif self.tag == ACC_DECIMAL:
            self.decimal.value().reserve(n)

    def current_len(self) -> Int:
        """Return the active arm's current logical element count. Used by
        the OCF reader to compute absolute reserve() targets per block."""
        if self.tag == ACC_I32:
            return self.i32.value()._len
        elif self.tag == ACC_I64:
            return self.i64.value()._len
        elif self.tag == ACC_F32:
            return self.f32.value()._len
        elif self.tag == ACC_F64:
            return self.f64.value()._len
        elif self.tag == ACC_BOOL:
            return len(self.boolean.value().values)
        elif self.tag == ACC_STRING:
            return len(self.string.value().offsets) - 1
        elif self.tag == ACC_BINARY:
            return self.binary.value().n_values()
        elif self.tag == ACC_DECIMAL:
            return len(self.decimal.value().lows)
        return 0

    # Typed push helpers used by the resolution interpreter (promotion +
    # default synthesis). Each routes to the active arm; a mismatched arm is an
    # internal error (the resolver guarantees the accumulator type).
    def push_bool(mut self, v: Bool):
        self.boolean.value().push(v)

    def push_i32(mut self, v: Int32) raises:
        self.i32.value().push(v)

    def push_i64(mut self, v: Int64) raises:
        self.i64.value().push(v)

    def push_f32(mut self, v: Float32) raises:
        self.f32.value().push(v)

    def push_f64(mut self, v: Float64) raises:
        self.f64.value().push(v)

    def push_string(mut self, var v: String):
        self.string.value().push(v^)

    def push_binary(mut self, var v: List[UInt8]):
        self.binary.value().push(v^)

    @always_inline
    def push_binary_span(mut self, v: Span[UInt8, _]):
        # Zero-alloc binary push: stream the borrowed value bytes straight into
        # the Arrow data buffer (one memcpy), no intermediate List[UInt8].
        self.binary.value().push_bytes(v)

    def build(mut self) raises -> Column[HeapRegion]:
        if self.tag == ACC_I32:
            return self.i32.take().build()
        elif self.tag == ACC_I64:
            return self.i64.take().build()
        elif self.tag == ACC_F32:
            return self.f32.take().build()
        elif self.tag == ACC_F64:
            return self.f64.take().build()
        elif self.tag == ACC_BOOL:
            return self.boolean.take().build()
        elif self.tag == ACC_STRING:
            return self.string.take().build()
        elif self.tag == ACC_BINARY:
            return self.binary.take().build()
        elif self.tag == ACC_DECIMAL:
            return self.decimal.take().build()
        raise Error("AvroDecodeError.INTERNAL: unknown accumulator tag")


# =============================================================================
# _ActionPlan — flat POD per-action descriptor (per-row dispatch tax killer).
# =============================================================================
#
# A per-row hot loop that calls `self.table.actions[f].read_field.value().copy()`
# for EVERY field of EVERY row makes a full `ReadFieldData` copy whose
# `logical_type: String` field heap-allocates+frees once per field per row;
# that single copy dominates the decode loop.
#
# This struct lifts every value the per-row loop needs into a flat, POD-only
# (no String, no Optional) descriptor computed ONCE at interpreter construction.
# The hot loop reads cheap scalars off `self._plan[f]` with zero heap traffic
# and zero Optional unwrap. The String `logical_type` is consumed at plan-build
# time (folded into `is_decimal`), never touched per row.

comptime _PK_READ: Int8 = 0       # FA_READ_FIELD (identity / alias / reorder)
comptime _PK_PROMOTE: Int8 = 1    # FA_READ_AND_PROMOTE
comptime _PK_SYNTH: Int8 = 2      # FA_SYNTHESIZE_DEFAULT
comptime _PK_SKIP: Int8 = 3       # FA_SKIP_BYTES
comptime _PK_SELECT: Int8 = 4     # FA_SELECT_BRANCH
comptime _PK_ENUM: Int8 = 5       # FA_REMAP_ENUM_SYMBOL


@fieldwise_init
struct _ActionPlan(Copyable, Movable):
    """Flat POD per-action descriptor for the hot decode loop. Carries only
    scalars (no String, no Optional) so the per-row dispatch copies nothing to
    the heap. `plan_kind` selects the inner branch; the remaining fields are
    the union of what each branch needs (sparse — unused fields are 0)."""

    var plan_kind: Int8       # _PK_*
    var out_index: Int
    var avro_kind: Int        # WIRE kind for READ / PROMOTE / SELECT branch
    var nullability: Int8     # NULL_NONE / NULL_FIRST / NULL_SECOND
    var is_decimal: Bool      # arrow_type == DECIMAL128 (READ bytes/fixed arm)
    var fixed_size: Int
    var promote_to: Int8
    var writer_is_union: Bool  # SELECT_BRANCH only


def _build_action_plan(table: ResolutionTable) raises -> List[_ActionPlan]:
    """Lift each FieldAction into a flat POD `_ActionPlan` ONCE. The String-
    bearing `logical_type` is consumed here (folded into `is_decimal`); the
    per-row loop never re-reads it."""
    var plan = List[_ActionPlan]()
    plan.reserve(len(table.actions))
    for f in range(len(table.actions)):
        var kind = table.actions[f].kind
        var oi = table.actions[f].out_index
        if kind == FA_READ_FIELD:
            var rfd = table.actions[f].read_field.value().copy()
            plan.append(
                _ActionPlan(
                    plan_kind=_PK_READ,
                    out_index=oi,
                    avro_kind=rfd.avro_kind,
                    nullability=rfd.nullability,
                    is_decimal=(rfd.arrow_type == ArrowType.DECIMAL128),
                    fixed_size=rfd.fixed_size,
                    promote_to=PROMOTE_NONE,
                    writer_is_union=False,
                )
            )
        elif kind == FA_READ_AND_PROMOTE:
            plan.append(
                _ActionPlan(
                    plan_kind=_PK_PROMOTE, out_index=oi, avro_kind=0,
                    nullability=NULL_NONE, is_decimal=False, fixed_size=0,
                    promote_to=PROMOTE_NONE, writer_is_union=False,
                )
            )
        elif kind == FA_SYNTHESIZE_DEFAULT:
            plan.append(
                _ActionPlan(
                    plan_kind=_PK_SYNTH, out_index=oi, avro_kind=0,
                    nullability=NULL_NONE, is_decimal=False, fixed_size=0,
                    promote_to=PROMOTE_NONE, writer_is_union=False,
                )
            )
        elif kind == FA_SKIP_BYTES:
            plan.append(
                _ActionPlan(
                    plan_kind=_PK_SKIP, out_index=oi, avro_kind=0,
                    nullability=NULL_NONE, is_decimal=False, fixed_size=0,
                    promote_to=PROMOTE_NONE, writer_is_union=False,
                )
            )
        elif kind == FA_SELECT_BRANCH:
            plan.append(
                _ActionPlan(
                    plan_kind=_PK_SELECT, out_index=oi, avro_kind=0,
                    nullability=NULL_NONE, is_decimal=False, fixed_size=0,
                    promote_to=PROMOTE_NONE, writer_is_union=False,
                )
            )
        elif kind == FA_REMAP_ENUM_SYMBOL:
            plan.append(
                _ActionPlan(
                    plan_kind=_PK_ENUM, out_index=oi, avro_kind=0,
                    nullability=NULL_NONE, is_decimal=False, fixed_size=0,
                    promote_to=PROMOTE_NONE, writer_is_union=False,
                )
            )
        else:
            raise Error(
                "AvroDecodeError.INTERNAL: unknown FieldAction kind "
                + String(Int(kind))
            )
    return plan^


# =============================================================================
# ActionTableInterpreter — decode block payloads into a RecordBatch.
# =============================================================================

struct ActionTableInterpreter(Movable):
    """Walks the ResolutionTable per record, dispatching each FieldAction into
    a direct-to-Arrow column builder. Accumulates across all blocks, then
    emits a single RecordBatch."""

    var table: ResolutionTable
    # One accumulator per OUTPUT column, in READER (output) order. Length ==
    # len(table.out_specs) == len(out_schema fields).
    var accs: Slab[ColumnAccVariant]
    # Flat POD per-action plan (built ONCE from `table.actions`). The per-row
    # hot loop dispatches off this, never touching the String-bearing
    # ReadFieldData / Optional arms of `table.actions`.
    var _plan: List[_ActionPlan]

    def __init__(out self, var table: ResolutionTable) raises:
        self.accs = Slab[ColumnAccVariant]()
        for i in range(len(table.out_specs)):
            var rfd = table.out_specs[i].copy()
            self.accs.append(ColumnAccVariant.create(rfd))
        self._plan = _build_action_plan(table)
        self.table = table^

    def decode_block(
        mut self, payload: Span[UInt8, _], object_count: Int
    ) raises:
        """Decode `object_count` records from a (decompressed) block payload.
        Actions are walked in WIRE order; each routes its value to its
        out_index column (or skips). Default-synthesis actions write to their
        out_index with no wire read.

        Pre-grows each
        accumulator's backing buffer by `object_count` per block so the
        per-row push hot loop is realloc-free for the bulk of typical
        batches. Idempotent; no-op if the accumulator is already sized."""
        # UNTRUSTED INPUT. `object_count` is a wire
        # varint; nothing in the file format makes it agree with the payload.
        #
        # The pre-reserve is a PERFORMANCE HINT — the accumulators grow
        # geometrically on push regardless — so the right response to a lying
        # count is not to trust it and not to reject the file here, but to stop
        # letting it size an allocation. A record occupies at least one payload
        # byte in every schema this decoder supports (each of the seven scalar
        # arms reads >= 1 byte, and a nullable field spends a byte on its union
        # tag), so `len(payload)` is a sound upper bound on the records this
        # block can actually yield. A file claiming 2^40 records in a 100-byte
        # block now pre-reserves 100, decodes what is really there, and raises
        # `TRUNCATED` when the payload runs out — instead of asking for 8 TiB
        # or wrapping the `length * elem_size` multiply into a 64-byte buffer.
        var reserve_hint = object_count
        if reserve_hint > len(payload):
            reserve_hint = len(payload)
        if reserve_hint < 0:
            reserve_hint = 0
        var ncols = len(self.accs)
        for c in range(ncols):
            # The desired total capacity is the current cursor + this block's
            # row count. reserve() takes an ABSOLUTE target capacity.
            var cur = self.accs[c].current_len()
            self.accs[c].reserve(cur + reserve_hint)
        var reader = AvroByteReader(payload)
        var nplan = len(self._plan)
        for _r in range(object_count):
            for f in range(nplan):
                self._dispatch_action(reader, f)

    @always_inline
    def _dispatch_action(
        mut self, mut reader: AvroByteReader[_], f: Int
    ) raises:
        # SAFETY: f is bounded by the caller loop over self._plan.
        # Hot path: read straight off the POD plan (no String copy, no Optional
        # unwrap). The cold resolution arms (PROMOTE/SYNTH/SKIP/SELECT/ENUM)
        # re-enter the original handlers which copy the rare-by-construction
        # action payload — they are not on the identity hot path.
        var pk = self._plan[f].plan_kind
        if pk == _PK_READ:
            self._decode_read_plan(reader, f)
        elif pk == _PK_PROMOTE:
            self._decode_promote(reader, f)
        elif pk == _PK_SYNTH:
            self._synthesize_default(f)
        elif pk == _PK_SKIP:
            self._skip_field(reader, f)
        elif pk == _PK_SELECT:
            self._decode_select_branch(reader, f)
        elif pk == _PK_ENUM:
            self._decode_remap_enum(reader, f)
        else:
            raise Error(
                "AvroDecodeError.INTERNAL: unknown plan kind "
                + String(Int(pk))
            )

    @always_inline
    def _decode_read_plan(
        mut self, mut reader: AvroByteReader[_], f: Int
    ) raises:
        """FA_READ_FIELD hot path, driven entirely by the POD plan. Resolves
        the nullable-union tag (if any) then issues the typed read into the
        accumulator arm — with zero heap traffic per row. Reads plan fields by
        ref (no struct copy)."""
        var oi = self._plan[f].out_index
        var nb = self._plan[f].nullability
        if nb != NULL_NONE:
            var tag = reader.read_long()
            var is_null: Bool
            if nb == NULL_FIRST:
                is_null = tag == 0  # branch 0 == null
            else:  # NULL_SECOND
                is_null = tag == 1  # branch 1 == null
            if is_null:
                self.accs[oi].push_null()
                return
        var k = self._plan[f].avro_kind
        if k == AVRO_KIND_LONG:
            self.accs[oi].i64.value().push(reader.read_long())
        elif k == AVRO_KIND_DOUBLE:
            self.accs[oi].f64.value().push(reader.read_double())
        elif k == AVRO_KIND_STRING:
            self.accs[oi].string.value().push_bytes(reader.read_string_span())
        elif k == AVRO_KIND_INT:
            self.accs[oi].i32.value().push(reader.read_int())
        elif k == AVRO_KIND_FLOAT:
            self.accs[oi].f32.value().push(reader.read_float())
        elif k == AVRO_KIND_BOOLEAN:
            self.accs[oi].boolean.value().push(reader.read_boolean())
        elif k == AVRO_KIND_BYTES:
            if self._plan[f].is_decimal:
                var raw = reader.read_bytes()
                var dec = _decode_decimal_be(raw)
                self.accs[oi].decimal.value().push(dec.low, dec.high)
            else:
                self.accs[oi].binary.value().push_bytes(reader.read_bytes_span())
        elif k == AVRO_KIND_FIXED:
            var fsz = self._plan[f].fixed_size
            if self._plan[f].is_decimal:
                var raw = reader.read_fixed(fsz)
                var dec = _decode_decimal_be(raw)
                self.accs[oi].decimal.value().push(dec.low, dec.high)
            else:
                self.accs[oi].binary.value().push_bytes(reader.read_fixed_span(fsz))
        elif k == AVRO_KIND_NULL:
            self.accs[oi].push_null()
        else:
            raise Error(
                "AvroDecodeError.UNSUPPORTED_FIELD_KIND: Avro kind "
                + String(k)
                + " (record / enum / array / map nested decode is not supported)"
            )

    def _decode_read_field(
        mut self, mut reader: AvroByteReader[_], f: Int
    ) raises:
        var rfd = self.table.actions[f].read_field.value().copy()
        var oi = self.table.actions[f].out_index
        # Resolve nullable-union tag if applicable.
        if rfd.nullability != NULL_NONE:
            var tag = reader.read_long()
            var is_null: Bool
            if rfd.nullability == NULL_FIRST:
                is_null = tag == 0  # branch 0 == null
            else:  # NULL_SECOND
                is_null = tag == 1  # branch 1 == null
            if is_null:
                self.accs[oi].push_null()
                return
        self._read_value(reader, oi, rfd)

    def _read_value(
        mut self,
        mut reader: AvroByteReader[_],
        oi: Int,
        rfd: ReadFieldData,
    ) raises:
        var k = rfd.avro_kind
        var at = rfd.arrow_type
        if k == AVRO_KIND_BOOLEAN:
            self.accs[oi].boolean.value().push(reader.read_boolean())
        elif k == AVRO_KIND_INT:
            # int → Int32 (or a logical type stored as Int32: date / time-millis)
            self.accs[oi].i32.value().push(reader.read_int())
        elif k == AVRO_KIND_LONG:
            self.accs[oi].i64.value().push(reader.read_long())
        elif k == AVRO_KIND_FLOAT:
            self.accs[oi].f32.value().push(reader.read_float())
        elif k == AVRO_KIND_DOUBLE:
            self.accs[oi].f64.value().push(reader.read_double())
        elif k == AVRO_KIND_STRING:
            self.accs[oi].string.value().push_bytes(reader.read_string_span())
        elif k == AVRO_KIND_BYTES:
            if at == ArrowType.DECIMAL128:
                # decimal over bytes: BE two's-complement → (low, high).
                var raw = reader.read_bytes()
                var dec = _decode_decimal_be(raw)
                self.accs[oi].decimal.value().push(dec.low, dec.high)
            else:
                self.accs[oi].binary.value().push_bytes(reader.read_bytes_span())
        elif k == AVRO_KIND_FIXED:
            if at == ArrowType.DECIMAL128:
                var raw = reader.read_fixed(rfd.fixed_size)
                var dec = _decode_decimal_be(raw)
                self.accs[oi].decimal.value().push(dec.low, dec.high)
            else:
                self.accs[oi].binary.value().push_bytes(
                    reader.read_fixed_span(rfd.fixed_size)
                )
        elif k == AVRO_KIND_NULL:
            # A bare null field — nothing on the wire; push a null marker.
            self.accs[oi].push_null()
        else:
            raise Error(
                "AvroDecodeError.UNSUPPORTED_FIELD_KIND: Avro kind "
                + String(k)
                + " (record / enum / array / map nested decode is not supported)"
            )

    # -------------------------------------------------------------------------
    # FA_READ_AND_PROMOTE — read the writer value, widen to the reader's type.
    # -------------------------------------------------------------------------
    def _decode_promote(
        mut self, mut reader: AvroByteReader[_], f: Int
    ) raises:
        var rfd = self.table.actions[f].read_field.value().copy()
        var oi = self.table.actions[f].out_index
        if rfd.nullability != NULL_NONE:
            var tag = reader.read_long()
            var is_null: Bool
            if rfd.nullability == NULL_FIRST:
                is_null = tag == 0
            else:
                is_null = tag == 1
            if is_null:
                self.accs[oi].push_null()
                return
        var promo = rfd.promote_to
        var k = rfd.avro_kind  # WIRE kind
        if promo == PROMOTE_TO_LONG:
            # int → long
            self.accs[oi].push_i64(Int64(reader.read_int()))
        elif promo == PROMOTE_TO_FLOAT:
            # int/long → float
            if k == AVRO_KIND_INT:
                self.accs[oi].push_f32(Float32(Int(reader.read_int())))
            else:  # AVRO_KIND_LONG
                self.accs[oi].push_f32(Float32(Int(reader.read_long())))
        elif promo == PROMOTE_TO_DOUBLE:
            # int/long/float → double
            if k == AVRO_KIND_INT:
                self.accs[oi].push_f64(Float64(Int(reader.read_int())))
            elif k == AVRO_KIND_LONG:
                self.accs[oi].push_f64(Float64(Int(reader.read_long())))
            else:  # AVRO_KIND_FLOAT
                self.accs[oi].push_f64(Float64(reader.read_float()))
        elif promo == PROMOTE_STRING_TO_BYTES:
            # string → bytes: read the UTF-8 string, store its raw bytes.
            var s = reader.read_string()
            var b = List[UInt8]()
            var sb = s.as_bytes()
            for i in range(len(sb)):
                b.append(sb[i])
            self.accs[oi].push_binary(b^)
        elif promo == PROMOTE_BYTES_TO_STRING:
            # bytes → string: the Avro spec reads the writer's bytes as UTF-8.
            # They are copied byte-exact and must be well-formed; widening
            # each byte through chr() turned C3 BC into "Ã¼".
            var raw = reader.read_bytes_span()
            var s = utf8_to_string(
                raw, "AvroDecodeError.MALFORMED: bytes value promoted to string"
            )
            self.accs[oi].push_string(s^)
        else:
            raise Error(
                "AvroResolutionError.INCOMPATIBLE_TYPE_PROMOTION: unknown"
                " promotion tag " + String(Int(promo))
            )

    # -------------------------------------------------------------------------
    # FA_SYNTHESIZE_DEFAULT — reader field absent in writer; emit the default.
    # -------------------------------------------------------------------------
    def _synthesize_default(mut self, f: Int) raises:
        var sd = self.table.actions[f].synthesize_default.value().copy()
        var oi = self.table.actions[f].out_index
        var dk = sd.default.kind
        if dk == AVRO_DEFAULT_NULL:
            self.accs[oi].push_null()
        elif dk == AVRO_DEFAULT_BOOL:
            self.accs[oi].push_bool(sd.default.bool_val)
        elif dk == AVRO_DEFAULT_INT:
            if self.accs[oi].tag == ACC_I32:
                self.accs[oi].push_i32(Int32(Int(sd.default.int_val)))
            elif self.accs[oi].tag == ACC_I64:
                self.accs[oi].push_i64(sd.default.int_val)
            elif self.accs[oi].tag == ACC_F32:
                self.accs[oi].push_f32(Float32(Int(sd.default.int_val)))
            elif self.accs[oi].tag == ACC_F64:
                self.accs[oi].push_f64(Float64(Int(sd.default.int_val)))
            else:
                self.accs[oi].push_i64(sd.default.int_val)  # cov: unreachable _check_default_fits admits an int default only for i32/i64/f32/f64
        elif dk == AVRO_DEFAULT_DOUBLE:
            if self.accs[oi].tag == ACC_F32:
                self.accs[oi].push_f32(Float32(sd.default.double_val))
            else:
                self.accs[oi].push_f64(sd.default.double_val)
        elif dk == AVRO_DEFAULT_STRING:
            self.accs[oi].push_string(sd.default.str_val)
        elif dk == AVRO_DEFAULT_BYTES:
            self.accs[oi].push_binary(sd.default.bytes_val.copy())
        else:
            raise Error(
                "AvroResolutionError.NO_DEFAULT_FOR_MISSING_FIELD: field '"
                + self.table.actions[f].field_name
                + "' has no synthesizable default"
            )

    # -------------------------------------------------------------------------
    # FA_SKIP_BYTES — writer field absent in reader; decode-and-discard.
    # -------------------------------------------------------------------------
    def _skip_field(mut self, mut reader: AvroByteReader[_], f: Int) raises:
        var sk = self.table.actions[f].skip_bytes.value().copy()
        if sk.nullability != NULL_NONE:
            var tag = reader.read_long()
            var is_null: Bool
            if sk.nullability == NULL_FIRST:
                is_null = tag == 0
            else:
                is_null = tag == 1
            if is_null:
                return
        _skip_value(reader, sk.avro_kind, sk.fixed_size)

    # -------------------------------------------------------------------------
    # FA_SELECT_BRANCH — union resolution.
    # -------------------------------------------------------------------------
    def _decode_select_branch(
        mut self, mut reader: AvroByteReader[_], f: Int
    ) raises:
        var sb = self.table.actions[f].select_branch.value().copy()
        var oi = self.table.actions[f].out_index
        # writer-union → reader-non-union: the wire carries a union tag. We
        # already validated (at resolve time) that the writer union is a
        # nullable 2-branch shape; read the tag and route null vs value.
        if sb.writer_is_union:
            var tag = reader.read_long()
            var is_null: Bool
            if sb.nullability == NULL_FIRST:
                is_null = tag == 0
            else:
                is_null = tag == 1
            if is_null:
                self.accs[oi].push_null()
                return
            self._read_branch_value(reader, oi, sb.branch_kind, sb.fixed_size)
        else:
            # writer-non-union → reader-union: no tag on the wire; the writer
            # always wrote a value. Read it; the reader column is nullable but
            # this record is non-null.
            self._read_branch_value(reader, oi, sb.branch_kind, sb.fixed_size)

    def _read_branch_value(
        mut self, mut reader: AvroByteReader[_], oi: Int, k: Int, fixed_size: Int
    ) raises:
        if k == AVRO_KIND_BOOLEAN:
            self.accs[oi].boolean.value().push(reader.read_boolean())
        elif k == AVRO_KIND_INT:
            self.accs[oi].i32.value().push(reader.read_int())
        elif k == AVRO_KIND_LONG:
            self.accs[oi].i64.value().push(reader.read_long())
        elif k == AVRO_KIND_FLOAT:
            self.accs[oi].f32.value().push(reader.read_float())
        elif k == AVRO_KIND_DOUBLE:
            self.accs[oi].f64.value().push(reader.read_double())
        elif k == AVRO_KIND_STRING:
            self.accs[oi].string.value().push_bytes(reader.read_string_span())
        elif k == AVRO_KIND_BYTES:
            self.accs[oi].binary.value().push_bytes(reader.read_bytes_span())
        elif k == AVRO_KIND_FIXED:
            self.accs[oi].binary.value().push_bytes(
                reader.read_fixed_span(fixed_size)
            )
        else:
            raise Error(
                "AvroResolutionError.UNION_NO_MATCHING_BRANCH: branch kind "
                + String(k) + " not decodable"
            )

    # -------------------------------------------------------------------------
    # FA_REMAP_ENUM_SYMBOL — enum resolution.
    # -------------------------------------------------------------------------
    def _decode_remap_enum(
        mut self, mut reader: AvroByteReader[_], f: Int
    ) raises:
        var re = self.table.actions[f].remap_enum_symbol.value().copy()
        var oi = self.table.actions[f].out_index
        var widx = Int(reader.read_int())  # writer symbol INDEX (zigzag int)
        if widx < 0 or widx >= len(re.writer_symbols):
            raise Error(
                "AvroDecodeError.MALFORMED: enum index " + String(widx)
                + " out of range for writer symbol set"
            )
        var sym = re.writer_symbols[widx]
        # Map the writer symbol → reader symbol set (string match).
        var found = False
        for i in range(len(re.reader_symbols)):
            if re.reader_symbols[i] == sym:
                found = True
                break
        if found:
            self.accs[oi].push_string(sym)
        elif re.has_default:
            self.accs[oi].push_string(re.enum_default)
        else:
            raise Error(
                "AvroResolutionError.ENUM_SYMBOL_UNKNOWN: writer symbol '"
                + sym + "' absent from reader symbol set and no default"
            )

    def build_batch(mut self) raises -> RecordBatch:
        """Emit the accumulated columns as a RecordBatch with the table's
        derived output schema."""
        var ncols = len(self.accs)
        var builder = RecordBatchBuilder.with_capacity(ncols)
        for i in range(ncols):
            builder.add_column(self.accs[i].build())
        return builder.build(self.table.out_schema.copy())


# =============================================================================
# Decimal BE two's-complement → (low, high) Int64 pair.
# =============================================================================
#
# Avro decimal-over-bytes/fixed is big-endian two's-complement. Arrow's
# Decimal128 stores a little-endian i128 as (low: Int64, high: Int64). We
# sign-extend the BE bytes into a 16-byte LE buffer and split.

def _skip_value(mut reader: AvroByteReader[_], k: Int, fixed_size: Int) raises:
    """Advance the cursor past one value of wire kind `k` without materializing
    it (FA_SKIP_BYTES). Only the scalar / fixed kinds are handled."""
    if k == AVRO_KIND_BOOLEAN:
        _ = reader.read_boolean()
    elif k == AVRO_KIND_INT or k == AVRO_KIND_LONG:
        reader.skip_long()
    elif k == AVRO_KIND_FLOAT:
        reader.skip_n(4)
    elif k == AVRO_KIND_DOUBLE:
        reader.skip_n(8)
    elif k == AVRO_KIND_STRING or k == AVRO_KIND_BYTES:
        var n = Int(reader.read_long())
        reader.skip_n(n)
    elif k == AVRO_KIND_FIXED:
        reader.skip_n(fixed_size)
    elif k == AVRO_KIND_NULL:
        pass  # zero bytes on the wire
    else:
        raise Error(
            "AvroDecodeError.UNSUPPORTED_FIELD_KIND: cannot skip kind "
            + String(k) + " (nested skip is not supported)"
        )


@fieldwise_init
struct _DecimalParts(Copyable, Movable):
    var low: Int64
    var high: Int64


def _decode_decimal_be(raw: List[UInt8]) raises -> _DecimalParts:
    """Decode big-endian two's-complement bytes into a LE (low, high) i128."""
    var n = len(raw)
    if n == 0:
        return _DecimalParts(Int64(0), Int64(0))
    if n > 16:
        raise Error(
            "AvroDecodeError.DECIMAL_TOO_WIDE: "
            + String(n)
            + " bytes > 16 (Decimal128 limit)"
        )
    # Sign byte: top bit of the most-significant (first) byte.
    var negative = (raw[0] & 0x80) != 0
    var fill: UInt8 = 0xFF if negative else 0x00
    # Build a 16-byte little-endian buffer (sign-extended).
    var le = Array[UInt8, 16](fill=fill)
    # raw is BE: raw[n-1] is least-significant. Place into le[0..n-1].
    for i in range(n):
        le[i] = raw[n - 1 - i]
    var low: UInt64 = 0
    var high: UInt64 = 0
    for i in range(8):
        low |= UInt64(le[i]) << UInt64(8 * i)
    for i in range(8):
        high |= UInt64(le[8 + i]) << UInt64(8 * i)
    return _DecimalParts(Int64(low), Int64(high))


# =============================================================================
# Resolution-rewriter (the Avro schema-resolution rules: name/alias
# matching, defaults, type promotion, field skip, field reorder, unions,
# enums).
# =============================================================================
#
# `ResolutionTable.resolve(writer, reader)` delegates here. The wire is laid
# out in WRITER field order; the output Arrow batch is in READER field order.
# The action list is walked in wire order by the interpreter; each action
# consumes the wire bytes for one writer field and routes the value to its
# reader output-column index. SYNTHESIZE_DEFAULT actions (reader fields with no
# matching writer field) consume no wire bytes and are appended last.


@fieldwise_init
struct _FieldTypeInfo(Copyable, Movable):
    """The effective type of a record field, after collapsing nullable unions.

    `nullability` is NULL_NONE / NULL_FIRST / NULL_SECOND. `inner_idx` is the
    arena index of the (un-unioned) value-type node. `is_union` is True iff the
    field's declared type node was a union (nullable or otherwise)."""

    var inner_idx: Int
    var nullability: Int8
    var is_union: Bool


def _field_type_info(schema: AvroSchema, type_idx: Int) raises -> _FieldTypeInfo:
    var n = schema.node(type_idx)
    if n.kind == AVRO_KIND_UNION:
        if len(n.children) == 2:
            var c0 = schema.node(n.children[0])
            var c1 = schema.node(n.children[1])
            if c0.kind == AVRO_KIND_NULL:
                return _FieldTypeInfo(n.children[1], NULL_FIRST, True)
            elif c1.kind == AVRO_KIND_NULL:
                return _FieldTypeInfo(n.children[0], NULL_SECOND, True)
        raise Error(
            "AvroResolutionError.UNION_NO_MATCHING_BRANCH: only nullable"
            " 2-branch unions are resolvable (n>=3 / no-null"
            " unions are not supported)"
        )
    return _FieldTypeInfo(type_idx, NULL_NONE, False)


def _names_match(
    reader_name: String,
    reader_aliases: List[String],
    writer_name: String,
) -> Bool:
    """A reader field matches a writer field if their names are equal OR the
    writer's name is one of the reader field's declared aliases (Avro
    rule 1 — aliases)."""
    if reader_name == writer_name:
        return True
    for i in range(len(reader_aliases)):
        if reader_aliases[i] == writer_name:
            return True
    return False


def _promotion_tag(writer_kind: Int, reader_kind: Int) -> Int8:
    """Return the PROMOTE_* tag for a writer→reader scalar promotion, or
    PROMOTE_NONE if the kinds are identical, or -1 (PROMOTE_NONE sentinel via
    a separate caller check) if not a legal promotion. The 6 numeric promotions
    + string↔bytes (type-promotion rule)."""
    if writer_kind == reader_kind:
        return PROMOTE_NONE
    if writer_kind == AVRO_KIND_INT and reader_kind == AVRO_KIND_LONG:
        return PROMOTE_TO_LONG
    if (
        (writer_kind == AVRO_KIND_INT or writer_kind == AVRO_KIND_LONG)
        and reader_kind == AVRO_KIND_FLOAT
    ):
        return PROMOTE_TO_FLOAT
    if (
        (
            writer_kind == AVRO_KIND_INT
            or writer_kind == AVRO_KIND_LONG
            or writer_kind == AVRO_KIND_FLOAT
        )
        and reader_kind == AVRO_KIND_DOUBLE
    ):
        return PROMOTE_TO_DOUBLE
    if writer_kind == AVRO_KIND_STRING and reader_kind == AVRO_KIND_BYTES:
        return PROMOTE_STRING_TO_BYTES
    if writer_kind == AVRO_KIND_BYTES and reader_kind == AVRO_KIND_STRING:
        return PROMOTE_BYTES_TO_STRING
    return -1  # illegal promotion


def _named_types_match(writer: AvroNode, reader: AvroNode) -> Bool:
    """For named types (record / enum / fixed): the writer type matches the
    reader type if their fullnames are equal OR the writer's fullname is one of
    the reader type's aliases (named-type by-fullname matching)."""
    if writer.name == reader.name:
        return True
    for i in range(len(reader.aliases)):
        if reader.aliases[i] == writer.name:
            return True
    return False


def _default_kind_name(dk: Int) -> String:
    """`a <kind>` / `an <kind>` for an AVRO_DEFAULT_* (diagnostics only)."""
    if dk == AVRO_DEFAULT_NULL:
        return String("a null")
    if dk == AVRO_DEFAULT_BOOL:
        return String("a boolean")
    if dk == AVRO_DEFAULT_INT:
        return String("an int")
    if dk == AVRO_DEFAULT_DOUBLE:
        return String("a double")
    if dk == AVRO_DEFAULT_STRING:
        return String("a string")
    if dk == AVRO_DEFAULT_BYTES:
        return String("a bytes")
    return String("a kind#") + String(dk)


def _check_default_fits(
    fname: String, dk: Int, rfd: ReadFieldData
) raises:
    """Refuse a reader default that `_synthesize_default` cannot push into
    the column accumulator `rfd` selects: null needs a nullable column; a
    boolean needs a boolean column; an int needs an int/long/float/double
    column; a double needs a float/double column; a string needs a string
    column; bytes need a binary column."""
    var fits: Bool
    if dk == AVRO_DEFAULT_NULL:
        fits = rfd.nullability != NULL_NONE
    else:
        var tag = ColumnAccVariant.create(rfd).tag
        if dk == AVRO_DEFAULT_BOOL:
            fits = tag == ACC_BOOL
        elif dk == AVRO_DEFAULT_INT:
            fits = (
                tag == ACC_I32
                or tag == ACC_I64
                or tag == ACC_F32
                or tag == ACC_F64
            )
        elif dk == AVRO_DEFAULT_DOUBLE:
            fits = tag == ACC_F32 or tag == ACC_F64
        elif dk == AVRO_DEFAULT_STRING:
            fits = tag == ACC_STRING
        elif dk == AVRO_DEFAULT_BYTES:
            fits = tag == ACC_BINARY
        else:
            fits = False
    if fits:
        return
    var ty = String("Avro ") + avro_kind_name(rfd.avro_kind)
    if rfd.logical_type.byte_length() > 0:
        ty += ", logical " + rfd.logical_type
    raise Error(
        "AvroResolutionError.INVALID_DEFAULT: reader field '"
        + fname
        + "' has "
        + _default_kind_name(dk)
        + " default that does not fit its type ("
        + ty
        + ")"
    )


def _resolve_schemas(
    writer: AvroSchema, reader: AvroSchema
) raises -> ResolutionTable:
    var wroot = writer.node(writer.root())
    var rroot = reader.node(reader.root())
    if wroot.kind != AVRO_KIND_RECORD:
        raise Error(
            "AvroResolutionError.NOT_A_RECORD: writer schema root is not a record"
        )
    if rroot.kind != AVRO_KIND_RECORD:
        raise Error(
            "AvroResolutionError.NOT_A_RECORD: reader schema root is not a record"
        )

    var n_reader = len(rroot.children)
    var n_writer = len(wroot.children)

    # Build reader output schema + out_specs (one per reader field, in order).
    var sb = SchemaBuilder()
    var out_specs = List[ReadFieldData]()
    var reader_matched = List[Bool]()
    for ri in range(n_reader):
        var rfd = _build_read_field(reader, rroot.children[ri])
        sb.add_field(
            Field(rroot.field_names[ri], rfd.arrow_type, rfd.nullability != NULL_NONE)
        )
        out_specs.append(rfd^)
        reader_matched.append(False)

    var actions = List[FieldAction]()

    # ---- Pass 1: walk WRITER fields in wire order. ----
    for wi in range(n_writer):
        var wname = wroot.field_names[wi]
        var wtype_idx = wroot.children[wi]
        # Find the matching reader field (by name or reader-field alias).
        var match_ri = -1
        for ri in range(n_reader):
            if reader_matched[ri]:
                continue
            var r_aliases = rroot.field_aliases[ri].copy()
            if _names_match(rroot.field_names[ri], r_aliases, wname):
                match_ri = ri
                break

        if match_ri < 0:
            # Writer-only field: decode-and-skip (field-skip rule).
            var winfo = _field_type_info(writer, wtype_idx)
            var wnode = writer.node(winfo.inner_idx)
            actions.append(
                FieldAction.skip(
                    wname,
                    SkipBytesData(
                        avro_kind=wnode.kind,
                        nullability=winfo.nullability,
                        fixed_size=wnode.size,
                    ),
                )
            )
            continue

        reader_matched[match_ri] = True
        var rtype_idx = rroot.children[match_ri]
        var winfo = _field_type_info(writer, wtype_idx)
        var rinfo = _field_type_info(reader, rtype_idx)
        var wnode = writer.node(winfo.inner_idx)
        var rnode = reader.node(rinfo.inner_idx)
        var out_rfd = out_specs[match_ri].copy()

        # ---- Union resolution (union rule). ----
        # If EITHER side is a union (and the other side differs in union-ness),
        # route through FA_SELECT_BRANCH. (Both-nullable identical inner kinds
        # fall through to the read/promote path which already handles
        # nullability via NULL_FIRST/NULL_SECOND.)
        if winfo.is_union != rinfo.is_union:
            # Decide the wire branch kind + the reader column nullability.
            var branch_kind = wnode.kind
            # The reader column's nullability ordering (used to push null when
            # the writer union selected the null branch). If reader is the
            # union side, use its ordering; else NULL_NONE (writer always wrote
            # a value). For writer-union→reader-non-union the column is still
            # produced from the non-null branch.
            var col_nullability = rinfo.nullability if rinfo.is_union else winfo.nullability
            actions.append(
                FieldAction.select_branch_action(
                    wname,
                    SelectBranchData(
                        writer_is_union=winfo.is_union,
                        reader_is_union=rinfo.is_union,
                        branch_kind=branch_kind,
                        nullability=col_nullability,
                        fixed_size=wnode.size,
                    ),
                    match_ri,
                )
            )
            continue

        # ---- Enum resolution (enum rule). ----
        if wnode.kind == AVRO_KIND_ENUM and rnode.kind == AVRO_KIND_ENUM:
            if not _named_types_match(wnode, rnode):
                raise Error(
                    "AvroResolutionError.ENUM_SYMBOL_UNKNOWN: enum type name"
                    " mismatch (writer '" + wnode.name + "' vs reader '"
                    + rnode.name + "')"
                )
            actions.append(
                FieldAction.remap_enum(
                    wname,
                    RemapEnumSymbolData(
                        writer_symbols=wnode.symbols.copy(),
                        reader_symbols=rnode.symbols.copy(),
                        enum_default=rnode.enum_default,
                        has_default=rnode.enum_default.byte_length() > 0,
                    ),
                    match_ri,
                )
            )
            continue

        # ---- fixed size mismatch. ----
        if wnode.kind == AVRO_KIND_FIXED and rnode.kind == AVRO_KIND_FIXED:
            if wnode.size != rnode.size:
                raise Error(
                    "AvroResolutionError.FIXED_SIZE_MISMATCH: writer fixed["
                    + String(wnode.size) + "] vs reader fixed["
                    + String(rnode.size) + "] for field '" + wname + "'"
                )
            if not _named_types_match(wnode, rnode):
                raise Error(
                    "AvroResolutionError.INCOMPATIBLE_TYPE_PROMOTION: fixed"
                    " type name mismatch for field '" + wname + "'"
                )

        # ---- Scalar identity or type-promotion (type-promotion rule). ----
        var promo = _promotion_tag(wnode.kind, rnode.kind)
        # The wire kind we read is the WRITER's kind; the accumulator selector
        # is the READER's arrow type. Build a ReadFieldData with the writer wire
        # kind + reader arrow accumulator + the writer-side nullability.
        var read_rfd = ReadFieldData(
            avro_kind=wnode.kind,
            arrow_type=out_rfd.arrow_type,
            nullability=winfo.nullability,
            fixed_size=wnode.size,
            precision=out_rfd.precision,
            scale=out_rfd.scale,
            logical_type=out_rfd.logical_type,
            promote_to=promo if promo >= 0 else PROMOTE_NONE,
        )
        if promo == PROMOTE_NONE:
            actions.append(FieldAction.read(wname, read_rfd^, match_ri))
        elif promo > 0:
            actions.append(FieldAction.promote(wname, read_rfd^, match_ri))
        else:
            raise Error(
                "AvroResolutionError.INCOMPATIBLE_TYPE_PROMOTION: writer kind "
                + String(wnode.kind) + " -> reader kind " + String(rnode.kind)
                + " for field '" + wname + "' is not a spec-allowed promotion"
            )

    # ---- Pass 2: reader fields with no matching writer field → defaults. ----
    for ri in range(n_reader):
        if reader_matched[ri]:
            continue
        var rname = rroot.field_names[ri]
        var rdefault = rroot.field_defaults[ri].copy()
        if not rdefault.present():
            raise Error(
                "AvroResolutionError.NO_DEFAULT_FOR_MISSING_FIELD: reader field"
                " '" + rname + "' is absent from the writer schema and has no"
                " declared default"
            )
        var rfd = out_specs[ri].copy()
        _check_default_fits(rname, rdefault.kind, rfd)
        actions.append(
            FieldAction.synth_default(
                rname,
                SynthesizeDefaultData(default=rdefault^, arrow_type=rfd.arrow_type),
                ri,
            )
        )

    return ResolutionTable(
        actions=actions^, out_schema=sb.build(), out_specs=out_specs^
    )
