# =============================================================================
# columnar_materializer.mojo — JSON Stage 2 walker (typed Arrow column emit)
# =============================================================================
#
# Stage 2 of the two-stage JSON parser. Takes a Stage 1 `StructuralIndex`
# + the original `bytes` + a `Schema` describing the target columns and
# emits a `RecordBatch`.
#
# Input: JSONL (one top-level object per line; every line is checked
# against RFC 8259 and that rule by `line_check.mojo` before any row is
# built, and a bad line raises naming it). Column types: the scalar
# parsers (Int64, Float64, Bool, String, Date32, Decimal128) plus the
# single-level nested parsers (List, Struct, Map).
#
# Architecture:
#
#                  ┌───────────────────────┐
#   raw bytes ───→ │ Stage 1: structural   │ ───→ StructuralIndex
#                  │   indexer             │      (offsets, tags)
#                  └───────────────────────┘
#                                                       │
#                                                       ▼
#                  ┌───────────────────────┐
#                  │ Stage 2: walker       │ ───→ RecordBatch
#                  │   (THIS module)       │      (one Column per
#                  └───────────────────────┘       schema field)
#
# Walker state machine (per record):
#
#   OBJECT_START   → expect '{'; consume; advance to KEY_START or
#                    object-close on empty object.
#   KEY_START      → expect TAG_QUOTE_OPEN; record key_start. Find
#                    matching TAG_QUOTE_CLOSE; key_bytes =
#                    bytes[key_start+1 .. key_close]. Lookup in
#                    KeyTable; if found, retain column_index; else
#                    column_index = -1 (skip-value).
#   COLON          → expect TAG_COLON.
#   VALUE_DISPATCH → peek next tag:
#                      TAG_QUOTE_OPEN → STRING (find close quote;
#                        bytes between).
#                      else (no immediate structural at value pos)
#                        → SCALAR (digits / true / false / null);
#                        consume bytes until next structural.
#                    (Nested OBJECT / ARRAY go to the nested parsers.)
#   POST_VALUE     → expect TAG_COMMA → loop to KEY_START | TAG_CLOSE_BRACE → end.
#
# Encapsulation discipline:
#   - All public function signatures take `Span[UInt8, _]` / value types;
#     no `UnsafePointer` in the surface.
#   - Internal byte indexing uses Span subscripting (Mojo lowers without
#     bounds-check overhead in -O3).
#
# Cross-references:
#   - Stage 1 structural index: `komira_json_index.structural_index`.
#   - Key dispatch: `komira_jsonl.key_dispatch`.
#   - Value parsers: `komira_jsonl.value_parsers`.
# =============================================================================

from std.collections import Optional
from std.memory import UnsafePointer
from std.sys import num_physical_cores, size_of


from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.chunk_work import ChunkWork
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join import (
    parallel_fork_join,
    parallel_fork_join_serial,
)

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.list_array import ListArray
from komira_arrow.map_array import MapArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_arrow.string_builder import ArrowStringBuilder
from komira_arrow.struct_array import StructArray
from komira_collections.slab import Slab

from komira_json_index.input_limits import (
    check_arrow_string_bytes,
    check_json_column_count,
    max_rows_for_columns,
    raise_json_cell_budget_exceeded,
)
from komira_jsonl.key_dispatch import KeyTable
from komira_jsonl.key_unescape import key_has_escape, unescape_key
from komira_jsonl.part_concat import _concat_jsonl_parts
from komira_jsonl.line_check import (
    build_jsonl_index,
    check_jsonl_lines,
    count_lf,
)
from komira_json_index.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
    TAG_OPEN_BRACKET,
    TAG_CLOSE_BRACKET,
    TAG_COLON,
    TAG_COMMA,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)
from komira_json_index.structural_index import (
    build_structural_index,
    JsonlPartitions,
    StructuralIndex,
)
from komira_jsonl.value_parsers.parse_bool import parse_bool, parse_null
from komira_jsonl.value_parsers.parse_date import parse_date32
from komira_jsonl.value_parsers.parse_decimal import parse_decimal128_unscaled
from komira_jsonl.value_parsers.parse_float import parse_float_f64
from komira_jsonl.value_parsers.parse_int import parse_int_i64
from komira_jsonl.value_parsers.parse_list import parse_list_one_value
from komira_jsonl.value_parsers.parse_map import parse_map_one_value
from komira_json_index.parse_string import parse_string_raw, parse_string_with_escapes
from komira_jsonl.value_parsers.parse_struct import parse_struct_one_value


# =============================================================================
# Column-accumulator helpers
# =============================================================================
#
# Each accumulator collects per-row values + validity for one column. At
# `build_record_batch`-time the accumulators emit their Arrow Column.


def _bitmap_from_nulls(imm nulls: List[Bool]) -> Optional[Bitmap[HeapRegion]]:
    """Convert a per-row nulls list to an Arrow validity Bitmap.

    The accumulators track per-row nulls; this helper packs the nulls
    list into a validity Bitmap if any row
    is null; returns None when every row is valid (the no-null fast
    path, mirroring Arrow's "validity may be omitted when null_count==0"
    convention).

    Bit semantics: per Arrow, validity bit `i` is 1 iff row `i` is
    VALID (not null); `nulls[i] == True` means row i IS null → bit 0.
    """
    var n = len(nulls)
    var has_null = False
    for i in range(n):
        if nulls[i]:
            has_null = True
            break
    if not has_null:
        return Optional[Bitmap[HeapRegion]](None)
    var bm = Bitmap.create_all_valid(n)
    for i in range(n):
        if nulls[i]:
            bm.clear(i)
    return Optional[Bitmap[HeapRegion]](bm^)


def _null_count(imm nulls: List[Bool]) -> Int:
    var n = len(nulls)
    var c = 0
    for i in range(n):
        if nulls[i]:
            c += 1
    return c


@fieldwise_init
struct _Int64Acc(Copyable, Movable):
    """Accumulator for an INT64 column. Stores per-row Int64 + per-row
    validity bit. No SIMD batching here — the materializer builds
    row-by-row."""

    var values: List[Int64]
    var nulls: List[Bool]   # True iff the row is null (validity bit 0)

    @staticmethod
    def create() -> _Int64Acc:
        return _Int64Acc(values=List[Int64](), nulls=List[Bool]())

    def push_value(mut self, v: Int64):
        self.values.append(v)
        self.nulls.append(False)

    def push_null(mut self):
        self.values.append(Int64(0))
        self.nulls.append(True)

    def build_column(var self) raises -> Column[HeapRegion]:
        var n = len(self.values)
        var has_null = False
        for i in range(n):
            if self.nulls[i]:
                has_null = True
                break
        if not has_null:
            var arr_nn = PrimitiveArray[DType.int64].from_list(self.values^)
            return Column.from_primitive[DType.int64](arr_nn)
        # when any row is null, allocate nullable + populate
        # data + clear validity bits for null rows.
        # `PrimitiveArray._set_null` clears the validity BIT but does NOT
        # bump `null_count` (unlike BooleanArray/Decimal128Array._set_null,
        # which do), so `arr.null_count` is stamped explicitly after the
        # bit-clear loop (as the CSV column reader does). Without it the
        # column reports `null_count == 0` even though the validity bitmap
        # is correct — collapsing a null Int64 to 0 in any
        # null_count-driven consumer.
        var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
        var nc = 0
        for i in range(n):
            arr.set(i, self.values[i])
            if self.nulls[i]:
                arr._set_null(i)
                nc += 1
        arr.null_count = nc
        return Column.from_primitive[DType.int64](arr)


@fieldwise_init
struct _BoolAcc(Copyable, Movable):
    """Accumulator for a BOOL column."""

    var values: List[Bool]
    var nulls: List[Bool]

    @staticmethod
    def create() -> _BoolAcc:
        return _BoolAcc(values=List[Bool](), nulls=List[Bool]())

    def push_value(mut self, v: Bool):
        self.values.append(v)
        self.nulls.append(False)

    def push_null(mut self):
        self.values.append(False)
        self.nulls.append(True)

    def build_column(var self) raises -> Column[HeapRegion]:
        var n = len(self.values)
        var arr = BooleanArray.allocate(n)
        for i in range(n):
            arr.set(i, self.values[i])
        # propagate per-row nulls into BooleanArray validity.
        for i in range(n):
            if self.nulls[i]:
                arr._set_null(i)
        return Column.from_boolean(arr)


@fieldwise_init
struct _StringAcc(Copyable, Movable):
    """Accumulator for a STRING column.

    Uses the shared zero-copy `ArrowStringBuilder` (byte-buffer + Int32
    offsets streamed straight into Arrow's variable-length layout) rather
    than a `List[String]` (one heap `String` alloc per row + a second full
    re-serialize at `StringArray.from_strings`). Each non-escaped value is
    a single `data.extend(span)` memcpy with NO intermediate `String`; the
    no-null hot path never touches the lazy validity list. This is the
    same primitive the ORC and Avro readers use
    (`komira_arrow.string_builder`)."""

    var builder: ArrowStringBuilder

    @staticmethod
    def create() -> _StringAcc:
        return _StringAcc(builder=ArrowStringBuilder())

    @always_inline
    def push_bytes(mut self, v: Span[UInt8, _]):
        """Append one value's raw UTF-8 bytes (zero-copy, no String alloc)."""
        self.builder.push_bytes(v)

    def push_null(mut self):
        self.builder.push_null()

    def build_column(var self) raises -> Column[HeapRegion]:
        # Partial-move-out-of-struct is not allowed; swap the
        # builder out into a local before the consuming `build()`.
        var b = ArrowStringBuilder()
        swap(self.builder, b)
        return b^.build()


@fieldwise_init
struct _Float64Acc(Copyable, Movable):
    """Accumulator for a FLOAT64 column."""

    var values: List[Float64]
    var nulls: List[Bool]

    @staticmethod
    def create() -> _Float64Acc:
        return _Float64Acc(values=List[Float64](), nulls=List[Bool]())

    def push_value(mut self, v: Float64):
        self.values.append(v)
        self.nulls.append(False)

    def push_null(mut self):
        self.values.append(Float64(0.0))
        self.nulls.append(True)

    def build_column(var self) raises -> Column[HeapRegion]:
        var n = len(self.values)
        var has_null = False
        for i in range(n):
            if self.nulls[i]:
                has_null = True
                break
        if not has_null:
            var typed_values = List[Scalar[DType.float64]]()
            for i in range(n):
                typed_values.append(Float64(self.values[i]))
            var arr_nn = PrimitiveArray[DType.float64].from_list(typed_values)
            return Column.from_primitive[DType.float64](arr_nn)
        # allocate_nullable + populate + clear null bits; stamp
        # null_count — see the _Int64Acc.build_column note.
        # PrimitiveArray._set_null clears the bit but does not bump
        # null_count.
        var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
        var nc = 0
        for i in range(n):
            arr.set(i, Float64(self.values[i]))
            if self.nulls[i]:
                arr._set_null(i)
                nc += 1
        arr.null_count = nc
        return Column.from_primitive[DType.float64](arr)


