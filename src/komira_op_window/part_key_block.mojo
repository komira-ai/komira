# =============================================================================
# part_key_block -- the typed partition-key columns of the hashed top-N
# =============================================================================
#
# `PartKeyBlock[*PartKeys]` holds the partition keys of
# `partition_topn_hash_state`, one typed column per key, one row per
# partition representative. `ptn_dense_directory` never sees a key: it asks
# this block for a row's hash (`hash_row`, `hash_batch_row`) and for equality
# on a salt hit (`equals_rows`, `equals_batch_row_to_rep`).
#
# Key columns (`PartKeyColumn`):
#   * `PartKeyCol_Numeric[dt, col]`: INT64 / INT32 / FLOAT64 / FLOAT32, stored
#     as their UInt64 bit pattern;
#   * `PartKeyCol_String[col]`: STRING, stored as bytes and offsets.
#
# Partition-key equality is DuckDB's (docs/design/query_semantics.md §9.9,
# §2.6): NULL equals NULL and nothing else, and a float key compares in its
# canonical form (every NaN equal, -0.0 equal to +0.0), which is also what it
# hashes. The stored bits are the representative's own, so a partition's key
# comes back as the first value seen for it.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_counters.keyeq_census import (
    KEYEQ_PARTKEY_BATCH_TOK,
    KEYEQ_PARTKEY_ROWS,
    keyeq_record,
)
from komira_op_sort.sort_stage_columns import sort_bits_of, sort_from_bits
from komira_udf.float_quotient_order import canonical_bits_f32, canonical_bits_f64


# The hash of a NULL key: one fixed value, so every NULL lands in one bucket.
comptime _NULL_KEY_HASH: UInt64 = 0x6E756C6C5F6B6579


@always_inline
def _mix64(x: UInt64) -> UInt64:
    var h = x
    h = h * 0x9E3779B97F4A7C15
    h = h ^ (h >> 29)
    h = h * 0xBF58476D1CE4E5B9
    h = h ^ (h >> 32)
    return h


@always_inline
def _combine_hash(acc: UInt64, h: UInt64) -> UInt64:
    # Order-sensitive combine of the per-column hashes.
    return acc ^ (h + 0x9E3779B97F4A7C15 + (acc << 6) + (acc >> 2))


@always_inline
def _part_arrow_type[dt: DType]() -> ArrowType:
    comptime if dt == DType.int64:
        return ArrowType.INT64
    elif dt == DType.int32:
        return ArrowType.INT32
    elif dt == DType.float64:
        return ArrowType.FLOAT64
    elif dt == DType.float32:
        return ArrowType.FLOAT32
    else:
        return ArrowType.INT64


@always_inline
def _canon_bits[dt: DType](bits: UInt64) -> UInt64:
    """The bits a key compares and hashes by: a float's canonical form (one
    NaN, +0.0 for -0.0), any other type's own bits."""
    comptime if dt == DType.float64:
        return canonical_bits_f64(sort_from_bits[DType.float64](bits))
    elif dt == DType.float32:
        return UInt64(canonical_bits_f32(sort_from_bits[DType.float32](bits)))
    else:
        return bits


