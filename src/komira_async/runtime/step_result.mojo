# =============================================================================
# komira_async.runtime.step_result — StepResult[T] discriminated value type
# =============================================================================
# ratification:
# this type is the ONLY sanctioned shape for signaling park / done / error /
# yielded from Pattern 2 operator step functions. `raises` for control-flow
# signaling is BANNED — the heap-alloc per Error string (~10 µs) dominates
# the spin-budget hot path that fires per-morsel-IO.
#
# Users: the `try_io` substrate primitive and the prefetch ring (the
# bulk-parallel pattern; the `parked_any(op_ids)` multi-op constructor is
# the headline shape it uses).
#
# Hot-path cost model:
#   * yielded() / parked()/parked_any(op_id) / done(): stack-allocate the
#     struct, write one byte tag + the variant payload. Zero heap allocations
#     for the single-op case (a 1-element List[Int64] stays in SSO-style
#     inline storage on Mojo 0.26.3's stdlib List, but even with a heap
#     alloc the cost is ~50ns + 16-byte buffer — far below the 10 µs heap
#     Error cost).
#   * parked_any(op_ids: List[Int64]): the caller supplies the List and
#     transfers ownership (`var op_ids`), so we move the List in. Zero
#     additional allocation — same allocation the caller already made.
#   * error(): one String construction; small-string-optimized inline if
#     the error text is <24 bytes. The error path is the cold path anyway
#     — even a heap String alloc here is acceptable since errors abort the
#     morsel.
#
# Compare to `raises Error("...")`: ~10 µs for the heap alloc + format +
# propagation walk. StepResult is 4-5 orders of magnitude cheaper on the
# hot path.
#
# multi-op `parked_any` extension (this file):
#   * Storage: `_op_ids: List[Int64]` (was `_op_id: Int64`). Single-op
#     forms wrap the value into a 1-element list at construction time;
#     multi-op forms move the caller's list in.
#   * `parked(op_id)` is preserved as a sugar overload (back-compat with
#     `LocalIoBlock.try_io_handle` and existing tests).
#   * `parked_any(op_id)` and `parked_any(op_ids)` are the new canonical
#     constructors.
#   * `op_id()` accessor returns the FIRST op_id in `_op_ids` (or 0 if
#     empty / non-PARKED) — preserves single-op call-site shape.
#   * `op_ids()` accessor returns the full List (Movable transfer for
#     callers that need the full set, e.g. parked-morsel slab indexing).
#
# Pointer discipline:
#   * ZERO `UnsafePointer` in any public method signature.
#   * ZERO new wildcard origins.
#   * ZERO new `unsafe_from_address=Int(...)` sites.
#   * Optional[T] + String + List[Int64] fields are stack/SSO; no manual
#     heap pointers.
# =============================================================================


# Discriminator constants — UInt8 sentinels. Same shape as IoOp's
# OP_PENDING/OP_READY/OP_ERR. Mojo 0.26.3 has no UInt-payloaded enum syntax;
# this is the canonical pattern.
comptime STEP_YIELDED: UInt8 = 0  # carries an Output value
comptime STEP_PARKED: UInt8 = 1  # carries one or more op_ids awaiting Completions
comptime STEP_DONE: UInt8 = 2  # operator finished, no more output
comptime STEP_ERR: UInt8 = 3  # carries a String error (no heap-Error)