@fieldwise_init
struct _Date32Acc(Copyable, Movable):
    """Accumulator for a DATE32 column."""

    var values: List[Int32]
    var nulls: List[Bool]

    @staticmethod
    def create() -> _Date32Acc:
        return _Date32Acc(values=List[Int32](), nulls=List[Bool]())

    def push_value(mut self, v: Int32):
        self.values.append(v)
        self.nulls.append(False)

    def push_null(mut self):
        self.values.append(Int32(0))
        self.nulls.append(True)

    def build_column(var self) raises -> Column[HeapRegion]:
        var n = len(self.values)
        var has_null = False
        for i in range(n):
            if self.nulls[i]:
                has_null = True
                break
        if not has_null:
            var typed_values = List[Scalar[DType.int32]]()
            for i in range(n):
                typed_values.append(Int32(self.values[i]))
            var arr_nn = PrimitiveArray[DType.int32].from_list(typed_values)
            # Stamp ArrowType.DATE32 (not INT32) on the resulting column.
            return Column.from_primitive_with_arrow_type[DType.int32](arr_nn, ArrowType.DATE32)
        # allocate_nullable + populate + clear null bits.
        # stamp null_count — see the
        # _Int64Acc.build_column note. PrimitiveArray._set_null clears the
        # bit but does not bump null_count.
        var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
        var nc = 0
        for i in range(n):
            arr.set(i, Int32(self.values[i]))
            if self.nulls[i]:
                arr._set_null(i)
                nc += 1
        arr.null_count = nc
        return Column.from_primitive_with_arrow_type[DType.int32](arr, ArrowType.DATE32)


def _scalar_child_column(
    at: ArrowType,
    mut ints: List[Int64],
    mut floats: List[Float64],
    mut bools: List[Bool],
    mut strings: List[String],
    mut dates: List[Int32],
    mut nulls: List[Bool],
    unsupported: String,
) raises -> Column[HeapRegion]:
    """The child column of a LIST, STRUCT or MAP: the one value list `at`
    selects, with `nulls` as its validity, built by the scalar column's own
    accumulator. A null element, member or map value (JSON `null`, a STRUCT
    member missing from its object, every member of a null STRUCT row) reads
    back NULL, not a valid 0, "" or false. The lists are moved out (left
    empty). Raises `unsupported` + the type id for any other `at`."""
    var n = List[Bool]()
    swap(n, nulls)
    if at == ArrowType.INT64:
        var v = List[Int64]()
        swap(v, ints)
        return _Int64Acc(values=v^, nulls=n^).build_column()
    elif at == ArrowType.FLOAT64:
        var v = List[Float64]()
        swap(v, floats)
        return _Float64Acc(values=v^, nulls=n^).build_column()
    elif at == ArrowType.BOOL:
        var v = List[Bool]()
        swap(v, bools)
        return _BoolAcc(values=v^, nulls=n^).build_column()
    elif at == ArrowType.STRING:
        var acc = _StringAcc.create()
        for i in range(len(strings)):
            if n[i]:
                acc.push_null()
            else:
                acc.push_bytes(strings[i].as_bytes())
        strings.clear()
        return acc^.build_column()
    elif at == ArrowType.DATE32:
        var v = List[Int32]()
        swap(v, dates)
        return _Date32Acc(values=v^, nulls=n^).build_column()
    raise Error(unsupported + String(Int(at.type_id)))


@fieldwise_init
struct _ListAcc(Copyable, Movable):
    """Accumulator for a LIST<inner> column.

    Single-level nesting only: `inner` is one of the scalar arrow
    types (INT64 / FLOAT64 / BOOL / STRING / DATE32). Carried in
    `inner_arrow_type`. Per-row offsets (Int32) + per-row validity. The
    five `child_*_vals` lists are PARALLEL — only the one matching
    `inner_arrow_type` is populated; others remain empty.
    """

    var offsets: List[Int32]
    var nulls: List[Bool]
    var inner_arrow_type: ArrowType
    var child_int_vals: List[Int64]
    var child_float_vals: List[Float64]
    var child_bool_vals: List[Bool]
    var child_string_vals: List[String]
    var child_date_vals: List[Int32]
    var child_nulls: List[Bool]

    @staticmethod
    def create_for(inner_at: ArrowType) -> _ListAcc:
        var offs = List[Int32]()
        offs.append(Int32(0))
        return _ListAcc(
            offsets=offs^,
            nulls=List[Bool](),
            inner_arrow_type=inner_at,
            child_int_vals=List[Int64](),
            child_float_vals=List[Float64](),
            child_bool_vals=List[Bool](),
            child_string_vals=List[String](),
            child_date_vals=List[Int32](),
            child_nulls=List[Bool](),
        )

    def push_null(mut self):
        # offsets unchanged; just append a duplicate of the last value
        # (Arrow convention: null lists may carry any offset span).
        var last = self.offsets[len(self.offsets) - 1]
        self.offsets.append(last)
        self.nulls.append(True)

    def close_row(mut self, n_added: Int32):
        var last = self.offsets[len(self.offsets) - 1]
        self.offsets.append(last + n_added)
        self.nulls.append(False)

    def _has_any_nulls(self) -> Bool:
        for i in range(len(self.nulls)):
            if self.nulls[i]:
                return True
        return False

    def build_column(var self) raises -> Column[HeapRegion]:
        var child_col = _scalar_child_column(
            self.inner_arrow_type,
            self.child_int_vals,
            self.child_float_vals,
            self.child_bool_vals,
            self.child_string_vals,
            self.child_date_vals,
            self.child_nulls,
            "_ListAcc.build_column: unsupported inner arrow_type ",
        )

        var n_rows = len(self.nulls)
        # Build offsets buffer: (n_rows + 1) * Int32.
        comptime int32_size = size_of[Int32]()
        var off_bytes = (n_rows + 1) * int32_size
        var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
        for i in range(n_rows + 1):
            off_buf.set_typed[Int32](i, self.offsets[i])
        off_buf.set_length(Int64(off_bytes))


        var validity = Optional[Bitmap[HeapRegion]](None)
        var null_count = 0
        if self._has_any_nulls():
            var bm = Bitmap.create_all_valid(n_rows)
            for i in range(n_rows):
                if self.nulls[i]:
                    bm.clear(i)
                    null_count += 1
            validity = bm^

        var la = ListArray[HeapRegion](
            offsets=off_buf^,
            child=child_col^,
            validity=validity^,
            length=n_rows,
            null_count=null_count,
        )
        return Column.from_list(la)


@fieldwise_init
struct _StructAcc(Copyable, Movable):
    """Accumulator for a STRUCT<fields...> column.

    Holds per-row nulls + per-CHILD parallel value lists. Child arrow
    types are stored in `child_arrow_types`; child names in
    `child_names`. Five parallel lists hold value accumulators per
    inner type; one of the lists is populated per child per row.

    For N child fields and R rows, len(child_X_vals[c]) == R for the
    child at index c. The 5 lists per child are PARALLEL across types
    — only the one matching `child_arrow_types[c]` is populated.
    """

    var nulls: List[Bool]
    var child_names: List[String]
    var child_arrow_types: List[ArrowType]
    var child_int_vals: List[List[Int64]]
    var child_float_vals: List[List[Float64]]
    var child_bool_vals: List[List[Bool]]
    var child_string_vals: List[List[String]]
    var child_date_vals: List[List[Int32]]
    var child_nulls: List[List[Bool]]

    @staticmethod
    def create_for(field: Field) raises -> _StructAcc:
        var n_children = field.num_children()
        var names = List[String]()
        var ats = List[ArrowType]()
        var c_int = List[List[Int64]]()
        var c_float = List[List[Float64]]()
        var c_bool = List[List[Bool]]()
        var c_string = List[List[String]]()
        var c_date = List[List[Int32]]()
        var c_nulls = List[List[Bool]]()
        for i in range(n_children):
            names.append(field.child_name(i))
            ats.append(field.child_arrow_type(i))
            c_int.append(List[Int64]())
            c_float.append(List[Float64]())
            c_bool.append(List[Bool]())
            c_string.append(List[String]())
            c_date.append(List[Int32]())
            c_nulls.append(List[Bool]())
        return _StructAcc(
            nulls=List[Bool](),
            child_names=names^,
            child_arrow_types=ats^,
            child_int_vals=c_int^,
            child_float_vals=c_float^,
            child_bool_vals=c_bool^,
            child_string_vals=c_string^,
            child_date_vals=c_date^,
            child_nulls=c_nulls^,
        )

    def push_null_row(mut self):
        # Append a row to every child accumulator (as null) AND mark the
        # parent row null.
        var n_children = len(self.child_names)
        for c in range(n_children):
            var at = self.child_arrow_types[c]
            if at == ArrowType.INT64:
                self.child_int_vals[c].append(Int64(0))
            elif at == ArrowType.FLOAT64:
                self.child_float_vals[c].append(Float64(0.0))
            elif at == ArrowType.BOOL:
                self.child_bool_vals[c].append(False)
            elif at == ArrowType.STRING:
                self.child_string_vals[c].append(String(""))
            elif at == ArrowType.DATE32:
                self.child_date_vals[c].append(Int32(0))
            self.child_nulls[c].append(True)
        self.nulls.append(True)

    def close_valid_row(mut self):
        # parse_struct_one_value has already appended a value per child.
        # Just mark the parent valid.
        self.nulls.append(False)

    def _has_any_nulls(self) -> Bool:
        for i in range(len(self.nulls)):
            if self.nulls[i]:
                return True
        return False

    def build_column(var self) raises -> Column[HeapRegion]:
        var n_children = len(self.child_names)
        var n_rows = len(self.nulls)
        # Build child Columns.
        var children = Slab[Column[HeapRegion]].create(n_children)
        for c in range(n_children):
            var child_col = _scalar_child_column(
                self.child_arrow_types[c],
                self.child_int_vals[c],
                self.child_float_vals[c],
                self.child_bool_vals[c],
                self.child_string_vals[c],
                self.child_date_vals[c],
                self.child_nulls[c],
                "_StructAcc.build_column: unsupported child arrow_type ",
            )
            children.append(child_col^)

        var validity = Optional[Bitmap[HeapRegion]](None)
        var null_count = 0
        if self._has_any_nulls():
            var bm = Bitmap.create_all_valid(n_rows)
            for i in range(n_rows):
                if self.nulls[i]:
                    bm.clear(i)
                    null_count += 1
            validity = bm^

        var sa = StructArray._build(
            self.child_names, n_children, n_rows, children^, validity^, null_count
        )
        return Column.from_struct(sa^)


