# =============================================================================
# KeyColumnView[dtype, batch_origin] -- parametric-origin read-only column view
# =============================================================================
#
# A lifetime-parameterized view over an Arrow column's data buffer. State
# structs hold these to reference borrowed key-column input WITHOUT
# wildcard-origin `UnsafePointer[Scalar, ...]` fields.
#
# PROBLEM THE VIEW SOLVES
# -----------------------
# A State struct that reaches key columns inside the input RecordBatch
# through a wildcard-origin pointer field disables ASAP-destruction
# tracking: a byte slab + wildcard origin + heap-owning inner value is a
# use-after-free on any take_pointee path.
#
# The fix: parameterize the view on the parent batch's concrete origin.
# The compiler tracks the batch's lifetime THROUGH the State's field
# and rejects any attempt to outlive the borrow.
#
# DESIGN CHOICES
# --------------
#
# 1) `batch_origin: Origin[mut=False]` (immutable borrow)
#    A read-only view needs only shared read access. An immutable origin
#    composes cleanly with `run_with_state[State, Task]` (MUT parametric
#    origins hit the aliasing check; IMMUT origins do not).
#
# 2) `dtype: DType` parameterization (compile-time-known Arrow type)
#    Aggregation / join plans know key dtypes at plan time. Parameterizing
#    on `dtype` means (a) typed accessors are the NATURAL API (no
#    runtime dtype branching in hot loops), (b) a mis-typed access is
#    a compile error, not a runtime error. Mirrors `PrimitiveArray[dtype]`
#    and `TypedColumnPtrs` which already parametrize this way.
#    Multi-key States carry one `KeyColumnView[dt_i, batch_origin]`
#    per key column.
#
# 3) Internal storage: `UnsafePointer[Scalar[dtype], batch_origin]`
#    The typed raw pointer is the cheapest representation for a 6M-row
#    inner loop. Encapsulation rule: this field is PRIVATE; no
#    UnsafePointer crosses the module boundary. Public methods return
#    values (`Scalar[dtype]`) or references (`ref [self] Scalar[dtype]`).
#
# WHY WE DO NOT USE bare `Origin` (rather than `Origin[mut=False]`)
# ----------------------------------------------------------------
# TypedColumnPtrs uses bare `Origin` because its pointer lists mix
# mut-borrow and immut-borrow use sites. The KeyColumnView is STRICTLY
# read-only (no write methods, no `mut self` accessors), so
# `Origin[mut=False]` is both more permissive (accepts immutable batches)
# AND more accurate (the view does not write).
#
# If a call site has a `mut: Origin[mut=True]` batch, they cannot
# construct `KeyColumnView[dtype, origin_of(batch)]` directly -- they
# pass `origin_of(batch)` through, and Mojo's subtype relation between
# mut and immut origins is not bidirectional. Fallback: use the
# batch through a `ref [imm_o] batch` pattern.
#
# The agg/join hot path takes input batches as `ref [imm_o] RecordBatch`
# where the borrow is already immutable; `origin_of(batch)` returns
# `Origin[mut=False]` and KeyColumnView composes cleanly.
# =============================================================================

