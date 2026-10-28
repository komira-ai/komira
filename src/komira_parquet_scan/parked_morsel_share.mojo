# =============================================================================
# parked_morsel_share — a decoded row group's parked sub-morsels, claimable by
# idle workers
# =============================================================================
#
# The source splits each decoded row group into `morsel_rows` sub-morsels,
# returns the first and parks the rest on the owner's pending slab, which only
# the owner consumes. When a scan has fewer row groups than workers (a
# selective footer prune), the owners consume their parked morsels serially
# while the other workers sit idle.
#
# With sharing on, after a claim returns the source MOVES what it parked into
# one shared pool (`publish`); every `next_morsel` takes from the pool before
# claiming, and a worker whose claim finds the cursor exhausted waits for the
# claims in flight instead of leaving (`wait_take`).
#
# It changes WHICH worker consumes a sub-morsel, never the set of rows nor how
# many times a row is consumed. That is value-identical only for a consumer
# whose per-worker state is insensitive to assignment and order (a grouped
# hash aggregate merges every group at combine), so the consumer opts in;
# every other caller keeps the owner-only pending slab.
#
# Exactly once: (1) a morsel is in one place at a time (the owner's slab, the
# pool, or one consumer's hands): `publish` moves out of the slab under the
# pool lock and `try_take` pops under it. (2) None is orphaned: a worker
# returns None only from `wait_take`, after it saw `inflight == 0` and then an
# empty pool. Every claim `enter()`s before its cursor `fetch_add` and
# `leave()`s only after it published, so a worker whose own `fetch_add` came
# back exhausted sees `inflight >= 1` until the last producer published.
# (3) `leave()` also runs when a claim raises.
#
# The wait cannot deadlock: a waiter waits only on claims that have entered,
# that is tasks already running on a thread, and a producer waits on nothing.
# =============================================================================

from std.memory import UnsafePointer

from komira_async.runtime.wake_primitives import cpu_pause, pause_intrinsic
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel


# `pause` spins between two yields in `wait_take`. The wait is bounded by one
# row group's decode; the periodic yield keeps a waiter from starving a
# producer that shares its core.
comptime PARKED_SHARE_SPINS_PER_YIELD: Int = 64


def parked_share_admitted(
    consumer_opt_in: Bool,
    morsel_rows: Int,
    claim_count: Int,
    num_workers: Int,
    alternate_decode_route: Bool,
    decode_arena: Bool,
    fused_agg_payload: Bool,
    ragged_tail: Bool = False,
) -> Bool:
    """Whether a scan shares its parked sub-morsels. True only when:
      * the consumer opted in (it is insensitive to assignment);
      * sub-morsels exist (`morsel_rows > 0`) and there are two workers or
        more;
      * there are fewer claimable row groups than workers, so a worker is idle
        from the first claim (or `ragged_tail`: share in the last round too,
        when the row groups do not divide evenly);
      * the whole-row-group decode is the route (the sub-row-group split and
        the cursor grain, `alternate_decode_route`, own their emit);
      * no per-worker decode arena (it reuses the owner's buffers for its next
        row group, which a parked morsel's columns may alias);
      * not the fused hash-aggregate payload (it emits no batch).
    """
    if not consumer_opt_in:
        return False
    if morsel_rows <= 0:
        return False
    if alternate_decode_route or decode_arena or fused_agg_payload:
        return False
    if num_workers <= 1:
        return False
    if ragged_tail:
        return claim_count > 0
    return claim_count > 0 and claim_count < num_workers


struct _ShareCtl:
    """The pool's atomics; lives once inside a one-slot `Slab`.

    Fields:
        lock: 0 free, 1 held; guards both pool stacks.
        inflight: claims entered and not yet left.
        parked: morsels in the pool (updated under `lock`, read without it as
            the fast emptiness test: a stale read costs a lock round trip or a
            spin, never a morsel).
        published: morsels published so far.
        foreign: pool morsels taken by a worker other than their publisher.
    """

    var lock: AtomicI64
    var inflight: AtomicI64
    var parked: AtomicI64
    var published: AtomicI64
    var foreign: AtomicI64