@fieldwise_init
struct _MapAcc(Copyable, Movable):
    """Accumulator for a MAP<STRING, value> column.

    Keys are STRING (Arrow Map spec). Value arrow type is one of the
    scalar types (INT64 / FLOAT64 / BOOL / STRING / DATE32).
    Holds per-row offsets + nulls + flat keys + flat value accumulators
    (five parallel lists, one populated per `value_arrow_type`).
    """

    var offsets: List[Int32]
    var nulls: List[Bool]
    var value_arrow_type: ArrowType
    var keys_acc: List[String]
    var value_int_vals: List[Int64]
    var value_float_vals: List[Float64]
    var value_bool_vals: List[Bool]
    var value_string_vals: List[String]
    var value_date_vals: List[Int32]
    var value_nulls: List[Bool]

    @staticmethod
    def create_for(value_at: ArrowType) -> _MapAcc:
        var offs = List[Int32]()
        offs.append(Int32(0))
        return _MapAcc(
            offsets=offs^,
            nulls=List[Bool](),
            value_arrow_type=value_at,
            keys_acc=List[String](),
            value_int_vals=List[Int64](),
            value_float_vals=List[Float64](),
            value_bool_vals=List[Bool](),
            value_string_vals=List[String](),
            value_date_vals=List[Int32](),
            value_nulls=List[Bool](),
        )

    def push_null(mut self):
        var last = self.offsets[len(self.offsets) - 1]
        self.offsets.append(last)
        self.nulls.append(True)

    def close_row(mut self, n_added: Int32):
        var last = self.offsets[len(self.offsets) - 1]
        self.offsets.append(last + n_added)
        self.nulls.append(False)

    def _has_any_nulls(self) -> Bool:
        for i in range(len(self.nulls)):
            if self.nulls[i]:
                return True
        return False

    def build_column(var self) raises -> Column[HeapRegion]:
        var n_rows = len(self.nulls)
        # Build keys column (STRING).
        var keys_arr = StringArray.from_strings(self.keys_acc)
        var keys_col = Column.from_string(keys_arr)

        # Build values column, with the null values' validity.
        var values_col = _scalar_child_column(
            self.value_arrow_type,
            self.value_int_vals,
            self.value_float_vals,
            self.value_bool_vals,
            self.value_string_vals,
            self.value_date_vals,
            self.value_nulls,
            "_MapAcc.build_column: unsupported value arrow_type ",
        )

        comptime int32_size = size_of[Int32]()
        var off_bytes = (n_rows + 1) * int32_size
        var off_buf = OwnedAlignedBuffer(max(off_bytes, 1))
        for i in range(n_rows + 1):
            off_buf.set_typed[Int32](i, self.offsets[i])
        off_buf.set_length(Int64(off_bytes))


        var validity = Optional[Bitmap[HeapRegion]](None)
        var null_count = 0
        if self._has_any_nulls():
            var bm = Bitmap.create_all_valid(n_rows)
            for i in range(n_rows):
                if self.nulls[i]:
                    bm.clear(i)
                    null_count += 1
            validity = bm^

        var ma = MapArray[HeapRegion](
            offsets=off_buf^,
            keys=keys_col^,
            values=values_col^,
            validity=validity^,
            length=n_rows,
            null_count=null_count,
            keys_sorted=False,
        )
        return Column.from_map(ma)


@fieldwise_init
struct _Decimal128Acc(Copyable, Movable):
    """Accumulator for a DECIMAL128(precision, scale) column."""

    var values: List[SIMD[DType.int128, 1]]
    var nulls: List[Bool]
    var precision: Int
    var scale: Int

    @staticmethod
    def create_with_pscale(precision: Int, scale: Int) -> _Decimal128Acc:
        return _Decimal128Acc(
            values=List[SIMD[DType.int128, 1]](),
            nulls=List[Bool](),
            precision=precision,
            scale=scale,
        )

    def push_value(mut self, v: SIMD[DType.int128, 1]):
        self.values.append(v)
        self.nulls.append(False)

    def push_null(mut self):
        self.values.append(SIMD[DType.int128, 1](0))
        self.nulls.append(True)

    def build_column(var self) raises -> Column[HeapRegion]:
        var n = len(self.values)
        var arr = Decimal128Array.from_i128_list(self.values, self.precision, self.scale)
        # propagate per-row nulls into Decimal128Array validity.
        for i in range(n):
            if self.nulls[i]:
                arr.set_null(i)
        return Column.from_decimal128(arr^)


# =============================================================================
# Materialization driver
# =============================================================================


@fieldwise_init
struct ColumnarMaterializer(Movable):
    """A struct-shaped Stage 2 driver that reads no rows: it has only
    `init_for_schema`, which builds the key table, the column-kind tags and
    an empty INT64, BOOL and STRING accumulator per column. No method feeds it an
    object or builds a batch from it; read JSONL with the free function
    `materialize_jsonl_to_batch` (or its parallel variants).

    `init_for_schema` accepts INT64, BOOL and STRING columns and raises on
    any other type, naming `materialize_jsonl_to_batch`, which covers the
    full type set.
    """

    var schema: Schema
    var key_table: KeyTable
    # Column-kind tags: one per schema field. 0=INT64, 1=BOOL, 2=STRING.
    # (The free-function path extends this with FLOAT64=3, DECIMAL128=4, etc.)
    var col_kinds: List[UInt8]
    # Per-column accumulators. The index into each list is the column
    # position in the schema. Only the accumulator matching the kind is
    # populated; others are empty placeholders.
    var int_accs: List[_Int64Acc]
    var bool_accs: List[_BoolAcc]
    var string_accs: List[_StringAcc]
    var row_count: Int

    @staticmethod
    def init_for_schema(var schema: Schema) raises -> ColumnarMaterializer:
        """Build a materializer for the given schema. Each column gets one
        accumulator of the matching kind.

        Raises if the schema includes a column type this struct does not
        support (FLOAT64, DECIMAL128, DATE32, LIST, STRUCT, MAP) — the
        error message points at `materialize_jsonl_to_batch`."""
        # The streaming-shaped materializer struct is INTENTIONALLY a
        # stub. All reads route through the free-function
        # `materialize_jsonl_to_batch` below, which uses local-var
        # accumulators (no struct-takeout-from-List complexity).
        var n = schema.num_columns()
        var col_kinds = List[UInt8](capacity=n)
        var int_accs = List[_Int64Acc](capacity=n)
        var bool_accs = List[_BoolAcc](capacity=n)
        var string_accs = List[_StringAcc](capacity=n)
        var field_names = List[String](capacity=n)
        for i in range(n):
            var at = schema.field_arrow_type(i)
            field_names.append(String(schema.field_name(i)))
            int_accs.append(_Int64Acc.create())
            bool_accs.append(_BoolAcc.create())
            string_accs.append(_StringAcc.create())
            if at == ArrowType.INT64:
                col_kinds.append(UInt8(0))
            elif at == ArrowType.BOOL:
                col_kinds.append(UInt8(1))
            elif at == ArrowType.STRING:
                col_kinds.append(UInt8(2))
            else:
                raise Error(
                    "ColumnarMaterializer.init_for_schema: column '"
                    + schema.field_name(i)
                    + "' has Arrow type "
                    + String(Int(at.type_id))
                    + " which is not supported by the streaming-struct"
                    + " shape. Use the free-function"
                    + " `materialize_jsonl_to_batch` for the full type set."
                )
        var key_table = KeyTable.from_field_names(field_names^)
        return ColumnarMaterializer(
            schema=schema^,
            key_table=key_table^,
            col_kinds=col_kinds^,
            int_accs=int_accs^,
            bool_accs=bool_accs^,
            string_accs=string_accs^,
            row_count=0,
        )

    # NOTE: the streaming builder method `build_batch(var self) -> RecordBatch`
    # is INTENTIONALLY UNIMPLEMENTED. Constructing one Column per
    # column accumulator requires per-accumulator takeout from a
    # `List[_Int64Acc | _BoolAcc | _StringAcc]` of NON-Copyable element
    # types (the accumulators own `List[String]` heaps that cannot be
    # cheaply duplicated). `List.pop(i)` shifts the tail, which
    # complicates lockstep parallel-list takeout. The simpler free-function
    # `materialize_jsonl_to_batch` below owns its accumulators as local
    # `var`s and pops them in reverse at the build step. A struct-shaped
    # streaming driver is only needed when chunked-batch emit (a row limit
    # per batch) requires multi-call assembly.


# =============================================================================
# Free-function variant — the surface for read_json_batch
# =============================================================================
#
# Rather than wrestle with the List-of-non-Copyable accumulator takeout
# pattern (which Mojo makes awkward), expose a free-function
# variant that owns its accumulators as local `var`s and emits the
# RecordBatch directly. The struct-shaped driver above is reserved for
# a streaming path that needs to chunk batches across many
# top-level records.


def materialize_jsonl_to_batch(
    bytes: Span[UInt8, _],
    var schema: Schema,
) raises -> RecordBatch:
    """Single-pass JSONL → RecordBatch materializer.

    Builds the Stage-1 structural index over `bytes`, then delegates to
    the index-accepting overload. Use that overload directly when the
    index has ALREADY been built (e.g. by the schema inferrer) to avoid
    a second full-file Stage-1 SIMD pass."""
    var no_prefix = List[UInt8]()
    var idx = build_jsonl_index(bytes, no_prefix, 0)
    return materialize_jsonl_to_batch(bytes, schema^, idx)


