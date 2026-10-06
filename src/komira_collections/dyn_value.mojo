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
#     (InlineArray[UInt8], fn-ptr, Bool, two StaticStrings). The synthesized
#     move copies `_storage` byte for byte, so `create[T]` refuses at compile
#     time a T whose move constructor is not trivial.
#   - NO UnsafePointer fields -- avoids the mojo 0.26 packager bug that
#     fires on hand-written __moveinit__ with UnsafePointer fields.
#   - Destructor calls the stored _destroy function pointer on drop.
#   - `get[T]()` is the one typed accessor. It is CHECKED against a type tag:
#     the linkage (symbol) name of `_type_tag[T]`, one instantiation per T.
#     `get[T]` raises unless the tags match; `holds[T]()` asks without
#     raising. No public signature carries a pointer.
#   - `create[T]` refuses at compile time a T larger than MAX_SIZE or more
#     aligned than the DynValue itself (the storage is at offset 0).
#
# Used by the engine's `DynAccumulator` for cold-path type-erased
# accumulator storage.
# =============================================================================


from std.reflection import get_linkage_name
from std.sys import align_of, size_of


# --- Type tag ---------------------------------------------------------------

def _type_tag[T: AnyType]():
    """Never called. Its linkage name is DynValue's type identity.

    Each T gives a distinct instantiation, hence a distinct symbol: the
    linker needs distinct names for distinct instantiations, so the name is
    injective in T. `reflect[T].name()` is NOT: every function type renders
    `std.builtin._stubs.__MLIRType[<unprintable>]` (measured on Mojo 1.0.0),
    and the module path it prints is not package-qualified.
    """
    pass


@always_inline
def _tag_of[T: AnyType]() -> StaticString:
    """The type tag of T (see `_type_tag`)."""
    return get_linkage_name[_type_tag[T]]()


# --- Destroy function helpers ------------------------------------------------

# The destroy fn-ptr takes the byte-storage base POINTER (not an Int address).
# The argument origin is `MutUntrackedOrigin` because a `def(...) thin -> None`
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

    The value is stored directly in `_storage` (no heap allocation). The
    metadata is `_destroy` (a function pointer), `_occupied` (a bool),
    `_type_tag` (the identity `get` checks) and `_type_name` (the readable
    name its errors print).

    PERF-CRITICAL: DynValue is used by DynAccumulator for cold-path
    accumulator storage (finalize, merge). It is NOT on the hot path --
    the hot path uses MonomorphicKernel for zero-dispatch direct calls.

    Usage:
        var dv = DynValue[256].create[MyStruct](MyStruct(42))
        print(dv.get[MyStruct]().x)  # 42
        dv.get[MyStruct]().x = 7     # writes through when `dv` is mutable
        _ = dv.get[Int]()            # raises: the stored type is MyStruct

    Type check: `create[T]` records the linkage name of `_type_tag[T]`, and
    `get[U]` compares it with `_type_tag[U]`'s. Distinct instantiations have
    distinct symbol names, so `get[U]` succeeds exactly when U is T. The
    readable `reflect[T].name()` is kept only for error text: it is not
    unique (all function types share one), so it is never the identity.
    The check is a string compare, which is why DynValue stays a cold-path
    container.
    """

    var _storage: Array[UInt8, Self.MAX_SIZE]
    var _destroy: _DestroyFn   # byte-storage-base destructor (FFI-POD fn-ptr)
    var _occupied: Bool
    var _type_tag: StaticString    # _tag_of[T]() of the stored T ("" when empty)
    var _type_name: StaticString   # reflect[T].name(), for error text only

    # NOTE: No __moveinit__ -- auto-synthesized. All fields (InlineArray,
    # fn-ptr, Bool, StaticString) are trivially copyable.

    def __init__(out self):
        """Create an empty (unoccupied) DynValue."""
        self._storage = Array[UInt8, Self.MAX_SIZE](fill=UInt8(0))
        self._destroy = _noop_destroy
        self._occupied = False
        self._type_tag = ""
        self._type_name = ""

    @staticmethod
    def create[T: Deinitable & Movable](var value: T) -> Self:
        """Create a DynValue holding `value`, moved in.

        Compile-time refusals (`comptime assert`), each with a message:
          - size_of[T]() > MAX_SIZE;
          - align_of[T]() > align_of[Self]() (the storage is the first
            field, so it is only as aligned as the DynValue: 8 bytes);
          - a T whose move constructor is not trivial (the DynValue moves
            the stored bytes without running it).

        Args:
            value: The value to store. Consumed by move.

        Returns:
            A new DynValue holding the value.
        """
        comptime assert size_of[T]() <= Self.MAX_SIZE, "DynValue: sizeof(T) exceeds MAX_SIZE"
        comptime assert align_of[T]() <= align_of[Self](), (
            "DynValue: align_of(T) exceeds the DynValue's alignment"
        )
        comptime assert T.__move_ctor_is_trivial, (
            "DynValue: T's move constructor is not trivial; the DynValue"
            " moves its bytes without running it"
        )
        var result = Self()
        # SAFETY: _storage is MAX_SIZE bytes, size_of[T]() <= MAX_SIZE.
        # We cast the InlineArray storage to a T* and move the value in.
        var dst = UnsafePointer(to=result._storage).bitcast[T]()
        dst.unsafe_write(value^)
        result._destroy = _make_destroy[T]()
        result._occupied = True
        result._type_tag = _tag_of[T]()
        result._type_name = reflect[T].name()
        return result^

    def is_occupied(self) -> Bool:
        """Return True when this DynValue holds a value."""
        return self._occupied

    def holds[T: Movable](self) -> Bool:
        """Return True when this DynValue holds a value of type `T`.

        The same check `get[T]` makes, without raising: the stored type tag
        equals `T`'s. An empty DynValue's tag is "", which no type has.
        """
        return self._type_tag == _tag_of[T]()

    def get[T: Movable](ref self) raises -> ref [self._storage] T:
        """Return a reference to the stored value as a `T`, checked.

        The reference borrows `self`: it is mutable when `self` is, and the
        compiler keeps the DynValue alive while it is in use.

        Raises:
            When this DynValue is empty (the error names the requested type)
            or holds a value of a type other than `T` (the error names both,
            by `reflect` name, which can read alike for function types). A
            mismatch is a caller bug, but it raises rather than aborts so a
            caller can recover and a test can observe it.
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
        # was moved in by `create[T]`, the only writer, which asserted
        # size_of[T]() <= MAX_SIZE and align_of[T]() <= align_of[Self]();
        # `_storage` is the first field, so it is that aligned). The pointer
        # is built from the inline `_storage` field, so it carries
        # `self._storage`'s concrete origin, and is dereferenced at once: no
        # pointer leaves this body.
        return UnsafePointer(to=self._storage).bitcast[T]()[]

    def __deinit__(deinit self):
        """Destroy the stored value (if occupied) via the fn-ptr destructor."""
        if self._occupied:
            # Pass the byte-storage base pointer (NOT an Int). The fn-ptr arg
            # type erases the origin to MutUntrackedOrigin (signatures can't
            # carry origin params), but this is `self`-tied at the call site.
            self._destroy(
                UnsafePointer(to=self._storage)
                .bitcast[UInt8]()
                .unsafe_origin_cast[MutUntrackedOrigin]()
            )
