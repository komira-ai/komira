# =============================================================================
# string_keys -- string group keys as interned ids with a carried content hash
# =============================================================================
#
# The grouped aggregation sink over string keys (`sink_string_group_agg`) keys
# a group by one 64-bit cell per key column, as the fixed-width sink does
# (`group_table`). For a string the cell is the id of the string in the
# worker's `InternTable`: a table that holds each distinct string once (its
# bytes in one arena) and, beside it, the 64-bit content hash of the string,
# computed once when the entry is made and never again (design section 4.3).
#
# The id is worker-local: two workers number their strings in the order they
# met them. Nothing that must agree between workers is derived from an id.
# What travels is the content hash and the bytes, which is how the merge of
# the workers' groups finds the same string under two ids (`InternTable.intern`
# takes the hash the caller already has).
#
# A column reaches the table in one of three ways (`read_string_keys`):
#
#   DICTIONARY, by code    the DICT_ENCODED row. A morsel's dictionary maps a
#                          code to its string; each code a selected row uses is
#                          interned once per morsel (hash, probe, byte compare
#                          on a hit) and every later row with that code reads
#                          its id from a per-morsel array. A code no selected
#                          row uses is never interned.
#   DICTIONARY, by value   the COLUMNAR row given a dictionary column: the
#                          string of each row is hashed and interned.
#   STRING                 either row: each row's bytes are hashed and
#                          interned. A column that is not dictionary encoded
#                          (a plain Parquet chunk) is this case.
#
# NULL is no string: a NULL row has a flag and no id, and the empty string is a
# string like any other, distinct from NULL.
#
# Memory is charged as the table grows, before it grows, to the
# `WorkerReservation` the caller passes: the entry arrays (28 bytes an entry of
# capacity: start 8, length 4, hash 8, two 4-byte slots) as the capacity
# doubles, and the byte arena as it doubles from 1 KiB. `intern` allocates
# nothing and returns -1 when the pool denies a step (`denied_bytes` says how
# many bytes were asked for), or when the table is at `max_entries`
# (`too_many`). Not charged: the old arrays while a table doubles.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.schema import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from .group_table import mix64
from .segment_pool import WorkerReservation

comptime _FNV_OFFSET: UInt64 = 0xCBF29CE484222325
comptime _FNV_PRIME: UInt64 = 0x100000001B3
comptime STRING_KEY_SEED: UInt64 = 0x2545F4914F6CDD1D
"""The start of a group's hash, before any key column is mixed in."""
comptime NULL_KEY_HASH: UInt64 = 0xD1B54A32D192ED03
"""What a NULL key column contributes to a group's hash."""
comptime _ENTRY_BYTES: Int = 28
comptime _FIRST_ENTRIES: Int = 64
comptime _FIRST_ARENA: Int = 1024
comptime _EMPTY_SLOT: Int32 = -1
comptime MAX_INTERN_ENTRIES: Int = 1 << 30
comptime _MAX_STRING_BYTES: Int = 0x7FFFFFFF


@always_inline
def hash_string(span: Span[UInt8, _]) -> UInt64:
    """The 64-bit content hash of a string's bytes (FNV-1a, then a finalizer
    that also takes the length): a function of the bytes alone, so the same
    string hashes the same in every worker."""
    var h = _FNV_OFFSET
    for i in range(len(span)):
        h = (h ^ UInt64(span[i])) * _FNV_PRIME
    return mix64(h ^ UInt64(len(span)))