def materialize_jsonl_to_batch(
    bytes: Span[UInt8, _],
    var schema: Schema,
    ref idx: StructuralIndex,
) raises -> RecordBatch:
    """Single-pass JSONL → RecordBatch materializer over an ALREADY-built
    structural index.

    Every line of `bytes` must be blank (skipped) or hold exactly one JSON
    object (RFC 8259); anything else raises `komira_jsonl: line N: ...`
    before any row is built, so the input is read whole or not at all
    (`line_check.mojo`). A key the schema reads may appear once per object:
    a repeat raises. That covers top-level columns and STRUCT children;
    keys inside a MAP value are its entries, kept in order, repeats
    included. Keys are compared as the text they spell (escapes decoded).
    Keys the schema does not read are skipped unread with their values,
    repeated or not, at top level and inside a STRUCT. Every error raised
    while reading a row names the row's line. One empty record per `{}`
    line: with a schema of no fields (inferred from `{}` lines, or given),
    the batch has no column and one row per object."""
    var no_prefix = List[UInt8]()
    return _materialize_checked(bytes, schema^, idx, no_prefix, 0)


def _materialize_checked(
    bytes: Span[UInt8, _],
    var schema: Schema,
    ref idx: StructuralIndex,
    before: Span[UInt8, _],
    lines_before: Int,
) raises -> RecordBatch:
    """`materialize_jsonl_to_batch` over `bytes`, a slice of a larger input:
    `before` is the bytes of that input preceding the slice (a parallel
    partition passes them) and `lines_before` the lines preceding those (a
    streaming chunk passes its count); both only number the line of an
    error and are read only when there is one."""
    check_jsonl_lines(bytes, idx, before, lines_before)
    # The byte offset of the `{` of the row being read, or -1 before the
    # first row: an error raised while reading a row is re-raised naming
    # the row's line.
    var row_start = -1
    try:
        return _walk_jsonl_rows(bytes, schema^, idx, row_start)
    except e:
        if row_start < 0:
            raise e^
        var line = (
            lines_before + count_lf(before) + count_lf(bytes[:row_start]) + 1
        )
        raise Error(
            String("komira_jsonl: line ") + String(line) + ": " + String(e)
        )


