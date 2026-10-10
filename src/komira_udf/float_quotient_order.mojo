# =============================================================================
# float_quotient_order.mojo — THE float equality + ordering model, in one place
# =============================================================================
#
# PLACEMENT: this module lives in `komira_udf` for now so that the packages
# above it (`komira_row_format`, `komira_kernels`, `komira_agg`) can import it
# without a dependency on the core packages. It is to move to
# `komira_column_kernels`.
#
# WHAT THIS FILE IS FOR
# =====================
#
# A hash table's contract is `a == b  =>  hash(a) == hash(b)`, and an
# order-sensitive reduction's contract is that its comparator is a strict weak
# ordering. Both are properties of a PAIR of functions, so both are violated by
# writing the two halves in two places: a `GROUP BY <float>` that hashes the
# RAW BITS while comparing with IEEE `==` makes `{+0.0, -0.0}`
# equal-but-differently-hashed (whether they ever meet is a function of the
# probe path, not of the data), and a `MIN`/`MAX` over a float that folds on
# bare `<` / `>` never displaces a NaN that reaches the accumulator (order-
# and worker-partition-dependent).
#
# ⭐ SO THE MODEL LIVES HERE, ONCE, AND EVERY SITE IMPORTS IT. Do not re-spell
# a canonicalization or a NaN-aware compare at a call site; add the case here.
#
# THE MODEL — MEASURED, NOT ASSUMED
# =================================
#
# DuckDB v1.5.3, over `{1.0, NaN, 2.0, +0.0, -0.0, inf, NaN, 1.0}`:
#
#   'nan' = 'nan'   -> true        'nan' > 'inf'  -> true
#   0.0 = -0.0      -> true        'nan' = -'nan' -> true
#   GROUP BY v      -> 5 groups: {0.0,-0.0} is ONE (n=2), {nan,nan} is ONE (n=2)
#   min(v) / max(v) -> 0.0 / nan   (NaN IS the max)
#   ORDER BY v      -> +0.0 and -0.0 TIE; both NaNs last, after +inf
#
# In words: **the IEEE values QUOTIENTED by {all NaNs are one value} and
# {+0.0 == -0.0}, with NaN ordered ABOVE +inf.** Postgres and Spark SQL both do
# the same thing and both document it as a deliberate deviation from IEEE; the
# SQL standard does not define NaN at all.
#
# ⛔ THIS IS NOT IEEE-754 §5.10 `totalOrder`. `totalOrder` puts `-NaN` BELOW `-inf` and `-0.0`
# STRICTLY below `+0.0`; DuckDB does neither. If you are reaching for the
# sign-flip encode trick, you are implementing a different model than this one.
#
# ⚠ THE REPRESENTATIVE IS A FREE CHOICE, THE CLASS IS NOT. `min` over
# `{-0.0, 0.0}` is `-0.0` in DuckDB and over `{0.0, -0.0}` is `0.0` — measured.
# Both are the same value under the quotient; DuckDB keeps the first-seen bit
# pattern and so does this engine. A test that asserts on the SIGN BIT of a
# zero, or on the PAYLOAD of a NaN, is asserting something neither engine
# promises. Assert with `float_quotient_eq_*`.
#
# SCOPE — WHAT USES THIS TODAY
# ============================
#
#   * `komira_kernels.builtin_hash_fns`      HashF32 / HashF64
#   * `komira_agg.builtin_agg_fns_minmax`  MinF32/MinF64/MaxF32/MaxF64
#   * `komira_agg.hash_agg_op_dt`           MinOp/MaxOp's float family
#         (the typed door's MIN/MAX) -- identities + fold steps
#   * `komira_engine_operators.hash_agg_untyped`
#         the F32/F64 arms of `_hash_single_col` / `_hash_storage_single_col`
#         and of `_key_eq_single_col` / `_key_eq_single_col_storage`
#         (the GROUP BY key), plus AGG_MIN_F64 / AGG_MAX_F64.
#   * `komira_engine_operators.stage_primitives.distinct_state`
#         `DistinctKeyColumn_Typed`'s float key: canonical-bits hash +
#         quotient equality (the typed door's GROUP BY / typed DISTINCT key;
#         without it every NaN row opens its own group).
#   * `komira_expr.composite_key` `_hash_column_value` / `_eq_column_value`
#         (the Float64 component of the multi-column GROUP BY key behind
#         `komira_op_agg_state.composite_hash_table`): canonical-bits hash +
#         quotient equality.
#   * ⭐ THE ORDER BY / TOP-N / WINDOW FAMILY: `sort.sort_indices_float64` (+ its heap sibling),
#     `sort_topn_sink._row_is_better`, `parallel_column_sort._f64_order_key`,
#     `partition_topn_sink` (order-key image + partition boundary),
#     `partition_scan_kernels._key_cells_equal` (RANK/DENSE_RANK peers),
#     `partition_scan_sink._detect_partition_boundaries` (PARTITION BY + RANGE
#     peers), `sort_external._cmp_float32/64`, `sort_nested`'s float leaves,
#     and `row_format/arrow_row.encode_f64/f32_to_bytes`.
#
# ⚠ AND WHAT DOES **NOT**, DELIBERATELY: the SQL comparison operators
# (`=`, `<>`, `<`, `>`, `<=`, `>=`), join-key equality
# and `PercentileAcc` are all still on plain IEEE and
# are a STAGED MIGRATION — welded tests pin the IEEE model for the
# comparison operators, so flipping them without updating those tests fails
# the build. Importing
# this module at one of those sites is a semantic change, not a cleanup.
# ⚠ Also still IEEE, and reachable from NO door (no production caller): the
# typed-stage `SortKeyColumn_Typed.compare_at`
# (`stage_primitives.sort_buffer`), `partition_topn_hash_state._order_heap_key`
# and `komira_expr.expr_sortable_key._cmp_float64`.
#
# Mojo discipline: no UnsafePointer in any signature, no wildcard origins,
# file < 1000 LOC.
# =============================================================================

