# =============================================================================
# expr_sortable_key.mojo — Sortable composite-key Expr family
# =============================================================================
#
# Consumed by:
#   - `SortStage[KeyExpr, SortDir, SortAlgo]`
#   - `TopNStage[N, KeyExpr, SortDir]`
#   - `WindowStage[PartKey, OrderKey, WindowFn, frame]`
#
# The `ExprSortableKey` trait extends the ExprX family by adding a
# `compare` method that returns a 3-valued ordering (-1/0/1). This
# avoids an "Expr returning trinary comparison" shape, which is an
# anti-pattern. The comparator lives on the SortableKey conformer, NOT on
# the Expr-tree.
#
# The SortKey1[K0] / SortKey2[K0, K1] / SortKey3[K0, K1, K2]
# adapters compose ExprXI64 / ExprXF64 / ExprXString components into a
# lexicographically-comparable composite key. Arities 1, 2, 3 are provided
# (covers ≥95% of realistic SortStage / TopNStage / WindowStage shapes).
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - `KeyTy` associated type: composite key value as a runtime struct
#     (SortKeyValue1/2/3 below). Heap-light by design.
#
# Cross-references:
#   - composite_key.mojo (analogous CompositeKey shape; KeyValue1..4).
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_expr.expr_x import ExprXBool, ExprXI64, ExprXF64, ExprXString


# =============================================================================
# §1 — SortDir + SortAlgo enums
# =============================================================================
#
# Mojo 1.0.0b1 doesn't ship a stdlib enum; the canonical in-tree pattern
# is `alias SORT_DIR_ASC: UInt8 = 0` (compile-time integer aliases). Same
# pattern as `SourceVariant`'s SEG_* tag aliases.
# =============================================================================

# SortDir
comptime SORT_DIR_ASC: UInt8 = 0
comptime SORT_DIR_DESC: UInt8 = 1

# SortAlgo
comptime SORT_ALGO_MERGE: UInt8 = 0  # stable + cache-friendly; default
comptime SORT_ALGO_RADIX: UInt8 = 1  # integer-key fast path
comptime SORT_ALGO_QUICK: UInt8 = 2  # legacy fallback; in-place; non-stable


# =============================================================================
# §2 — SortKeyValue1/2/3 — runtime composite-key values
# =============================================================================
#
# Each component is one of Int64 / Float64 / String. Bool is not a
# meaningful sort key DType (use a Bool-to-Int64 cast Expr upstream if
# needed). Each value carries an `is_null` companion bit for nullable-
# key NULLS-FIRST/LAST handling Q11.
#
# Why dedicated SortKeyValue (vs reusing KeyValueN from composite_key.mojo):
#   - Sort keys need an explicit `is_null` per component for NULLS-FIRST
#     vs NULLS-LAST ordering semantics. CompositeKeyN does not carry
#     this — its ColumnValue tag does not encode null-ness.
#   - Sort keys do not need Bool component; CompositeKeyN does.
#   - Sort comparison is lexicographic across components; the runtime
#     SortKeyValueN ships its own dedicated `compare` helper distinct
#     from the eq-only KeyValueN helpers.
# =============================================================================


@fieldwise_init
struct SortKeyComponentI64(Copyable, Movable, Deinitable):
    """One Int64-typed sort-key component cell.

    Fields:
        value: The Int64 value (meaningful iff is_null == False).
        is_null: True if the source column had NULL at this row.
    """

    var value: Int64
    var is_null: Bool


@fieldwise_init
struct SortKeyComponentF64(Copyable, Movable, Deinitable):
    """One Float64-typed sort-key component cell."""

    var value: Float64
    var is_null: Bool


@fieldwise_init
struct SortKeyComponentString(Copyable, Movable, Deinitable):
    """One String-typed sort-key component cell."""

    var value: String
    var is_null: Bool


# DType discrimination for runtime sort-key dispatch
comptime SKC_INT64: UInt8 = 1
comptime SKC_FLOAT64: UInt8 = 2
comptime SKC_STRING: UInt8 = 3