def _walk_jsonl_rows(
    bytes: Span[UInt8, _],
    var schema: Schema,
    ref idx: StructuralIndex,
    mut row_start: Int,
) raises -> RecordBatch:
    """The row walk of `materialize_jsonl_to_batch`, over a tape
    `check_jsonl_lines` has passed. Sets `row_start` to the byte offset of
    each row's `{` as it starts the row, and back to -1 once the rows are
    read.

    Reads `bytes` (a complete JSONL byte stream — one `{...}` per line,
    `\\n`-separated) using the caller-provided `idx` and produces ONE
    RecordBatch matching `schema`. Supports the type set
    (INT64 / BOOL / STRING / FLOAT64 / DATE32 / DECIMAL128 / LIST /
    STRUCT / MAP); raises on any other schema type.

    The `idx` is taken by `ref` — NO copy of the (large) offsets/tags
    Lists. Threading the inferrer's index in here is what eliminates a
    second full-file Stage-1 walk on the read path.

    Algorithm:
      1. Walk the structural-token tape, one top-level object at a time.
      2. For each (key, value) pair inside the object: look up the key
         in the schema's key table; if found, parse the value with the
         per-column-kind parser; append to the matching accumulator.
         Keys not in the schema are SKIPPED.
      3. After the last object, build columns from each accumulator
         and assemble into the final RecordBatch.

    Raises on:
      * A key the schema reads repeated in one object.
      * A JSON `null`, or an object without the key, for a NOT NULL field
        (a nullable field reads both as NULL).
      * Schema column type outside the supported set.
      * Per-value parse errors (overflow, bad bool literal, ...).
    """
    var n = schema.num_columns()
    # HOSTILE-INPUT CEILING (ASSERT=none hardening). The loop
    # below eagerly constructs NINE accumulator structs per column regardless
    # of the column's actual kind, and the end-of-object loop pushes exactly
    # one value-or-null into EVERY column for EVERY row. Allocation is
    # therefore rows x cols, NOT rows x populated-cells — quadratic in two
    # quantities the input controls. Checked HERE, before the first
    # allocation, which is the only place the check is free.
    check_json_column_count(n)
    # Row ceiling implied by the cell budget, which is stated PER INPUT BYTE:
    # the invariant that was broken is "allocation is O(input bytes)", and a
    # column cap alone does not restore it (4096 cols x 349k rows of `{}` from
    # a 1 MB file is still 1.4e9 cells). Computed ONCE; the row loop compares
    # against it with a single Int compare (no divide, no multiply).
    var max_rows = max_rows_for_columns(n, len(bytes))

    # Build per-column accumulators as local vars (no List-of-non-Copyable
    # gymnastics).
    var int_accs = List[_Int64Acc](capacity=n)
    var bool_accs = List[_BoolAcc](capacity=n)
    var string_accs = List[_StringAcc](capacity=n)
    var float_accs = List[_Float64Acc](capacity=n)
    var date_accs = List[_Date32Acc](capacity=n)
    var dec_accs = List[_Decimal128Acc](capacity=n)
    # Nested accumulators. One slot per schema column; only the slot
    # matching this column's kind is populated, others remain at
    # placeholder ".create_for(INT64)" / etc. defaults.
    var list_accs = List[_ListAcc](capacity=n)
    var struct_accs = List[_StructAcc](capacity=n)
    var map_accs = List[_MapAcc](capacity=n)
    # Column kind: 0=INT64, 1=BOOL, 2=STRING, 3=FLOAT64, 4=DATE32,
    # 5=DECIMAL128, 6=LIST, 7=STRUCT, 8=MAP.
    var col_kinds = List[UInt8](capacity=n)
    var field_names = List[String](capacity=n)
    # A NOT NULL field refuses a JSON `null` and an object without its key
    # (both read as NULL in a nullable field): it never holds a NULL.
    var col_nullable = List[Bool](capacity=n)
    for i in range(n):
        var at = schema.field_arrow_type(i)
        var fld = schema.field_at_unchecked(i)
        field_names.append(String(schema.field_name(i)))
        col_nullable.append(schema.field_nullable(i))
        int_accs.append(_Int64Acc.create())
        bool_accs.append(_BoolAcc.create())
        string_accs.append(_StringAcc.create())
        float_accs.append(_Float64Acc.create())
        date_accs.append(_Date32Acc.create())
        # Default decimal pscale; overridden below when the column IS DECIMAL128.
        dec_accs.append(_Decimal128Acc.create_with_pscale(1, 0))
        # Placeholder nested accs (overridden in-place below for matching kinds).
        list_accs.append(_ListAcc.create_for(ArrowType.INT64))
        struct_accs.append(_StructAcc.create_for(Field(String(""), ArrowType.STRUCT, True)))
        map_accs.append(_MapAcc.create_for(ArrowType.INT64))
        if at == ArrowType.INT64:
            col_kinds.append(UInt8(0))
        elif at == ArrowType.BOOL:
            col_kinds.append(UInt8(1))
        elif at == ArrowType.STRING:
            col_kinds.append(UInt8(2))
        elif at == ArrowType.FLOAT64:
            col_kinds.append(UInt8(3))
        elif at == ArrowType.DATE32:
            col_kinds.append(UInt8(4))
        elif at == ArrowType.DECIMAL128:
            # Read precision + scale from the field's decimal_precision /
            # decimal_scale. A precision below 1 reads as 18 and a negative scale
            # as 4; a field built without decimal metadata
            # (`Field(name, DECIMAL128, ...)`) has precision 0 and scale 0,
            # so it reads as DECIMAL128(18, 0).
            var p = fld.decimal_precision if fld.decimal_precision > 0 else 18
            var s = fld.decimal_scale if fld.decimal_scale >= 0 else 4
            dec_accs[i] = _Decimal128Acc.create_with_pscale(p, s)
            col_kinds.append(UInt8(5))
        elif at == ArrowType.LIST:
            # Inner type from child Field 0.
            if fld.num_children() != 1:
                raise Error(
                    "materialize_jsonl_to_batch: LIST column '"
                    + schema.field_name(i)
                    + "' must have exactly 1 child Field for the inner"
                    + " type (got " + String(fld.num_children()) + "). Use"
                    + " Field.list_of_string or add_child to declare it."
                )
            var inner_at = fld.child_arrow_type(0)
            list_accs[i] = _ListAcc.create_for(inner_at)
            col_kinds.append(UInt8(6))
        elif at == ArrowType.STRUCT:
            if fld.num_children() < 1:
                raise Error(
                    "materialize_jsonl_to_batch: STRUCT column '"
                    + schema.field_name(i)
                    + "' must have at least 1 child Field"
                )
            struct_accs[i] = _StructAcc.create_for(fld)
            col_kinds.append(UInt8(7))
        elif at == ArrowType.MAP:
            # MAP has 1 child Field per Arrow spec — the value type.
            # (Keys are always STRING.)
            if fld.num_children() != 1:
                raise Error(
                    "materialize_jsonl_to_batch: MAP column '"
                    + schema.field_name(i)
                    + "' must have exactly 1 child Field for the value"
                    + " type (got " + String(fld.num_children()) + ")"
                )
            var value_at = fld.child_arrow_type(0)
            map_accs[i] = _MapAcc.create_for(value_at)
            col_kinds.append(UInt8(8))
        else:
            raise Error(
                "materialize_jsonl_to_batch: column '"
                + schema.field_name(i)
                + "' has Arrow type "
                + String(Int(at.type_id))
                + " not supported (supported: INT64 / BOOL / STRING /"
                + " FLOAT64 / DATE32 / DECIMAL128 / LIST / STRUCT / MAP)."
            )

    var key_table = KeyTable.from_field_names(field_names^)

    # Stage 1 structural index is caller-provided (built once by the
    # inferrer, threaded in here — no second full-file SIMD pass).
    var tape_len = idx.size()
    var input_len = len(bytes)

    # Walk the tape: each top-level object is OPEN_BRACE ... CLOSE_BRACE.
    var t: Int = 0
    var row_count: Int = 0
    # `per_row_seen` is allocated ONCE outside the row loop and reset to
    # all-False at the start of each object, rather than a fresh
    # `List[Bool]` heap alloc per row.
    var per_row_seen = List[Bool](capacity=n)
    for _ in range(n):
        per_row_seen.append(False)
    # The decoded spelling of a key that holds an escape, reused per key.
    var key_buf = List[UInt8]()
    while t < tape_len:
        # Find next OPEN_BRACE.
        if idx.tags[t] != TAG_OPEN_BRACE:
            # Unreachable on a tape `check_jsonl_lines` passed (every
            # top-level token is a `{`); kept so the walk never reads past a
            # token it does not understand.
            t += 1
            continue
        row_start = Int(idx.offsets[t])
        # Walk this object: reset the reused seen-flags to all-False.
        for c in range(n):
            per_row_seen[c] = False
        t += 1  # consume OPEN_BRACE
        while t < tape_len:
            var tag = idx.tags[t]
            if tag == TAG_CLOSE_BRACE:
                # End of object.
                t += 1
                break
            if tag == TAG_COMMA:
                t += 1
                continue
            if tag != TAG_QUOTE_OPEN:
                raise Error(
                    "materialize_jsonl_to_batch: expected TAG_QUOTE_OPEN at"
                    " tape position " + String(t) + ", got tag=" + String(Int(tag))
                )
            var quote_open_offset = Int(idx.offsets[t])
            t += 1
            # Find matching TAG_QUOTE_CLOSE.
            if t >= tape_len or idx.tags[t] != TAG_QUOTE_CLOSE:
                raise Error(
                    "materialize_jsonl_to_batch: missing TAG_QUOTE_CLOSE for key at byte "
                    + String(quote_open_offset)
                )
            var quote_close_offset = Int(idx.offsets[t])
            t += 1
            # Key bytes are between the quote bytes (exclusive of both).
            var key_start = quote_open_offset + 1
            var key_end = quote_close_offset
            # Walk key bytes — copy into a Span via input[].
            # A key is looked up as the text it spells (key_unescape.mojo):
            # raw bytes when it has no backslash, decoded otherwise.
            var col_idx: Int
            if key_has_escape(bytes[key_start:key_end]):
                unescape_key(bytes[key_start:key_end], key_buf)
                col_idx = key_table.lookup(key_buf)
            else:
                col_idx = key_table.lookup(bytes[key_start:key_end])
            # DUPLICATE KEY. A key the schema reads, seen twice in one
            # object, would push two values into its column for one row
            # (the column then outgrows the row count and every later row
            # is shifted). Refused, not first- or last-wins: neither value
            # is the record's, and komira_json, which keeps both in order,
            # has no single-value answer to match. Keys are compared as
            # the text they spell (decoded above).
            if col_idx >= 0 and per_row_seen[col_idx]:
                raise Error(
                    "duplicate key '" + schema.field_name(col_idx)
                    + "' in one object (a key the schema reads may appear once)"
                )
            # Expect colon next.
            if t >= tape_len or idx.tags[t] != TAG_COLON:
                raise Error(
                    "materialize_jsonl_to_batch: expected TAG_COLON after key at byte "
                    + String(quote_open_offset)
                )
            var colon_offset = Int(idx.offsets[t])
            t += 1
            # Dispatch on value: peek next tag.
            if t >= tape_len:
                raise Error("materialize_jsonl_to_batch: truncated input (expected value after colon)")
            var value_tag = idx.tags[t]
            if value_tag == TAG_QUOTE_OPEN:
                # STRING value.
                var v_start = Int(idx.offsets[t])
                t += 1
                if t >= tape_len or idx.tags[t] != TAG_QUOTE_CLOSE:
                    raise Error(
                        "materialize_jsonl_to_batch: missing TAG_QUOTE_CLOSE for string value at byte "
                        + String(v_start)
                    )
                var v_end = Int(idx.offsets[t])
                t += 1
                if col_idx >= 0:
                    var kk = col_kinds[col_idx]
                    # Detect escapes by scanning for '\\' within the byte range.
                    # Note: Stage 1 produces an unescaped-quote mask
                    # internally but doesn't expose has_escapes per emit;
                    # we scan here (cheap for short strings).
                    var has_escapes = False
                    for j in range(v_start + 1, v_end):
                        if bytes[j] == UInt8(0x5C):
                            has_escapes = True
                            break
                    if kk == UInt8(2):
                        # STRING column. The no-escape
                        # hot path streams the raw byte span straight into
                        # the Arrow builder (one memcpy, no `String` alloc).
                        # The rare escaped path still decodes into a `String`
                        # then pushes its bytes (correctness over the alloc).
                        if has_escapes:
                            var s = parse_string_with_escapes(bytes, v_start + 1, v_end)
                            string_accs[col_idx].push_bytes(s.as_bytes())
                        else:
                            string_accs[col_idx].push_bytes(bytes[v_start + 1:v_end])
                        per_row_seen[col_idx] = True
                    elif kk == UInt8(4):
                        # DATE32 column — JSON string "YYYY-MM-DD".
                        var d = parse_date32(bytes, v_start + 1, v_end)
                        date_accs[col_idx].push_value(d)
                        per_row_seen[col_idx] = True
                    elif kk == UInt8(5):
                        # DECIMAL128 — JSON string "123.45" form.
                        var prec = dec_accs[col_idx].precision
                        var scl = dec_accs[col_idx].scale
                        var v = parse_decimal128_unscaled(bytes, v_start + 1, v_end, prec, scl)
                        dec_accs[col_idx].push_value(v)
                        per_row_seen[col_idx] = True
                    else:
                        raise Error(
                            "materialize_jsonl_to_batch: key '"
                            + schema.field_name(col_idx)
                            + "' has a non-string Arrow type but JSON value is String. (Int/Float/Bool columns require unquoted scalars; Date/Decimal accept either string-form or scalar-form depending on schema.)"
                        )
            elif value_tag == TAG_OPEN_BRACE or value_tag == TAG_OPEN_BRACKET:
                # Nested object / array. Dispatches to parse_struct /
                # parse_list / parse_map when the column is one of the
                # nested types. Unknown columns or type-mismatched columns
                # fall back to depth-counter skip.
                if col_idx >= 0:
                    var kk = col_kinds[col_idx]
                    if kk == UInt8(6) and value_tag == TAG_OPEN_BRACKET:
                        # LIST column.
                        var inner_at = list_accs[col_idx].inner_arrow_type
                        var n_added = parse_list_one_value(
                            bytes, idx, t, inner_at,
                            list_accs[col_idx].child_int_vals,
                            list_accs[col_idx].child_float_vals,
                            list_accs[col_idx].child_bool_vals,
                            list_accs[col_idx].child_string_vals,
                            list_accs[col_idx].child_date_vals,
                            list_accs[col_idx].child_nulls,
                            1,
                        )
                        list_accs[col_idx].close_row(n_added)
                        per_row_seen[col_idx] = True
                    elif kk == UInt8(7) and value_tag == TAG_OPEN_BRACE:
                        # STRUCT column.
                        _ = parse_struct_one_value(
                            bytes, idx, t,
                            struct_accs[col_idx].child_names,
                            struct_accs[col_idx].child_arrow_types,
                            struct_accs[col_idx].child_int_vals,
                            struct_accs[col_idx].child_float_vals,
                            struct_accs[col_idx].child_bool_vals,
                            struct_accs[col_idx].child_string_vals,
                            struct_accs[col_idx].child_date_vals,
                            struct_accs[col_idx].child_nulls,
                            1,
                        )
                        struct_accs[col_idx].close_valid_row()
                        per_row_seen[col_idx] = True
                    elif kk == UInt8(8) and value_tag == TAG_OPEN_BRACE:
                        # MAP column.
                        var value_at = map_accs[col_idx].value_arrow_type
                        var n_added = parse_map_one_value(
                            bytes, idx, t, value_at,
                            map_accs[col_idx].keys_acc,
                            map_accs[col_idx].value_int_vals,
                            map_accs[col_idx].value_float_vals,
                            map_accs[col_idx].value_bool_vals,
                            map_accs[col_idx].value_string_vals,
                            map_accs[col_idx].value_date_vals,
                            map_accs[col_idx].value_nulls,
                            1,
                        )
                        map_accs[col_idx].close_row(n_added)
                        per_row_seen[col_idx] = True
                    else:
                        raise Error(
                            "materialize_jsonl_to_batch: key '"
                            + schema.field_name(col_idx)
                            + "' got a nested JSON value but the schema's Arrow type"
                            + " (kind " + String(Int(kk)) + ") is not LIST/STRUCT/MAP."
                            + " Did you forget to declare child Fields?"
                        )
                else:
                    # Key not in schema — skip-walk the nested value via
                    # depth counter.
                    var depth: Int = 1
                    t += 1
                    while t < tape_len and depth > 0:
                        var tg = idx.tags[t]
                        if tg == TAG_OPEN_BRACE or tg == TAG_OPEN_BRACKET:
                            depth += 1
                        elif tg == TAG_CLOSE_BRACE or tg == TAG_CLOSE_BRACKET:
                            depth -= 1
                        t += 1
            else:
                # Scalar value — number / true / false / null. The
                # value bytes are at colon_offset+1 .. next-structural-1
                # (skipping whitespace at both ends).
                # Find end-of-scalar = next tape position's offset, or
                # end-of-input.
                var next_tape_pos: Int
                if t < tape_len:
                    next_tape_pos = Int(idx.offsets[t])
                else:
                    next_tape_pos = input_len
                # Scalar bytes are colon_offset+1 .. next_tape_pos.
                # Trim whitespace at start.
                var s_start = colon_offset + 1
                while s_start < next_tape_pos and _is_ws(bytes[s_start]):
                    s_start += 1
                var s_end = next_tape_pos
                while s_end > s_start and _is_ws(bytes[s_end - 1]):
                    s_end -= 1
                if s_end <= s_start:
                    raise Error("materialize_jsonl_to_batch: empty scalar value after key at byte " + String(quote_open_offset))
                # Dispatch on the column kind.
                if col_idx >= 0:
                    var kind = col_kinds[col_idx]
                    # Check for explicit "null" first — affects validity.
                    if (s_end - s_start) == 4 and bytes[s_start] == UInt8(0x6E):
                        parse_null(bytes, s_start, s_end)
                        if not col_nullable[col_idx]:
                            raise Error(
                                "NOT NULL field '" + schema.field_name(col_idx)
                                + "' holds JSON null"
                            )
                        if kind == UInt8(0):
                            int_accs[col_idx].push_null()
                        elif kind == UInt8(1):
                            bool_accs[col_idx].push_null()
                        elif kind == UInt8(2):
                            string_accs[col_idx].push_null()
                        elif kind == UInt8(3):
                            float_accs[col_idx].push_null()
                        elif kind == UInt8(4):
                            date_accs[col_idx].push_null()
                        elif kind == UInt8(5):
                            dec_accs[col_idx].push_null()
                        elif kind == UInt8(6):
                            list_accs[col_idx].push_null()
                        elif kind == UInt8(7):
                            struct_accs[col_idx].push_null_row()
                        elif kind == UInt8(8):
                            map_accs[col_idx].push_null()
                        per_row_seen[col_idx] = True
                    elif kind == UInt8(0):
                        # INT64.
                        var v = parse_int_i64(bytes, s_start, s_end)
                        int_accs[col_idx].push_value(v)
                        per_row_seen[col_idx] = True
                    elif kind == UInt8(1):
                        # BOOL.
                        var v = parse_bool(bytes, s_start, s_end)
                        bool_accs[col_idx].push_value(v)
                        per_row_seen[col_idx] = True
                    elif kind == UInt8(3):
                        # FLOAT64.
                        var v = parse_float_f64(bytes, s_start, s_end)
                        float_accs[col_idx].push_value(v)
                        per_row_seen[col_idx] = True
                    elif kind == UInt8(5):
                        # DECIMAL128 — accept unquoted JSON number form.
                        var prec = dec_accs[col_idx].precision
                        var scl = dec_accs[col_idx].scale
                        var v = parse_decimal128_unscaled(bytes, s_start, s_end, prec, scl)
                        dec_accs[col_idx].push_value(v)
                        per_row_seen[col_idx] = True
                    elif kind == UInt8(2):
                        # STRING column with a bare numeric / bool / null
                        # value? Reject — JSON Spec forbids unquoted
                        # string (a lenient policy is possible future
                        # work).
                        raise Error(
                            "materialize_jsonl_to_batch: STRING column '"
                            + schema.field_name(col_idx)
                            + "' but value is unquoted scalar at byte "
                            + String(s_start)
                        )
                    elif kind == UInt8(4):
                        # DATE32 — typed columns require quoted string form.
                        raise Error(
                            "materialize_jsonl_to_batch: DATE32 column '"
                            + schema.field_name(col_idx)
                            + "' expects a quoted ISO 8601 string \"YYYY-MM-DD\" but value is unquoted at byte "
                            + String(s_start)
                        )
                    else:
                        # LIST / STRUCT / MAP (kinds 6, 7, 8) given a number
                        # or literal: refused, as an unquoted value for a
                        # STRING or DATE32 column is (it is not a NULL).
                        var name = String("LIST")
                        var want = String("array")
                        if kind == UInt8(7):
                            name = String("STRUCT")
                            want = String("object")
                        elif kind == UInt8(8):
                            name = String("MAP")
                            want = String("object")
                        raise Error(
                            "materialize_jsonl_to_batch: " + name + " column '" + schema.field_name(col_idx)
                            + "' expects a JSON " + want
                            + " but value is a scalar at byte " + String(s_start)
                        )
                # (col_idx < 0 → skip; nothing to push.)
        # End of one object — for any column NOT seen in this row,
        # push null.
        for c in range(n):
            if not per_row_seen[c]:
                if not col_nullable[c]:
                    raise Error(
                        "NOT NULL field '" + schema.field_name(c)
                        + "' has no key in the object"
                    )
                var kind = col_kinds[c]
                if kind == UInt8(0):
                    int_accs[c].push_null()
                elif kind == UInt8(1):
                    bool_accs[c].push_null()
                elif kind == UInt8(2):
                    string_accs[c].push_null()
                elif kind == UInt8(3):
                    float_accs[c].push_null()
                elif kind == UInt8(4):
                    date_accs[c].push_null()
                elif kind == UInt8(5):
                    dec_accs[c].push_null()
                elif kind == UInt8(6):
                    list_accs[c].push_null()
                elif kind == UInt8(7):
                    struct_accs[c].push_null_row()
                elif kind == UInt8(8):
                    map_accs[c].push_null()
        row_count += 1
        # Cell-budget ceiling (see `max_rows` above). One Int compare per
        # row, against a value computed once outside the loop.
        if row_count > max_rows:
            raise_json_cell_budget_exceeded(row_count, n, len(bytes))
    # The rows are read; an error from here on (building the columns)
    # belongs to no row, so it is not labelled with a line.
    row_start = -1

    # No columns (a schema with no fields, e.g. inferred from `{}` lines):
    # the batch carries the row count alone, one empty record per object.
    # The builder below would return 0 rows, having no column to count.
    if n == 0:
        var empty = RecordBatch.count_only(row_count)
        empty.schema = schema^
        return empty^

    # Assemble RecordBatch. Build columns by popping accumulators from
    # the front in lockstep across all 9 parallel acc lists (6 scalar +
    # 3 nested).
    var builder = RecordBatchBuilder.with_capacity(n)
    for i in range(n):
        var kind = col_kinds[i]
        # Pop one element from each parallel list.
        var ia = int_accs.pop(0)
        var ba = bool_accs.pop(0)
        var sa = string_accs.pop(0)
        var fa = float_accs.pop(0)
        var da = date_accs.pop(0)
        var dca = dec_accs.pop(0)
        var la = list_accs.pop(0)
        var stra = struct_accs.pop(0)
        var ma = map_accs.pop(0)
        if kind == UInt8(0):
            _ = ba^; _ = sa^; _ = fa^; _ = da^; _ = dca^
            _ = la^; _ = stra^; _ = ma^
            builder.add_column(ia^.build_column())
        elif kind == UInt8(1):
            _ = ia^; _ = sa^; _ = fa^; _ = da^; _ = dca^
            _ = la^; _ = stra^; _ = ma^
            builder.add_column(ba^.build_column())
        elif kind == UInt8(2):
            _ = ia^; _ = ba^; _ = fa^; _ = da^; _ = dca^
            _ = la^; _ = stra^; _ = ma^
            # INT32 OFFSET CEILING (ASSERT=none hardening).
            # `ArrowStringBuilder._append_offset` narrows with a bare
            # `Int32(len(self.data))`; past 2 GiB in one column of one batch
            # the offsets wrap NEGATIVE while the data buffer stays correctly
            # large, so the array ships with `offsets[i] < 0` and every
            # consumer doing `data[offsets[i]:offsets[i+1]]` reads BEFORE the
            # buffer. Checked ONCE per column here — the total is already
            # summed by build time, so nothing is re-walked and the per-value
            # push path is untouched.
            check_arrow_string_bytes(
                sa.builder.data_len(), String(schema.field_name(i))
            )
            builder.add_column(sa^.build_column())
        elif kind == UInt8(3):
            _ = ia^; _ = ba^; _ = sa^; _ = da^; _ = dca^
            _ = la^; _ = stra^; _ = ma^
            builder.add_column(fa^.build_column())
        elif kind == UInt8(4):
            _ = ia^; _ = ba^; _ = sa^; _ = fa^; _ = dca^
            _ = la^; _ = stra^; _ = ma^
            builder.add_column(da^.build_column())
        elif kind == UInt8(5):
            _ = ia^; _ = ba^; _ = sa^; _ = fa^; _ = da^
            _ = la^; _ = stra^; _ = ma^
            builder.add_column(dca^.build_column())
        elif kind == UInt8(6):
            # LIST.
            _ = ia^; _ = ba^; _ = sa^; _ = fa^; _ = da^; _ = dca^
            _ = stra^; _ = ma^
            builder.add_column(la^.build_column())
        elif kind == UInt8(7):
            # STRUCT.
            _ = ia^; _ = ba^; _ = sa^; _ = fa^; _ = da^; _ = dca^
            _ = la^; _ = ma^
            builder.add_column(stra^.build_column())
        else:
            # MAP (kind == 8).
            _ = ia^; _ = ba^; _ = sa^; _ = fa^; _ = da^; _ = dca^
            _ = la^; _ = stra^
            builder.add_column(ma^.build_column())
    return builder.build(schema^)


