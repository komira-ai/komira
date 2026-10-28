# parked_morsel_share under real concurrency: four workers each run claims
# that enter the pool, publish parked sub-morsels, leave, and then drain with
# wait_take until it returns None. Whatever the interleaving, every published
# morsel id must be taken exactly once (none lost to a worker that left too
# early, none handed to two workers), and the pool must hold the published
# count. Asserts counts only; no wait is timed or capped.

from std.memory import OwnedPointer, alloc
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.record_batch import RecordBatch
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.for_each_morsel import MorselBody
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.worker_pool_traits import KeepAlive
from komira_atomic_alias import AtomicI64
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_parquet_scan.parked_morsel_share import ParkedMorselShare

comptime _WORKERS = 4
comptime _CLAIMS = 64
comptime _PER_CLAIM = 5
comptime _ROUNDS = 25


struct _Shared(KeepAlive, Movable, Deinitable):
    """The pool and, per morsel id, how many times it was taken."""

    var pool: ParkedMorselShare
    var taken: OwnedPointer[AtomicI64]

    def __init__(out self):
        self.pool = ParkedMorselShare(True)
        var raw = alloc[AtomicI64](_CLAIMS * _PER_CLAIM)
        for i in range(_CLAIMS * _PER_CLAIM):
            (raw + i)[] = AtomicI64(Int64(0))
        self.taken = OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)

    def count(self, id: Int) -> Int:
        return Int((UnsafePointer(to=self.taken[]) + id)[].load())

    def note(mut self, id: Int):
        var slot = UnsafePointer(to=self.taken[]) + id
        _ = slot[].fetch_add(Int64(1))


@fieldwise_init
struct _ClaimBody(MorselBody, Deinitable):
    var _pad: Int

    def process[
        State: KeepAlive,
        MorselT: Copyable & ImplicitlyCopyable & Movable & Deinitable,
    ](mut self, mut state: State, wid: Int, var morsel: MorselT) raises:
        var sp = UnsafePointer(to=state).bitcast[_Shared]()
        var claim = UnsafePointer(to=morsel).bitcast[Int]()[]
        _ = morsel^
        var parked = Slab[Morsel]()
        for k in range(_PER_CLAIM):
            var id = claim * _PER_CLAIM + k
            parked.append(Morsel(RecordBatch.count_only(id + 1), id, 0))
        ref pool = sp[].pool
        pool.enter()
        pool.publish(parked, wid)
        pool.leave()
        while True:
            var got = pool.wait_take(wid)
            if not got:
                break
            sp[].note(got.value().morsel_id)


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_every_published_morsel_is_taken_exactly_once() raises:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    for _ in range(_ROUNDS):
        ref d = rt.dispatcher()
        var s = _Shared()
        var claims = List[Int]()
        for i in range(_CLAIMS):
            claims.append(i)
        var back = d.for_each_morsel[_Shared, Int, _ClaimBody](
            s, claims^, _ClaimBody(_pad=0), CancellationToken.never()^
        )
        _ = back^
        assert_equal(s.pool.published_count(), _CLAIMS * _PER_CLAIM)
        for id in range(_CLAIMS * _PER_CLAIM):
            assert_equal(s.count(id), 1, "morsel " + String(id))
        assert_true(s.pool.foreign_count() <= _CLAIMS * _PER_CLAIM)
    rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