from std.memory import bitcast


# The ONE canonical NaN per width. DuckDB's own choice: `nanf("")` /
# `nan("")` — the positive quiet NaN with a zero payload.
comptime CANONICAL_NAN_BITS_F32: UInt32 = UInt32(0x7FC00000)
comptime CANONICAL_NAN_BITS_F64: UInt64 = UInt64(0x7FF8000000000000)


@always_inline
def canonical_nan_f32() -> Float32:
    return bitcast[DType.float32](CANONICAL_NAN_BITS_F32)


@always_inline
def canonical_nan_f64() -> Float64:
    return bitcast[DType.float64](CANONICAL_NAN_BITS_F64)


# =============================================================================
# CANONICALIZE — collapse each equivalence class to ONE bit pattern.
#
# After this, bit equality IS quotient equality, which is what makes a raw-bit
# hash and a value equality agree. Every other float value is returned
# unchanged, so this is a no-op on all normal data.
# =============================================================================


@always_inline
def canonicalize_f32(v: Float32) -> Float32:
    """`-0.0 -> +0.0`, every NaN -> the one canonical NaN, else `v` unchanged.

    `v != v` is true iff `v` is NaN (IEEE: NaN compares unordered with
    everything, itself included). `v == 0.0` is true for BOTH zeros, so the
    assignment is what erases the sign bit.
    """
    if v != v:
        return bitcast[DType.float32](CANONICAL_NAN_BITS_F32)
    if v == Float32(0):
        return Float32(0)
    return v


@always_inline
def canonicalize_f64(v: Float64) -> Float64:
    """`-0.0 -> +0.0`, every NaN -> the one canonical NaN, else `v` unchanged.
    See `canonicalize_f32` for why the two tests are spelled this way."""
    if v != v:
        return bitcast[DType.float64](CANONICAL_NAN_BITS_F64)
    if v == Float64(0):
        return Float64(0)
    return v


@always_inline
def canonical_bits_f32(v: Float32) -> UInt32:
    """The canonical form's raw bits — the hash input. Two values that are
    EQUAL under this model produce the same UInt32 here, by construction."""
    return bitcast[DType.uint32](canonicalize_f32(v))


@always_inline
def canonical_bits_f64(v: Float64) -> UInt64:
    """The canonical form's raw bits — the hash input."""
    return bitcast[DType.uint64](canonicalize_f64(v))


# =============================================================================
# EQUALITY — what a GROUP BY / DISTINCT key comparison must use.
#
# ⚠ This is NOT `==`. It differs from IEEE on exactly two inputs, and those two
# are the whole point: `NaN == NaN` is FALSE in IEEE and TRUE here; `+0.0 ==
# -0.0` is TRUE in both. SQL NULL is a separate channel and is not this
# function's business.
# =============================================================================


@always_inline
def float_quotient_eq_f32(a: Float32, b: Float32) -> Bool:
    if a != a:
        return b != b
    if b != b:
        return False
    return a == b


@always_inline
def float_quotient_eq_f64(a: Float64, b: Float64) -> Bool:
    if a != a:
        return b != b
    if b != b:
        return False
    return a == b