# =============================================================================
# Line-range parallel materializer.
# =============================================================================
#
# Shards the JSONL byte stream into N line-range partitions (no JSON record
# spans a worker boundary — see partition contract below) and decodes them
# in parallel via the komira_async fork-join helper. Each worker independently runs
# `build_structural_index` + `materialize_jsonl_to_batch` over its byte
# range into ITS OWN RecordBatch; the per-worker batches are concatenated
# via `_concat_variable_width_batches`.
#
# This mirrors the CSV parallel reader and the ORC column-parallel decode.
# The JSONL case is simpler than CSV's quoted-
# newline complication: in valid JSONL every *unescaped* `0x0A` is a record
# separator (literal newlines inside JSON strings must be escaped as `\n`),
# so a raw `0x0A` byte is ALWAYS a record boundary. The partition scan keys
# on raw `0x0A` directly.
#
# Partition contract (the disjointness key):
#   - Partition `w` is the half-open byte range `[lo_w, hi_w)`.
#   - `lo_0 = 0`; `lo_w` for w>0 = (byte AFTER the first `\n` at/after the
#     raw candidate offset `n*w/k`).
#   - `hi_w = lo_{w+1}` for w<k-1; `hi_{k-1} = n`.
#   - Every partition therefore begins exactly at the first byte of a JSON
#     record and ends just past a record-terminating `\n` (or at EOF). No
#     record straddles a boundary; each worker sees only whole records.
# =============================================================================


# Files smaller than this fall back to single-thread. Below ~4 MiB the
# partition + concat overhead exceeds the parallel materialize win.
comptime _MIN_PARALLEL_JSONL_BYTES: Int = 4 * 1024 * 1024  # 4 MiB

# Cap worker count. More than 32 workers rarely pays back the per-worker
# index-build cold-cache fill on this workload.
comptime _MAX_JSONL_WORKERS: Int = 32


