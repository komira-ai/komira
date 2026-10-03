# =============================================================================
# DynValue[MAX_SIZE] -- type-erased inline storage for Movable values
# =============================================================================
#
# Reusable primitive: Rust's `Box<dyn Any>` equivalent but with INLINE storage
# (no heap allocation). The concrete value lives directly in `_storage`; only
# one function pointer (`_destroy`) is stored for cleanup.
#
# Key properties:
#   - NO hand-written __moveinit__ -- all fields are trivially copyable
#     (InlineArray[UInt8], fn-ptr, Bool). Auto-synth move works.
#   - NO UnsafePointer fields -- avoids the mojo 0.26 packager bug that
#     fires on hand-written __moveinit__ with UnsafePointer fields.
#   - Destructor calls the stored _destroy function pointer on drop.
#   - as_ref[T] / as_mut[T] provide typed access (caller must know T).
#
# Used by the engine's `DynAccumulator` for cold-path type-erased
# accumulator storage.
# =============================================================================


from std.sys import size_of


# --- Destroy function helpers ------------------------------------------------

# The destroy fn-ptr takes the byte-storage base POINTER (not an Int address).
# The argument origin is `MutExternalOrigin` because a `def(...) thin -> None`
# fn-ptr SIGNATURE cannot carry an origin parameter — this is the FFI-POD
# fn-ptr carve-out: a code pointer whose argument
# type references a wildcard origin, with no heap and no raw-address round-trip.
# The caller (`__deinit__`) passes a `self`-origin-tied byte pointer; the fn-ptr
# reconstructs `T*` via `bitcast[T]()` (no banned address-reconstruction API).
comptime _DestroyFn = def(UnsafePointer[UInt8, MutUntrackedOrigin]) thin -> None


def _noop_destroy(ptr: UnsafePointer[UInt8, MutUntrackedOrigin]) -> None:
    """No-op destructor for unoccupied DynValue slots."""
    pass


def _make_destroy[T: Deinitable & Movable]() -> _DestroyFn:
    """Create a type-specialized destroy function pointer.

    The returned fn-ptr bitcasts the byte-storage base pointer to `T*` and
    calls `destroy_pointee`. This is the only fn-ptr stored per DynValue --
    all other operations use typed access via `_as_ptr[T]`.

    SAFETY: The byte pointer must point at a live, initialized T value.
    Calling the returned function on an already-destroyed or never-initialized
    address is undefined behavior.
    """
    # Leading underscore: this is a private, type-erased local closure (the
    # stored fn-ptr), NOT a public API — its `UnsafePointer` arg is the
    # FFI-POD fn-ptr carve-out, not a boundary leak.
    def _destroy_impl(base: UnsafePointer[UInt8, MutUntrackedOrigin]) -> None:
        # SAFETY: `base` points at the live `_storage` bytes (passed from
        # DynValue.__deinit__ as a self-origin-tied byte pointer). Reconstruct the
        # typed pointer with `bitcast[T]()` — no Int, no raw-address rebuild.
        base.bitcast[T]().unsafe_deinit_pointee()
    return _destroy_impl


# =============================================================================
# DynValue struct
# =============================================================================

struct DynValue[MAX_SIZE: Int](Movable):
    """Type-erased inline storage for any Movable value up to MAX_SIZE bytes.

    The value is stored directly in `_storage` (no heap allocation). Only
    `_destroy` (a function pointer) and `_occupied` (a bool) are metadata.

    PERF-CRITICAL: DynValue is used by DynAccumulator for cold-path
    accumulator storage (finalize, merge). It is NOT on the hot path --
    the hot path uses MonomorphicKernel for zero-dispatch direct calls.

    Usage:
        var dv = DynValue[256].create[MyStruct](MyStruct(42))
        ref val = dv._as_ptr[MyStruct]()[]
        print(val.x)  # 42
    """

    var _storage: Array[UInt8, Self.MAX_SIZE]
    var _destroy: _DestroyFn   # byte-storage-base destructor (FFI-POD fn-ptr)
    var _occupied: Bool

    # NOTE: No __moveinit__ -- auto-synthesized. All fields (InlineArray,
    # fn-ptr, Bool) are trivially copyable.

    def __init__(out self):
        """Create an empty (unoccupied) DynValue."""
        self._storage = Array[UInt8, Self.MAX_SIZE](fill=UInt8(0))
        self._destroy = _noop_destroy
        self._occupied = False

    @staticmethod
    def create[T: Deinitable & Movable](var value: T) -> Self:
        """Create a DynValue holding `value`, moved in.

        SAFETY: T must fit within MAX_SIZE bytes. This is checked at
        compile time via `comptime assert`. If T exceeds MAX_SIZE, the
        build fails with a clear error message.

        Args:
            value: The value to store. Consumed by move.

        Returns:
            A new DynValue holding the value.
        """
        comptime assert size_of[T]() <= Self.MAX_SIZE, "DynValue: sizeof(T) exceeds MAX_SIZE"
        var result = Self()
        # SAFETY: _storage is MAX_SIZE bytes, size_of[T]() <= MAX_SIZE.
        # We cast the InlineArray storage to a T* and move the value in.
        var dst = UnsafePointer(to=result._storage).bitcast[T]()
        dst.unsafe_write(value^)
        result._destroy = _make_destroy[T]()
        result._occupied = True
        return result^

    def _as_ptr[
        _mut: Bool, o: Origin[mut=_mut], //, T: Movable,
    ](ref [o] self) -> UnsafePointer[T, o]:
        """Return a typed pointer to the stored value with ORIGIN TIED to
        `self`.

        `_storage` is an `InlineArray[UInt8, MAX_SIZE]` stored INLINE in
        `self` (no heap indirection), so the value's address IS
        `UnsafePointer(to=self._storage)` carrying `self`'s origin. We bitcast
        that to `T*` and re-tie the origin to the receiver borrow `o` — the
        compiler tracks every deref site against `self`'s liveness, so an
        ASAP-drop of the owning DynValue (or the DynAccumulator that embeds it)
        can no longer fire between this call and the pointer's first use.

        The origin tie matters: rebuilding a wildcard-origin pointer from a
        raw storage address would sever the lifetime tie to `self`, so an
        ASAP-drop of the owner could fire before the pointer's first use.
        Returning an origin-tied pointer makes that hazard unrepresentable.

        SAFETY: Caller must ensure T matches the type passed to `create[T]`.
        The pointer is valid for the duration of `self`'s borrow `o`; do NOT
        cache it across a move or drop of the owning DynValue.

        Returns:
            A pointer to the stored value, origin-tied to `self`.
        """
        # SAFETY: _storage is MAX_SIZE bytes, size_of[T]() <= MAX_SIZE (checked
        # at create[T]). The inline-storage address carries self's origin; the
        # bitcast + unsafe_origin_cast[o] re-tie the typed pointer to the
        # receiver borrow `o`. No Int round-trip, no wildcard origin.
        return (
            UnsafePointer(to=self._storage)
            .bitcast[T]()
            .unsafe_mut_cast[_mut]()
            .unsafe_origin_cast[o]()
        )

    def __deinit__(deinit self):
        """Destroy the stored value (if occupied) via the fn-ptr destructor."""
        if self._occupied:
            # Pass the byte-storage base pointer (NOT an Int). The fn-ptr arg
            # type erases the origin to MutExternalOrigin (signatures can't
            # carry origin params), but this is `self`-tied at the call site.
            self._destroy(
                UnsafePointer(to=self._storage)
                .bitcast[UInt8]()
                .unsafe_origin_cast[MutUntrackedOrigin]()
            )