struct ParkedMorselShare(Movable):
    """The shared pool of parked sub-morsels. Every method takes `self`
    immutably and mutates through `Slab.get_mut_interior`, as the source's
    `next_morsel(self, worker_id)` requires. Built disabled it allocates its
    control slot and nothing is reached."""

    var _on: Bool
    var _ctl: Slab[_ShareCtl]
    # Two parallel stacks: the morsel and the worker that published it.
    var _pool_m: Slab[Slab[Morsel]]
    var _pool_o: Slab[List[Int]]

    def __init__(out self, on: Bool):
        self._on = on
        self._ctl = Slab[_ShareCtl].create_prefilled(1)
        # SAFETY: slot 0 was zero-filled by `create_prefilled`, and no worker
        # exists yet; the pointer is to the whole slot and stays in this
        # function.
        var cptr = UnsafePointer(to=self._ctl.get_mut_interior(0))
        cptr[].lock = AtomicI64(0)
        cptr[].inflight = AtomicI64(0)
        cptr[].parked = AtomicI64(0)
        cptr[].published = AtomicI64(0)
        cptr[].foreign = AtomicI64(0)
        var pm = Slab[Slab[Morsel]].create(1)
        pm.append(Slab[Morsel]())
        self._pool_m = pm^
        var po = Slab[List[Int]].create(1)
        po.append(List[Int]())
        self._pool_o = po^

    @always_inline
    def enabled(self) -> Bool:
        """Whether sharing is on."""
        return self._on

    @always_inline
    def enter(self):
        """A claim starts. Must precede the claim cursor's `fetch_add`."""
        _ = self._ctl.get_mut_interior(0).inflight.fetch_add(Int64(1))

    @always_inline
    def leave(self):
        """A claim finished, after its parked morsels were published (and on
        the raise path too)."""
        _ = self._ctl.get_mut_interior(0).inflight.fetch_add(Int64(-1))

    @always_inline
    def _lock(self):
        ref c = self._ctl.get_mut_interior(0)
        while True:
            var expected = Int64(0)
            if c.lock.compare_exchange(expected, Int64(1)):
                return
            pause_intrinsic()

    @always_inline
    def _unlock(self):
        ref c = self._ctl.get_mut_interior(0)
        var expected = Int64(1)
        _ = c.lock.compare_exchange(expected, Int64(0))

    def publish(self, mut parked: Slab[Morsel], owner: Int):
        """Move every morsel of `parked` (one worker's pending slab) into the
        pool; `parked` is empty on return. `owner` is the publishing worker."""
        if len(parked) == 0:
            return
        self._lock()
        ref pm = self._pool_m.get_mut_interior(0)
        ref po = self._pool_o.get_mut_interior(0)
        var moved = 0
        while len(parked) > 0:
            var m = parked.pop()
            if m:
                pm.append(m.take())
                po.append(owner)
                moved += 1
        ref c = self._ctl.get_mut_interior(0)
        _ = c.parked.fetch_add(Int64(moved))
        _ = c.published.fetch_add(Int64(moved))
        self._unlock()

    def try_take(self, worker_id: Int) -> Optional[Morsel]:
        """One parked morsel, which no other worker will receive, or None
        when the pool is empty."""
        ref c = self._ctl.get_mut_interior(0)
        if c.parked.load() <= 0:
            return None
        self._lock()
        ref pm = self._pool_m.get_mut_interior(0)
        ref po = self._pool_o.get_mut_interior(0)
        var got = pm.pop()
        var owner = -1
        if got:
            owner = po.pop()
            _ = c.parked.fetch_add(Int64(-1))
        self._unlock()
        if got and owner != worker_id:
            _ = c.foreign.fetch_add(Int64(1))
        return got^

    def wait_take(self, worker_id: Int) -> Optional[Morsel]:
        """The claim cursor is exhausted for `worker_id`: a parked morsel,
        waiting while any claim is in flight. None only when no claim is in
        flight and the pool is empty (end of stream)."""
        ref c = self._ctl.get_mut_interior(0)
        var spins = 0
        while True:
            var got = self.try_take(worker_id)
            if got:
                return got^
            if c.inflight.load() <= 0:
                # A producer publishes before its `leave()`, which happened
                # before this load: one last look.
                return self.try_take(worker_id)
            spins += 1
            if spins >= PARKED_SHARE_SPINS_PER_YIELD:
                spins = 0
                cpu_pause()
            else:
                pause_intrinsic()

    def published_count(self) -> Int:
        """Morsels published into the pool so far."""
        return Int(self._ctl.get_mut_interior(0).published.load())

    def foreign_count(self) -> Int:
        """Pool morsels taken by a worker other than their publisher."""
        return Int(self._ctl.get_mut_interior(0).foreign.load())