def _compute_jsonl_line_ranges(
    bytes: Span[UInt8, _],
    n: Int,
    k_desired: Int,
    mut los: List[Int],
    mut his: List[Int],
):
    """Split `[0, n)` into ≤ `k_desired` line-range partitions aligned to
    `\\n` boundaries; populate `los` + `his` in place.

    For each candidate boundary `n*w/k_desired` (w in 1..k_desired-1),
    advance forward to the byte AFTER the next `0x0A`. Partition 0 starts
    at byte 0; the final partition ends at `n`. Consecutive boundaries that
    resolve to the same position are merged (drops empty partitions), so the
    returned `len(los) == len(his) <= k_desired` and always covers `[0, n)`.

    JSONL safety: a raw `0x0A` is unconditionally a record separator in valid
    JSONL (string-internal newlines are escaped), so no quote-context
    tracking is needed across boundaries — unlike CSV.
    """
    los.clear()
    his.clear()
    if k_desired <= 1 or n <= 0:
        los.append(0)
        his.append(n)
        return

    var boundaries = List[Int]()
    boundaries.append(0)
    var w = 1
    while w < k_desired:
        var candidate = (n * w) // k_desired
        var p = candidate
        var found = False
        while p < n:
            if bytes[p] == UInt8(0x0A):
                p = p + 1  # boundary = byte AFTER the newline
                found = True
                break
            p = p + 1
        if found:
            if p > boundaries[len(boundaries) - 1]:
                boundaries.append(p)
        w = w + 1
    boundaries.append(n)

    var b = 0
    while b + 1 < len(boundaries):
        var lo = boundaries[b]
        var hi = boundaries[b + 1]
        if hi > lo:
            los.append(lo)
            his.append(hi)
        b = b + 1


# =============================================================================
# Parallel JSONL materialize — fork-join work units (the komira_async
# fork-join helper).
#
# Two per-chunk work units, both producing one owned Optional[RecordBatch]
# per chunk into the helper's disjoint output Slab. The shared
# `parallel_fork_join` layer owns the dispatch safety contract ONCE
# (immutable-origin borrow, disjoint pre-sized Slab, Optional.take reclaim,
# first-error-wins re-raise, wake-word-barrier liveness). These units carry
# only the per-chunk byte-range materialize.
#
# DISPATCH-BOUNDARY SAFETY: the per-worker disjointness contract —
# chunk `c` reads ONLY `[los[c], his[c])` of the shared
# read-only byte stream (the partition contract makes these ranges disjoint
# and ordered) plus a per-chunk read-only StructuralIndex (with-partitions
# variant) or builds its own (build-index variant); writes ONLY its own
# Optional[RecordBatch] out_slot. The byte stream + schema + offset lists are
# borrowed read-only via the bundle's concrete IMMUTABLE origin; no wildcard.
# =============================================================================


@fieldwise_init
struct _JsonlMatInputWithIdx[byte_o: Origin[mut=False]](Deinitable):
    """Input bundle for the with-prebuilt-index materialize work unit. OWNS
    the schema + the whole JsonlPartitions (moved in); only the byte stream
    is borrowed (by the Span's own concrete immutable origin `byte_o` — NO
    wildcard). The helper borrows the whole bundle read-only; the synchronous
    wake-word barrier guarantees the byte pointer outlives every worker.

    # SAFETY: `byte_o` is CONCRETE (the caller's byte-stream origin). The
    # byte pointer is read-only and live for the synchronous dispatch; never
    # exposed publicly. All other fields are owned by the bundle.
    """

    var bytes_ptr: UnsafePointer[UInt8, Self.byte_o]
    var bytes_len: Int
    var schema: Schema
    var partitions: JsonlPartitions


@fieldwise_init
struct _JsonlMatInputBuildIdx[byte_o: Origin[mut=False]](
    Deinitable
):
    """Input bundle for the build-own-index materialize work unit (no
    prebuilt StructuralIndex; each worker builds its own over its slice).
    OWNS the schema + offset lists; only the byte stream is borrowed.

    # SAFETY: `byte_o` is CONCRETE. The byte pointer is read-only and live
    # for the synchronous dispatch; never exposed publicly.
    """

    var bytes_ptr: UnsafePointer[UInt8, Self.byte_o]
    var bytes_len: Int
    var schema: Schema
    var los: List[Int]
    var his: List[Int]


@fieldwise_init
struct _JsonlMatWithIdxWork[byte_o: Origin[mut=False]](ChunkWork):
    """Per-chunk materialize over a PRE-BUILT StructuralIndex. Reads chunk
    `chunk_id`'s byte range + index slot; writes the RecordBatch into
    `out_slot`."""

    var _pad: Int32

    def process[
        In: Deinitable, O: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut out_slot: Optional[O],
    ) raises:
        # SAFETY: the helper binds In=_JsonlMatInputWithIdx[byte_o],
        # O=RecordBatch at the parallel_fork_join[...] call site; the
        # bitcasts resolve to those concrete types. Internal to this module.
        var ip = UnsafePointer(to=input).bitcast[
            _JsonlMatInputWithIdx[Self.byte_o]
        ]()
        var lo = ip[].partitions.los[chunk_id]
        var hi = ip[].partitions.his[chunk_id]
        var slice = Span(unsafe_ptr=ip[].bytes_ptr + lo, length=hi - lo)
        ref idx = ip[].partitions.indices[chunk_id]
        # The bytes before this partition number an error's line.
        var before = Span(unsafe_ptr=ip[].bytes_ptr, length=lo)
        var batch = _materialize_checked(
            slice, ip[].schema.copy(), idx, before, 0
        )
        var op = UnsafePointer(to=out_slot).bitcast[Optional[RecordBatch]]()
        op[] = Optional[RecordBatch](batch^)


@fieldwise_init
struct _JsonlMatBuildIdxWork[byte_o: Origin[mut=False]](ChunkWork):
    """Per-chunk materialize that BUILDS its own StructuralIndex over its
    slice. Reads chunk `chunk_id`'s byte range; writes the RecordBatch into
    `out_slot`."""

    var _pad: Int32

    def process[
        In: Deinitable, O: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut out_slot: Optional[O],
    ) raises:
        # SAFETY: the helper binds In=_JsonlMatInputBuildIdx[byte_o],
        # O=RecordBatch at the parallel_fork_join[...] call site; the
        # bitcasts resolve to those concrete types. Internal to this module.
        var ip = UnsafePointer(to=input).bitcast[
            _JsonlMatInputBuildIdx[Self.byte_o]
        ]()
        var lo = ip[].los[chunk_id]
        var hi = ip[].his[chunk_id]
        var slice = Span(unsafe_ptr=ip[].bytes_ptr + lo, length=hi - lo)
        # The bytes before this partition number an error's line.
        var before = Span(unsafe_ptr=ip[].bytes_ptr, length=lo)
        var idx = build_jsonl_index(slice, before, 0)
        var batch = _materialize_checked(
            slice, ip[].schema.copy(), idx, before, 0
        )
        var op = UnsafePointer(to=out_slot).bitcast[Optional[RecordBatch]]()
        op[] = Optional[RecordBatch](batch^)