from std.memory import UnsafePointer


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (Mojo no longer
    provides an `UnsafePointer[T, o]()` null constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (Mojo's non-null pointer design); `None` is
    # the all-zero (NULL) bit pattern. Origin `o` is `Self.batch_origin`
    # (concrete, not a wildcard). The empty KeyColumnView (`_len == 0`)
    # never dereferences this pointer.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


struct KeyColumnView[
    dtype: DType,
    batch_origin: Origin[mut=False],
](Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Read-only view over a key column's `Scalar[dtype]` data buffer.

    Parameters:
        dtype: Arrow data type of this key column (e.g. `DType.int64`).
            Compile-time-known, threaded from the plan's Schema.
        batch_origin: Immutable origin of the parent RecordBatch. The
            compiler tracks this as the borrow's lifetime; the view
            cannot outlive the batch.

    Fields (all private):
        _ptr: `UnsafePointer[Scalar[dtype], batch_origin]` -- internal
            typed pointer to the column's data buffer. Never escapes
            the module.
        _num_rows: Logical row count in the column.

    Public API (typed, view-semantic):
        len()            -- row count.
        get(row)         -- typed Scalar[dtype] by value.
        get_ref(row)     -- immutable ref to the slot (for reading
                            SIMD / large primitives without copy).

    Ownership / lifetime:
        * The view does NOT own the buffer; the parent RecordBatch does.
        * Caller builds the view at the top of a function where the
          batch is in scope, consumes it through worker dispatch, and
          lets it drop at scope exit. The compiler enforces that the
          view's uses don't outlive the batch via `batch_origin`.

    Not Movable? Actually, `Copyable` and `Movable`. The view is a
    cheap 2-word POD (pointer + length); copying it is free and moving
    it is trivial. Both are safe because the lifetime is pinned by the
    origin parameter, not by the view value itself.

    SAFETY (internal): `_ptr` is a raw pointer borrowed from the
    parent batch's `MmapAlignedBuffer`. Caller establishes the `_num_rows`
    bound at construction. Every public accessor is bounded by
    `_num_rows`. No write methods.
    """

    # SAFETY: internal-only typed pointer. Origin parameter pins the
    # borrow to the caller's RecordBatch lifetime. Never exposed via
    # public API.
    var _ptr: UnsafePointer[Scalar[Self.dtype], Self.batch_origin]
    var _num_rows: Int

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(
        out self,
        ptr: UnsafePointer[Scalar[Self.dtype], Self.batch_origin],
        num_rows: Int,
    ):
        """Construct a view over `num_rows` elements at `ptr`.

        Pre-conditions (caller enforces):
          * `ptr` points at a contiguous run of at least `num_rows`
            Scalar[dtype] elements.
          * `num_rows >= 0`.
          * The pointed-to memory lives for at least as long as
            `batch_origin`.

        The `batch_origin` parameter is inferred from `ptr`'s origin
        parameter. Typical construction:

            var col_ptr = my_primitive_array.data.get_typed_ptr[Scalar[dt]]()
            var view = KeyColumnView[dt, origin_of(my_primitive_array)](
                col_ptr, my_primitive_array.length
            )

        (The first parameter of the type is explicit because Mojo can't
        always infer dtype from a nested pointer; both parameters flow
        together at the type-level.)
        """
        self._ptr = ptr
        self._num_rows = num_rows

    @staticmethod
    def empty() -> KeyColumnView[Self.dtype, Self.batch_origin]:
        """Zero-length view (default constructor). Useful for
        zero-operator degenerate test cases and default State
        initializers.

        SAFETY: `_num_rows == 0` means every bounded accessor rejects
        before dereferencing `_ptr`. The null pointer is never
        dereferenced.
        """
        return KeyColumnView[Self.dtype, Self.batch_origin](
            _null_ptr[Scalar[Self.dtype], Self.batch_origin](),
            0,
        )

    # -------------------------------------------------------------------------
    # Public read-only API
    # -------------------------------------------------------------------------

    @always_inline
    def len(self) -> Int:
        """Logical row count."""
        return self._num_rows

    @always_inline
    def get(self, row: Int) -> Scalar[Self.dtype]:
        """Return the value at `row` by copy.

        SAFETY (caller): `0 <= row < self.len()`. The view does not
        bounds-check on the hot path (the morsel-aware caller's loop
        bound is the row count and is trivially correct); a separate
        `get_checked` lives in the audit API if bounds checks are
        required.
        """
        # SAFETY: internal pointer arithmetic bounded by caller's
        # row-loop precondition. `_ptr` is non-null when `_num_rows > 0`
        # and the parametric origin pins the batch lifetime.
        return self._ptr.load(row)

    @always_inline
    def get_ref(self, row: Int) -> ref [Self.batch_origin] Scalar[Self.dtype]:
        """Return an immutable ref to `row`. Useful for SIMD loads
        and large primitive types where copy-by-value is wasteful
        (Scalar[dtype] is POD so copy is trivial today; kept as an
        extension point for future wider types).

        SAFETY (caller): same as `get`.
        """
        # SAFETY: internal pointer arithmetic. The ref's origin is
        # `batch_origin` -- the same parametric origin pinning the
        # parent batch's lifetime -- not `[self]`. A view value can
        # itself be dropped or re-constructed without invalidating
        # the refs it handed out, because the batch behind it is what
        # they borrow from.
        return (self._ptr + row)[]

    # -------------------------------------------------------------------------
    # Diagnostics
    # -------------------------------------------------------------------------

    @always_inline
    def is_empty(self) -> Bool:
        return self._num_rows == 0
