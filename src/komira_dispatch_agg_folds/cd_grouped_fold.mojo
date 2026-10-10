# =============================================================================
# cd_grouped_fold.mojo — the GROUPED COUNT(DISTINCT) serial fold (TPC-H q16)
# =============================================================================
#
# The shape (TPC-H q16 — grouped
#   count-distinct over a multi-way join with COMPOSITE / STRING group keys).
#
# WHAT THIS IS — the grouped serial COUNT(DISTINCT) fold for the shape the
# single-INT-key `CountDistinctAggSink` (`_build_cd_agg_sink_data`) does NOT
# carry: a grouped `count_distinct(...)` whose group-by has MORE than one key OR
# a non-INT (STRING) key. The sink's `WorkerCDState` contract is "0 or 1 group-by
# key, INT32/INT64 typed". TPC-H Q16 groups by `[p_brand, p_type, p_size]`
# (2 STRING + 1 INT64) and counts `count_distinct(ps_suppkey)` over the
# part-filtered ⋈ (partsupp ANTI-JOIN supplier) multi-way join — 3 keys, 2 STRING
# -> the sink declines.
#
# WHY A SERIAL FOLD (NOT widening the parallel CD sink kernel) — the same
# correctness rail as the 0-key scalar fold (`agg_scalar_fold`) and the extended
# fold (`agg_extended_fold`): a
# serial single-accumulator fold over ONE resident batch has ONE deterministic
# accumulation order -> value-stable by construction, byte-identical to a hand
# oracle. The COUNT is EXACT (a per-group `Set[Int64]` of the distinct values, not
# an HLL estimate). The q16 join output is bounded (partsupp ~800K rows; the
# part-filter + anti-join narrow it well below the serial-fold scale ceiling).
#
# THE SHAPE this serves (anything else DECLINES -> None -> the caller falls back /
# raises, never silent-wrong):
#   * 1..N group-by KEY col_refs, each STRING or INT32/INT64 (the composite key is
#     a byte-joined STRING of the per-key cell values);
#   * 1..N agg exprs, EVERY one AGG_COUNT_DISTINCT over a plain col_ref input of an
#     INT32/INT64 DType (the exact-set accumulator keys on the int64 value bits);
#   * the resident batch is within the serial-fold scale ceiling.
#
# No `UnsafePointer` in any public signature; no wildcard
# origins; the accumulators are POD `Set[Int64]` / `Dict`.
# =============================================================================

from std.collections import Optional, Set, Dict
from std.collections import List
from std.memory import unsafe_memcmp

from komira_arrow.schema import (
    Schema, SchemaBuilder, Field, ArrowType, RecordBatch, RecordBatchBuilder,
)
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import Expr, EXPR_COL_REF, EXPR_ALIAS
from komira_plan_ir.logical_plan_variants import AggregateData
from komira_plan_expr.agg_expr import AGG_COUNT_DISTINCT, AGG_MIN, AGG_MAX

# ⭐ THE STRING-MIN/MAX ARMING WITNESS. A decline-returning fold
# leaves NO value-level trace of having been called, so "who armed it, and did
# the decline cost anything" is only observable through these two counters. See
# the block beside them in `agg_driver_witness`.
from komira_dispatch_agg_folds.agg_driver_witness import (
    agg_str_minmax_fold_record_call,
    agg_str_minmax_fold_record_row_work,
)


# =============================================================================
# NATIVE-COLUMN HASHING for the grouped COUNT(DISTINCT) fold (q16)
# =============================================================================
#
# WHY: a group-key path that renders EACH group-key cell to a heap `String`,
# concatenates a composite key, and probes a `Dict[String, Int]` pays that PER
# ROW — on q16, hundreds of thousands of String renders and appends over the
# anti-join output — where DuckDB does ZERO per-row key materialization. The
# `_fold_grouped_cd_nativehash` path
# below hashes the NATIVE group-key columns directly (splitmix64 over the raw
# int64 bits; FNV-1a over the raw Arrow string_t byte view) into an open-address
# hash table, resolving collisions by comparing the NATIVE cell values (int64 ==
# / string `memcmp` on the zero-copy Arrow data-buffer spans). NO per-row String
# is built. The distinct SET semantics are the SAME — only the GROUP-KEY
# representation differs (native-hashed columns instead of a rendered composite
# String), so the per-group `Set[Int64]` distinct counts are byte-identical to
# the String-key fold (`_fold_grouped_cd_stringkey`, kept as the byte-equiv
# ORACLE). No production switch chooses between them:
# `tests/test_cd_grouped_fold.mojo` calls
# `_fold_grouped_cd_nativehash` and `_fold_grouped_cd_stringkey` DIRECTLY, so the
# oracle keeps its ability to FAIL with no env probe in production.
#
# Encapsulation: the raw-buffer `memcmp` + the string-byte hash use
# `Span.unsafe_ptr()` (a concrete-origin borrow, NOT `UnsafePointer` in any
# public signature) — see `_CDNativeKeyCol.row_eq` / `_cd_hash_bytes`. No
# wildcard origin, no `unsafe_from_address`.


@always_inline
def _cd_mix_u64(x: UInt64) -> UInt64:
    """splitmix64 finalizer — the integer group-key hash. A good avalanche mix
    so the open-address table's collision chains stay short on int keys."""
    var z = x + UInt64(0x9E3779B97F4A7C15)
    z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> 31)


@always_inline
def _cd_hash_i64(v: Int64) -> UInt64:
    """Hash an int64 group-key cell from its RAW bits (no String render)."""
    return _cd_mix_u64(v.cast[DType.uint64]())


# ★ THE HASH OF A NULL KEY CELL, one constant for every key DType. A NULL key
# cell has NO value to hash: its data word is whatever the writer left there (0
# for `allocate_nullable`, arbitrary for a parquet page), and hashing THAT would
# land a null INT key row in the bucket of a real key. Every null cell hashes HERE instead, in
# every key column, so the open-address probe brings the null rows together and
# `row_eq` (which tests validity FIRST) settles the rest. The value is
# arbitrary — correctness comes from `row_eq`, not from this constant — but it
# must not be the hash of a LIKELY key, so it is not 0 and not
# `_cd_hash_i64(0)`.
comptime _CD_NULL_KEY_HASH: UInt64 = UInt64(0xD1B54A32D192ED03)

# ★ The composite-key rendering of a NULL cell in the String-key oracle fold.
# A real STRING cell renders `<len>:<bytes>` (leading DIGIT) and a real INT cell
# renders `#<v>` (leading `#`), so a leading `~` cannot be produced by either —
# which is what keeps a NULL from aliasing a genuine value, `''` included.
comptime _CD_NULL_KEY_RENDER: StaticString = "~NULL~"


@always_inline
def _cd_hash_bytes[O: Origin](imm s: Span[UInt8, O]) -> UInt64:
    """FNV-1a over a STRING group-key cell's RAW Arrow bytes (the zero-copy
    string_t view — offset+len into the data buffer), no String render."""
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(s)):
        h = h ^ UInt64(Int(s[i]))
        h = h * UInt64(0x100000001B3)
    return h


@always_inline
def _cd_hash_combine(acc: UInt64, h: UInt64) -> UInt64:
    """Boost-style hash_combine — fold a per-key hash into the composite-key
    accumulator (order-sensitive, so [brand,type,size] != [type,brand,size])."""
    return acc ^ (h + UInt64(0x9E3779B97F4A7C15) + (acc << 6) + (acc >> 2))


