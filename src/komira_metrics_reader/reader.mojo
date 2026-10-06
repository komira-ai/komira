# =============================================================================
# komira_metrics_reader/reader.mojo: the MetricsReader trait, the non-generic
#   facade a service holds as one field, and a scripted double.
# =============================================================================
#
# ── TWO METHODS: A REFUSAL, THEN THE READ ───────────────────────────────────
# A reader may be unable to answer a query for a reason that is the CALLER's
# to fix: CloudWatch cannot group series by a label in one statistic call, a
# store that keeps no histograms cannot compute a quantile, a provider's
# smallest step is a minute. `refusal(q)` says so before anything is read, in
# a sentence the route returns as a 400. `read(q)` raises only for a fault:
# the provider or the store failed, which the route returns as a 500 naming
# it. Keeping the two apart is what lets the route classify a failure by what
# happened rather than by matching the text of an error.
#
# ── WHY ERASE ───────────────────────────────────────────────────────────────
# A reader is generic over its transport (a connector, a credential source, a
# clock), bound in the binary. The facade is non-generic, so a router holds
# one plain field and the transport instantiates only at `erase[R]`. This
# package stays a leaf on komira_http_core: service code that mounts the route
# need not link a cloud SDK.
#
# ── NO CALLER ARGUMENT ──────────────────────────────────────────────────────
# A reader answers from everything it is configured to read. Who may read is
# decided before the read by the route's `MetricsReadAccess` hook; a service
# with several audiences wires a reader and a route per audience.
#
# Encapsulation: the public surface takes and returns value types and owned
# `Self`. The one private pointer field is an `OwnedPointer[UInt8]` home with
# a concrete origin; the fn-pointer fields are code pointers; the untracked
# origin appears only in the alias signatures and the cast sites. A value built
# once and dropped at teardown, never a pool member.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer, UnsafePointer, alloc

from komira_metrics_reader.query import MetricsQuery
from komira_metrics_reader.series import MetricsPage


# =============================================================================
# §1 — MetricsReader.
# =============================================================================
trait MetricsReader(Movable, Deinitable):
    """A readable source of metric series: a cloud metric service, or files a
    service wrote to an object store.

    `refusal(q)` returns "" when the reader can answer `q`, else ONE sentence
    naming what it cannot do and what the caller can change (a step, an
    aggregation, a matcher). It reads nothing and must not raise.

    `read(q)` answers `q`. It is called only with a query `refusal` accepted.
    It must honour `q.series_limit` and `q.point_limit`, set
    `MetricsPage.truncated` when it stops at either or at a page limit of its
    own, keep each series' NEWEST samples when the point limit cuts it, and
    return each series' samples oldest first. It raises for a fault
    (the provider answered an error, the store is unreachable, a response did
    not parse); it never returns an empty page in place of a fault."""

    def refusal(self, q: MetricsQuery) -> String:
        ...

    def read(mut self, q: MetricsQuery) raises -> MetricsPage:
        ...


# =============================================================================
# §2 — the manual vtable.
# =============================================================================
comptime _ReadFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],  # the erased R home
    MetricsQuery,
) raises thin -> MetricsPage

comptime _RefusalFn = def (
    UnsafePointer[UInt8, ImmUntrackedOrigin],  # the erased R home, read only
    MetricsQuery,
) thin -> String

comptime _DropFn = def (
    UnsafePointer[UInt8, MutUntrackedOrigin],  # the erased R home (consumed)
) thin -> None


# =============================================================================
# §3 — ErasedMetricsReader.
# =============================================================================
struct ErasedMetricsReader(MetricsReader, Movable, Deinitable):
    """A runtime-erased `MetricsReader`: owns one concrete `R` behind a
    type-erased heap home and a manual fn-pointer vtable. Build it with
    `ErasedMetricsReader.erase[R](reader^)`. It conforms to `MetricsReader`
    itself."""

    # The bytes of the concrete R (`alloc[R](1)` + move + bitcast). Concrete
    # origin, ASAP-tracked; the only pointer field.
    var _home: OwnedPointer[UInt8]
    var _read_fn: _ReadFn
    var _refusal_fn: _RefusalFn
    var _drop_fn: _DropFn

    def __init__(
        out self,
        var home: OwnedPointer[UInt8],
        read_fn: _ReadFn,
        refusal_fn: _RefusalFn,
        drop_fn: _DropFn,
    ):
        self._home = home^
        self._read_fn = read_fn
        self._refusal_fn = refusal_fn
        self._drop_fn = drop_fn

    @staticmethod
    def erase[R: MetricsReader](var reader: R) -> ErasedMetricsReader:
        """Erase a concrete `R`. The one site where `R`, and its transport, is
        instantiated for a consumer.

        SAFETY: `alloc[R](1)` + an in-place move puts `reader` on a fresh heap
        slot; `OwnedPointer(unsafe_from_raw_pointer=...)` takes single
        ownership of its byte cast. The three trampolines are bound for the
        same `R`, so reinterpreting the home in their bodies is type-correct
        by construction."""
        var home_typed = alloc[R](1)
        # SAFETY: a fresh allocation we own; move-construct `reader` into it.
        UnsafePointer(to=home_typed[]).unsafe_write(reader^)
        var home = OwnedPointer[UInt8](
            unsafe_from_raw_pointer=home_typed.bitcast[UInt8]()
        )
        var read_t: _ReadFn = _erased_read_for[R]
        var refusal_t: _RefusalFn = _erased_refusal_for[R]
        var drop_t: _DropFn = _erased_drop_for[R]
        return ErasedMetricsReader(home^, read_t, refusal_t, drop_t)

    def refusal(self, q: MetricsQuery) -> String:
        """The erased reader's refusal of `q`, or "".

        SAFETY: `_home` owns R's home for this facade's lifetime; the
        trampoline reads it in place for the same R bound at `erase`."""
        var p = self._home.unsafe_ptr().unsafe_origin_cast[ImmUntrackedOrigin]()
        return self._refusal_fn(p, q)

    def read(mut self, q: MetricsQuery) raises -> MetricsPage:
        """Read through the erased reader.

        SAFETY: as `refusal`; the trampoline drives R in place and neither
        moves nor frees it."""
        var p = self._home.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
        return self._read_fn(p, q)

    def __deinit__(deinit self):
        """Destroy the erased R and free its home once, through `_drop_fn`.

        SAFETY: `unsafe_leak()` gives up `_home`'s own free, so the only owner
        at teardown is the `OwnedPointer[R]` the drop trampoline rebuilds over
        the same allocation. Runs exactly once per facade."""
        var raw = self._home^.unsafe_take_allocation().unsafe_leak().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        self._drop_fn(raw)