trait PartKeyColumn(Defaultable, Movable, Deinitable):
    """One partition-key column: its value at every fed row, in order. The
    block delegates hashing and equality to it."""

    @staticmethod
    def make(capacity: Int) -> Self:
        ...

    def read_and_append[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises:
        """Append the key of input `row` (one fed row)."""
        ...

    def hash_at(self, row: Int) -> UInt64:
        """The hash of fed row `row`."""
        ...

    def hash_batch_row[bo: Origin[mut=False]](self, batch: BatchView[bo], row: Int) raises -> UInt64:
        """The hash of input `batch[row]`, read without appending; equal to
        `hash_at` of the same key."""
        ...

    def equals_batch_row_to_token[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, token: Int
    ) raises -> Bool:
        """True if input `batch[row]` has the key of fed row `token`."""
        ...

    def equals_rows(self, a: Int, b: Int) -> Bool:
        """True if fed rows `a` and `b` have the same key."""
        ...

    def length(self) -> Int:
        ...

    def pop_last_row(mut self):
        """Drop the last fed row."""
        ...

    def append_other(mut self, other: Self) raises:
        """Append every fed row of `other` (cross-worker combine)."""
        ...

    def add_schema_field(self, mut sb: SchemaBuilder, k: Int):
        """Append this key's output field (`pk<k>`, its own type)."""
        ...

    def emit_at_tokens(self, tokens: List[Int], mut rb: RecordBatchBuilder) raises:
        """Append this key column, one row per fed-row token in `tokens`."""
        ...


# =============================================================================
# PartKeyCol_Numeric[dt, col]
# =============================================================================


struct PartKeyCol_Numeric[dt: DType, col: Int](PartKeyColumn):
    """A numeric key column: the bit pattern of each fed row and whether it
    is non-NULL."""

    var bits: List[UInt64]
    var valid: List[Bool]

    def __init__(out self):
        self.bits = List[UInt64]()
        self.valid = List[Bool]()

    @staticmethod
    def make(capacity: Int) -> Self:
        var c = Self()
        c.bits = List[UInt64](capacity=capacity)
        c.valid = List[Bool](capacity=capacity)
        return c^

    @always_inline
    def _read_bits[bo: Origin[mut=False]](self, batch: BatchView[bo], row: Int) raises -> UInt64:
        comptime if Self.dt == DType.int32:
            return sort_bits_of[DType.int32](batch.col_i32(Self.col).load[1](row)[0])
        elif Self.dt == DType.float64:
            return sort_bits_of[DType.float64](batch.col_f64(Self.col).load[1](row)[0])
        elif Self.dt == DType.float32:
            return sort_bits_of[DType.float32](batch.col_f32(Self.col).load[1](row)[0])
        else:
            return sort_bits_of[DType.int64](batch.col_i64(Self.col).load[1](row)[0])

    def read_and_append[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises:
        if batch.col_is_null(Self.col, row):
            self.bits.append(UInt64(0))
            self.valid.append(False)
        else:
            self.bits.append(self._read_bits[bo](batch, row))
            self.valid.append(True)

    @always_inline
    def hash_at(self, row: Int) -> UInt64:
        if not self.valid[row]:
            return _NULL_KEY_HASH
        return _mix64(_canon_bits[Self.dt](self.bits[row]))

    @always_inline
    def hash_batch_row[bo: Origin[mut=False]](self, batch: BatchView[bo], row: Int) raises -> UInt64:
        if batch.col_is_null(Self.col, row):
            return _NULL_KEY_HASH
        return _mix64(_canon_bits[Self.dt](self._read_bits[bo](batch, row)))

    @always_inline
    def equals_batch_row_to_token[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, token: Int
    ) raises -> Bool:
        var null_row = batch.col_is_null(Self.col, row)
        if null_row or not self.valid[token]:
            return null_row and not self.valid[token]
        return _canon_bits[Self.dt](self._read_bits[bo](batch, row)) == _canon_bits[
            Self.dt
        ](self.bits[token])

    @always_inline
    def equals_rows(self, a: Int, b: Int) -> Bool:
        if not self.valid[a] or not self.valid[b]:
            return not self.valid[a] and not self.valid[b]
        return _canon_bits[Self.dt](self.bits[a]) == _canon_bits[Self.dt](self.bits[b])

    @always_inline
    def length(self) -> Int:
        return len(self.bits)

    @always_inline
    def pop_last_row(mut self):
        _ = self.bits.pop()
        _ = self.valid.pop()

    def append_other(mut self, other: Self) raises:
        for i in range(len(other.bits)):
            self.bits.append(other.bits[i])
            self.valid.append(other.valid[i])

    def add_schema_field(self, mut sb: SchemaBuilder, k: Int):
        sb.add_field(Field(String("pk") + String(k), _part_arrow_type[Self.dt](), True))

    def emit_at_tokens(self, tokens: List[Int], mut rb: RecordBatchBuilder) raises:
        var n = len(tokens)
        var any_null = False
        for i in range(n):
            if not self.valid[tokens[i]]:
                any_null = True
                break
        var arr: PrimitiveArray[Self.dt]
        if any_null:
            arr = PrimitiveArray[Self.dt].allocate_nullable(n)
        else:
            arr = PrimitiveArray[Self.dt].allocate(n)
        for i in range(n):
            var t = tokens[i]
            arr.store[1](i, sort_from_bits[Self.dt](self.bits[t]))
            if not self.valid[t]:
                arr._set_null(i)
        rb.add_column(Column.from_primitive[Self.dt](arr^))


# =============================================================================
# PartKeyCol_String[col]
# =============================================================================


struct PartKeyCol_String[col: Int](PartKeyColumn):
    """A STRING key column: each fed row's bytes (a NULL row stores none),
    their offsets, and whether the row is non-NULL. FNV-1a hash; byte-exact
    equality."""

    var data: List[UInt8]
    var offsets: List[Int]
    var valid: List[Bool]

    def __init__(out self):
        self.data = List[UInt8]()
        self.offsets = List[Int]()
        self.offsets.append(0)
        self.valid = List[Bool]()

    @staticmethod
    def make(capacity: Int) -> Self:
        var c = Self()
        c.data = List[UInt8](capacity=capacity * 8)
        c.offsets = List[Int](capacity=capacity + 1)
        c.offsets.append(0)
        c.valid = List[Bool](capacity=capacity)
        return c^

    def read_and_append[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises:
        if batch.col_is_null(Self.col, row):
            self.valid.append(False)
        else:
            var sv = batch.col_str(Self.col).get(row)
            for i in range(sv.length()):
                self.data.append(sv.byte_at(i))
            self.valid.append(True)
        self.offsets.append(len(self.data))

    @always_inline
    def _len_of(self, row: Int) -> Int:
        return self.offsets[row + 1] - self.offsets[row]

    def hash_at(self, row: Int) -> UInt64:
        if not self.valid[row]:
            return _NULL_KEY_HASH
        var h = UInt64(0xCBF29CE484222325)
        var base = self.offsets[row]
        for i in range(self._len_of(row)):
            h = h ^ UInt64(self.data[base + i])
            h = h * UInt64(0x100000001B3)
        return _mix64(h)

    def hash_batch_row[bo: Origin[mut=False]](self, batch: BatchView[bo], row: Int) raises -> UInt64:
        if batch.col_is_null(Self.col, row):
            return _NULL_KEY_HASH
        var sv = batch.col_str(Self.col).get(row)
        var h = UInt64(0xCBF29CE484222325)
        for i in range(sv.length()):
            h = h ^ UInt64(sv.byte_at(i))
            h = h * UInt64(0x100000001B3)
        return _mix64(h)

    def equals_batch_row_to_token[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, token: Int
    ) raises -> Bool:
        var null_row = batch.col_is_null(Self.col, row)
        if null_row or not self.valid[token]:
            return null_row and not self.valid[token]
        var sv = batch.col_str(Self.col).get(row)
        var n = sv.length()
        if n != self._len_of(token):
            return False
        var base = self.offsets[token]
        var i = 0
        var eq = True
        while i < n:
            if sv.byte_at(i) != self.data[base + i]:
                eq = False
                break
            i += 1
        keyeq_record(KEYEQ_PARTKEY_BATCH_TOK, n, i, eq)
        return eq

    def equals_rows(self, a: Int, b: Int) -> Bool:
        if not self.valid[a] or not self.valid[b]:
            return not self.valid[a] and not self.valid[b]
        var la = self._len_of(a)
        if la != self._len_of(b):
            return False
        var ba = self.offsets[a]
        var bb = self.offsets[b]
        var i = 0
        var eq = True
        while i < la:
            if self.data[ba + i] != self.data[bb + i]:
                eq = False
                break
            i += 1
        keyeq_record(KEYEQ_PARTKEY_ROWS, la, i, eq)
        return eq

    @always_inline
    def length(self) -> Int:
        return len(self.offsets) - 1

    def pop_last_row(mut self):
        _ = self.offsets.pop()
        _ = self.valid.pop()
        var keep = self.offsets[len(self.offsets) - 1]
        while len(self.data) > keep:
            _ = self.data.pop()

    def append_other(mut self, other: Self) raises:
        for r in range(other.length()):
            var base = other.offsets[r]
            for i in range(other._len_of(r)):
                self.data.append(other.data[base + i])
            self.offsets.append(len(self.data))
            self.valid.append(other.valid[r])

    def _to_string(self, row: Int) raises -> String:
        var bytes = List[UInt8]()
        var base = self.offsets[row]
        for i in range(self._len_of(row)):
            bytes.append(self.data[base + i])
        return String(StringSlice(unsafe_from_utf8=Span(bytes)))

    def add_schema_field(self, mut sb: SchemaBuilder, k: Int):
        sb.add_field(Field(String("pk") + String(k), ArrowType.STRING, True))

    def emit_at_tokens(self, tokens: List[Int], mut rb: RecordBatchBuilder) raises:
        var strs = List[String](capacity=len(tokens))
        var valid = List[Bool](capacity=len(tokens))
        for i in range(len(tokens)):
            strs.append(self._to_string(tokens[i]))
            valid.append(self.valid[tokens[i]])
        rb.add_column(Column.from_string(StringArray.from_strings_with_validity(strs, valid)))


# =============================================================================
# PartKeyBlock[*PartKeys]
# =============================================================================


trait PartKeyBlockTrait(Movable, Deinitable):
    """The non-variadic surface `partition_topn_hash_state` calls."""

    @staticmethod
    def make_empty(capacity: Int) -> Self:
        ...

    @staticmethod
    def arity() -> Int:
        ...

    def feed_row[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises -> Int:
        ...

    def pop_last_row(mut self):
        ...

    def hash_row(self, row: Int) -> UInt64:
        ...

    def hash_batch_row[bo: Origin[mut=False]](self, batch: BatchView[bo], row: Int) raises -> UInt64:
        ...

    def equals_batch_row_to_rep[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, token: Int
    ) raises -> Bool:
        ...

    def equals_rows(self, a: Int, b: Int) -> Bool:
        ...

    def append_other(mut self, other: Self) raises:
        ...

    def n_rows_count(self) -> Int:
        ...

    def add_schema(self, mut sb: SchemaBuilder):
        ...

    def emit_at_tokens(self, tokens: List[Int], mut rb: RecordBatchBuilder) raises:
        ...


struct PartKeyBlock[*PartKeys: PartKeyColumn](PartKeyBlockTrait):
    """The `*PartKeys` pack behind a non-variadic surface: a composite key's
    hash folds the columns' hashes in order; its equality is every column's."""

    var cols: Tuple[*Self.PartKeys]
    var n_rows: Int

    def __init__(out self):
        self.cols = Tuple[*Self.PartKeys]()
        self.n_rows = 0

    def __init__(out self, var cols: Tuple[*Self.PartKeys]):
        self.cols = cols^
        self.n_rows = 0

    @staticmethod
    def make_empty(capacity: Int) -> Self:
        var t = Tuple[*Self.PartKeys]()
        comptime for k in range(Self.PartKeys.__len__()):
            t[k] = Self.PartKeys[k].make(capacity)
        return Self(t^)

    @staticmethod
    def arity() -> Int:
        return Self.PartKeys.__len__()

    @always_inline
    def n_rows_count(self) -> Int:
        return self.n_rows

    def feed_row[bo: Origin[mut=False]](mut self, batch: BatchView[bo], row: Int) raises -> Int:
        """Append input `row`'s keys; return its fed-row token."""
        comptime for k in range(Self.PartKeys.__len__()):
            self.cols[k].read_and_append[bo](batch, row)
        var token = self.n_rows
        self.n_rows += 1
        return token

    def pop_last_row(mut self):
        comptime for k in range(Self.PartKeys.__len__()):
            self.cols[k].pop_last_row()
        self.n_rows -= 1

    def hash_row(self, row: Int) -> UInt64:
        var acc = UInt64(0)
        comptime for k in range(Self.PartKeys.__len__()):
            acc = _combine_hash(acc, self.cols[k].hash_at(row))
        return acc

    def hash_batch_row[bo: Origin[mut=False]](self, batch: BatchView[bo], row: Int) raises -> UInt64:
        """Equal to `hash_row` of the same keys (same fold order)."""
        var acc = UInt64(0)
        comptime for k in range(Self.PartKeys.__len__()):
            acc = _combine_hash(acc, self.cols[k].hash_batch_row[bo](batch, row))
        return acc

    def equals_batch_row_to_rep[bo: Origin[mut=False]](
        self, batch: BatchView[bo], row: Int, token: Int
    ) raises -> Bool:
        comptime for k in range(Self.PartKeys.__len__()):
            if not self.cols[k].equals_batch_row_to_token[bo](batch, row, token):
                return False
        return True

    def equals_rows(self, a: Int, b: Int) -> Bool:
        comptime for k in range(Self.PartKeys.__len__()):
            if not self.cols[k].equals_rows(a, b):
                return False
        return True

    def append_other(mut self, other: Self) raises:
        comptime for k in range(Self.PartKeys.__len__()):
            self.cols[k].append_other(other.cols[k])
        self.n_rows += other.n_rows

    def add_schema(self, mut sb: SchemaBuilder):
        comptime for k in range(Self.PartKeys.__len__()):
            self.cols[k].add_schema_field(sb, k)

    def emit_at_tokens(self, tokens: List[Int], mut rb: RecordBatchBuilder) raises:
        comptime for k in range(Self.PartKeys.__len__()):
            self.cols[k].emit_at_tokens(tokens, rb)