# A pre-extracted NATIVE group-key column for the native-hash fold: per-row
# precomputed hash + the native cell value kept for the on-collision equality
# compare AND the representative-row emit. NO per-row String is materialized:
# INT keys keep the int64 values; STRING keys keep the source `StringArray` and
# reach each cell's bytes via the zero-copy `get_span` (offset+len view). A null
# cell of any key DType marks `nulls[r]=True` and hashes to `_CD_NULL_KEY_HASH`;
# `cell_eq` tests validity before the native compare.
struct _CDNativeKeyCol(Movable):
    var arrow_type: ArrowType
    var is_string: Bool
    var nulls: List[Bool]        # per-row null flag
    var hashes: List[UInt64]     # per-row hash of the cell (native value / bytes)
    var i64_vals: List[Int64]    # per-row int64 value (INT keys); empty for STRING
    var strs: StringArray[HeapRegion]  # the STRING column (STRING keys); empty for INT

    def __init__(
        out self,
        arrow_type: ArrowType,
        is_string: Bool,
        var nulls: List[Bool],
        var hashes: List[UInt64],
        var i64_vals: List[Int64],
        var strs: StringArray[HeapRegion],
    ):
        self.arrow_type = arrow_type
        self.is_string = is_string
        self.nulls = nulls^
        self.hashes = hashes^
        self.i64_vals = i64_vals^
        self.strs = strs^

    def row_eq(self, a: Int, b: Int) raises -> Bool:
        """True iff this key's cell at row `a` equals its cell at row `b`.

        The SAME-COLUMN spelling of `cell_eq`, which holds the one definition.
        Kept because every single-batch caller reads better this way, and
        because a same-column compare cannot be written wrong here."""
        return self.cell_eq(a, self, b)

    def cell_eq(self, a: Int, imm other: Self, b: Int) raises -> Bool:
        """True iff THIS key's cell at row `a` equals `other`'s cell at row `b`,
        by NATIVE value (int64 `==`, or STRING `memcmp` on the raw Arrow bytes)
        — the on-collision equality resolution. NO String render.

        ⭐ TWO COLUMNS, NOT ONE, AND THAT IS THE WHOLE REASON THIS EXISTS. The
        mixed fold runs over the collect's batch LIST instead of over one
        concatenated batch, so the retained
        representative row of a group and the row being probed live in
        DIFFERENT batches and therefore in different `_CDNativeKeyCol`s. Writing
        that compare a second time beside `row_eq` is how the two spellings
        would drift; there is one body and `row_eq` delegates to it.

        ⚠ THE CALLER MUST HAVE ESTABLISHED THAT BOTH COLUMNS ARE THE SAME KEY of
        the same aggregate — same `arrow_type`, same `is_string`. The mixed
        fold's own per-batch schema-agreement gate is what establishes it.

        ★ VALIDITY IS TESTED FIRST, AND IT HAS TO BE.
        SQL collapses every NULL key into ONE group, and a NULL is not equal to
        any value — including the one whose bytes it happens to share. In Arrow
        a NULL STRING cell and a genuine `''` ARE the same bytes (length 0), so
        the `memcmp` arm below compares them EQUAL; a NULL INT cell's data word
        is whatever the writer left there, and `==` compares it to a real key.
        Both are settled here, before either native compare runs."""
        if self.nulls[a] != other.nulls[b]:
            return False
        if self.nulls[a]:
            # Two NULL cells: ONE group (SQL GROUP BY), never per-row groups.
            return True
        if self.is_string:
            var la = self.strs.get_length(a)
            var lb = other.strs.get_length(b)
            if la != lb:
                return False
            if la == 0:
                return True
            var span_a = self.strs.get_span(a)
            var span_b = other.strs.get_span(b)
            # SAFETY: span_a / span_b are zero-copy borrows of the two columns'
            # own data buffers (both alive for this call; no realloc here). Both
            # are READ-ONLY for the memcmp; the pointers do not escape this
            # module. The length equality is checked above, so the `la`-byte
            # compare is in-bounds on both sides.
            return unsafe_memcmp(span_a.unsafe_ptr(), span_b.unsafe_ptr(), la) == 0
        return self.i64_vals[a] == other.i64_vals[b]


def _cd_extract_native_key_col(
    imm batch: RecordBatch, col_idx: Int
) raises -> Optional[_CDNativeKeyCol]:
    """Extract a group-key column ONCE into a native-hash representation (per-row
    hash + native values), NO per-row String render. Returns None for an
    out-of-envelope key DType (matching `_cd_extract_key_col`'s envelope:
    STRING / INT32 / INT64)."""
    var n = batch.num_rows()
    var at = batch.column_arrow_type(col_idx)
    var nulls = List[Bool](capacity=n)
    var hashes = List[UInt64](capacity=n)
    var i64_vals = List[Int64]()
    if at == ArrowType.STRING:
        var sa = batch.column_as_string(col_idx)
        for r in range(n):
            if sa.is_null(r):
                nulls.append(True)
                hashes.append(_CD_NULL_KEY_HASH)
            else:
                nulls.append(False)
                var span = sa.get_span(r)
                hashes.append(_cd_hash_bytes(span))
        return Optional[_CDNativeKeyCol](
            _CDNativeKeyCol(at, True, nulls^, hashes^, i64_vals^, sa^)
        )
    elif at == ArrowType.INT64 or at == ArrowType.INT32:
        i64_vals = List[Int64](capacity=n)
        # ★ BOTH INT ARMS CONSULT VALIDITY, exactly as the STRING arm above
        # does. A null INT key row declared non-null would have its raw data
        # word hashed and compared as a real key, and the row would JOIN THE
        # GROUP ITS BYTES LAND IN — a wrong COUNT under a row set that still
        # looks right. `c.is_null(r)` is the column view's own validity; the
        # value is still read (an Arrow null slot holds SOME word) but it is
        # never hashed.
        if at == ArrowType.INT64:
            var c = batch.column_as_primitive_int64(col_idx)
            for r in range(n):
                var v = Int64(c.get(r))
                i64_vals.append(v)
                if c.is_null(r):
                    nulls.append(True)
                    hashes.append(_CD_NULL_KEY_HASH)
                else:
                    nulls.append(False)
                    hashes.append(_cd_hash_i64(v))
        else:
            var c = batch.column_as_primitive_int32(col_idx)
            for r in range(n):
                var v = Int64(c.get(r))
                i64_vals.append(v)
                if c.is_null(r):
                    nulls.append(True)
                    hashes.append(_CD_NULL_KEY_HASH)
                else:
                    nulls.append(False)
                    hashes.append(_cd_hash_i64(v))
        var empty = StringArray.from_strings(List[String]())
        return Optional[_CDNativeKeyCol](
            _CDNativeKeyCol(at, False, nulls^, hashes^, i64_vals^, empty^)
        )
    else:
        return None


def _cd_native_keys_equal(
    imm key_cols: List[_CDNativeKeyCol], a_row: Int, b_row: Int, n_keys: Int
) raises -> Bool:
    """True iff EVERY group key's cell at `a_row` equals its cell at `b_row`
    (native value compare across all keys) — the composite-key equality the
    open-address table uses to resolve a hash-bucket collision."""
    for k in range(n_keys):
        if not key_cols[k].row_eq(a_row, b_row):
            return False
    return True