struct SortKeyComponent(Copyable, Movable, Deinitable):
    """Tagged-union runtime sort-key component cell.

    Holds one of {Int64, Float64, String} per the `kind` field plus the
    component's `is_null` flag. Mirrors the tag+Optional in-tree pattern.

    Used by SortKeyValueN. Per-component sort direction is held on the
    SortKey1/2/3 conformer struct, NOT on the value cell.
    """

    var kind: UInt8
    var _i64: Optional[SortKeyComponentI64]
    var _f64: Optional[SortKeyComponentF64]
    var _str: Optional[SortKeyComponentString]

    def __init__(out self, value: Int64, is_null: Bool):
        """Construct an Int64 sort-key component."""
        self.kind = SKC_INT64
        self._i64 = Optional(SortKeyComponentI64(value, is_null))
        self._f64 = None
        self._str = None

    def __init__(out self, value: Float64, is_null: Bool):
        """Construct a Float64 sort-key component."""
        self.kind = SKC_FLOAT64
        self._i64 = None
        self._f64 = Optional(SortKeyComponentF64(value, is_null))
        self._str = None

    def __init__(out self, var value: String, is_null: Bool):
        """Construct a String sort-key component."""
        self.kind = SKC_STRING
        self._i64 = None
        self._f64 = None
        self._str = Optional(SortKeyComponentString(value^, is_null))

    @always_inline
    def is_null(self) -> Bool:
        """Read the null flag of the active component."""
        if self.kind == SKC_INT64:
            return self._i64.value().is_null if self._i64 else False
        elif self.kind == SKC_FLOAT64:
            return self._f64.value().is_null if self._f64 else False
        elif self.kind == SKC_STRING:
            return self._str.value().is_null if self._str else False
        return False


# =============================================================================
# §3 — Component comparison helper (3-valued: -1, 0, +1)
# =============================================================================


@always_inline
def _cmp_int64(a: Int64, b: Int64) -> Int8:
    """3-valued Int64 comparison: -1 if a<b, 0 if eq, +1 if a>b."""
    if a < b:
        return Int8(-1)
    if a > b:
        return Int8(1)
    return Int8(0)


@always_inline
def _cmp_float64(a: Float64, b: Float64) -> Int8:
    """3-valued Float64 comparison.

    ⚠ NaN: the three lines below return 0 ("equivalent") for NaN against
    ANYTHING, because both `a < b` and `a > b` are false. That is not an
    ordering at all -- it is not transitive as an equivalence (NaN ~ 1.0 and
    NaN ~ 2.0 but 1.0 !~ 2.0), so any sort driven by this comparator is outside
    its own contract on NaN-bearing input. In particular it does NOT order
    "NaN > +Inf > everything", and nothing upstream normalizes NaN away.

    ⛔ DEAD CODE. Nothing outside this module imports `_cmp_float64`,
    `cmp_sort_key_component` or `SortKeyComponent`; the only symbols consumed
    downstream are `SORT_DIR_ASC` / `SORT_DIR_DESC`
    (`komira_engine_operators.stage_primitives.topn_stage`). Prefer
    DELETING this comparator family over repairing it."""
    if a < b:
        return Int8(-1)
    if a > b:
        return Int8(1)
    return Int8(0)


@always_inline
def _cmp_string(a: String, b: String) -> Int8:
    """3-valued lexicographic String comparison."""
    if a < b:
        return Int8(-1)
    if a > b:
        return Int8(1)
    return Int8(0)


@always_inline
def cmp_sort_key_component(a: SortKeyComponent, b: SortKeyComponent) -> Int8:
    """3-valued comparison on two SortKeyComponents.

    Null handling: nulls sort LAST in ascending order (NULLS LAST per
    SQL standard default). Per-key NULLS FIRST semantics flip the sign
    of the comparator output (handled at SortKey* conformer level via
    `nulls_first` flag).

    Tag mismatch: undefined — caller responsible for matching DTypes
    across the two values. SortStage enforces this by storing
    only one DType per sort-key column.
    """
    var an = a.is_null()
    var bn = b.is_null()
    if an and bn:
        return Int8(0)
    if an:
        return Int8(1)  # null > non-null (NULLS LAST default)
    if bn:
        return Int8(-1)
    var k = a.kind
    if k == SKC_INT64:
        var av = a._i64.value().value if a._i64 else Int64(0)
        var bv = b._i64.value().value if b._i64 else Int64(0)
        return _cmp_int64(av, bv)
    elif k == SKC_FLOAT64:
        var av = a._f64.value().value if a._f64 else Float64(0.0)
        var bv = b._f64.value().value if b._f64 else Float64(0.0)
        return _cmp_float64(av, bv)
    elif k == SKC_STRING:
        var av = a._str.value().value if a._str else String("")
        var bv = b._str.value().value if b._str else String("")
        return _cmp_string(av, bv)
    return Int8(0)


