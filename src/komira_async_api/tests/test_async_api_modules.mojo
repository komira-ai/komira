# =============================================================================
# komira_async_api: the token tree, the shared-payload fork-join, the dispatch
# contracts and the pool-depth counter
# =============================================================================
#
# Each test states the behaviour it asserts:
#   * token: cancellation flows to descendants and never to ancestors; the
#     outermost reason wins; `never` ignores `cancel`.
#   * fork-join, inline: `has_pool=False` runs every chunk on the caller's
#     thread and fills the payload; zero chunks hand the payload back as is.
#   * fork-join, error: a chunk that raises surfaces as "chunk <n> failed".
#   * fork-join, pooled: a dispatcher with several workers is asked to run the
#     wave once, every chunk runs once; when the pool-depth counter is above
#     zero (a dispatch already live) the same wave runs inline and the
#     dispatcher is not called.
#   * pool depth: the C counter moves by one per enter and exit.
#   * NoDispatch and ScaleSignal: the serial stand-in reports one worker and
#     hands its segment back; a conformer of the signal trait is callable
#     through the trait.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from komira_async_api.fork_join_shared import (
    fork_join_pool_depth,
    fork_join_shared,
    raise_first_chunk_error,
)
from komira_async_api.parallel_dispatch import NoDispatch, ParallelDispatch
from komira_async_api.scale_signal import ScaleSignal
from komira_async_api.sched_sites import (
    SITE_GATHER_FIXEDWIDTH,
    SITE_GATHER_STR_LEN,
    SITE_GATHER_STR_SCATTER,
    SITE_JOIN_CHUNK_PRICE,
)
from komira_async_api.shared_chunk_work import SharedChunkWork
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment


@fieldwise_init
struct SquareChunk(SharedChunkWork):
    var chunk_len: Int
    var fail_chunk: Int

    def process[In: Deinitable, P: Movable & Deinitable](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P
    ) raises:
        if chunk_id == self.fail_chunk:
            raise Error("boom")
        # Every call below binds both In and P to List[Int].
        ref src = rebind[List[Int]](input)
        ref dst = rebind[List[Int]](payload)
        for i in range(chunk_id * self.chunk_len, (chunk_id + 1) * self.chunk_len):
            dst[i] = src[i] * src[i]


struct SerialPool(ParallelDispatch, Movable, Deinitable):
    """A dispatcher that runs the n copies of a segment one after another on the
    calling thread and counts how many times it was asked to."""

    var runs: Int
    var workers: Int

    def __init__(out self, workers: Int):
        self.runs = 0
        self.workers = workers

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        self.runs += 1
        for tid in range(n):
            seg.execute[State](state, Int32(tid), Int64(tid))
        _ = cancel_token^
        return seg^

    def worker_count(self) -> Int:
        return self.workers


@fieldwise_init
struct FixedSignal(ScaleSignal):
    var behind: Float64

    def pressure(self) -> Float64:
        return self.behind

    def pressure_trend(self) -> Float64:
        return 0.0

    def skew_locus(self) -> Optional[UInt32]:
        return None

    def cold_start_floor(self) -> Int64:
        return 5_000_000


def _squares_inline(
    imm values: List[Int], chunk_len: Int, fail_chunk: Int
) raises -> List[Int]:
    var serial = NoDispatch()
    return fork_join_shared[
        SquareChunk, List[Int], List[Int], origin_of(values), NoDispatch,
        has_pool=False, disp_o=origin_of(serial),
    ](
        SquareChunk(chunk_len, fail_chunk),
        values,
        List[Int](length=len(values), fill=0),
        len(values) // chunk_len,
        2,
        0,
        None,
        CancellationToken.never(),
        UInt32(0),
    )


def _squares_pooled(
    imm values: List[Int], chunk_len: Int, mut pool: SerialPool
) raises -> List[Int]:
    return fork_join_shared[
        SquareChunk, List[Int], List[Int], origin_of(values), SerialPool,
        has_pool=True, disp_o=origin_of(pool),
    ](
        SquareChunk(chunk_len, -1),
        values,
        List[Int](length=len(values), fill=0),
        len(values) // chunk_len,
        2,
        0,
        Optional[Pointer[SerialPool, origin_of(pool)]](Pointer(to=pool)),
        CancellationToken.never(),
        UInt32(0),
    )