# Serial-fold scale ceiling (mirrors the in-mem agg ceiling rationale): the
# per-group exact-set fold materializes one `Set[Int64]` per (group, agg). The q16
# join output is well within this; an above-scale resident batch declines (None ->
# the caller falls back / raises a clean cap-gap, never a crash).
comptime _CD_FOLD_MAX_ROWS: Int = 8_000_000


def agg_all_count_distinct(imm agg_data: AggregateData) -> Bool:
    """True iff the agg has >=1 group key AND EVERY agg expr is AGG_COUNT_DISTINCT
    — the GROUPED all-CD shape `fold_grouped_count_distinct_over_batch` serves (the
    variable-size distinct SET the fixed-cell AggSpec op-set / scalar fold both
    decline). The shared gate the resident-batch agg kernel + the typed parquet-leaf
    CD arms use to route to the CD fold BEFORE the descriptor build (which declines
    CD)."""
    if len(agg_data.group_by) < 1:
        return False
    if len(agg_data.agg_exprs) < 1:
        return False
    for a in range(len(agg_data.agg_exprs)):
        if agg_data.agg_exprs[a].func != AGG_COUNT_DISTINCT:
            return False
    return True


def agg_scalar_all_count_distinct(imm agg_data: AggregateData) -> Bool:
    """True iff the agg has 0 group keys AND EVERY agg expr is AGG_COUNT_DISTINCT —
    the 0-key (ungrouped) all-CD shape `fold_scalar_count_distinct_over_batch`
    serves. The 0-key sibling of `agg_all_count_distinct`."""
    if len(agg_data.group_by) != 0:
        return False
    if len(agg_data.agg_exprs) < 1:
        return False
    for a in range(len(agg_data.agg_exprs)):
        if agg_data.agg_exprs[a].func != AGG_COUNT_DISTINCT:
            return False
    return True


def _cd_col_idx(imm schema: Schema, name: String) -> Int:
    for i in range(schema.num_columns()):
        if String(schema.field_at_unchecked(i).name) == name:
            return i
    return -1


def _cd_strip_alias_col_ref(imm e: Expr) -> Optional[String]:
    """Return the bare column name of `e` (a col-ref or an alias-of-col-ref),
    else None (a computed / non-col-ref expr)."""
    if e.tag == EXPR_COL_REF:
        return Optional[String](String(e.col_ref_name()))
    if e.tag == EXPR_ALIAS:
        ref c = e.alias_child_ref()
        if c.tag == EXPR_COL_REF:
            return Optional[String](String(c.col_ref_name()))
    return None


def _cd_key_dtype_ok(at: ArrowType) -> Bool:
    """Group-key DType envelope: STRING or INT32/INT64."""
    return (
        at == ArrowType.STRING
        or at == ArrowType.INT32
        or at == ArrowType.INT64
    )


# A pre-extracted GROUP-KEY column: a flat per-row STRING rendering of the cell
# value (STRING cells verbatim; INT cells decimal-formatted) + the original-typed
# value (kept so the emit re-materializes the key column in its source DType). A
# null cell renders as a sentinel that cannot collide with a real value.
struct _CDKeyCol(Copyable, Movable):
    var rendered: List[String]   # per-row composite-key contribution
    var arrow_type: ArrowType    # the key's source DType (for the emit)
    var i64_vals: List[Int64]    # INT key values (for the INT emit); empty for STRING
    var str_vals: List[String]   # STRING key values (for the STRING emit); empty for INT
    var nulls: List[Bool]

    def __init__(
        out self,
        var rendered: List[String],
        arrow_type: ArrowType,
        var i64_vals: List[Int64],
        var str_vals: List[String],
        var nulls: List[Bool],
    ):
        self.rendered = rendered^
        self.arrow_type = arrow_type
        self.i64_vals = i64_vals^
        self.str_vals = str_vals^
        self.nulls = nulls^


def _cd_extract_key_col(
    imm batch: RecordBatch, col_idx: Int
) raises -> Optional[_CDKeyCol]:
    """Extract a group-key column ONCE into a flat render + original-typed values.
    Returns None for an out-of-envelope key DType."""
    var n = batch.num_rows()
    var at = batch.column_arrow_type(col_idx)
    var rendered = List[String](capacity=n)
    var i64_vals = List[Int64]()
    var str_vals = List[String]()
    var nulls = List[Bool](capacity=n)
    if at == ArrowType.STRING:
        var sa = batch.column_as_string(col_idx)
        for r in range(n):
            if sa.is_null(r):
                nulls.append(True)
                # ★ A NULL KEY RENDERS A SENTINEL, not `""`. The composite key is a
                # byte-join of these renderings, and a NULL must not render to
                # anything a real cell can produce.
                rendered.append(String(_CD_NULL_KEY_RENDER))
                str_vals.append(String(""))
            else:
                var s = sa.get(r)
                nulls.append(False)
                # Length-prefix the rendered cell so two STRING keys can't alias
                # across the composite-key join (`"a" + "bc"` vs `"ab" + "c"`).
                rendered.append(String(s.byte_length()) + ":" + s)
                str_vals.append(s^)
    elif at == ArrowType.INT64 or at == ArrowType.INT32:
        var ca: PrimitiveArray[DType.int64]
        # ★ BOTH INT ARMS CONSULT VALIDITY here too, and THIS extractor is
        # shared with the grouped MIN/MAX fold at the bottom of this file, so a
        # null INT key matters to both folds, not only to COUNT(DISTINCT).
        #
        # ⚠ THE MASK IS READ FROM THE **SOURCE** COLUMN, NOT FROM `ca`. The
        # INT32 arm WIDENS into a fresh `allocate`d int64 array, which has no
        # validity bitmap at all — `ca.is_null(r)` there is False BY
        # CONSTRUCTION and would declare every null INT32 key non-null.
        var src_nulls = List[Bool](capacity=n)
        if at == ArrowType.INT64:
            ca = batch.column_as_primitive_int64(col_idx)
            for r in range(n):
                src_nulls.append(ca.is_null(r))
        else:
            var c32 = batch.column_as_primitive_int32(col_idx)
            ca = PrimitiveArray[DType.int64].allocate(n)
            for r in range(n):
                ca._typed_ptr_mut()[r] = Int64(c32.get(r))
                src_nulls.append(c32.is_null(r))
        for r in range(n):
            var v = Int64(ca.get(r))
            if src_nulls[r]:
                nulls.append(True)
                rendered.append(String(_CD_NULL_KEY_RENDER))
            else:
                nulls.append(False)
                rendered.append("#" + String(v))
            i64_vals.append(v)
    else:
        return None
    return Optional[_CDKeyCol](
        _CDKeyCol(rendered^, at, i64_vals^, str_vals^, nulls^)
    )


