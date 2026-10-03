# =============================================================================
# Slab[T] -- the unified typed slab
# =============================================================================
#
# The typed-slab surface is ONE primitive, with movability as a per-method
# receiver refinement rather than a struct-level type distinction.
#
# Interior-mutability primitive: `get_mut_interior`
# -------------------------------------------------------------------------
# `Slab.get_mut_interior(self, i) -> ref [MutExternalOrigin] Self.T` is the
# interior-mutability primitive. It returns a MUTABLE ref through
# an IMMUTABLE `self` — the Mojo analog of C++'s `mutable` keyword or
# Rust's `UnsafeCell<T>`. It exists specifically to support the engine's
# `MorselSinkImpl.consume(self, worker_id, var morsel)` trait contract:
# `consume` takes immutable `self`
# so the generic executor can fan it out to multiple worker threads
# without aliasing a `mut` binding, and each worker writes to its own
# per-worker slot via `self._workers.get_mut_interior(worker_id)`.
#
# This is NOT an escape hatch — it is a *permanent* primitive with a
# documented contract:
#   1. Callers MUST ensure worker-slot disjointness: thread `w` touches
#      only slot `w`, never another thread's slot. (Guaranteed by the
#      `parallelize`+`worker_id` pattern.)
#   2. The returned ref has `MutExternalOrigin` — the compiler CANNOT
#      track use-after-move. Callers must not move/reallocate the slab
#      while the ref is live.
#   3. Concurrent mutation of Atomic fields through this ref is sound
#      (CAS is atomic). Concurrent mutation of non-Atomic fields by
#      DIFFERENT threads on the SAME slot is UB.
#   4. The primitive lives IN `slab.mojo`; callers only see `get_mut_interior`,
#      never the internal `_wild_ptr()` path or raw `UnsafePointer`.
#
# `_mut_ptr(self, i)` is a deprecated pointer-returning alias that forwards
# to `get_mut_interior`.
#
# Storage shape:
#   Byte-backed storage (List[UInt8]) plus _len_t / _cap_t counters. The
#   byte-backed shape is universal -- it serves ANY T: Deinitable
#   including non-Movable (Atomic-bearing) types via `create(n)` + init_slot.
#
# Per-method receiver refinement:
#   Growth methods (append, pop, extend, take_at, swap_remove, shrink_to_fit,
#   __setitem__) are gated via:
#     fn method[Self.T: Movable & Deinitable, //](
#         mut self: Slab[Self.T], ...)
#   Non-Movable T call-sites fail to compile with "no matching method".
#
# Construction patterns:
#   - Non-Movable T, all slots live -> Slab[T].create_prefilled(n)
#     + init_slot[init_fn](i) per slot. `create_prefilled` zero-fills bytes
#     and sets _len_t = n so the destructor runs on all slots.
#   - Empty-with-capacity (_len_t=0; append to populate) ->
#     Slab[T].create(capacity), Slab[T](capacity) or
#     Slab[T].with_capacity(n).
#   - Zero-cap default -> Slab[T]().
#   - Compile-time-N fixed arrays -> stdlib InlineArray[T, N] directly.
#
# Non-Movable init:
#   init_slot[init_fn] takes a closure of shape
#   `fn (UnsafePointer[Self.T, MutAnyOrigin]) -> None`, NOT `fn (mut T)`.
#   The latter would require T: Movable to move a fresh T into the receiver
#   slot, which breaks the non-Movable use case. The MutAnyOrigin wildcard
#   is safe because the pointer is not stored and does not outlive the
#   closure body -- it's a narrow init-only escape analogous to FFI-init.
#
# Append fast/slow split:
#   `append` MUST be split into @always_inline fast path + @no_inline
#   _grow_and_append slow path; the split is what lets it reach parity
#   with stdlib List[Int].
# =============================================================================

from std.memory import UnsafePointer, unsafe_memset, unsafe_uninit_move_n
from komira_atomic_alias import AtomicI64
from std.sys import size_of


comptime _MIN_CAP_T: Int = 4


