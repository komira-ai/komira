# =============================================================================
# komira_log_query/search_seam.mojo — the NON-GENERIC seam a service dispatcher
#   can hold as ONE plain field to read its own operational log.
# =============================================================================
#
# ── WHY ERASE RATHER THAN PARAMETERISE THE DISPATCHER ────────────────────────
# The shipped conformer (`komira_log_index.split_log_search.SplitIndexLogSearch`)
# is generic over `Storage: CloneableConditionalWriteStore`, and the concrete
# Storage (an object-store client over its transport) is bound at the BINARY.
# Threading that parameter into a service dispatcher that is already generic
# over other parameters, and is instantiated by many tests, would monomorphize
# the object-store transport into every one of them.
#
# The facade is non-generic, so a dispatcher holds ONE plain field and `Storage`
# instantiates ONLY at `erase[S]` time.
#
# ⭐ AND IT BUYS A SECOND THING: this package stays a CLEAN LEAF on `komira_http`.
# A dispatcher that links `komira_http` and must not link `komira_search`,
# `komira_search_s3` or `komira_log_index` can depend on THIS package without
# widening its closure.
#
# ── ⛔ WHAT THIS SEAM DELIBERATELY CANNOT EXPRESS ────────────────────────────
# There is NO tenant parameter, and adding one would be a mistake rather than a
# feature. The records behind this seam are the service's OWN diagnostics, and
# they cannot be filed per-tenant: a service-level record carries no `org_id`
# and no `run_id`, so it cannot be filed into a tenant's readable keyspace
# without inventing an attribution — which would be a tenancy leak, not a
# logging upgrade. A `search(org_id, ...)` overload here would be exactly that
# invented attribution. A customer-visible, genuinely run-scoped stream belongs
# in a DIFFERENT, tenant-scoped sink behind a DIFFERENT, tenant-gated route.
#
# Encapsulation: the PUBLIC surface takes/returns only value types (`String`,
# `Int`, `ServiceLogPage`) + owned `Self`. ZERO UnsafePointer crosses a public
# signature; the `OwnedPointer[UInt8]` home is a private CONCRETE-origin field;
# the fn-ptrs are FFI-POD fields (code pointers, no heap; the untracked origin
# lives only in the alias signature and the cast-site bodies); NO
# `unsafe_from_address`; NO wildcard-origin FIELD.
#
# A dispatcher value built once at boot and dropped at teardown — not a
# byte-slab element, not a destroy-recreate pool field.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_log_query.hit import ServiceLogPage, ServiceLogQuery


# =============================================================================
# §1 — ServiceLogSearch — the trait every conformer answers.
# =============================================================================
trait ServiceLogSearch(Movable, Deinitable):
    """A readable index of THIS service's own operational log records.

    `Movable, Deinitable` are supertraits because `erase[S]` heap-boxes a
    conformer (`init_pointee_move`) and the drop trampoline reconstructs one
    `OwnedPointer[S]` to destroy it.

    ⭐ THE ARGUMENT IS A `ServiceLogQuery`, WHOSE FIRST TWO FIELDS ARE A TIME
    WINDOW. The base at-rest artifact is time-partitioned Parquet and the text
    index is an optional sidecar, so the primary bound on a log read is a TIME
    RANGE and the term is optional. `hit.mojo`'s `ServiceLogQuery` docstring
    carries the full reasoning, including why a term-only `search(query, limit)`
    shape would encode a property of the SPLIT FORMAT into the seam every reader
    has to satisfy.

    ⛔ `term` IS A REQUEST-DERIVED STRING, AND THAT IS DELIBERATE. A seam that
    DIALS must take no request byte at all; this one READS, so the input is a
    search term and the only thing it can reach is an analyzer. There is no URL,
    no host and no outbound socket anywhere below this line, so the SSRF class
    does not arise here. ⚠ A conformer that acquired an outbound dial would
    break that, and the fix would be to remove the dial, not to validate the
    term.

    ⚠ A CONFORMER THAT CANNOT ANSWER A TERM-FREE WINDOW MUST RAISE, AND THE
    MESSAGE IS PART OF ITS CONTRACT — the route renders it to the operator as a
    400, so it must name the FORMAT limitation and what to supply instead.
    Returning an empty page would say "nothing was logged in that window", which
    is a different and false answer.

    `q.limit` BOUNDS THE PAGE AND MUST BE HONOURED. The route clamps it before it
    arrives (`SERVICE_LOG_MAX_LIMIT`), but a conformer that ignored it would let
    one query materialise an entire log index in memory on a service instance
    sized for HTTP.

    `raises` because a store fault is REAL information: an operator whose read
    fails against the bucket needs the fault, not an empty page that reads as
    "nothing was logged". The route turns a raise into a 500 that names it — see
    `route.mojo`.

    Returns a `ServiceLogPage` whose `hits` are NEWEST-FIRST; the ordering is the
    seam's contract, not the conformer's choice (`hit.mojo`)."""

    def scan(mut self, q: ServiceLogQuery) raises -> ServiceLogPage:
        ...


# =============================================================================
# §2 — the FFI-POD thin fn-ptr TYPE aliases (the manual vtable).
#
# `search` takes the type-erased home byte ptr (an untracked origin — the
# type-erasure handle, confined to the alias signature) plus the value-typed
# query, and returns the value-typed page. The drop arm cannot
# raise.
# =============================================================================
comptime _SearchLogFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],  # the erased S home
    ServiceLogQuery,  # the window + optional term + limit
) raises thin -> ServiceLogPage

comptime _DropLogSearchFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],  # the erased S home (consumed)
) thin -> None