def fold_grouped_count_distinct_over_batch(
    imm agg_data: AggregateData,
    imm batch: RecordBatch,
    imm out_schema: Schema,
) raises -> Optional[RecordBatch]:
    """Fold a GROUPED `count_distinct(...)` over an ALREADY-RESIDENT batch into a
    result RecordBatch (n_keys key cols + n_aggs INT64 count cols), DECLINE-
    RETURNING.

    SCOPE (the q16 grouped-CD shape the single-INT-key sink declines): n_keys>=1
    over STRING/INT32/INT64 keys; EVERY agg is AGG_COUNT_DISTINCT over a plain
    col_ref of an INT32/INT64 DType. An out-of-envelope shape (non-CD agg,
    COUNT(*), a derived agg input, an unsupported key/input DType, above-scale)
    returns None.

    The fold is SERIAL (one `Set[Int64]` per (group, agg)) — value-stable +
    EXACT by construction (a real dedup, not an estimate). The count equals the
    String-key oracle's per-group distinct count byte-for-byte.

    Routes UNCONDITIONALLY to `_fold_grouped_cd_nativehash`
    (hash the NATIVE group-key columns directly — no per-row String render). The
    per-row-String-composite-key path (`_fold_grouped_cd_stringkey`)
    is the byte-equiv ORACLE, reached only by a DIRECT call from
    `tests/test_cd_grouped_fold.mojo`: both produce
    byte-identical grouped distinct counts (only the GROUP-KEY representation
    differs). No production gate selects the oracle."""
    return _fold_grouped_cd_nativehash(agg_data, batch, out_schema)


def _fold_grouped_cd_nativehash(
    imm agg_data: AggregateData,
    imm batch: RecordBatch,
    imm out_schema: Schema,
) raises -> Optional[RecordBatch]:
    """The native-column-hash grouped COUNT(DISTINCT) fold. Hashes the raw
    group-key columns (splitmix64 over int64 bits / FNV-1a over the Arrow
    string_t byte view) into an open-address hash table, resolving collisions by
    NATIVE cell compare (int64 `==` / string `memcmp`). NO per-row String render
    / composite-key concatenation / `Dict[String,Int]` probe. The per-group
    exact `Set[Int64]` distinct semantics + the first-occurrence group ORDER are
    byte-identical to `_fold_grouped_cd_stringkey`; only the group-key
    representation changes. Same DECLINE envelope."""
    var n_keys = len(agg_data.group_by)
    var n_aggs = len(agg_data.agg_exprs)
    if n_keys < 1 or n_aggs < 1:
        return None
    var n_rows = batch.num_rows()
    if n_rows > _CD_FOLD_MAX_ROWS:
        return None

    # --- Resolve + pre-extract group-key columns (NATIVE, no String render). --
    var key_cols = List[_CDNativeKeyCol]()
    var key_names = List[String]()
    for k in range(n_keys):
        ref ke = agg_data.group_by[k]
        var kn_opt = _cd_strip_alias_col_ref(ke)
        if not kn_opt:
            return None
        var kn = kn_opt.value()
        var ki = _cd_col_idx(batch.schema, kn)
        if ki < 0:
            return None
        if not _cd_key_dtype_ok(batch.column_arrow_type(ki)):
            return None
        var kc_opt = _cd_extract_native_key_col(batch, ki)
        if not kc_opt:  # cov: unreachable the extractor reads the same column type the dtype gate above admitted
            return None  # cov: unreachable see the line above
        key_cols.append(kc_opt.take())
        key_names.append(kn)

    # --- Resolve CD agg input columns (INT32/INT64 col_ref only). ------------
    var agg_input_i64 = List[List[Int64]]()  # per-agg flat int64 input values
    var agg_input_null = List[List[Bool]]()
    var out_names = List[String]()
    for a in range(n_aggs):
        ref ae = agg_data.agg_exprs[a]
        if ae.func != AGG_COUNT_DISTINCT:
            return None
        if not ae.child:
            return None
        var in_opt = _cd_strip_alias_col_ref(ae.child.value())
        if not in_opt:
            return None
        var ci = _cd_col_idx(batch.schema, in_opt.value())
        if ci < 0:
            return None
        var at = batch.column_arrow_type(ci)
        if at != ArrowType.INT64 and at != ArrowType.INT32:
            return None
        # ★ THE NULL SKIP. `nulls` IS consulted by the accumulate loop below
        # (`if not agg_input_null[a][r]`), so it must carry the column's real
        # validity: a null-tracking structure told there are never any nulls
        # would add every NULL row's DATA WORD (Arrow leaves it unspecified) to
        # the group's distinct SET as a value, and `GROUP BY k ->
        # count(DISTINCT v)` would come back ONE TOO HIGH per group holding a
        # NULL whose payload is not already present.
        #
        # ⚠ THIS IS THE LIVE KERNEL; `_fold_grouped_cd_stringkey` IS TEST-ONLY
        # (the public entry routes UNCONDITIONALLY here). A null skip present
        # in the byte-equiv ORACLE and missing here would not be seen by an
        # oracle test whose fixtures are null-FREE; only a differential over
        # null-bearing inputs catches one of the two being wrong.
        #
        # ⚠ `c.is_null(r)`, NOT `ValidityLanes`: kernels that read values
        # through a raw base pointer + row index need a separate validity
        # CHANNEL. This fold holds the COLUMN VIEW, which already carries
        # validity — the spelling its two siblings in this file use. DuckDB /
        # SQL standard: DISTINCT NON-NULL values, and 0 (not NULL) when every
        # value is NULL.
        var vals = List[Int64](capacity=n_rows)
        var nulls = List[Bool](capacity=n_rows)
        if at == ArrowType.INT64:
            var c = batch.column_as_primitive_int64(ci)
            for r in range(n_rows):
                vals.append(Int64(c.get(r)))
                nulls.append(c.is_null(r))
        else:
            var c = batch.column_as_primitive_int32(ci)
            for r in range(n_rows):
                vals.append(Int64(c.get(r)))
                nulls.append(c.is_null(r))
        agg_input_i64.append(vals^)
        agg_input_null.append(nulls^)
        if ae.alias_name:
            out_names.append(String(ae.alias_name.value()))
        else:
            out_names.append("count_distinct_" + String(a))

    # --- Serial group fold via an open-address hash table over the NATIVE keys.
    #     Slots are assigned in FIRST-OCCURRENCE order (byte-identical group
    #     ORDER to the Dict[String,Int] fold); one representative source row per
    #     group; per-group per-agg distinct-value Set[Int64]. -------------------
    var slot_keyrows = List[Int]()   # first source row per group
    var slot_hashes = List[UInt64]()  # composite hash per group (for resize)
    var slot_sets = List[List[Set[Int64]]]()
    var n_groups = 0

    var cap = 1024
    var table = List[Int](capacity=cap)  # slot index at each bucket; -1 == empty
    for _ in range(cap):
        table.append(-1)
    var mask = cap - 1

    for r in range(n_rows):
        # ★ NO ROW IS SKIPPED FOR A NULL KEY. SQL `GROUP BY` collapses every
        # NULL key into ONE group, and that group is a group like any other —
        # it is neither dropped, nor split per row, nor merged into a real key.
        # Skipping null-key rows would remove them from the RESULT ROW SET
        # entirely (a caller joining the output would join against a hole).
        #
        # A null cell hashes to `_CD_NULL_KEY_HASH` and `row_eq` matches it only
        # against another null cell OF THE SAME KEY, so a COMPOSITE key
        # (NULL, 'x') and (NULL, 'y') remain two different groups.

        # Composite key hash = order-sensitive combine of the per-key hashes.
        var h = UInt64(1469598103934665603)
        for k in range(n_keys):
            h = _cd_hash_combine(h, key_cols[k].hashes[r])

        # Open-address probe: match on (hash, native-key equality).
        var slot = -1
        var pos = Int(h & UInt64(mask))
        while True:
            var e = table[pos]
            if e < 0:
                break  # empty bucket -> a new group lands here
            if slot_hashes[e] == h and _cd_native_keys_equal(
                key_cols, slot_keyrows[e], r, n_keys
            ):
                slot = e
                break
            pos = (pos + 1) & mask

        if slot < 0:
            slot = n_groups
            table[pos] = slot
            slot_keyrows.append(r)
            slot_hashes.append(h)
            var fresh = List[Set[Int64]]()
            for _a in range(n_aggs):
                fresh.append(Set[Int64]())
            slot_sets.append(fresh^)
            n_groups += 1
            # Grow + rehash at load factor 0.7 (keeps probe chains short).
            if n_groups * 10 >= cap * 7:
                cap = cap * 2
                mask = cap - 1
                var ntable = List[Int](capacity=cap)
                for _ in range(cap):
                    ntable.append(-1)
                for s in range(n_groups):
                    var hp = Int(slot_hashes[s] & UInt64(mask))
                    while ntable[hp] >= 0:
                        hp = (hp + 1) & mask
                    ntable[hp] = s
                table = ntable^

        # Accumulate each agg's input value into the group's distinct set.
        ref sets = slot_sets[slot]
        for a in range(n_aggs):
            if not agg_input_null[a][r]:
                sets[a].add(agg_input_i64[a][r])

    # --- Readback: emit n_keys key cols (source DType) + n_aggs INT64 counts. --
    var rbb = RecordBatchBuilder.with_capacity(n_groups)
    var out_sb = SchemaBuilder()

    for k in range(n_keys):
        ref kc = key_cols[k]
        # ★ A group whose representative row holds a NULL key IS the NULL
        # group, and it has to READ BACK as NULL. A key column emitted with no
        # validity renders the NULL group as `''` / `0`: the row set would be
        # right and the key value would be a lie.
        #
        # ⚠ VALIDITY IS EMITTED ONLY WHEN A NULL GROUP EXISTS. A null-free input
        # therefore takes `from_strings_with_validity`'s all-valid fast path /
        # the plain `allocate`, i.e. NO bitmap — which is what `_build_grouped_cd_parallel_sink_data`'s drop-in
        # byte-identity guarantee is stated against (it declines a null-bearing
        # key, so it only ever has to match this branch).
        var key_has_null = False
        for g in range(n_groups):
            if kc.nulls[slot_keyrows[g]]:
                key_has_null = True
                break
        if kc.is_string:
            var svals = List[String](capacity=n_groups)
            var kvalid = List[Bool](capacity=n_groups)
            for g in range(n_groups):
                if kc.nulls[slot_keyrows[g]]:
                    svals.append(String(""))
                    kvalid.append(False)
                else:
                    svals.append(kc.strs.get(slot_keyrows[g]))
                    kvalid.append(True)
            var sa = StringArray.from_strings_with_validity(svals, kvalid)
            rbb.add_column(Column.from_string(sa^))
            out_sb.add_field(
                Field(key_names[k], ArrowType.STRING, key_has_null)
            )
        elif key_has_null:
            # INT32/INT64 key -> emit INT64 (the join/agg widen the int key family).
            var narr = PrimitiveArray[DType.int64].allocate_nullable(n_groups)
            for g in range(n_groups):
                narr.store[1](g, kc.i64_vals[slot_keyrows[g]])
            # Values FIRST, then the nulls: a store marks its index VALID.
            for g in range(n_groups):
                if kc.nulls[slot_keyrows[g]]:
                    narr._set_null(g)
            rbb.add_column(Column.from_primitive[DType.int64](narr^))
            out_sb.add_field(Field(key_names[k], ArrowType.INT64, True))
        else:
            var arr = PrimitiveArray[DType.int64].allocate(n_groups)
            for g in range(n_groups):
                arr._typed_ptr_mut()[g] = kc.i64_vals[slot_keyrows[g]]
            rbb.add_column(Column.from_primitive[DType.int64](arr^))
            out_sb.add_field(Field(key_names[k], ArrowType.INT64, False))

    for a in range(n_aggs):
        var arr = PrimitiveArray[DType.int64].allocate(n_groups)
        for g in range(n_groups):
            arr._typed_ptr_mut()[g] = Int64(len(slot_sets[g][a]))
        rbb.add_column(Column.from_primitive[DType.int64](arr^))
        out_sb.add_field(Field(out_names[a], ArrowType.INT64, False))

    _ = out_schema
    var out_batch = rbb.build(out_sb.build())
    return Optional[RecordBatch](out_batch^)