struct Slab[T: Movable & Deinitable](Movable, Sized):
    """The unified typed slab -- one struct for every former slab variant.

    Fields:
        _bytes: List[UInt8] holding the raw byte buffer. UInt8 is Copyable
            + Deinitable, so List[UInt8] auto-synthesizes move
            and drop.
        _len_t: Number of live T slots. Invariant: 0 <= _len_t <= _cap_t.
        _cap_t: Number of T slots the buffer can hold.

    Invariants (maintained by this file only):
        I1: 0 <= _len_t <= _cap_t
        I2: _bytes.len() >= _cap_t * size_of[T]()
        I3: T slots [0, _len_t) hold initialized T values
        I4: T slots [_len_t, _cap_t) hold uninitialized bytes

    Move semantics:
        Auto-synthesized. Transfers List[UInt8] ownership; _len_t / _cap_t
        are trivial Int copies.

    Destruction:
        Hand-written __deinit__ destroys live T slots [0, _len_t) in forward
        order, then List[UInt8]'s auto-drop frees the backing buffer.
    """

    # SAFETY: List[UInt8] holds the heap allocation. We treat its bytes as
    # a strided T buffer via unsafe_ptr().bitcast[T](). UInt8 is Copyable +
    # Deinitable so List[UInt8] auto-synths Movable.
    var _bytes: List[UInt8]
    var _len_t: Int
    var _cap_t: Int

    # =========================================================================
    # Construction -- universal (any T: Deinitable)
    # =========================================================================

    def __init__(out self):
        """Create an empty slab (capacity 0)."""
        self._bytes = List[UInt8]()
        self._len_t = 0
        self._cap_t = 0

    def __init__(out self, capacity: Int):
        """Create an empty slab with `capacity` pre-allocated T slots.

        `_len_t = 0` — slots are uninitialized, callers use `append()`
        (or `init_slot[...]` for non-Movable T) to fill.

        Args:
            capacity: Number of T slots to pre-allocate. If <= 0, no
                allocation occurs (equivalent to the default constructor).
        """
        self._bytes = List[UInt8]()
        self._len_t = 0
        self._cap_t = 0
        if capacity > 0:
            self._reserve_t(capacity)

    @staticmethod
    def create(n: Int) -> Slab[Self.T]:
        """Allocate storage for N T-slots; leave slab empty (_len_t=0).

        The empty-with-capacity factory. Callers populate via
        `append(...)` (for Movable T) or via `init_slot[init_fn](i)` +
        `set_len_unchecked(n)` (for non-Movable T with explicit per-slot
        init).

        For the all-slots-live zero-filled factory, use
        `create_prefilled(n)` instead.

        Args:
            n: Number of T slots. Must be >= 0.

        Returns:
            A slab with capacity=n, length=0, and uninitialized storage.
        """
        var out = Slab[Self.T]()
        if n > 0:
            out._reserve_t(n)
        return out^

    @staticmethod
    def with_capacity(capacity: Int) -> Slab[Self.T]:
        """Create an empty slab with pre-allocated capacity.

        Static factory mirror of `Slab[T](capacity)`. `_len_t = 0` after
        this call — callers populate via `append()`.
        """
        return Slab[Self.T](capacity)

    @staticmethod
    def create_with_capacity(capacity: Int) -> Slab[Self.T]:
        """Alias for `with_capacity(n)`.
        """
        return Slab[Self.T](capacity)

    @staticmethod
    def create_prefilled(n: Int) -> Slab[Self.T]:
        """Allocate N zero-byte-filled slots and set `_len_t = n`.

        All N slots are considered live from this call forward; the
        destructor will run `destroy_pointee` on each. The bytes are
        zeroed, which is
        critical for element types containing `Atomic`, `PosixMutex`,
        `PosixCondvar`, or `List` fields whose destructors check for
        null/zero bit patterns.

        Callers populate per-slot fields via `get_mut_interior(i)` or
        `init_slot[init_fn](i)` BEFORE any field-destroying mutation.

        Args:
            n: Number of T slots. Must be >= 0. If 0, returns an empty
                slab with no allocation.

        Returns:
            A slab with capacity=n, length=n, zero-filled bytes.
        """
        var out = Slab[Self.T]()
        if n > 0:
            out._reserve_t(n)
            # SAFETY: _reserve_t grew _bytes to n * size_of[T]() bytes;
            # zero-fill so that
            # field-destroying operations on Atomic-bearing non-Movable T
            # don't read uninitialized bytes. UInt8 is a plain byte — no
            # T-level destructors can run until we set _len_t > 0.
            unsafe_memset(out._bytes.unsafe_ptr(), 0, n * size_of[Self.T]())
            out._len_t = n
        return out^

    # =========================================================================
    # Destructor -- universal
    # =========================================================================

    def __deinit__(deinit self):
        """Destroy live T slots, then List[UInt8]'s auto-drop frees bytes.

        T.__deinit__ runs for slots in [0, _len_t) in forward order. After
        this, List[UInt8]'s auto-synth drop frees the backing allocation.
        """
        # SAFETY: slots [0, _len_t) are initialized T values. Destroy in
        # forward order via destroy_pointee on the T-typed pointer. The
        # bitcast is sound while self._bytes is still live (auto-drop of
        # fields runs AFTER this __deinit__ body).
        if self._len_t > 0:
            var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
            for i in range(self._len_t):
                (t_ptr + i).unsafe_deinit_pointee()

    # =========================================================================
    # Size queries -- universal
    # =========================================================================

    @always_inline
    def __len__(self) -> Int:
        """Return the number of live T slots."""
        return self._len_t

    @always_inline
    def len(self) -> Int:
        """Return the number of live T slots."""
        return self._len_t

    @always_inline
    def capacity(self) -> Int:
        """Return the number of T slots the buffer can hold."""
        return self._cap_t

    @always_inline
    def is_empty(self) -> Bool:
        """Return True when there are no live slots."""
        return self._len_t == 0

    @always_inline
    def is_full(self) -> Bool:
        """Return True when `_len_t == _cap_t`.
        """
        return self._len_t == self._cap_t

    # =========================================================================
    # Element access -- universal (any T: Deinitable)
    # -------------------------------------------------------------------------
    # __getitem__ returns `ref [self._bytes] T` (the compiler
    # tracks liveness transitively through `self`, so callers see a
    # functionally-equivalent borrow).
    # =========================================================================

    @always_inline
    def __getitem__(ref self, idx: Int) -> ref [self._bytes] Self.T:
        """Return a reference to slot `idx`.

        PANICS if idx >= _len_t or idx < 0. Returns a tight-origin ref
        through the owning byte-allocation field. For
        non-Movable T with Atomic fields: CAS through Atomic is sound
        (interior mutability). Non-Atomic field mutation through this
        ref from multiple threads is UB -- caller SAFETY comment required.
        """
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.__getitem__: index out of bounds",
        )
        # SAFETY: idx is bounds-checked. The bitcast is sound while
        # self._bytes is live (which it is -- we are inside a method on
        # self and the returned ref borrows through self._bytes).
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        return (t_ptr + idx)[]

    @always_inline
    def get(ref self, idx: Int) -> ref [self._bytes] Self.T:
        """Return a reference to slot `idx`. Identical semantics to
        `__getitem__`.
        """
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.get: index out of bounds",
        )
        # SAFETY: idx is bounds-checked. See __getitem__.
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        return (t_ptr + idx)[]

    # =========================================================================
    # init_slot -- universal non-Movable init path
    # =========================================================================

    @always_inline
    def init_slot[
        init_fn: def (UnsafePointer[Self.T, MutAnyOrigin]) thin -> None
    ](mut self, idx: Int):
        """Single-threaded in-place init of slot `idx`.

        PANICS if idx < 0 or idx >= _cap_t.

        init_fn receives `UnsafePointer[Self.T, MutAnyOrigin]`
        (not `mut T`). `fn (mut T)` would require T: Movable to move a
        fresh T into the receiver slot, which breaks non-Movable T. The
        MutAnyOrigin wildcard is safe because:
          (a) the pointer is provided synchronously to the closure -- it
              cannot be stored;
          (b) the pointee is uninitialized BEFORE the closure runs and
              initialized AFTER -- there is no "live data" to disable
              tracking on;
          (c) the closure is comptime-specialized and fully inlined --
              there is no fn-pointer value escape.

        Callers direct-field-assign via the raw pointer, e.g.:
            `slot[].counter = Atomic[DType.int64](0)`.

        After init_fn returns, __getitem__ is safe on that slot. If the
        slot is in `[_len_t, _cap_t)` the caller MUST follow up with
        `set_len_unchecked` (or have used `create(n)` which set _len_t=n
        at construction time) before calling __getitem__.

        Parameters:
            init_fn: Comptime-specialized closure that initializes the slot
                via the raw pointer. MUST NOT store or leak the pointer.
        """
        debug_assert(
            idx >= 0 and idx < self._cap_t,
            "Slab.init_slot: idx out of capacity range",
        )
        # SAFETY: init-only wildcard; pointer does not escape
        # the closure. idx bounds-checked above.
        var t_ptr = (
            self._bytes.unsafe_ptr()
            .bitcast[Self.T]()
            .unsafe_origin_cast[MutAnyOrigin]()
        )
        init_fn(t_ptr + idx)

    # =========================================================================
    # Typed Atomic helpers -- universal
    # -------------------------------------------------------------------------
    # Each `[field_accessor]` is a comptime fn-parameter (not a fn-ptr value;
    # origin-parameterized fn-ptr values are not allowed). Accessor is
    # origin-generic over `o: MutOrigin`, NOT `self`. Inside
    # the accessor body, subfield access yields `ref [o.<field>] U`, so the
    # accessor must widen back to `ref [o] U` via
    # `UnsafePointer(to=inner).unsafe_origin_cast[o]()[]`.
    # =========================================================================

    @always_inline
    def field_load_i64[
        field_accessor: def[o: MutOrigin] (ref [o] Self.T) thin -> ref [o] AtomicI64
    ](mut self, idx: Int) -> Int64:
        """Load the Atomic[DType.int64] field selected by `field_accessor`.

        Takes `mut self` so `origin_of(self)` resolves to a concrete
        MutOrigin for the accessor to instantiate at.

        PANICS if idx >= _len_t or idx < 0.

        Parameters:
            field_accessor: Comptime closure returning a ref to the target
                Atomic field within Self.T. Must widen subfield origin to
                `o`.
        """
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.field_load_i64: idx out of bounds",
        )
        # SAFETY: idx bounds-checked. Widen slot-ref from `self._bytes`
        # origin to `origin_of(self)` via UnsafePointer+unsafe_origin_cast
        # so the field_accessor's `o: MutOrigin` parameter can unify with
        # the slab-level origin.
        var t_ptr = (
            self._bytes.unsafe_ptr()
            .bitcast[Self.T]()
            .unsafe_origin_cast[origin_of(self)]()
        )
        ref slot = (t_ptr + idx)[]
        ref atom = field_accessor[origin_of(self)](slot)
        return atom.load()

    @always_inline
    def field_fetch_add_i64[
        field_accessor: def[o: MutOrigin] (ref [o] Self.T) thin -> ref [o] AtomicI64
    ](mut self, idx: Int, delta: Int64) -> Int64:
        """Atomic fetch_add on the Atomic[DType.int64] field selected by `field_accessor`.

        PANICS if idx >= _len_t or idx < 0.

        Returns the value stored before the add (fetch_add semantics).

        Parameters:
            field_accessor: See `field_load_i64`.
        """
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.field_fetch_add_i64: idx out of bounds",
        )
        # SAFETY: idx bounds-checked. See field_load_i64 for why we widen
        # the slot-ref origin to `origin_of(self)` before the accessor.
        var t_ptr = (
            self._bytes.unsafe_ptr()
            .bitcast[Self.T]()
            .unsafe_origin_cast[origin_of(self)]()
        )
        ref slot = (t_ptr + idx)[]
        ref atom = field_accessor[origin_of(self)](slot)
        return atom.fetch_add(delta)

    # =========================================================================
    # Length-management -- universal
    # =========================================================================

    def clear(mut self):
        """Destroy all live slots; set _len_t = 0. Keeps _bytes allocated."""
        if self._len_t > 0:
            var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
            for i in range(self._len_t):
                (t_ptr + i).unsafe_deinit_pointee()
            self._len_t = 0

    def reserve(mut self, additional: Int):
        """Ensure room for at least `additional` more T slots beyond len().

        Grows the buffer if necessary; preserves existing contents.

        Args:
            additional: Extra slots required. Must be >= 0.
        """
        if additional <= 0:
            return
        var required = self._len_t + additional
        if required <= self._cap_t:
            return
        var new_cap = self._cap_t
        if new_cap < _MIN_CAP_T:
            new_cap = _MIN_CAP_T
        while new_cap < required:
            new_cap = new_cap * 2
        self._reserve_t(new_cap)

    def resize(mut self, new_capacity: Int):
        """Ensure capacity is at least `new_capacity` T slots.

        No-op if new_capacity <= current capacity (we do not shrink).
        Does NOT change _len_t.

        Args:
            new_capacity: Desired minimum T-slot capacity. Must be >= 0.
        """
        if new_capacity <= self._cap_t:
            return
        self._reserve_t(new_capacity)

    @always_inline
    def set_len_unchecked(mut self, new_len: Int):
        """UNSAFE: set _len_t without destroying abandoned slots.

        SAFETY CONTRACT (caller must uphold):
          - 0 <= new_len <= capacity().
          - If new_len < len(): slots [new_len, len()) must have been
            destroyed (via take_at/swap_remove/pop) OR moved-out before
            this call -- otherwise their destructors leak.
          - If new_len > len(): slots [len(), new_len) must have been
            manually initialized via init_slot -- otherwise the next drop
            calls destroy_pointee on uninitialized memory (UB).

        Used by morsel fast paths that batch-init a range via init_slot
        and then set length in one call.

        Args:
            new_len: New logical length. Must be in [0, capacity()].
        """
        debug_assert(
            new_len >= 0 and new_len <= self._cap_t,
            "Slab.set_len_unchecked: new_len out of bounds",
        )
        self._len_t = new_len

    @always_inline
    def set_len(mut self, new_len: Int):
        """Set the logical length (alias of `set_len_unchecked`).

        Same contract as `set_len_unchecked` — caller must manage
        element lifetimes across the length change. See
        `set_len_unchecked` docstring for the full contract.
        """
        debug_assert(
            new_len >= 0 and new_len <= self._cap_t,
            "Slab.set_len: new_len out of bounds",
        )
        self._len_t = new_len

    @always_inline
    def unsafe_set_len(mut self, new_len: Int):
        """Alias of `set_len_unchecked`.

        Identical semantics to `set_len_unchecked`.
        """
        debug_assert(
            new_len >= 0 and new_len <= self._cap_t,
            "Slab.unsafe_set_len: new_len out of bounds",
        )
        self._len_t = new_len

    # =========================================================================
    # Movable-gated API (T: Movable & Deinitable)
    # -------------------------------------------------------------------------
    # Each method uses receiver refinement (the stdlib `Span` pattern).
    # Compile error "no matching method" on
    # Slab[NonMovableT].<movable_method>(...) is the negative-test contract.
    # =========================================================================

    @always_inline
    def __setitem__(mut self, idx: Int, var value: Self.T):
        """Replace slot `idx`. PANICS if idx >= _len_t or idx < 0.

        Destroys the existing value at idx (must be initialized) and moves
        `value` into place. For idx == len_t, use `append`. For
        uninitialized slots (idx in [_len_t, _cap_t)), use `init_slot`
        instead -- __setitem__ would destroy garbage memory otherwise.
        """
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.__setitem__: index out of bounds",
        )
        # SAFETY: idx is bounds-checked; slot is initialized (idx < _len_t).
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        (t_ptr + idx).unsafe_deinit_pointee()
        (t_ptr + idx).unsafe_write(value^)

    @always_inline
    def set(mut self, idx: Int, var value: Self.T):
        """Replace slot `idx`. Identical semantics to `__setitem__`.
        """
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.set: index out of bounds",
        )
        # SAFETY: idx is bounds-checked; slot is initialized (idx < _len_t).
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        (t_ptr + idx).unsafe_deinit_pointee()
        (t_ptr + idx).unsafe_write(value^)

    @always_inline
    def replace(mut self, idx: Int, var value: Self.T) -> Self.T:
        """Replace slot `idx` with `value`, returning the previous occupant.

        Mojo equivalent of Rust's `std::mem::replace(&mut slot, value)`.
        PANICS if idx >= _len_t or idx < 0.

        Use case: extracting a Movable-but-not-Copyable value from a
        slab slot WITHOUT shrinking the slab — e.g. taking an
        `Optional[T]` out of a per-segment output slot while the slot
        index remains valid for downstream readers (e.g. an inter-
        segment shallow-batch hand-off).

        Direct `slab[idx].take()` trips Mojo 0.26.3's implicit-copy
        check on a non-Copyable element type (the `__getitem__` ref
        does not bind to `mut self` of `Optional.take`); `replace` is
        the move-out primitive that bypasses that limitation by doing
        the take-and-restore inside one method on `mut self: Slab[Self.T]`.
        """
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.replace: index out of bounds",
        )
        # SAFETY: idx is bounds-checked; slot is initialized (idx < _len_t).
        # take_pointee moves the old occupant out; init_pointee_move
        # installs `value` byte-aligned. No leak (old returned), no
        # double-free (slot stays initialized exactly once at all times).
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        var old = (t_ptr + idx).take_pointee()
        (t_ptr + idx).unsafe_write(value^)
        return old^

    @always_inline
    def append(mut self, var value: Self.T):
        """Append `value` to the slab, growing if needed.

        Fast path: cap-check + store + len++. Slow path is outlined
        (`_grow_and_append`) to keep this body tight. Amortized O(1) via
        geometric growth (2x, min 4).

        The fast/slow split is a load-bearing perf contract: it is what
        brings append to parity with stdlib List[Int].
        """
        if self._len_t < self._cap_t:
            # SAFETY: len_t < cap_t means slot _len_t is in-bounds and
            # uninitialized. init_pointee_move initializes it.
            var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
            (t_ptr + self._len_t).unsafe_write(value^)
            self._len_t += 1
            return
        self._grow_and_append(value^)

    @no_inline
    def _grow_and_append(mut self, var value: Self.T):
        """Slow path of `append` -- geometric resize then append.

        Outlined (@no_inline) to keep the append fast path tight.
        Called only when _len_t == _cap_t.
        """
        var new_cap = self._cap_t * 2
        if new_cap < _MIN_CAP_T:
            new_cap = _MIN_CAP_T
        self._reserve_t(new_cap)
        # SAFETY: after _reserve_t, slot _len_t is in-bounds and uninitialized.
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        (t_ptr + self._len_t).unsafe_write(value^)
        self._len_t += 1

    def pop(mut self) -> Optional[Self.T]:
        """Remove and return the last slot, or None if empty."""
        if self._len_t == 0:
            return None
        # SAFETY: _len_t > 0 so slot _len_t - 1 is initialized.
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        self._len_t -= 1
        var val = (t_ptr + self._len_t).take_pointee()
        return val^

    def extend(mut self, var src: Self):
        """Move all elements from `src` into self. `src` is consumed empty.

        Grows self as needed. This is O(n) moves -- for huge batches,
        prefer `reserve` + repeated `append` or a memcpy-based bulk path
        on the caller side.
        """
        var n = src._len_t
        if n == 0:
            return
        if self._len_t + n > self._cap_t:
            var new_cap = self._cap_t
            if new_cap < _MIN_CAP_T:
                new_cap = _MIN_CAP_T
            while new_cap < self._len_t + n:
                new_cap = new_cap * 2
            self._reserve_t(new_cap)
        # SAFETY: bounds are in range for both sides after reserve.
        var dst_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        var src_ptr = src._bytes.unsafe_ptr().bitcast[Self.T]()
        for i in range(n):
            var val = (src_ptr + i).take_pointee()
            (dst_ptr + self._len_t + i).unsafe_write(val^)
        self._len_t += n
        # Src slots [0, n) have been moved-out; prevent src.__deinit__ from
        # destroying them.
        src._len_t = 0

    def extend(mut self, mut src: Self):
        """`mut src` overload of `extend(var src)`.

        Takes a mutable reference and empties the source in place, for
        callers that cannot move `src`
        (e.g. callers that hold `src` via a field of a `var struct` —
        Mojo forbids partial moves out of structs).

        After this call, `src._len_t == 0`; elements have been moved
        into self.
        """
        var n = src._len_t
        if n == 0:
            return
        if self._len_t + n > self._cap_t:
            var new_cap = self._cap_t
            if new_cap < _MIN_CAP_T:
                new_cap = _MIN_CAP_T
            while new_cap < self._len_t + n:
                new_cap = new_cap * 2
            self._reserve_t(new_cap)
        # SAFETY: bounds are in range for both sides after reserve.
        var dst_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        var src_ptr = src._bytes.unsafe_ptr().bitcast[Self.T]()
        for i in range(n):
            var val = (src_ptr + i).take_pointee()
            (dst_ptr + self._len_t + i).unsafe_write(val^)
        self._len_t += n
        # Src slots [0, n) have been moved-out; mark src empty so its
        # destructor does not double-destroy.
        src._len_t = 0

    def take_at(mut self, idx: Int) -> Self.T:
        """Remove slot `idx`, shifting subsequent slots left. PANICS if
        idx >= _len_t or idx < 0."""
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.take_at: index out of bounds",
        )
        # SAFETY: idx is bounds-checked. take_pointee moves out of the
        # slot (pointee is now invalid); subsequent slots are shifted via
        # take_pointee/init_pointee_move pairs.
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        var val = (t_ptr + idx).take_pointee()
        var tail = self._len_t - idx - 1
        for i in range(tail):
            var moved = (t_ptr + idx + 1 + i).take_pointee()
            (t_ptr + idx + i).unsafe_write(moved^)
        self._len_t -= 1
        return val^

    def take_slot_unchecked(mut self, idx: Int) -> Self.T:
        """Move slot `idx` out WITHOUT shifting tail OR adjusting length.

        PANICS if idx >= _len_t or idx < 0.

        Canonical "drain in place" primitive for a NON-FALLIBLE bulk
        drain — see the ⛔⛔ clause below before using it in a loop whose
        body can raise. Used by bulk-drain loops that move every slot out
        in forward order before dropping the slab. Prefer it over the
        pointer pattern:

            for i in range(len): val = slab._mut_ptr(i).take_pointee()
            slab.set_len(0)

        with the safer:

            for i in range(len): val = slab.take_slot_unchecked(i)
            slab.set_len_unchecked(0)

        SAFETY CONTRACT (caller must uphold):
          After all draining calls, caller MUST call
          `set_len_unchecked(new_len)` with `new_len` equal to the
          number of slots that are STILL INITIALIZED. The drop will
          `destroy_pointee` on slots [0, _len_t); if drained slots are
          still counted as live, the destructor will read uninitialized
          memory (UB).

        ⛔⛔ AND THE LOOP BODY MUST NOT BE ABLE TO RAISE. This is the half
        of the contract that is NOT visible in the example above. The
        length fix is a SEPARATE STATEMENT AFTER the loop, so an
        error escaping the loop skips it: the slab unwinds still claiming
        all N slots are live and its destructor `destroy_pointee`s the
        ones already moved out. For a heap-owning T that is a DOUBLE FREE,
        not a leak.

        ⭐ THE MOVED-FROM SLOT IS NOT POISONED, and that is what makes it a
        double free rather than a no-op. This method is a bitwise
        `take_pointee`; the slot's bytes are left as they were. MEASURED on
        `Slab[List[Int]]`: the address the moved-out value owns and the
        address STILL IN THE SLOT after the move are the same word, and the
        slot still reports its original length.

        ⚠ IT IS UB, NOT A GUARANTEED CRASH — which is why the class stays
        latent. The same probe, and a much heavier nested payload, BOTH
        SURVIVE the double drop on macOS/libmalloc, because nothing
        reallocated the blocks in between. A green toy proves nothing about
        a site; read the consumer's signature.

        ⚠ THE CHECK IS MECHANICAL, AND IT IS THE CONSUMER'S SIGNATURE. A
        `def` raises ONLY if it writes `raises` (it is NOT implicit), so
        "can this drain unwind" is answered by reading
        the call target. Two ways to read it wrong: a MULTI-LINE signature
        carries `raises` on its CLOSING line, and a TRAIT method's `raises`
        is on the trait's declaration, not at the call site.

        Forward, O(N), and unwind-safe at every point — use this when the
        body can raise:

            for i in range(len): val = slab.replace(i, T_default())
            # no trailing length fix: every slot is initialised throughout

        `replace` swaps a default-constructed T into the slot it empties,
        so the destructor is sound on EVERY unwind path. `take_at(0)` and
        `pop()` are unwind-safe for the same reason (they adjust `_len_t`
        as they go), but `take_at(0)` in a loop reintroduces the O(N^2)
        tail shift this primitive exists to avoid.

        ⚠ THE PREFIX LENGTH MODEL IS WHY THERE IS NO SAFE FORWARD
        `take_slot_unchecked` DRAIN. `_len_t` can only describe live =
        [0, _len_t); a forward drain's intermediate state is live =
        [i, n), which the model cannot spell. So the window between the
        first move-out and the trailing `set_len_unchecked` is not an
        oversight to tighten — it is unrepresentable, and any fallible
        call inside it is unsound.

        Args:
            idx: Slot index in [0, len()).

        Returns:
            The value formerly held at slot `idx`.
        """
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.take_slot_unchecked: index out of bounds",
        )
        # SAFETY: idx bounds-checked; we do not touch `_len_t`, so the
        # destructor contract shifts to the caller (documented above).
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        return (t_ptr + idx).take_pointee()

    def swap_remove(mut self, idx: Int) -> Self.T:
        """Remove slot `idx` in O(1) by swapping the last slot into its
        place. PANICS if idx >= _len_t or idx < 0."""
        debug_assert(
            idx >= 0 and idx < self._len_t,
            "Slab.swap_remove: index out of bounds",
        )
        var t_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
        var val = (t_ptr + idx).take_pointee()
        var last = self._len_t - 1
        if idx != last:
            var moved = (t_ptr + last).take_pointee()
            (t_ptr + idx).unsafe_write(moved^)
        self._len_t -= 1
        return val^

    def shrink_to_fit(mut self):
        """Shrink capacity down to len(). No-op if already at that size."""
        if self._len_t == self._cap_t:
            return
        # Build a new slab with exactly _len_t capacity, move elements in,
        # then swap storage.
        var new_cap = self._len_t
        var new_bytes = List[UInt8]()
        if new_cap > 0:
            new_bytes.resize(
                unsafe_uninit_length=new_cap * size_of[Self.T]()
            )
            # SAFETY: both sides have _len_t initialized slots at the
            # start; we move each T then set the new List as our storage.
            var src_ptr = self._bytes.unsafe_ptr().bitcast[Self.T]()
            var dst_ptr = new_bytes.unsafe_ptr().bitcast[Self.T]()
            for i in range(self._len_t):
                var moved = (src_ptr + i).take_pointee()
                (dst_ptr + i).unsafe_write(moved^)
        # Replace self._bytes. Old List[UInt8] auto-drops its (now
        # moved-out, byte-only) buffer; T-level slots were already handed
        # off so no double-destroy.
        self._bytes = new_bytes^
        self._cap_t = new_cap

    # =========================================================================
    # Wildcard-origin pointer helpers (module-internal)
    # -------------------------------------------------------------------------
    # Do NOT add new callers of these methods — write new code against
    # `__getitem__` / `__setitem__` / `get` / `set` / `init_slot[init_fn]` /
    # `get_mut_interior` (see above). `_mut_ptr` lives below under the
    # interior-mutability section — it is a deprecated ALIAS for the
    # permanent `get_mut_interior` primitive.
    # =========================================================================

    @always_inline
    def _wild_ptr(self) -> UnsafePointer[Self.T, MutUntrackedOrigin]:
        """T-typed base pointer with a wildcard origin (module-internal).

        SAFETY: wildcard origin — compiler does NOT track use-after-move.
        Caller must keep `self` alive through any use and must not
        reallocate the buffer.
        """
        return self._bytes.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]().bitcast[Self.T]()

    # =========================================================================
    # Interior-mutability primitive -- PERMANENT
    # -------------------------------------------------------------------------
    # `get_mut_interior` is the interior-mutability primitive. It
    # returns a MUTABLE ref to slot `i` through an IMMUTABLE `self`, by
    # laundering the detachable-origin (wildcard) pointer internally. This
    # is the Mojo analog of C++ `mutable` / Rust `UnsafeCell<T>`, and it
    # exists specifically to support the engine's
    # `MorselSinkImpl.consume(self, ...)` trait contract: immutable `self` +
    # per-worker-slot mutation from parallel workers.
    #
    # The wildcard origin is load-bearing here: it detaches the returned
    # ref's mutability from `self`'s immutability. Only the
    # disjoint-worker-slot invariant (worker `w` touches only slot `w`)
    # makes this sound. The interior-mutability pattern is fundamental to
    # the worker-fan-out design and cannot be expressed otherwise in Mojo.
    # =========================================================================

    # PERMANENT-PRIMITIVE: interior mutability for
    # MorselSinkImpl.consume(self, ...).
    # DO NOT DELETE.
    @always_inline
    def get_mut_interior(self, i: Int) -> ref [MutUntrackedOrigin] Self.T:
        """Return a MUTABLE ref to slot `i` through an IMMUTABLE `self`.

        The interior-mutability primitive — Mojo's equivalent of C++'s
        `mutable` keyword / Rust's `UnsafeCell<T>`. Callers hold `self`
        as an immutable borrow (required by
        `MorselSinkImpl.consume(self, worker_id, var morsel)`) and obtain
        a mutable ref to a per-worker slot.

        SAFETY contract (all four are required — breaking any is UB):

          (1) Disjointness. Each worker `w` must touch ONLY slot `w`.
              Two threads writing different fields of the SAME slot
              through get_mut_interior is UB on non-Atomic fields;
              two threads writing DIFFERENT slots is sound. Enforced
              by the `parallelize` + `worker_id` dispatch pattern.

          (2) Liveness. `self` must remain alive for the entire duration
              of the returned ref's use. The wildcard origin detaches
              the compiler's use-after-move tracking; the caller is the
              proof carrier. In practice `self` is a `ref [outer]` inside
              a `consume(self, ...)` body, which is scoped to the
              method call — always satisfied.

          (3) No reallocation. `self` must NOT undergo `append` / `reserve`
              / `resize` / `_grow_and_append` / `shrink_to_fit` while the
              ref is live. Those operations may reallocate the backing
              `List[UInt8]` and invalidate the laundered pointer.
              `consume(self, ...)` takes immutable `self`, which
              structurally prevents mutation methods (they require
              `mut self`) — the only way to violate this is if a method
              on `self` internally uses `get_mut_interior` AND then
              reallocates through a separate path.

          (4) Atomic-discipline for inter-thread sharing. If the SAME
              slot is read by thread A while thread B writes it, every
              mutating access through the returned ref must be against
              `Atomic[...]` fields (CAS / fetch_add). Non-atomic writes
              observed across threads are UB.

        This primitive is NOT an escape hatch — it is an intentional,
        permanent API with a documented contract, load-bearing for the
        consume-trait pattern.

        Args:
            i: Slot index. Must be in `[0, len())`.

        Returns:
            A `ref [MutExternalOrigin] Self.T` to slot `i`.
        """
        # SAFETY: (1) Disjointness is caller-carried (worker_id == slot).
        # (2) Liveness: `self` is the immutable borrow on the current
        #     method-call stack frame; the ref cannot outlive `self` in
        #     any realistic caller because Mojo rejects returning the
        #     bare ref past the containing scope — it must be consumed
        #     in-place or bound to a named ref.
        # (3) No-reallocation: `self` is immutable here; growth methods
        #     require `mut self` and are statically unreachable from
        #     this call site.
        # (4) Atomic-discipline is caller-carried per the contract.
        #
        # `_wild_ptr()` returns `UnsafePointer[Self.T, MutExternalOrigin]`
        # pointing at slot 0 of the byte-backed buffer. Offsetting by
        # `i` and dereferencing yields the `ref [MutExternalOrigin] T`.
        # The wildcard-origin laundering is confined to this one line
        # inside the Slab module — callers see only the safe ref-return.
        return (self._wild_ptr() + i)[]

    # =========================================================================
    # Deprecated alias for `get_mut_interior`
    # -------------------------------------------------------------------------
    # `_mut_ptr(self, i) -> UnsafePointer[Self.T, ...]` is the
    # pointer-returning spelling of the interior-mutability primitive
    # `get_mut_interior` (which returns a `ref`). Prefer
    # `slab.get_mut_interior(i)` over `slab._mut_ptr(i)[]`, and
    # `UnsafePointer(to=slab.get_mut_interior(i))` over `slab._mut_ptr(i)`.
    # =========================================================================

    @always_inline
    def _mut_ptr(self, i: Int) -> UnsafePointer[Self.T, MutUntrackedOrigin]:
        """DEPRECATED — use `get_mut_interior(i)` for the interior-mutability
        ref, or `UnsafePointer(to=get_mut_interior(i))` when a pointer is
        required.

        Same wildcard-origin, same semantics as `get_mut_interior`;
        callers that deref immediately
        (`slab._mut_ptr(i)[].method(...)`) behave identically.

        SAFETY: caller must ensure 0 <= i < len(). Do NOT store past the
        next mutation (append/resize may reallocate and invalidate).
        See `get_mut_interior` for the full interior-mutability contract.
        """
        return self._wild_ptr() + i


    @always_inline
    def _unsafe_as_pointer(
        self,
    ) -> UnsafePointer[Self.T, MutUntrackedOrigin]:
        """Base pointer with a wildcard origin, for `@parameter parallelize`
        captures: the raw pointer is lifted out of `mut self` so the
        closure can access disjoint worker slots without re-borrowing
        `mut self` across tasks. A `ref`-returning API
        (`get_mut_interior`) would require closure-capture primitives the
        Mojo compiler does not yet support.

        SAFETY: caller owns disjointness proof (parallelize) and liveness
        proof (self outlives the closure). Do NOT mutate length/capacity
        while the pointer is live.
        """
        return self._wild_ptr()

    @always_inline
    def _unsafe_ptr[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self) -> UnsafePointer[Self.T, o]:
        """Return a pointer to the base of the T array with ORIGIN TIED to
        `self` (and therefore to the owning container — e.g. the RecordBatch
        whose `_columns` Slab this is).

        A wildcard origin here would disable ASAP-destruction lifetime
        tracking — `rb._columns._unsafe_ptr()` would NOT extend `rb`'s
        borrow, letting the compiler ASAP-drop `rb` (running the Slab
        `__deinit__` -> `destroy_pointee` on each Column -> dropping the
        Column._data Arc -> freeing the data bytes) BEFORE the derived
        pointer was read. An allocator that reuses a freed small buffer
        immediately then surfaces garbage (e.g. a freelist pointer read
        back as an F64), while larger buffers in a slower-reused size
        class survive to the read — so the defect depends on result size.

        Origin `o` is inferred from the receiver borrow `ref [o] self`,
        binding the returned pointer's lifetime to `self`; the compiler
        tracks every deref site against `self`'s liveness. Callers that
        immediately chain `+ i` / `.bitcast[...]()` / `[]` are unaffected
        (those ops preserve the origin). Callers that need a TRULY
        lifetime-severed pointer for a parallelize-closure capture must use
        the explicitly-wildcard `_unsafe_as_pointer` instead.

        SAFETY: pointer valid for the duration of `self`'s borrow `o`. Do
        NOT store past the next mutation (append/resize may reallocate and
        invalidate). The MutExternalOrigin internal cast in `_wild_ptr` is
        re-tied to `o` here so the returned origin is `self`-bound.
        """
        return self._wild_ptr().unsafe_mut_cast[_mut]().unsafe_origin_cast[
            o
        ]()


    @staticmethod
    def from_raw_parts[
        _T: Movable & Deinitable
    ](
        # SAFETY (container-reconstruct primitive): this is the Slab's own
        # intentional unsafe constructor — the stdlib `from_raw_parts`
        # pattern. The raw pointer in the signature is the buffer the Slab
        # ADOPTS ownership of (it `uninit_move_n`s the initialized prefix
        # into its byte buffer and `free`s the source). The pointer is
        # encapsulated BY the Slab here, not leaked outward. See the
        # docstring below.
        data: UnsafePointer[_T, MutUntrackedOrigin],
        size: Int,
        capacity: Int,
    ) -> Slab[_T]:
        """Adopt a raw buffer into a typed Slab.

        Parallel combine helpers build an output buffer via raw
        `alloc[T](n)` for parallelize worker-slot mutation and return the
        base pointer; this adopts it into a Slab.

        Movable-gated via an explicit `_T` parameter (no default —
        Mojo 0.26.3 cannot bind _T defaults against stricter trait
        bounds). Callers typically write `Slab.from_raw_parts[MyT](...)`.

        SAFETY: caller transfers ownership of `data`. `data` must point
        to a heap-allocated buffer of at least `capacity` T slots with
        slots [0, size) holding initialized T values.
        """
        var slab = Slab[_T](capacity)
        if size > 0:
            # SAFETY: move `size` initialized Ts from the source buffer
            # into the new slab's byte buffer. Both buffers have room
            # for `capacity` slots; the destination starts uninitialized.
            # b2: `uninit_move_n` requires a `Movable` pointee. `_wild_ptr()`
            # returns `UnsafePointer[_T, ...]` carrying only the struct's
            # weaker `Deinitable` bound; bitcast to the enclosing
            # method's `_T` (`Movable & Deinitable`) re-establishes
            # the Movable pointee trait `uninit_move_n` needs.
            unsafe_uninit_move_n[overlapping=False](
                dest=slab._wild_ptr().bitcast[_T](),
                src=data,
                count=size,
            )
            slab._len_t = size
        if capacity > 0:
            data.free()
        return slab^

    @staticmethod
    def from_slab(var slab: Slab[Self.T]) -> Slab[Self.T]:
        """Move-through passthrough: returns `slab` unchanged.
        """
        return slab^

    def steal_slab(mut self) -> Self:
        """Steal self's buffer into a new Slab and
        replace self with an empty one.
        """
        var tmp = Slab[Self.T]()
        # SWAP self <-> tmp: move self's contents out, leave self empty.
        tmp._bytes = self._bytes^
        tmp._len_t = self._len_t
        tmp._cap_t = self._cap_t
        self._bytes = List[UInt8]()
        self._len_t = 0
        self._cap_t = 0
        return tmp^

    # =========================================================================
    # Internal: byte-level buffer management (universal -- not Movable-gated)
    # =========================================================================

    def _reserve_t(mut self, new_cap_t: Int):
        """Grow the byte buffer to hold at least `new_cap_t` T slots.

        Preserves T-level invariants by relying on List[UInt8]'s realloc
        to bitwise-move the existing bytes. For most Movable T this is
        equivalent to a move (Mojo moves are bitwise-copy + source-invalidate;
        destructors do not fire on moved-from values). For non-Movable T
        callers use `create(n)` once (fixed-size) and don't grow, so this
        path is not hit.

        Args:
            new_cap_t: New T-slot capacity. Must be >= current capacity.
        """
        if new_cap_t <= self._cap_t:
            return
        var new_byte_len = new_cap_t * size_of[Self.T]()
        # List[UInt8].resize(unsafe_uninit_length=) grows the backing
        # allocation without initializing new bytes. For bitpatterns of
        # pre-existing T values in [0, _len_t), List's internal realloc
        # memcpy preserves them. For [_len_t, new_cap_t) the bytes are
        # uninitialized, which matches our contract.
        self._bytes.resize(unsafe_uninit_length=new_byte_len)
        self._cap_t = new_cap_t