# =============================================================================
# ORDER — what MIN / MAX must use.
#
# ⛔ BARE `<` IS NOT A STRICT WEAK ORDERING ONCE A NaN IS PRESENT: every
# comparison against a NaN is FALSE, so NaN is neither below, above, nor
# equivalent to anything — including itself. A reduction folding on `v < best`
# therefore can never displace a NaN that reached `best`, and which row reached
# it first is decided by arrival order and by how the workers cut the input.
#
# Here NaN is the TOP element: strictly above every non-NaN, equivalent to
# every other NaN. So `float_quotient_lt(NaN, x)` is false for every `x`
# (nothing is below anything via NaN) and `float_quotient_gt(NaN, x)` is true
# for every non-NaN `x`. Both are FALSE for NaN-vs-NaN, which is what keeps
# `merge` symmetric: an incumbent is never replaced by an equivalent.
# =============================================================================


@always_inline
def float_quotient_lt_f32(a: Float32, b: Float32) -> Bool:
    """True iff `a` is STRICTLY below `b`. NaN is the top element."""
    if a != a:
        return False
    if b != b:
        return True
    return a < b


@always_inline
def float_quotient_lt_f64(a: Float64, b: Float64) -> Bool:
    """True iff `a` is STRICTLY below `b`. NaN is the top element."""
    if a != a:
        return False
    if b != b:
        return True
    return a < b


@always_inline
def float_quotient_gt_f32(a: Float32, b: Float32) -> Bool:
    """True iff `a` is STRICTLY above `b`. NaN is the top element."""
    if a != a:
        return b == b
    if b != b:
        return False
    return a > b


@always_inline
def float_quotient_gt_f64(a: Float64, b: Float64) -> Bool:
    """True iff `a` is STRICTLY above `b`. NaN is the top element."""
    if a != a:
        return b == b
    if b != b:
        return False
    return a > b


# =============================================================================
# IDENTITIES — the sentinel a sentinel-based MIN / MAX accumulator must start
# from, stated in terms of the order above rather than re-derived per call site.
#
# ⭐ MIN's identity is the TOP of the order, and the top is NaN — NOT `+inf`.
# A `+inf` MIN sentinel cannot represent the answer for an all-NaN group, so
# such a group drains as the SENTINEL, and `+-inf` is worse than a wrong scalar
# because it PROPAGATES (`max - min` over that group is `-inf`). The canonical
# NaN has no such problem: it is simultaneously the identity AND the correct
# answer for the all-NaN group, so the accumulator needs no extra flag.
#
# ⚠ AN ACCUMULATOR SEEDED WITH AN IDENTITY STILL NEEDS A `seen` / touched
# channel to tell an EMPTY group (SQL NULL) from a group whose only values were
# NaN. These identities do not replace it.
# =============================================================================


@always_inline
def float_min_identity_f64() -> Float64:
    """MIN's identity = the TOP of the order = the canonical NaN."""
    return bitcast[DType.float64](CANONICAL_NAN_BITS_F64)


@always_inline
def float_max_identity_f64() -> Float64:
    """MAX's identity = the BOTTOM of the order = `-inf`. NaN sits at the top,
    so `-inf` is still the least element and stays the right seed."""
    return Float64(-1.0) / Float64(0.0)


# The two seeds as RAW BITS, for the fixed-cell accumulators that initialise a
# slot with one 8-byte store (`(ap + 16).bitcast[UInt64]()[] = ...`).
comptime FLOAT_MIN_SEED_BITS_F64: UInt64 = CANONICAL_NAN_BITS_F64
comptime FLOAT_MAX_SEED_BITS_F64: UInt64 = UInt64(0xFFF0000000000000)  # -inf


# =============================================================================
# THE MIN / MAX FOLD STEP — one spelling for every fixed-cell accumulator.
#
# ⛔ SEEDING MIN with `Float64.MAX` and MAX with `Float64.MIN` (the most
# negative FINITE double) and folding with bare `<` / `>` is wrong: a NaN-only
# group answers (1.7976931348623157e308, -1.7976931348623157e308); `max` over
# {-inf} answers -1.797e308 and `min` over {+inf} 1.797e308 -- the SEED, a
# value not in the column -- where DuckDB 1.5.3, polars 1.44.2 and pandas
# 3.0.6 all answer NaN / -inf / +inf. A seed that is not the identity of the fold's order leaks
# whenever no value displaces it.
#
# These are the model's steps (NaN the TOP element): MIN is NaN-SKIPPING and is
# NaN only for an all-NaN group; MAX is NaN as soon as one NaN arrives -- the
# order every string-key / RADIX / FLAT route
# already answers. Both are order-independent, so a fold and a MERGE use the
# same step.
# =============================================================================