def _fold_grouped_cd_stringkey(
    imm agg_data: AggregateData,
    imm batch: RecordBatch,
    imm out_schema: Schema,
) raises -> Optional[RecordBatch]:
    """The per-row-String-composite-key grouped COUNT(DISTINCT) fold —
    TEST-ONLY: nothing in production reaches it; it exists purely as
    the byte-equiv ORACLE for `_fold_grouped_cd_nativehash`, called DIRECTLY by
    `tests/test_cd_grouped_fold.mojo`. Renders each
    group-key cell to a length-prefixed String, byte-joins the composite key, and
    probes a `Dict[String, Int]`. Same DECLINE envelope + exact per-group
    `Set[Int64]` distinct semantics as the native-hash path — that identity is
    exactly what the oracle asserts, so DO NOT delete it."""
    var n_keys = len(agg_data.group_by)
    var n_aggs = len(agg_data.agg_exprs)
    if n_keys < 1 or n_aggs < 1:
        return None
    var n_rows = batch.num_rows()
    if n_rows > _CD_FOLD_MAX_ROWS:
        return None

    # --- Resolve + pre-extract group-key columns. ----------------------------
    var key_cols = List[_CDKeyCol]()
    var key_names = List[String]()
    for k in range(n_keys):
        ref ke = agg_data.group_by[k]
        var kn_opt = _cd_strip_alias_col_ref(ke)
        if not kn_opt:
            return None
        var kn = kn_opt.value()
        var ki = _cd_col_idx(batch.schema, kn)
        if ki < 0:
            return None
        if not _cd_key_dtype_ok(batch.column_arrow_type(ki)):
            return None
        var kc_opt = _cd_extract_key_col(batch, ki)
        if not kc_opt:  # cov: unreachable the extractor reads the same column type the dtype gate above admitted
            return None  # cov: unreachable see the line above
        key_cols.append(kc_opt.take())
        key_names.append(kn)

    # --- Resolve CD agg input columns (INT32/INT64 col_ref only). ------------
    var agg_input_i64 = List[List[Int64]]()  # per-agg flat int64 input values
    var agg_input_null = List[List[Bool]]()
    var out_names = List[String]()
    for a in range(n_aggs):
        ref ae = agg_data.agg_exprs[a]
        if ae.func != AGG_COUNT_DISTINCT:
            return None
        if not ae.child:
            return None
        var in_opt = _cd_strip_alias_col_ref(ae.child.value())
        if not in_opt:
            return None
        var ci = _cd_col_idx(batch.schema, in_opt.value())
        if ci < 0:
            return None
        var at = batch.column_arrow_type(ci)
        if at != ArrowType.INT64 and at != ArrowType.INT32:
            return None
        # Pre-extract the input column ONCE.
        #
        # ★ THE NULL SKIP. `nulls` is CONSULTED by the accumulate loop below
        # (`if not agg_input_null[a][r]`), so it must carry the column's real
        # validity: otherwise every NULL row's DATA WORD — Arrow leaves it
        # unspecified, and 0 is what every writer stores — would be added to
        # the group's distinct SET as if it were a value, and
        # `count(DISTINCT x)` over a nullable INT column would come back ONE
        # TOO HIGH whenever the column held a NULL whose payload is not
        # already present.
        #
        # ⚠ AND THE ANSWER MUST NOT DEPEND ON WHAT ELSE IS IN THE SELECT LIST.
        # The MIXED arm (`agg_mixed_cd_fold.mojo`) reads `c.is_null(r)` and is
        # chosen when the plan mixes a CD with a non-CD aggregate, so
        # `SELECT count(DISTINCT i) FROM t` and
        # `SELECT count(*), count(DISTINCT i) FROM t` must skip nulls the same
        # way over the same column.
        #
        # SQL standard / DuckDB: `count(DISTINCT x)` counts DISTINCT NON-NULL
        # values, and is 0 (not NULL) when every value is NULL.
        var vals = List[Int64](capacity=n_rows)
        var nulls = List[Bool](capacity=n_rows)
        if at == ArrowType.INT64:
            var c = batch.column_as_primitive_int64(ci)
            for r in range(n_rows):
                vals.append(Int64(c.get(r)))
                nulls.append(c.is_null(r))
        else:
            var c = batch.column_as_primitive_int32(ci)
            for r in range(n_rows):
                vals.append(Int64(c.get(r)))
                nulls.append(c.is_null(r))
        agg_input_i64.append(vals^)
        agg_input_null.append(nulls^)
        # Output name (the alias, else a positional default).
        if ae.alias_name:
            out_names.append(String(ae.alias_name.value()))
        else:
            out_names.append("count_distinct_" + String(a))

    # --- Serial group fold: per-group per-agg distinct-value Set[Int64]. ------
    var slot_of = Dict[String, Int]()
    var slot_keyrows = List[Int]()  # one representative source row per group
    var slot_sets = List[List[Set[Int64]]]()

    for r in range(n_rows):
        # ★ No row is skipped for a NULL key; see the native-hash fold above. Here a NULL cell renders to `_CD_NULL_KEY_RENDER`, which no
        # real STRING (`<len>:<bytes>`) or INT (`#<v>`) cell can produce, so the
        # composite key groups the nulls together without aliasing a value.
        #
        # Composite key = length-prefixed byte-join of the per-key renderings.
        var ckey = String("")
        for k in range(n_keys):
            ckey += key_cols[k].rendered[r]
            ckey += "|"

        var slot: Int
        if ckey in slot_of:
            slot = slot_of[ckey]
        else:
            slot = len(slot_sets)
            slot_of[ckey] = slot
            slot_keyrows.append(r)
            var fresh = List[Set[Int64]]()
            for _a in range(n_aggs):
                fresh.append(Set[Int64]())
            slot_sets.append(fresh^)

        # Accumulate each agg's input value into the group's distinct set.
        ref sets = slot_sets[slot]
        for a in range(n_aggs):
            if not agg_input_null[a][r]:
                sets[a].add(agg_input_i64[a][r])

    # --- Readback: emit n_keys key cols (source DType) + n_aggs INT64 counts. -
    var n_groups = len(slot_sets)
    var rbb = RecordBatchBuilder.with_capacity(n_groups)
    var out_sb = SchemaBuilder()

    for k in range(n_keys):
        ref kc = key_cols[k]
        # ★ The byte-equiv ORACLE has to emit the NULL group the same way the
        # native-hash fold does, or a differential between the two reports a
        # disagreement that is only about the emit.
        var key_has_null = False
        for g in range(n_groups):
            if kc.nulls[slot_keyrows[g]]:
                key_has_null = True
                break
        if kc.arrow_type == ArrowType.STRING:
            var svals = List[String](capacity=n_groups)
            var kvalid = List[Bool](capacity=n_groups)
            for g in range(n_groups):
                svals.append(kc.str_vals[slot_keyrows[g]])
                kvalid.append(not kc.nulls[slot_keyrows[g]])
            var sa = StringArray.from_strings_with_validity(svals, kvalid)
            rbb.add_column(Column.from_string(sa^))
            out_sb.add_field(
                Field(key_names[k], ArrowType.STRING, key_has_null)
            )
        elif key_has_null:
            var narr = PrimitiveArray[DType.int64].allocate_nullable(n_groups)
            for g in range(n_groups):
                narr.store[1](g, kc.i64_vals[
                    _cd_i64_index_of_row(kc, slot_keyrows[g])
                ])
            for g in range(n_groups):
                if kc.nulls[slot_keyrows[g]]:
                    narr._set_null(g)
            rbb.add_column(Column.from_primitive[DType.int64](narr^))
            out_sb.add_field(Field(key_names[k], ArrowType.INT64, True))
        else:
            # INT32/INT64 key -> emit INT64 (the join/agg widen the int key family).
            var arr = PrimitiveArray[DType.int64].allocate(n_groups)
            for g in range(n_groups):
                arr._typed_ptr_mut()[g] = kc.i64_vals[
                    _cd_i64_index_of_row(kc, slot_keyrows[g])
                ]
            rbb.add_column(Column.from_primitive[DType.int64](arr^))
            out_sb.add_field(Field(key_names[k], ArrowType.INT64, False))

    for a in range(n_aggs):
        var arr = PrimitiveArray[DType.int64].allocate(n_groups)
        for g in range(n_groups):
            arr._typed_ptr_mut()[g] = Int64(len(slot_sets[g][a]))
        rbb.add_column(Column.from_primitive[DType.int64](arr^))
        out_sb.add_field(Field(out_names[a], ArrowType.INT64, False))

    _ = out_schema
    var out_batch = rbb.build(out_sb.build())
    return Optional[RecordBatch](out_batch^)