def materialize_jsonl_to_batch_parallel_with_partitions(
    bytes: Span[UInt8, _],
    var schema: Schema,
    var partitions: JsonlPartitions,
) raises -> RecordBatch:
    """Parallel materializer that REUSES the
    per-worker structural indices built by the parallel inferrer.

    Eliminates a redundant Stage-1 SIMD scan (a large share of read wall): the
    inferrer already walked the file and built one StructuralIndex per
    partition; this entry takes those indices by-move and goes directly
    to Stage-2 columnar walk (NO build_structural_index call).

    Inputs:
        bytes:   origin-poly Span over the full JSONL byte stream. Same
                 bytes the inferrer walked.
        schema:  the target Arrow schema (consumed; each worker uses a
                 copy).
        los:     per-worker lo (inclusive) byte offsets, length=k. From
                 the inferrer's JsonlPartitions.
        his:     per-worker hi (exclusive) byte offsets, length=k. From
                 the inferrer's JsonlPartitions.
        indices: per-worker pre-built StructuralIndex, length=k. From
                 the inferrer's JsonlPartitions; consumed (each worker
                 takes its own slot by-move).

    Contract: `len(los) == len(his) == len(indices)`. Partitions must be
    `\n`-aligned (`_compute_jsonl_line_ranges` contract). The partitioning
    must match the inferrer's exactly so the index is correct for the
    byte range each worker walks.

    Output: row-for-row and byte-for-byte identical to
    `materialize_jsonl_to_batch(bytes, schema)`.

    No-dispatcher entry: routes the per-partition materialize through the
    SERIAL fork-join fallback (`parallel_fork_join_serial`). Callers with an
    EngineContext-owned dispatcher should use
    `materialize_jsonl_to_batch_parallel_with_partitions_with_dispatcher`
    for true multi-worker parallelism.
    """
    return _materialize_with_partitions_impl[
        has_dispatcher=False, disp_o=MutAnyOrigin
    ](
        bytes,
        schema^,
        partitions^,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def materialize_jsonl_to_batch_parallel_with_partitions_with_dispatcher[
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    var schema: Schema,
    var partitions: JsonlPartitions,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware twin of
    `materialize_jsonl_to_batch_parallel_with_partitions`. Caller threads
    `ctx.dispatcher()` + `ctx.cancel_token()` for true multi-worker
    parallelism via the shared `parallel_fork_join` helper."""
    return _materialize_with_partitions_impl[
        has_dispatcher=True, disp_o=disp_o
    ](
        bytes,
        schema^,
        partitions^,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _materialize_with_partitions_impl[
    has_dispatcher: Bool,
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    var schema: Schema,
    var partitions: JsonlPartitions,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Shared body for the with-partitions parallel materializer.

    Dispatches one chunk per partition via the shared `parallel_fork_join`
    fork-join helper (dispatcher-aware) or `parallel_fork_join_serial`
    (no-dispatcher), each producing one owned `Optional[RecordBatch]` in
    INDEX ORDER; then concatenates them. The helper owns the
    dispatch-boundary safety contract."""
    var k = len(partitions.los)
    # Defensive: contract violation falls back to the standard parallel
    # materializer (which rebuilds indices). Caller should have detected
    # `len(partitions.indices) == 0` upstream and routed to the regular
    # parallel materializer; this guard catches the edge case.
    if k == 0 or k != len(partitions.his) or k != len(partitions.indices):
        _ = partitions^
        _ = cancel_token^
        comptime if has_dispatcher:
            return materialize_jsonl_to_batch_parallel_with_dispatcher[disp_o](
                bytes, schema^, dispatcher_ptr.value(), CancellationToken.never()
            )
        else:
            return materialize_jsonl_to_batch_parallel(bytes, schema^)

    # HOSTILE-INPUT / API-CONTRACT CHECK (ASSERT=none hardening).
    #
    # The arity guard above validated only that the three parallel Lists have
    # the same length; it stopped one step short of validating the VALUES.
    # `_JsonlMatWithIdxWork.process` then does
    #     Span(unsafe_ptr= bytes_ptr + lo, length = hi - lo)
    # with no further check. `materialize_jsonl_to_batch_parallel_with_partitions`
    # is PUBLIC and takes `bytes` and `partitions` as INDEPENDENT arguments, so
    # their pairing was a prose contract ("the partitioning must match the
    # inferrer's exactly"), not a checked one. An inconsistent pair yields a
    # Span with a NEGATIVE length or a base pointer past the end of the buffer
    # — and a negative-length Span is not caught by any stdlib bounds check
    # even at ASSERT=safe, let alone ASSERT=none.
    #
    # Cost: three Int compares per PARTITION (k <= 32), once per call. This is
    # not a per-row or per-byte path.
    var bytes_len = len(bytes)
    for t in range(k):
        var lo_t = partitions.los[t]
        var hi_t = partitions.his[t]
        if lo_t < 0 or hi_t < lo_t or hi_t > bytes_len:
            raise Error(
                "materialize_jsonl_to_batch_parallel_with_partitions:"
                " partition "
                + String(t)
                + " has byte range ["
                + String(lo_t)
                + ", "
                + String(hi_t)
                + ") which is not a valid sub-range of the "
                + String(bytes_len)
                + "-byte input. Required: 0 <= lo <= hi <= len(bytes)."
                " The partitions must come from the SAME buffer the inferrer"
                " walked (see _compute_jsonl_line_ranges); pairing a"
                " JsonlPartitions with a different `bytes` argument produces a"
                " negative-length or out-of-buffer Span."
            )


    # Build the input bundle. The bundle OWNS the schema + the whole
    # JsonlPartitions (moved in — los/his/indices read by-ref inside the
    # worker, no copy); only the byte stream is borrowed, through the Span's
    # own CONCRETE immutable origin (NO wildcard). The synchronous wake-word
    # barrier guarantees the byte pointer outlives the dispatch.
    comptime byte_o = bytes.origin
    var fj_in = _JsonlMatInputWithIdx[byte_o](
        bytes.unsafe_ptr(),
        len(bytes),
        schema.copy(),
        partitions^,
    )
    var work = _JsonlMatWithIdxWork[byte_o](Int32(0))

    var fj_out: Slab[Optional[RecordBatch]]

    comptime if has_dispatcher:
        comptime in_o = origin_of(fj_in)
        fj_out = parallel_fork_join[
            _JsonlMatWithIdxWork[byte_o],
            _JsonlMatInputWithIdx[byte_o],
            RecordBatch,
            in_o,
            disp_o,
        ](
            work^, fj_in, k, dispatcher_ptr.value(), cancel_token^,
        )
    else:
        _ = cancel_token^
        comptime in_o2 = origin_of(fj_in)
        fj_out = parallel_fork_join_serial[
            _JsonlMatWithIdxWork[byte_o],
            _JsonlMatInputWithIdx[byte_o],
            RecordBatch,
            in_o2,
        ](
            work^, fj_in, k,
        )
    # `fj_in` owns `partitions` (moved in at construction) + the byte-pointer
    # borrow; dropping it here frees the partitions struct.
    _ = fj_in^

    # Concat per-worker batches — single-pass multi-way.
    if k == 0:
        _ = fj_out^  # cov: unreachable k >= 1 here: k == 0 returned at the partition check above
        return materialize_jsonl_to_batch(bytes, schema^)  # cov: unreachable see the line above
    # Zero-column parts (a schema with no fields) are joined by row count.
    var combined = _concat_jsonl_parts(fj_out, k)
    _ = fj_out^
    _ = schema^
    return combined^


def materialize_jsonl_to_batch_parallel(
    bytes: Span[UInt8, _],
    var schema: Schema,
    n_workers: Int = 0,
) raises -> RecordBatch:
    """Line-range PARALLEL JSONL → RecordBatch materializer.

    Shards `bytes` into `n_workers` line-range partitions (aligned to `\\n`),
    builds a per-partition `StructuralIndex` + materializes a per-partition
    `RecordBatch` in parallel (fork-join), then concatenates the
    per-worker batches into one output. Output is row-for-row and byte-for-
    byte identical to the single-thread `materialize_jsonl_to_batch(bytes,
    schema)` (same schema applied to every partition; partitions cover the
    file in order; concat preserves order).

    The `schema` is REQUIRED (each worker stamps it onto its partition's
    batch). Callers that infer schema first (`ctx.read_json`) pass the
    inferred schema here.

    Falls back to single-thread when the file is below
    `_MIN_PARALLEL_JSONL_BYTES`, `n_workers <= 1`, or the partition collapses
    to a single range (e.g. a file with no interior `\\n`).

    Args:
        bytes:     origin-poly Span over the full JSONL byte stream. Must
                   outlive the call (it does — the caller owns it across the
                   synchronous dispatch).
        schema:    the target Arrow schema, applied uniformly. Consumed.
        n_workers: worker count; 0 -> `num_physical_cores()` capped at
                   `_MAX_JSONL_WORKERS`. Pass 1 to force single-thread.

    No-dispatcher entry: routes the per-partition index-build + materialize
    through the SERIAL fork-join fallback (`parallel_fork_join_serial`).
    Callers with an EngineContext-owned dispatcher should use
    `materialize_jsonl_to_batch_parallel_with_dispatcher` for true
    multi-worker parallelism.
    """
    return _materialize_parallel_impl[
        has_dispatcher=False, disp_o=MutAnyOrigin
    ](
        bytes,
        schema^,
        n_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def materialize_jsonl_to_batch_parallel_with_dispatcher[
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    var schema: Schema,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    n_workers: Int = 0,
) raises -> RecordBatch:
    """Dispatcher-aware twin of `materialize_jsonl_to_batch_parallel`. Caller
    threads `ctx.dispatcher()` + `ctx.cancel_token()` for true multi-worker
    parallelism via the shared `parallel_fork_join` helper."""
    return _materialize_parallel_impl[
        has_dispatcher=True, disp_o=disp_o
    ](
        bytes,
        schema^,
        n_workers,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _materialize_parallel_impl[
    has_dispatcher: Bool,
    disp_o: Origin[mut=True],
](
    bytes: Span[UInt8, _],
    var schema: Schema,
    n_workers: Int,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Shared body for the build-own-index parallel materializer.

    Partitions the byte stream into line-range sub-ranges, then dispatches
    one chunk per partition via the shared `parallel_fork_join` fork-join
    helper (dispatcher-aware) or `parallel_fork_join_serial` (no-dispatcher),
    each building its OWN StructuralIndex and producing one owned
    `Optional[RecordBatch]` in INDEX ORDER; then concatenates them. The
    helper owns the dispatch-boundary safety contract."""
    var n = len(bytes)

    var effective_workers = n_workers
    if effective_workers <= 0:
        effective_workers = num_physical_cores()
    if effective_workers > _MAX_JSONL_WORKERS:
        effective_workers = _MAX_JSONL_WORKERS
    if effective_workers < 1:
        effective_workers = 1

    if n < _MIN_PARALLEL_JSONL_BYTES or effective_workers == 1:
        _ = cancel_token^
        return materialize_jsonl_to_batch(bytes, schema^)


    # ---------------------------------------------------------------------
    # Step 1: partition the byte stream into line-range sub-ranges.
    # ---------------------------------------------------------------------
    var los = List[Int]()
    var his = List[Int]()
    _compute_jsonl_line_ranges(bytes, n, effective_workers, los, his)
    var k = len(los)
    if k <= 1:
        # Single range (no interior newline) — single-thread fallback.
        _ = cancel_token^
        return materialize_jsonl_to_batch(bytes, schema^)

    # ---------------------------------------------------------------------
    # Step 2: parallel index-build + materialize via the fork-join helper.
    # ---------------------------------------------------------------------
    # Build the input bundle. The bundle OWNS the schema + offset lists
    # (moved in); only the byte stream is borrowed, through the Span's own
    # CONCRETE immutable origin (NO wildcard). The synchronous wake-word
    # barrier guarantees the byte pointer outlives the dispatch.
    comptime byte_o = bytes.origin
    var fj_in = _JsonlMatInputBuildIdx[byte_o](
        bytes.unsafe_ptr(), n, schema.copy(), los^, his^
    )
    var work = _JsonlMatBuildIdxWork[byte_o](Int32(0))

    var fj_out: Slab[Optional[RecordBatch]]

    comptime if has_dispatcher:
        comptime in_o = origin_of(fj_in)
        fj_out = parallel_fork_join[
            _JsonlMatBuildIdxWork[byte_o],
            _JsonlMatInputBuildIdx[byte_o],
            RecordBatch,
            in_o,
            disp_o,
        ](
            work^, fj_in, k, dispatcher_ptr.value(), cancel_token^,
        )
    else:
        _ = cancel_token^
        comptime in_o2 = origin_of(fj_in)
        fj_out = parallel_fork_join_serial[
            _JsonlMatBuildIdxWork[byte_o],
            _JsonlMatInputBuildIdx[byte_o],
            RecordBatch,
            in_o2,
        ](
            work^, fj_in, k,
        )
    # `fj_in` owns `los`/`his`/`schema` (moved in) + the byte-pointer borrow;
    # dropping it here frees the offset lists.
    _ = fj_in^

    # ---------------------------------------------------------------------
    # Step 3: concat per-worker batches (single-pass multi-way).
    # ---------------------------------------------------------------------
    if k == 0:
        _ = fj_out^  # cov: unreachable k >= 2 here: k <= 1 returned after the line ranges above
        return materialize_jsonl_to_batch(bytes, schema^)  # cov: unreachable see the line above

    # `_concat_jsonl_parts` walks slots [0, k) in order; zero-column parts
    # (a schema with no fields) are joined by row count.
    var combined = _concat_jsonl_parts(fj_out, k)
    # The concat `.take()`s each slot, so the slab destructor sees empty
    # slots (no-op drop). schema is dropped here (each worker used a copy).
    _ = fj_out^
    _ = schema^
    return combined^


@always_inline
def _is_ws(b: UInt8) -> Bool:
    """Per RFC 8259 §2 JSON whitespace: space, tab, LF, CR."""
    return (
        b == UInt8(0x20)
        or b == UInt8(0x09)
        or b == UInt8(0x0A)
        or b == UInt8(0x0D)
    )