@fieldwise_init
struct StepResult[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
](Copyable, Movable, Deinitable):
    """Discriminated value — replaces `raises Parked`.

    Field set:
      var _kind: UInt8                # STEP_* sentinel
      var _value: Optional[Self.T]    # populated when STEP_YIELDED
      var _op_ids: List[Int64]        # populated when STEP_PARKED
      var _err: String                # populated when STEP_ERR ("" sentinel)

    NOT `@register_passable("trivial")`: the Optional[T] + String + List
    fields have heap-tracking; trivial register-pass requires PODs only.
    The struct IS Movable + Copyable for ergonomic propagation through the
    worker trampoline (each step returns by value; the worker matches on
    _kind).

    `T: ImplicitlyCopyable` bound matches IoOp's contract (no partial move
    through a pointer). The `morsel()` accessor returns
    `Optional[T]` by COPY (no partial-move via take_pointee).

    Multi-op shape:
      * The PARKED variant carries `List[Int64]` of op_ids. Single-op
        `parked(op_id)` is a sugar wrapper that stores a 1-element list;
        multi-op `parked_any(op_ids)` moves the caller's list in. The
        worker-loop treats both uniformly: it scans the list and indexes
        the morsel into the parked-morsel slab keyed by ALL ids; the
        first completion that matches any id wakes the morsel.
      * `parked` (single-op) is preserved as a back-compat constructor.
      * `op_id()` returns the FIRST id in the list (or 0 if empty);
        `op_ids()` returns the full list (Movable transfer).
    """

    var _kind: UInt8
    var _value: Optional[Self.T]
    var _op_ids: List[Int64]
    var _err: String

    # ---- Constructors ----

    @staticmethod
    def yielded(value: Self.T) -> StepResult[Self.T]:
        """Operator emits a morsel; worker pulls next. Hot path: ~3-5 cycles
        + the Optional wrap. Zero heap allocations."""
        var sr = StepResult[Self.T](
            _kind=STEP_YIELDED,
            _value=Optional[Self.T](value),
            _op_ids=List[Int64](),
            _err=String(""),
        )
        return sr^

    @staticmethod
    def parked(op_id: Int64) -> StepResult[Self.T]:
        """Sugar overload: park on a single op_id. Equivalent to
        `parked_any(op_id)`; preserved as the existing single-op shape used
        by `LocalIoBlock.try_io_handle` and existing tests.

        Hot path: zero heap allocations beyond the single 1-element List
        construction (which is itself a small inline buffer on Mojo 0.26.3
        stdlib List for very small N)."""
        var ids = List[Int64](capacity=1)
        ids.append(op_id)
        var sr = StepResult[Self.T](
            _kind=STEP_PARKED,
            _value=Optional[Self.T](),
            _op_ids=ids^,
            _err=String(""),
        )
        return sr^

    @staticmethod
    def parked_any(op_id: Int64) -> StepResult[Self.T]:
        """Park on a single op_id — the depth=1 specialization of the
        bulk-parallel pattern. Functionally
        identical to `parked(op_id)`; this name is the canonical
        operator-author-facing surface, while `parked` is preserved for
        backward compatibility with the substrate primitives that
        predate the unification (LocalIoBlock.try_io_handle)."""
        var ids = List[Int64](capacity=1)
        ids.append(op_id)
        var sr = StepResult[Self.T](
            _kind=STEP_PARKED,
            _value=Optional[Self.T](),
            _op_ids=ids^,
            _err=String(""),
        )
        return sr^

    @staticmethod
    def parked_any(var op_ids: List[Int64]) -> StepResult[Self.T]:
        """Park on any-of N op_ids (the depth>=1 bulk-parallel form).
        The worker resumes the morsel on the FIRST completion
        that matches any id in the set.

        `op_ids` is moved in (`var op_ids`). The empty-list case is
        accepted (callers can pass a fresh empty list to indicate "no
        in-flight ops"; the worker treats this as a parked morsel with
        no wake source — typically a programming error, but we don't
        crash on it). Hot path: zero additional heap allocation; the
        caller's allocation transfers ownership."""
        var sr = StepResult[Self.T](
            _kind=STEP_PARKED,
            _value=Optional[Self.T](),
            _op_ids=op_ids^,
            _err=String(""),
        )
        return sr^

    @staticmethod
    def done() -> StepResult[Self.T]:
        """Operator finished; no more morsels. Worker drops the operator
        and any associated state. Hot path: zero heap allocations."""
        var sr = StepResult[Self.T](
            _kind=STEP_DONE,
            _value=Optional[Self.T](),
            _op_ids=List[Int64](),
            _err=String(""),
        )
        return sr^

    @staticmethod
    def error(err: String) -> StepResult[Self.T]:
        """Unrecoverable error during the step (cancellation, IO submit
        failure). The worker trampoline propagates this (e.g., aborts the
        query). Cold path; small-string-optimized for typical errors."""
        var sr = StepResult[Self.T](
            _kind=STEP_ERR,
            _value=Optional[Self.T](),
            _op_ids=List[Int64](),
            _err=err,
        )
        return sr^

    # ---- Variant predicates ----

    @always_inline
    def is_yielded(self) -> Bool:
        """True when the step emitted a morsel; use morsel() to read."""
        return self._kind == STEP_YIELDED

    @always_inline
    def is_parked(self) -> Bool:
        """True when try_io's spin budget elapsed; use op_id() (single-op)
        or op_ids() (multi-op) to key the worker's parked-morsel slab."""
        return self._kind == STEP_PARKED

    @always_inline
    def is_done(self) -> Bool:
        """True when the operator is finished (no more morsels)."""
        return self._kind == STEP_DONE

    @always_inline
    def is_error(self) -> Bool:
        """True when the step encountered an unrecoverable error; use
        err() to read the error text."""
        return self._kind == STEP_ERR

    @always_inline
    def kind(self) -> UInt8:
        """Raw discriminator — useful for debug / structured logging.
        Returns one of STEP_YIELDED / STEP_PARKED / STEP_DONE / STEP_ERR."""
        return self._kind

    # ---- Variant accessors (safe — return Optional / sentinel) ----

    def morsel(self) -> Optional[Self.T]:
        """Returns Some(value) when STEP_YIELDED; None otherwise. Returns
        the value by COPY (the T: ImplicitlyCopyable bound is
        load-bearing). Use `value().value()`
        on the result; we keep the Optional outer to make non-yielded
        access a no-op rather than a crash."""
        if self._kind == STEP_YIELDED:
            return self._value
        return Optional[Self.T]()

    @always_inline
    def op_id(self) -> Int64:
        """Returns the FIRST parked op_id when STEP_PARKED; 0 otherwise.
        Op_id 0 is the reactor's never-allocated sentinel; safe distinguisher
        against any real allocated op_id (which start at 1 per
        Reactor.alloc_op_id's `fetch_add(1) + 1` shape).

        Single-op call-site shape — preserved for `LocalIoBlock.try_io_handle`
        and for tests that were written against the depth=1 pre-unification
        surface. For the multi-op case, prefer `op_ids()` to retrieve the
        full set."""
        if self._kind == STEP_PARKED and len(self._op_ids) > 0:
            return self._op_ids[0]
        return Int64(0)

    def op_ids(self) -> List[Int64]:
        """Returns a COPY of the parked op_ids list when STEP_PARKED; an
        empty list otherwise. Use `op_ids_len()` for a cheap len-query
        without the copy.

        Returns by COPY (Int64 is trivially Copyable so List[Int64].copy()
        is a single buffer memcpy). The worker-loop trampoline can call
        this to walk the wait-set when keying its parked-morsel slab.

        Mojo 0.26.3 cannot synthesize a partial-move-out-of-`var self`
        for a single field while the rest of the struct still drops
        normally (the pointer rules / partial-move-via-UnsafePointer ban),
        so the multi-op accessor copies. Int64 List copy on N<=64
        elements is single-digit-microseconds and dominated by the
        StepResult drop itself."""
        if self._kind == STEP_PARKED:
            return List[Int64](self._op_ids)
        return List[Int64]()

    @always_inline
    def op_ids_len(self) -> Int:
        """Returns the number of parked op_ids when STEP_PARKED; 0
        otherwise. Cheap — no list copy. Useful for the worker loop's
        decision: depth=1 vs depth=N parked-morsel slab indexing."""
        if self._kind == STEP_PARKED:
            return len(self._op_ids)
        return 0

    def err(self) -> Optional[String]:
        """Returns Some(error_text) when STEP_ERR; None otherwise. Returns
        a copy of the String — small-string-optimized for typical errors
        so this is usually a stack-only operation."""
        if self._kind == STEP_ERR:
            return Optional[String](self._err)
        return Optional[String]()

    def err_text(self) -> String:
        """Convenience accessor: returns the error text directly (or "" if
        not in STEP_ERR state). For caller code that already knows the
        variant via is_error()."""
        return self._err