# =============================================================================
# §4 — the trampolines, top-level so they lower as stable thin fn-pointers.
# =============================================================================
def _erased_read_for[
    R: MetricsReader
](
    home: UnsafePointer[UInt8, MutUntrackedOrigin], q: MetricsQuery
) raises -> MetricsPage:
    """SAFETY: `home` is the byte cast of a live R home bound at `erase[R]`;
    R is used in place, not moved or freed."""
    var rp = home.bitcast[R]()
    return rp[].read(q)


def _erased_refusal_for[
    R: MetricsReader
](home: UnsafePointer[UInt8, ImmUntrackedOrigin], q: MetricsQuery) -> String:
    """SAFETY: as `_erased_read_for`."""
    var rp = home.bitcast[R]()
    return rp[].refusal(q)


def _erased_drop_for[
    R: MetricsReader
](home: UnsafePointer[UInt8, MutUntrackedOrigin]):
    """Rebuild one `OwnedPointer[R]` over the home and let it destroy R and
    free the allocation. SAFETY: the facade's `__deinit__` gave up the home's
    own free, so this is the single owner."""
    var owned = OwnedPointer[R](unsafe_from_raw_pointer=home.bitcast[R]())
    var r = owned^.into_inner()
    _ = r^


# =============================================================================
# §5 — ScriptedMetricsReader, the double.
# =============================================================================
struct _ScriptedState(Movable):
    """The double's interior: what it answers, and every query it saw."""

    var page: MetricsPage
    var refusal_text: String
    var fault: String
    var queries: List[MetricsQuery]
    var refusal_calls: Int

    def __init__(out self):
        self.page = MetricsPage()
        self.refusal_text = String("")
        self.fault = String("")
        self.queries = List[MetricsQuery]()
        self.refusal_calls = 0


struct ScriptedMetricsReader(MetricsReader, Movable, Deinitable):
    """A `MetricsReader` that answers from a script and records every query.

    It lives in the library so the route's tests, a reader's conformance test
    and a service's tests share one double rather than each writing their own.

    `share()` gives a second handle on the same state, so a test can read what
    the double saw after moving it into a route or an erased facade. That is
    the sanctioned `ArcPointer` case: true shared ownership, one thread, a test
    double."""

    var _p: ArcPointer[_ScriptedState]

    def __init__(out self):
        self._p = ArcPointer[_ScriptedState](_ScriptedState())

    def __init__(out self, *, var _share: ArcPointer[_ScriptedState]):
        self._p = _share^

    def share(self) -> ScriptedMetricsReader:
        """A second handle on this double's state."""
        return ScriptedMetricsReader(
            _share=ArcPointer[_ScriptedState](copy=self._p)
        )

    def answer(mut self, var page: MetricsPage):
        """Answer every read with `page`."""
        self._p[].page = page^

    def refuse(mut self, text: String):
        """Refuse every query with `text` ("" accepts again)."""
        self._p[].refusal_text = text.copy()

    def fail(mut self, text: String):
        """Raise `text` from every read ("" answers again)."""
        self._p[].fault = text.copy()

    def refusal(self, q: MetricsQuery) -> String:
        self._p[].refusal_calls += 1
        return self._p[].refusal_text.copy()

    def read(mut self, q: MetricsQuery) raises -> MetricsPage:
        self._p[].queries.append(q.copy())
        if self._p[].fault.byte_length() > 0:
            raise Error(self._p[].fault)
        return self._p[].page.copy()

    def read_count(self) -> Int:
        """How many reads this double served."""
        return len(self._p[].queries)

    def refusal_count(self) -> Int:
        """How many times it was asked for a refusal."""
        return self._p[].refusal_calls

    def last_query(self) raises -> MetricsQuery:
        """The most recent query read. Raises when none was."""
        var n = len(self._p[].queries)
        if n == 0:
            raise Error("ScriptedMetricsReader: no query has been read")
        return self._p[].queries[n - 1].copy()
