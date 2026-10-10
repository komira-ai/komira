# =============================================================================
# expr_sortable_key.mojo — Sortable composite-key Expr family
# =============================================================================
#
# Callers: only tests/test_expr_sortable_key.mojo today.
#
# This module ships the runtime pieces of a composite sort key:
#   - `SortKeyComponent`, a tagged Int64 / Float64 / String cell with a
#     null flag, and `SortKeyValue1/2/3`, tuples of them.
#   - `cmp_sort_key_component` and `cmp_sort_key_value1/2/3`, 3-valued
#     (-1/0/1) lexicographic comparators taking one SortDir per position.
#   - The `ExprSortableKey` marker trait (arity + per-position direction).
#
# No `ExprSortableKey` conformer is declared here or anywhere in the tree;
# a caller passes the directions to `cmp_sort_key_valueN` itself.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - `SortKeyValue1/2/3` are fixed-arity structs (no List). A String
#     component holds a heap String; the other components are inline scalars.
#
# Cross-references:
#   - composite_key.mojo (the GROUP BY key: `ColumnValue`, `KeyValue1..4`).
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_expr.expr_x import ExprXBool, ExprXI64, ExprXF64, ExprXString


# =============================================================================
# §1 — SortDir + SortAlgo enums
# =============================================================================
#
# Both are `comptime UInt8` constants. `cmp_sort_key_valueN` reads the
# SORT_DIR_* values. Nothing reads the SORT_ALGO_* ids: no sort in this
# package selects an algorithm by them.
# =============================================================================

# SortDir
comptime SORT_DIR_ASC: UInt8 = 0
comptime SORT_DIR_DESC: UInt8 = 1

# SortAlgo
comptime SORT_ALGO_MERGE: UInt8 = 0  # merge sort: stable
comptime SORT_ALGO_RADIX: UInt8 = 1  # radix sort: integer keys
comptime SORT_ALGO_QUICK: UInt8 = 2  # quicksort: in place, not stable


# =============================================================================
# §2 — SortKeyValue1/2/3 — runtime composite-key values
# =============================================================================
#
# Each component is one of Int64 / Float64 / String. Bool is not a
# meaningful sort key DType (use a Bool-to-Int64 cast Expr upstream if
# needed). Each component carries an `is_null` flag; `cmp_sort_key_component`
# sorts a null after every non-null (see its docstring for DESC).
#
# Why a separate SortKeyValueN rather than `KeyValueN` from composite_key.mojo:
#   - A sort key needs a null flag per component. composite_key's
#     `ColumnValue` has none: its tag names the type, not null-ness.
#   - A sort key has no Bool component; `ColumnValue` has a Bool arm.
#   - A sort key is compared three-way, lexicographically
#     (`cmp_sort_key_valueN`); composite_key ships only hash and equality
#     (`hash_key_valueN`, `eq_key_valueN`).
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

    Used by SortKeyValueN. The sort direction is not on the value cell;
    the caller passes one per position to `cmp_sort_key_valueN`.
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

    No production caller: nothing outside this module and its test imports
    any symbol of this module, `SORT_DIR_ASC` / `SORT_DIR_DESC` included."""
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

    Null handling: a null compares above every non-null and equal to
    another null, so nulls sort LAST ascending. `cmp_sort_key_valueN`
    negates the whole result for SORT_DIR_DESC, so under DESC nulls sort
    FIRST. There is no separate NULLS FIRST / NULLS LAST control.

    Kind mismatch: the result is meaningless. Both values are read under
    `a.kind`, and `b`'s empty cell reads as 0, 0.0 or the empty string.
    The caller must pass two components of one kind; nothing here checks.
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
    """1-component sort key."""

    var c0: SortKeyComponent


@fieldwise_init
struct SortKeyValue2(Copyable, Movable, Deinitable):
    """2-component sort key, compared lexicographically."""

    var c0: SortKeyComponent
    var c1: SortKeyComponent


@fieldwise_init
struct SortKeyValue3(Copyable, Movable, Deinitable):
    """3-component sort key, compared lexicographically."""

    var c0: SortKeyComponent
    var c1: SortKeyComponent
    var c2: SortKeyComponent


# =============================================================================
# §5 — Lexicographic comparator helpers (per-arity)
# =============================================================================
#
# Compares two SortKeyValueN values position-wise. Each position has its
# own SortDir, passed by the caller (dir0, dir1, dir2).
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
# §6 — ExprSortableKey marker trait
# =============================================================================
#
# `ExprSortableKey` is a marker trait declaring a key's arity and the
# direction of each position. It declares no `extract` or `compare`; this
# module ships the trait only, with no conformer.
# =============================================================================


trait ExprSortableKey(Copyable, Movable, ImplicitlyCopyable):
    """Marker trait for composite sortable keys: the arity and the sort
    direction of each position. No conformer exists in the tree."""

    @staticmethod
    def key_arity() -> Int:
        """Return the number of sort-key components (1, 2, or 3)."""
        ...

    @staticmethod
    def key_dir_at(idx: Int) -> UInt8:
        """Return SORT_DIR_ASC or SORT_DIR_DESC for the i-th key component."""
        ...