struct InternTable(Movable):
    """Distinct strings by content, each with the hash computed for it."""

    var n: Int
    var capacity: Int
    var bytes: List[UInt8]
    var starts: List[Int]
    var lens: List[Int32]
    var hashes: List[UInt64]
    var _slots: List[Int32]
    var _arena_charged: Int
    var denied_bytes: Int
    var max_entries: Int
    var too_many: Bool

    def __init__(out self, max_entries: Int = MAX_INTERN_ENTRIES):
        self.n = 0
        self.capacity = 0
        self.bytes = List[UInt8]()
        self.starts = List[Int]()
        self.lens = List[Int32]()
        self.hashes = List[UInt64]()
        self._slots = List[Int32]()
        self._arena_charged = 0
        self.denied_bytes = 0
        self.max_entries = max_entries
        self.too_many = False

    def value(ref self, id: Int) -> Span[UInt8, origin_of(self.bytes)]:
        """The bytes of entry `id`."""
        var s = self.starts[id]
        return Span(self.bytes)[s : s + Int(self.lens[id])]

    def _equals(self, id: Int, span: Span[UInt8, _]) -> Bool:
        var n = Int(self.lens[id])
        if n != len(span):
            return False
        var s = self.starts[id]
        for i in range(n):
            if self.bytes[s + i] != span[i]:
                return False
        return True

    def _grow_entries(mut self, mut res: WorkerReservation) -> Bool:
        var new_cap = _FIRST_ENTRIES if self.capacity == 0 else (
            self.capacity * 2
        )
        if new_cap > self.max_entries:
            self.too_many = True
            return False
        var step = (new_cap - self.capacity) * _ENTRY_BYTES
        if not res.try_grow(step):
            self.denied_bytes = step
            return False
        self.starts.reserve(new_cap)
        self.lens.reserve(new_cap)
        self.hashes.reserve(new_cap)
        self.capacity = new_cap
        var slots = List[Int32](capacity=new_cap * 2)
        for _ in range(new_cap * 2):
            slots.append(_EMPTY_SLOT)
        var mask = new_cap * 2 - 1
        for g in range(self.n):
            var s = Int(self.hashes[g]) & mask
            while slots[s] != _EMPTY_SLOT:
                s = (s + 1) & mask
            slots[s] = Int32(g)
        self._slots = slots^
        return True

    def _grow_arena(mut self, extra: Int, mut res: WorkerReservation) -> Bool:
        var need = len(self.bytes) + extra
        if need <= self._arena_charged:
            return True
        var target = max(need, max(self._arena_charged * 2, _FIRST_ARENA))
        var step = target - self._arena_charged
        if not res.try_grow(step):
            self.denied_bytes = step
            return False
        self._arena_charged = target
        self.bytes.reserve(target)
        return True

    def intern(
        mut self,
        span: Span[UInt8, _],
        h: UInt64,
        mut res: WorkerReservation,
    ) -> Int:
        """The id of the string `span` whose content hash is `h`, made if new.
        -1 when a new entry needed memory the pool denied, or when the table
        is at `max_entries` (`too_many`)."""
        if self.capacity > 0:
            var mask = self.capacity * 2 - 1
            var s = Int(h) & mask
            while self._slots[s] != _EMPTY_SLOT:
                var id = Int(self._slots[s])
                if self.hashes[id] == h and self._equals(id, span):
                    return id
                s = (s + 1) & mask
        if len(span) > _MAX_STRING_BYTES:
            self.too_many = True
            return -1
        if self.n == self.capacity:
            if not self._grow_entries(res):
                return -1
        if not self._grow_arena(len(span), res):
            return -1
        var mask = self.capacity * 2 - 1
        var s = Int(h) & mask
        while self._slots[s] != _EMPTY_SLOT:
            s = (s + 1) & mask
        var id = self.n
        self._slots[s] = Int32(id)
        self.n += 1
        self.starts.append(len(self.bytes))
        self.lens.append(Int32(len(span)))
        self.hashes.append(h)
        for i in range(len(span)):
            self.bytes.append(span[i])
        return id


struct StrKeyRows(Movable):
    """One string key column of a morsel: per row the id in the worker's
    table, the content hash, and 1 when the row is NULL (the id is 0 then)."""

    var ids: List[Int64]
    var hashes: List[UInt64]
    var null: List[UInt8]

    def __init__(out self):
        self.ids = List[Int64]()
        self.hashes = List[UInt64]()
        self.null = List[UInt8]()

    def push_null(mut self):
        self.ids.append(0)
        self.hashes.append(NULL_KEY_HASH)
        self.null.append(1)

    def push(mut self, id: Int, h: UInt64):
        self.ids.append(Int64(id))
        self.hashes.append(h)
        self.null.append(0)


def is_string_key_type(t: ArrowType) -> Bool:
    """Whether a column of type `t` can be a string key of the sink."""
    return t == ArrowType.STRING or t == ArrowType.DICTIONARY