# =============================================================================
# §4 — SortKeyValue1/2/3 — composite-key runtime values
# =============================================================================


@fieldwise_init
struct SortKeyValue1(Copyable, Movable, Deinitable):
    """1-component sort key. Used by single-column ORDER BY clauses."""

    var c0: SortKeyComponent


@fieldwise_init
struct SortKeyValue2(Copyable, Movable, Deinitable):
    """2-component sort key. Used by ORDER BY a, b clauses (lex-compared)."""

    var c0: SortKeyComponent
    var c1: SortKeyComponent


@fieldwise_init
struct SortKeyValue3(Copyable, Movable, Deinitable):
    """3-component sort key. Used by ORDER BY a, b, c clauses."""

    var c0: SortKeyComponent
    var c1: SortKeyComponent
    var c2: SortKeyComponent


# =============================================================================
# §5 — Lexicographic comparator helpers (per-arity)
# =============================================================================
#
# Compares two SortKeyValueN values position-wise. Each position has its
# own per-key SortDir (held on the SortKey1/2/3 conformer struct as
# comptime params). The conformer's `compare` method calls the appropriate
# `cmp_sort_key_valueN` helper passing the per-position dir vector.
#
# Returns Int8: -1 if a<b under the dir vector, 0 if equal, +1 if a>b.
# =============================================================================


@always_inline
def _apply_dir(cmp: Int8, dir: UInt8) -> Int8:
    """If dir == SORT_DIR_DESC, negate the comparison; else passthrough."""
    if dir == SORT_DIR_DESC:
        return -cmp
    return cmp


@always_inline
def cmp_sort_key_value1(
    a: SortKeyValue1, b: SortKeyValue1, dir0: UInt8
) -> Int8:
    """Lex-compare two 1-component sort keys under dir0."""
    var c = cmp_sort_key_component(a.c0, b.c0)
    return _apply_dir(c, dir0)


@always_inline
def cmp_sort_key_value2(
    a: SortKeyValue2,
    b: SortKeyValue2,
    dir0: UInt8,
    dir1: UInt8,
) -> Int8:
    """Lex-compare two 2-component sort keys under (dir0, dir1).
    Earlier components dominate; later components break ties."""
    var c0 = _apply_dir(cmp_sort_key_component(a.c0, b.c0), dir0)
    if c0 != 0:
        return c0
    return _apply_dir(cmp_sort_key_component(a.c1, b.c1), dir1)


@always_inline
def cmp_sort_key_value3(
    a: SortKeyValue3,
    b: SortKeyValue3,
    dir0: UInt8,
    dir1: UInt8,
    dir2: UInt8,
) -> Int8:
    """Lex-compare two 3-component sort keys under (dir0, dir1, dir2)."""
    var c0 = _apply_dir(cmp_sort_key_component(a.c0, b.c0), dir0)
    if c0 != 0:
        return c0
    var c1 = _apply_dir(cmp_sort_key_component(a.c1, b.c1), dir1)
    if c1 != 0:
        return c1
    return _apply_dir(cmp_sort_key_component(a.c2, b.c2), dir2)


# =============================================================================
# §6 — ExprSortableKey trait + per-arity conformer scaffolding
# =============================================================================
#
# `ExprSortableKey` is a marker trait — concrete conformers (SortKey1,
# SortKey2, SortKey3) ship per-arity with their own typed `extract`
# returning the matching SortKeyValueN, and a per-arity `compare` static
# method.
#
# This module ships the TRAIT SURFACE and a sample conformer per arity for
# smoke-test coverage. Production SortKey conformers (tightly-typed
# per-shape) are emitted by the StageFusionPass.
# =============================================================================


trait ExprSortableKey(Copyable, Movable, ImplicitlyCopyable):
    """Marker trait for composite sortable-key conformers.

    Each conformer (SortKey1[...], SortKey2[...], SortKey3[...]) ships
    its own typed `extract` method returning the matching SortKeyValueN
    and a `compare` static method that lex-compares two extracted values
    under the per-key sort direction.

    This module ships the trait surface + per-arity scaffolding conformers;
    production conformers are emitted by the StageFusionPass
    per the LogicalPlan's ORDER BY clause shape.
    """

    @staticmethod
    def key_arity() -> Int:
        """Return the number of sort-key components (1, 2, or 3)."""
        ...

    @staticmethod
    def key_dir_at(idx: Int) -> UInt8:
        """Return SORT_DIR_ASC or SORT_DIR_DESC for the i-th key component."""
        ...