def _cd_i64_index_of_row(imm kc: _CDKeyCol, row: Int) -> Int:
    """The index into `kc.i64_vals` for source `row`. For an INT key column the
    i64_vals list is appended PER ROW — including a NULL row, whose data word is
    appended and simply never rendered or compared — so the index == row. Kept
    as a named helper so the emit intent is explicit.

    ⚠ The served envelope admits a nullable INT key, and no null-key row is
    filtered before the emit: a NULL row's index is used like any other, and
    `kc.nulls` decides whether its group reads back as NULL."""
    return row


def fold_scalar_count_distinct_over_batch(
    imm agg_data: AggregateData,
    imm batch: RecordBatch,
) raises -> Optional[RecordBatch]:
    """Fold a 0-KEY (scalar / ungrouped) `count_distinct(...)` over an ALREADY-
    RESIDENT batch into a SINGLE-ROW result RecordBatch (n_aggs INT64 count cols),
    DECLINE-RETURNING.

    SCOPE (the ungrouped CD shape the parallel `CountDistinctAggSink` also serves
    at n_keys==0, byte-identically): 0 group keys; EVERY agg is AGG_COUNT_DISTINCT
    over a plain col_ref of an INT32/INT64 DType. An out-of-envelope shape (a group
    key present, a non-CD agg, COUNT(*), a derived agg input, an unsupported input
    DType, above-scale) returns None.

    The fold is SERIAL (one `Set[Int64]` per agg over the whole column) — value-
    stable + EXACT by construction (a real dedup, not an estimate). The count ==
    the walker's ungrouped distinct count byte-for-byte. DuckDB `COUNT(DISTINCT x)`
    over an empty input is 0 (not NULL); an empty column naturally yields 0."""
    var n_keys = len(agg_data.group_by)
    var n_aggs = len(agg_data.agg_exprs)
    if n_keys != 0 or n_aggs < 1:
        return None
    var n_rows = batch.num_rows()
    if n_rows > _CD_FOLD_MAX_ROWS:
        return None

    var sets = List[Set[Int64]]()
    var out_names = List[String]()
    for a in range(n_aggs):
        ref ae = agg_data.agg_exprs[a]
        if ae.func != AGG_COUNT_DISTINCT:
            return None
        if not ae.child:
            return None
        var in_opt = _cd_strip_alias_col_ref(ae.child.value())
        if not in_opt:
            return None
        var ci = _cd_col_idx(batch.schema, in_opt.value())
        if ci < 0:
            return None
        var at = batch.column_arrow_type(ci)
        if at != ArrowType.INT64 and at != ArrowType.INT32:
            return None
        # ★ THE NULL SKIP. Without the `is_null` test every NULL row's
        # unspecified data word would join the distinct SET and
        # `SELECT count(DISTINCT i) FROM t` would come back one too high. Same
        # rule as the grouped sibling above, same rationale — see there for why
        # the answer must not depend on what else is in the SELECT list.
        var s = Set[Int64]()
        if at == ArrowType.INT64:
            var c = batch.column_as_primitive_int64(ci)
            for r in range(n_rows):
                if c.is_null(r):
                    continue
                s.add(Int64(c.get(r)))
        else:
            var c = batch.column_as_primitive_int32(ci)
            for r in range(n_rows):
                if c.is_null(r):
                    continue
                s.add(Int64(c.get(r)))
        sets.append(s^)
        if ae.alias_name:
            out_names.append(String(ae.alias_name.value()))
        else:
            out_names.append("count_distinct_" + String(a))

    # Emit a single-row batch: n_aggs INT64 count columns.
    var rbb = RecordBatchBuilder.with_capacity(1)
    var out_sb = SchemaBuilder()
    for a in range(n_aggs):
        var arr = PrimitiveArray[DType.int64].allocate(1)
        arr._typed_ptr_mut()[0] = Int64(len(sets[a]))
        rbb.add_column(Column.from_primitive[DType.int64](arr^))
        out_sb.add_field(Field(out_names[a], ArrowType.INT64, False))
    var out_batch = rbb.build(out_sb.build())
    return Optional[RecordBatch](out_batch^)


