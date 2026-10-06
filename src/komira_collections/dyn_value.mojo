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
#   - `get[T]()` is the one typed accessor. It is CHECKED: `create[T]` records
#     T's qualified name (`reflect[T].name()`) and size, and `get[T]` raises
#     unless the stored value is occupied and both match. `holds[T]()` asks the
#     same question without raising. No public signature carries a pointer.
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
    all other operations use the checked typed access of `get[T]`.

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
        print(dv.get[MyStruct]().x)  # 42
        dv.get[MyStruct]().x = 7     # writes through when `dv` is mutable
        _ = dv.get[Int]()            # raises: the stored type is MyStruct

    Type check: `create[T]` records `reflect[T].name()` (the fully qualified
    type name, parameters included) and `size_of[T]()`; `get[T]` compares both.
    Two distinct types share a qualified name only if they are the same type,
    so a mismatch is always caught; the size comparison is a second, cheap
    guard. The check is a string compare, which is why DynValue stays a
    cold-path container.
    """

    var _storage: Array[UInt8, Self.MAX_SIZE]
    var _destroy: _DestroyFn   # byte-storage-base destructor (FFI-POD fn-ptr)
    var _occupied: Bool
    var _type_name: StaticString   # reflect[T].name() of the stored T ("" when empty)
    var _type_size: Int            # size_of[T]() of the stored T (0 when empty)

    # NOTE: No __moveinit__ -- auto-synthesized. All fields (InlineArray,
    # fn-ptr, Bool) are trivially copyable.

    def __init__(out self):
        """Create an empty (unoccupied) DynValue."""
        self._storage = Array[UInt8, Self.MAX_SIZE](fill=UInt8(0))
        self._destroy = _noop_destroy
        self._occupied = False
        self._type_name = ""
        self._type_size = 0

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
        result._type_name = reflect[T].name()
        result._type_size = size_of[T]()
        return result^

    def is_occupied(self) -> Bool:
        """Return True when this DynValue holds a value."""
        return self._occupied

    def holds[T: Movable](self) -> Bool:
        """Return True when this DynValue holds a value of type `T`.

        The same check `get[T]` makes, without raising: occupied, and the
        stored type's qualified name and size equal `T`'s.
        """
        return (
            self._occupied
            and self._type_size == size_of[T]()
            and self._type_name == reflect[T].name()
        )

    def get[T: Movable](ref self) raises -> ref [self._storage] T:
        """Return a reference to the stored value as a `T`, checked.

        The reference borrows `self`: it is mutable when `self` is, and the
        compiler keeps the DynValue alive while it is in use.

        Raises:
            An error naming both types when this DynValue is empty or holds a
            value of a type other than `T`. A mismatch is a caller bug, but it
            raises rather than aborts so a caller can recover and a test can
            observe it.
        """
        if not self._occupied:
            raise Error(
                "DynValue.get: empty, asked for " + String(reflect[T].name())
            )
        if not self.holds[T]():
            raise Error(
                "DynValue.get: holds "
                + String(self._type_name)
                + ", asked for "
                + String(reflect[T].name())
            )
        # SAFETY: `holds[T]` proved the storage holds an initialized T (it
        # was moved in by `create[T]`, the only writer, and size_of[T]() <=
        # MAX_SIZE was asserted there). The pointer is built from the inline
        # `_storage` field, so it carries `self._storage`'s concrete origin,
        # and is dereferenced at once: no pointer leaves this body.
        return UnsafePointer(to=self._storage).bitcast[T]()[]

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