def read_string_keys(
    mut out: StrKeyRows,
    ref batch: RecordBatch,
    col_idx: Int,
    rows: Int,
    by_code: Bool,
    ref label: String,
    mut table: InternTable,
    mut res: WorkerReservation,
) raises -> Bool:
    """Column `col_idx` (`rows` rows) of `batch` interned into `table`. A
    dictionary column is interned by code when `by_code`, else by value.
    False when the table needed memory the pool denied (or is full): see
    `table.denied_bytes` and `table.too_many`.

    Raises:
        A column that is not STRING or a string dictionary, a code outside its
        dictionary, a column of other than `rows` rows."""
    ref col = batch.column_at(col_idx)
    if col.length() != rows:
        raise Error(
            "komira_pipeline_exec: "
            + label
            + " got a column of "
            + String(col.length())
            + " rows for "
            + String(rows)
            + " selected rows"
        )
    var t = col.arrow_type
    var has_nulls = col.null_count() > 0
    out.ids.reserve(rows)
    out.hashes.reserve(rows)
    out.null.reserve(rows)
    if t == ArrowType.DICTIONARY:
        if not col.is_string_dict():
            raise Error(
                "komira_pipeline_exec: "
                + label
                + " is a numeric dictionary column; the string rows key"
                " STRING and string DICTIONARY columns"
            )
        var size = col.dict_size()
        var seen = List[Int32]()
        if by_code:
            seen = List[Int32](length=size, fill=-1)
        for r in range(rows):
            if has_nulls and col.is_null_at(r):
                out.push_null()
                continue
            var code = col.string_dict_code_at(r)
            if code < 0 or code >= size:
                raise Error(
                    "komira_pipeline_exec: "
                    + label
                    + " found dictionary code "
                    + String(code)
                    + " at row "
                    + String(r)
                    + " of a dictionary of "
                    + String(size)
                    + " entries"
                )
            var id = -1
            if by_code:
                id = Int(seen[code])
            if id < 0:
                var span = col.string_dict_value_at(code).into_span()
                id = table.intern(span, hash_string(span), res)
                if id < 0:
                    return False
                if by_code:
                    seen[code] = Int32(id)
            out.push(id, table.hashes[id])
        return True
    if t == ArrowType.STRING:
        var arr = col.as_string()
        for r in range(rows):
            if has_nulls and arr.is_null(r):
                out.push_null()
                continue
            var span = arr.get_span(r)
            var id = table.intern(span, hash_string(span), res)
            if id < 0:
                return False
            out.push(id, table.hashes[id])
        return True
    raise Error(
        "komira_pipeline_exec: "
        + label
        + " is a "
        + String(t)
        + " column; the string rows key STRING and string DICTIONARY columns"
    )


def string_key_column(
    ref table: InternTable,
    ref cells: List[Int64],
    ref nulls: List[UInt8],
    nk: Int,
    k: Int,
    rows: Int,
) raises -> Column[HeapRegion]:
    """Key column `k` of `rows` groups whose keys are stored `nk` cells to a
    group, the cells being ids in `table`, as a STRING column. A NULL flag
    makes a NULL row."""
    var offsets = List[Int32](capacity=rows + 1)
    offsets.append(0)
    var total = 0
    var null_count = 0
    for g in range(rows):
        if nulls[g * nk + k] != 0:
            null_count += 1
        else:
            total += Int(table.lens[Int(cells[g * nk + k])])
        if total > _MAX_STRING_BYTES:
            raise Error(
                "komira_pipeline_exec: the string key column of "
                + String(rows)
                + " groups holds more than 2 GiB of string bytes"
            )
        offsets.append(Int32(total))
    var data = List[UInt8](capacity=total)
    var validity = Optional[Bitmap[HeapRegion]]()
    if null_count > 0:
        validity = Optional(Bitmap.create(rows))
    for g in range(rows):
        if nulls[g * nk + k] != 0:
            if null_count > 0:
                validity.value().clear(g)
            continue
        if null_count > 0:
            validity.value().set(g)
        var span = table.value(Int(cells[g * nk + k]))
        for i in range(len(span)):
            data.append(span[i])
    return Column.from_string(
        StringArray.from_buffers(offsets, data, validity^, null_count)
    )