# =============================================================================
# GROUPED STRING MIN/MAX serial fold (column-TYPED String MIN/MAX)
# =============================================================================
#
# WHAT THIS IS — the grouped serial `min(str)` / `max(str)` fold for the shape
# the fixed-cell `HashAggUntypedSink` (the `_build_and_run_agg` descriptor
# route) DECLINES: a STRING agg VALUE is not fixed-width (no `AggSpec` byte-slab
# cell), so `_agg_input_supported(STRING)` returns False and the descriptor build
# bails. The column DynAccumulator engine (`MinUtf8Acc` / `MaxUtf8Acc`, tags
# ACC_MIN_UTF8 / ACC_MAX_UTF8 in `accumulator_factory.mojo`) DOES carry the
# variable-length String state — but it is not reachable from the plan walker
# (`execute_agg_plan`) parquet-leaf route, which only builds descriptors.
#
# This is the string-value sibling of `fold_grouped_count_distinct_over_batch`
# (also a variable-state agg the fixed-cell descriptor route declines): decode
# the parquet leaf to a resident batch (the caller —
# `try_run_grouped_string_minmax_over_filtered_scan`), then fold the lexicographic
# per-group min/max serially. Value-identical to the column ACC_MIN_UTF8 /
# ACC_MAX_UTF8 kernel (the lexicographic UTF-8 byte-order compare Mojo `String`
# `<` / `>` performs); the test oracle is a HAND lexicographic min/max.
#
# SCOPE: n_keys>=1 over STRING/INT32/INT64 keys (composite key reuses the CD
# fold's key extraction); EVERY agg is AGG_MIN or AGG_MAX over a plain col_ref of
# a STRING / LARGE_STRING DType. Any other shape (a non-MIN/MAX agg, a numeric
# agg input, a derived agg input, an unsupported key DType, above-scale) returns
# None — the caller falls through to the fixed-cell descriptor route (numeric
# MIN/MAX stay on the fast path).
# =============================================================================