@always_inline
def float_min_fold_f64(acc: Float64, v: Float64) -> Float64:
    """One MIN step in the quotient order (seed `float_min_identity_f64`)."""
    return v if float_quotient_lt_f64(v, acc) else acc


@always_inline
def float_max_fold_f64(acc: Float64, v: Float64) -> Float64:
    """One MAX step in the quotient order (seed `float_max_identity_f64`)."""
    return v if float_quotient_gt_f64(v, acc) else acc


# =============================================================================
# ORDER KEYS + THREE-WAY COMPARE — what a SORT must use
#
# ⛔ A NaN SORT KEY IS NOT "A VALUE IN THE WRONG PLACE" UNDER BARE `<`. Every
# IEEE comparison against a NaN is false, so a comparison sort handed `<` sees
# a NaN as EQUIVALENT to every value while those values are not equivalent to
# each other — an invalid (non-transitive) comparator. A stable merge sort
# then treats each NaN as a BARRIER: the runs between NaNs come back sorted and
# are never merged (e.g. `ORDER BY v LIMIT 3` over {3, NaN, 1, NULL, -2, 2,
# NaN, 0.5} answers 3.0, NaN, -2.0 — different ROWS, nothing raised).
#
# So a sort compares through the QUOTIENT order above. Two spellings:
#
#   * `float_quotient_cmp_*`        a comparator (-1 / 0 / +1) for a merge,
#                                   insertion or heap sort over raw values;
#   * `float_quotient_order_bits_*` an UNSIGNED integer image, monotone in the
#                                   quotient order, for a site that sorts, merges
#                                   or heaps INTEGER keys (a radix pass, a
#                                   co-rank merge, an encoded row key).
#                                   `float_quotient_order_key_*` is the same
#                                   image re-biased to SIGNED, for a site that
#                                   compares Int64s.
#
# ⛔ THE BIT IMAGE IS `totalOrder` OF THE **CANONICAL** VALUE — and the
# canonicalisation is the whole difference. `totalOrder` of the raw value puts
# `-NaN` below `-inf` and `-0.0` strictly below `+0.0`; canonicalising first
# sends every NaN to the one positive quiet NaN (above `+inf`) and `-0.0` to
# `+0.0`, so the two equivalence classes of the model each get ONE image. Do
# not "optimise" the canonicalisation away.
# =============================================================================


@always_inline
def float_quotient_order_bits_f64(v: Float64) -> UInt64:
    """UNSIGNED image of `v`, monotone in the quotient order:
    `lt(a, b) <=> bits(a) < bits(b)` and `eq(a, b) <=> bits(a) == bits(b)`.
    Every NaN maps to ONE image above `+inf`'s; `-0.0` maps to `+0.0`'s."""
    var bits = bitcast[DType.uint64](canonicalize_f64(v))
    if bits & (UInt64(1) << 63) != 0:
        return ~bits
    return bits | (UInt64(1) << 63)


@always_inline
def float_quotient_order_bits_f32(v: Float32) -> UInt32:
    """UNSIGNED image of `v`, monotone in the quotient order (see `_f64`)."""
    var bits = bitcast[DType.uint32](canonicalize_f32(v))
    if bits & (UInt32(1) << 31) != 0:
        return ~bits
    return bits | (UInt32(1) << 31)


@always_inline
def float_quotient_order_key_f64(v: Float64) -> Int64:
    """SIGNED image of `v`, monotone in the quotient order under Int64 `<`:
    `float_quotient_order_bits_f64` with its top bit flipped."""
    return bitcast[DType.int64](
        float_quotient_order_bits_f64(v) ^ (UInt64(1) << 63)
    )


@always_inline
def float_quotient_cmp_f64(a: Float64, b: Float64) -> Int:
    """Three-way compare in the quotient order: -1 if `a` is below `b`, 0 if
    they are EQUAL under the model (both NaN, or `+0.0` vs `-0.0`), else +1."""
    if a != a:
        return 0 if b != b else 1
    if b != b:
        return -1
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


@always_inline
def float_quotient_cmp_f32(a: Float32, b: Float32) -> Int:
    """Three-way compare in the quotient order (see `float_quotient_cmp_f64`)."""
    if a != a:
        return 0 if b != b else 1
    if b != b:
        return -1
    if a < b:
        return -1
    if a > b:
        return 1
    return 0