# =============================================================================
# §3 — ErasedServiceLogSearch — the non-generic runtime facade.
# =============================================================================
struct ErasedServiceLogSearch(ServiceLogSearch, Movable, Deinitable):
    """A RUNTIME-erased `ServiceLogSearch`: owns ONE concrete
    `S: ServiceLogSearch` behind a type-erased heap home + a manual fn-ptr
    vtable, exposing only `scan(q)`. Construct via
    `ErasedServiceLogSearch.erase[S](conformer^)`.

    ITSELF conforms `ServiceLogSearch`, so anything written against the trait
    accepts the erased facade directly."""

    # `_home` owns the raw bytes of the concrete S (an `alloc[S](1) +
    # init_pointee_move(source) + bitcast[UInt8]()` home). CONCRETE origin,
    # ASAP-tracked. The single private pointer field — no wildcard origin.
    var _home: OwnedPointer[UInt8]

    # FFI-POD thin fn-ptr fields (code pointers, no heap; the untracked origin
    # lives only in the alias signature, the type-erasure handle).
    var _search_fn: _SearchLogFn
    var _drop_fn: _DropLogSearchFn

    def __init__(
        out self,
        var home: OwnedPointer[UInt8],
        search_fn: _SearchLogFn,
        drop_fn: _DropLogSearchFn,
    ):
        self._home = home^
        self._search_fn = search_fn
        self._drop_fn = drop_fn

    @staticmethod
    def erase[
        S: ServiceLogSearch
    ](var source: S) -> ErasedServiceLogSearch:
        """Erase a concrete `S` into an `ErasedServiceLogSearch`. Heap-boxes
        `source` and binds the TOP-LEVEL parametric trampolines (NOT nested
        closures — nested closures over a comptime param do not lower as stable
        fn-ptrs). This is the ONE site where `S` — and, for the shipped
        conformer, its object-store transport — is instantiated for a consumer.

        SAFETY: `alloc[S](1) + init_pointee_move(source)` moves `source` onto a
        fresh heap slot; `OwnedPointer(unsafe_from_raw_pointer=...)` takes single
        ownership of the byte-cast slot (concrete origin, ASAP-tracked). Both
        trampolines are bound for the SAME `S`, so the in-body reinterpret of the
        home ptr is type-correct by construction. The wildcard origin is confined
        to this cast-site + the trampoline bodies — never a struct field."""
        var home_typed = alloc[S](1)
        # SAFETY: fresh allocation we own; in-place move-construct source into it.
        UnsafePointer(to=home_typed[]).unsafe_write(source^)
        var home = OwnedPointer[UInt8](
            unsafe_from_raw_pointer=home_typed.bitcast[UInt8]()
        )
        var search_t: _SearchLogFn = _erased_search_log_for[S]
        var drop_t: _DropLogSearchFn = _erased_drop_log_search_for[S]
        return ErasedServiceLogSearch(home^, search_t, drop_t)

    def scan(mut self, q: ServiceLogQuery) raises -> ServiceLogPage:
        """Read the log index through the erased conformer.

        SAFETY: `_home` owns S's heap home for this facade's lifetime; we form a
        `MutUntrackedOrigin` byte ptr to it (the type-erasure handle the trampoline
        expects) and invoke `_search_fn`, which reinterprets the byte ptr back to
        the SAME S bound at `erase[S]` time and drives it in-place (not
        moved/freed). The wildcard origin is confined to this cast-site body."""
        var p = self._home.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
        return self._search_fn(p, q)

    def __deinit__(deinit self):
        """Destroy the erased S AND free its home in ONE shot via `_drop_fn`. We
        RELINQUISH `_home`'s own free first (`unsafe_leak()`) so the single owner of
        the bytes for teardown is the `OwnedPointer[S]` the drop trampoline
        reconstructs.

        SAFETY: `unsafe_leak()` relinquishes the home's free so it does NOT also
        free the buffer; the bytes go to `_drop_fn`, which reconstructs one
        `OwnedPointer[S]` over the SAME allocation and runs destroy+free in one
        shot. Runs exactly once per facade."""
        var raw = self._home^.unsafe_take_allocation().unsafe_leak().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        self._drop_fn(raw)


# =============================================================================
# §4 — the TOP-LEVEL parametric trampolines (bound ONCE per concrete S at
#      `erase[S]`). NOT nested closures — top-level so they lower as stable thin
#      fn-ptrs.
# =============================================================================
def _erased_search_log_for[
    S: ServiceLogSearch
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], q: ServiceLogQuery
) raises -> ServiceLogPage:
    """`scan` trampoline for concrete `S`. SAFETY: `home` is the byte-cast of a
    live `OwnedPointer[S]` home (same S bound here at `erase[S]`); reinterpret to
    `S*` and call in-place (S is NOT moved/freed — the facade owns it). `q` is a
    borrowed value type; the returned page is an owned value."""
    var sp = home.bitcast[S]()
    return sp[].scan(q)


def _erased_drop_log_search_for[
    S: ServiceLogSearch
](home: UnsafePointer[UInt8, MutUntrackedOrigin]):
    """The drop trampoline for concrete `S`: reconstruct ONE `OwnedPointer[S]`
    over the home bytes and let it run `S.__deinit__` + free the allocation in a
    single tracked consume. SAFETY: `home` is the byte-cast of the S-home
    allocation whose free was relinquished by the facade's `__deinit__`
    (`unsafe_leak()`); we reconstruct the single owner over the SAME bytes so
    destroy+free happens exactly once."""
    var owned = OwnedPointer[S](unsafe_from_raw_pointer=home.bitcast[S]())
    var s = owned^.into_inner()
    _ = s^