def fold_grouped_string_minmax_over_batch(
    imm agg_data: AggregateData,
    imm batch: RecordBatch,
) raises -> Optional[RecordBatch]:
    """Fold a GROUPED all-MIN/MAX-over-STRING agg over an ALREADY-RESIDENT batch
    into a result RecordBatch (n_keys key cols + n_aggs STRING min/max cols),
    DECLINE-RETURNING.

    The fold is SERIAL (one current-best `String` + any-seen flag per (group,
    agg)) — value-stable + the lexicographic per-group min/max the column
    ACC_MIN_UTF8 / ACC_MAX_UTF8 accumulators compute. NULL agg values are IGNORED
    (a group whose values are all null yields a NULL cell — DuckDB `min`/`max`
    semantics).
    An out-of-envelope shape (a non-MIN/MAX agg, a non-STRING agg input, a derived
    input, an unsupported key DType, above-scale) returns None."""
    # ⭐ THE ARMING WITNESS — recorded FIRST, before any guard, so it answers
    # "a caller armed this fold on this shape" and nothing else.
    agg_str_minmax_fold_record_call()
    var n_keys = len(agg_data.group_by)
    var n_aggs = len(agg_data.agg_exprs)
    if n_keys < 1 or n_aggs < 1:
        return None
    var n_rows = batch.num_rows()
    if n_rows > _CD_FOLD_MAX_ROWS:
        return None

    # =========================================================================
    # ⭐ PHASE A — RESOLVE EVERY DECLINE BEFORE TOUCHING A SINGLE ROW.
    # =========================================================================
    # ⛔⛔ THE ORDER OF THESE TWO PHASES IS LOAD-BEARING, AND NOT A STYLE
    # PREFERENCE. If this fold EXTRACTED the group-key columns first and
    # resolved the agg-input DType second, a NUMERIC grouped min/max — a shape
    # this fold must decline, and which the PARALLEL fixed-cell kernel owns —
    # would pay a full `_cd_extract_key_col` over every resident row (a
    # decimal-rendered heap `String` PER ROW, plus the widened i64 and null
    # lists) and only THEN look at the aggregate's input DType, return None,
    # and throw all of it away. On TPC-H q2 (`GROUP BY ps_partkey ->
    # MIN(ps_supplycost)` over the 4-table partsupp join) that is a measurable
    # slowdown with identical values. A decline that costs O(rows) is invisible
    # to every value test there is.
    #
    # ⚠ THE CALLER'S GATE IS THE PRIMARY GUARD — `grouped_string_minmax_servable_
    # for_schema` in `agg_extended_fold`, which is what the resident altitude
    # arms on so a numeric min/max never reaches this function. This phase
    # is the FLOOR underneath it: a decline-returning fold has more than one
    # caller, and with the phases in this order the price of a future caller
    # arming on the structural half alone is O(n_keys + n_aggs) rather than
    # O(rows). Keep BOTH; neither is redundant with the other.
    #
    # Declines are resolved keys first, then aggs, so which reason a given
    # out-of-envelope node declines for does not depend on this phase split.
    var key_names = List[String]()
    var key_idx = List[Int]()
    for k in range(n_keys):
        ref ke = agg_data.group_by[k]
        var kn_opt = _cd_strip_alias_col_ref(ke)
        if not kn_opt:
            return None
        var kn = kn_opt.value()
        var ki = _cd_col_idx(batch.schema, kn)
        if ki < 0:
            return None
        if not _cd_key_dtype_ok(batch.column_arrow_type(ki)):
            return None
        key_idx.append(ki)
        key_names.append(kn)

    # --- Resolve MIN/MAX agg input columns (STRING col_ref only). --------------
    var agg_is_min = List[Bool]()
    var agg_idx = List[Int]()
    var out_names = List[String]()
    for a in range(n_aggs):
        ref ae = agg_data.agg_exprs[a]
        if ae.func != AGG_MIN and ae.func != AGG_MAX:
            return None
        if not ae.child:
            return None
        var in_opt = _cd_strip_alias_col_ref(ae.child.value())
        if not in_opt:
            return None
        var ci = _cd_col_idx(batch.schema, in_opt.value())
        if ci < 0:
            return None
        var at = batch.column_arrow_type(ci)
        if at != ArrowType.STRING and at != ArrowType.LARGE_STRING:
            return None
        agg_idx.append(ci)
        agg_is_min.append(ae.func == AGG_MIN)
        if ae.alias_name:
            out_names.append(String(ae.alias_name.value()))
        else:
            out_names.append("minmax_" + String(a))

    # =========================================================================
    # PHASE B — every decline is behind us. NOW pay the per-row cost.
    # =========================================================================
    # ⛔ THE WORK WITNESS GOES HERE AND NOWHERE EARLIER. Every `return None`
    # above it is a cheap decline; everything below it is O(rows). Moving this
    # line up would make the regression test pass while the defect is present.
    agg_str_minmax_fold_record_row_work()
    var key_cols = List[_CDKeyCol]()
    for k in range(n_keys):
        var kc_opt = _cd_extract_key_col(batch, key_idx[k])
        if not kc_opt:  # cov: unreachable phase A admitted this column's type, and the extractor reads the same type
            return None  # cov: unreachable see the line above
        key_cols.append(kc_opt.take())

    var agg_vals = List[List[String]]()   # per-agg flat string input values
    var agg_null = List[List[Bool]]()
    for a in range(n_aggs):
        # Pre-extract the input column ONCE.
        var vals = List[String](capacity=n_rows)
        var nulls = List[Bool](capacity=n_rows)
        var sa = batch.column_as_string(agg_idx[a])
        for r in range(n_rows):
            if sa.is_null(r):
                nulls.append(True)
                vals.append(String(""))
            else:
                nulls.append(False)
                vals.append(sa.get(r))
        agg_vals.append(vals^)
        agg_null.append(nulls^)

    # --- Serial group fold: per-group per-agg current best + any-seen flag. ----
    var slot_of = Dict[String, Int]()
    var slot_keyrows = List[Int]()   # one representative source row per group
    var slot_best = List[List[String]]()
    var slot_seen = List[List[Bool]]()

    for r in range(n_rows):
        # ★ No row is skipped; a NULL key is ONE group. This fold shares
        # `_cd_extract_key_col` with the CD folds above, so the same NULL-key
        # rules hold over MIN/MAX as over COUNT(DISTINCT): a null-key row is
        # neither merged into the group its raw bytes would land in nor
        # dropped.
        var ckey = String("")
        for k in range(n_keys):
            ckey += key_cols[k].rendered[r]
            ckey += "|"

        var slot: Int
        if ckey in slot_of:
            slot = slot_of[ckey]
        else:
            slot = len(slot_best)
            slot_of[ckey] = slot
            slot_keyrows.append(r)
            var fresh_v = List[String]()
            var fresh_s = List[Bool]()
            for _a in range(n_aggs):
                fresh_v.append(String(""))
                fresh_s.append(False)
            slot_best.append(fresh_v^)
            slot_seen.append(fresh_s^)

        ref best = slot_best[slot]
        ref seen = slot_seen[slot]
        for a in range(n_aggs):
            if agg_null[a][r]:
                continue
            var v = agg_vals[a][r]
            if not seen[a]:
                seen[a] = True
                best[a] = v
            elif agg_is_min[a]:
                if v < best[a]:
                    best[a] = v
            else:
                if v > best[a]:
                    best[a] = v

    # --- Readback: n_keys key cols (source DType) + n_aggs STRING min/max cols. -
    var n_groups = len(slot_best)
    var rbb = RecordBatchBuilder.with_capacity(n_groups)
    var out_sb = SchemaBuilder()

    for k in range(n_keys):
        ref kc = key_cols[k]
        # ★ Emit the NULL group AS NULL; validity only when one exists, so a
        # null-free input carries no bitmap.
        var key_has_null = False
        for g in range(n_groups):
            if kc.nulls[slot_keyrows[g]]:
                key_has_null = True
                break
        if kc.arrow_type == ArrowType.STRING:
            var svals = List[String](capacity=n_groups)
            var kvalid = List[Bool](capacity=n_groups)
            for g in range(n_groups):
                svals.append(kc.str_vals[slot_keyrows[g]])
                kvalid.append(not kc.nulls[slot_keyrows[g]])
            var sa = StringArray.from_strings_with_validity(svals, kvalid)
            rbb.add_column(Column.from_string(sa^))
            out_sb.add_field(
                Field(key_names[k], ArrowType.STRING, key_has_null)
            )
        elif key_has_null:
            var narr = PrimitiveArray[DType.int64].allocate_nullable(n_groups)
            for g in range(n_groups):
                narr.store[1](g, kc.i64_vals[
                    _cd_i64_index_of_row(kc, slot_keyrows[g])
                ])
            for g in range(n_groups):
                if kc.nulls[slot_keyrows[g]]:
                    narr._set_null(g)
            rbb.add_column(Column.from_primitive[DType.int64](narr^))
            out_sb.add_field(Field(key_names[k], ArrowType.INT64, True))
        else:
            var arr = PrimitiveArray[DType.int64].allocate(n_groups)
            for g in range(n_groups):
                arr._typed_ptr_mut()[g] = kc.i64_vals[
                    _cd_i64_index_of_row(kc, slot_keyrows[g])
                ]
            rbb.add_column(Column.from_primitive[DType.int64](arr^))
            out_sb.add_field(Field(key_names[k], ArrowType.INT64, False))

    for a in range(n_aggs):
        var svals = List[String](capacity=n_groups)
        var valid = List[Bool](capacity=n_groups)
        for g in range(n_groups):
            svals.append(slot_best[g][a])
            valid.append(slot_seen[g][a])
        var sa = StringArray.from_strings_with_validity(svals, valid)
        rbb.add_column(Column.from_string(sa^))
        # A group can be all-null only for a NULLABLE input; emit the column
        # nullable so an all-null group's min/max reads back NULL (byte-equiv to
        # the ACC_MIN_UTF8 / ACC_MAX_UTF8 `Optional[String](None)` finalize).
        out_sb.add_field(Field(out_names[a], ArrowType.STRING, True))

    var out_batch = rbb.build(out_sb.build())
    return Optional[RecordBatch](out_batch^)