def test_token_tree() raises:
    var root = CancellationToken.new()
    var child = root.child()
    var shared = root.clone()
    var leaf = child.child()
    leaf.cancel("leaf done")
    assert_true(leaf.is_cancelled())
    assert_false(child.is_cancelled())
    root.cancel("deadline")
    root.cancel("ignored")
    assert_true(shared.is_cancelled())
    assert_true(child.is_cancelled())
    assert_equal(child.reason(), "deadline")
    assert_equal(leaf.reason(), "deadline")
    var never = CancellationToken.never()
    never.cancel("no effect")
    assert_false(never.is_cancelled())


def test_fork_join_inline_fills_every_slot() raises:
    assert_equal(
        _squares_inline([1, 2, 3, 4, 5, 6], 2, -1), [1, 4, 9, 16, 25, 36]
    )
    assert_equal(fork_join_pool_depth(), Int64(0))


def test_fork_join_zero_chunks_returns_the_payload() raises:
    var empty = List[Int]()
    assert_equal(len(_squares_inline(empty, 2, -1)), 0)


def test_fork_join_chunk_error_names_the_chunk() raises:
    var raised = False
    try:
        _ = _squares_inline([1, 2, 3, 4, 5, 6], 2, 1)
    except e:
        raised = True
        assert_true("chunk 1 failed" in String(e))
        assert_true("boom" in String(e))
    assert_true(raised)


def test_raise_first_chunk_error_passes_when_no_chunk_failed() raises:
    var errors = List[Optional[String]]()
    errors.append(Optional[String](None))
    errors.append(Optional[String](None))
    raise_first_chunk_error(errors)


def test_fork_join_pooled_asks_the_dispatcher_once() raises:
    var pool = SerialPool(3)
    assert_equal(
        _squares_pooled([1, 2, 3, 4, 5, 6, 7, 8], 2, pool),
        [1, 4, 9, 16, 25, 36, 49, 64],
    )
    assert_equal(pool.runs, 1)


def test_fork_join_inside_a_dispatch_runs_inline() raises:
    var pool = SerialPool(3)
    assert_equal(external_call["komira_on_pool_enter", Int64](), Int64(1))
    assert_equal(fork_join_pool_depth(), Int64(1))
    var out = _squares_pooled([1, 2, 3, 4], 2, pool)
    assert_equal(external_call["komira_on_pool_exit", Int64](), Int64(0))
    assert_equal(out, [1, 4, 9, 16])
    assert_equal(pool.runs, 0)
    assert_equal(fork_join_pool_depth(), Int64(0))


def test_no_dispatch_is_one_serial_worker() raises:
    var none = NoDispatch()
    assert_equal(none.worker_count(), 1)


def test_scale_signal_through_the_trait() raises:
    var sig = FixedSignal(1.5)
    var copy = sig.copy()
    assert_equal(copy.pressure(), 1.5)
    assert_equal(copy.pressure_trend(), 0.0)
    assert_false(Bool(copy.skew_locus()))
    assert_equal(copy.cold_start_floor(), Int64(5_000_000))


def test_sched_sites_are_distinct() raises:
    assert_equal(SITE_GATHER_STR_LEN, UInt32(40))
    assert_equal(SITE_GATHER_STR_SCATTER, UInt32(41))
    assert_equal(SITE_GATHER_FIXEDWIDTH, UInt32(42))
    assert_equal(SITE_JOIN_CHUNK_PRICE, UInt32(44))


def main() raises:
    test_token_tree()
    test_fork_join_inline_fills_every_slot()
    test_fork_join_zero_chunks_returns_the_payload()
    test_fork_join_chunk_error_names_the_chunk()
    test_raise_first_chunk_error_passes_when_no_chunk_failed()
    test_fork_join_pooled_asks_the_dispatcher_once()
    test_fork_join_inside_a_dispatch_runs_inline()
    test_no_dispatch_is_one_serial_worker()
    test_scale_signal_through_the_trait()
    test_sched_sites_are_distinct()
    print("PASS komira_async_api modules")
