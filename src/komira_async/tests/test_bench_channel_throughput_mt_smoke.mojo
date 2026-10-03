# =============================================================================
# test_bench_channel_throughput_mt_smoke.mojo
# =============================================================================
# 4a smoke — verify the multi-threaded MPSC channel throughput
# protocol completes without deadlock or pointer-corruption at LOW N.
#
# This test does NOT assert specific perf numbers — perf is the bench's
# output, the test is just a structural guard:
#   * heap-stashed sender clones (one per pthread, intentionally leaked)
#   * heap-stashed receiver
#   * cross-thread MpscSender.try_send via wildcard-origin direct
#     reconstruction (NOT through a struct wrap — see bench file header
#     for the documented 0.26.3 limitation)
#   * pthread_create / pthread_join discipline
#   * shared atomic done-counter across producers + main
#
# Linux-only (pthread_setaffinity_np); macOS skips with WARN-PASS.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from komira_atomic_alias import AtomicI32
from std.testing import assert_true

from komira_async.channel.mpsc import (
    MpscReceiver,
    MpscSender,
    channel as mpsc_channel,
)
from komira_async.channel.spsc import (


    TRY_SEND_OK,
    TRY_RECV_OK,
    TRY_RECV_EMPTY,
)

@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed null
    UnsafePointer ctor / the `_unsafe_null=()` b1 idiom).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Origin `o` is concrete; the NULL sentinel is never
    # dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]



# =============================================================================
# Same shape as the bench's _BenchSharedAtomics — bare atomics in struct.
# =============================================================================

struct _SmokeAtomics(Deinitable):
    var done: AtomicI32

    def __init__(out self):
        self.done = AtomicI32(Int32(0))


@fieldwise_init
struct _SmokeProdArg(Copyable, Movable, Deinitable):
    var sender_addr: Int
    var atomics_addr: Int
    var n_items: Int


@fieldwise_init
struct _SmokeConsArg(Copyable, Movable, Deinitable):
    var receiver_addr: Int
    var total_items: Int


# =============================================================================
# Producer entry — wildcard-origin direct on heap-stashed MpscSender.
# =============================================================================

def _producer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    var typed_arg = arg.bitcast[_SmokeProdArg]()
    var sender_addr = typed_arg[].sender_addr
    var atomics_addr = typed_arg[].atomics_addr
    var n_items = typed_arg[].n_items
    typed_arg.bitcast[UInt8]().free()

    var sender_ptr = UnsafePointer[MpscSender[Int], MutUntrackedOrigin](
        unsafe_from_address=sender_addr,
    )
    var atomics_ptr = UnsafePointer[_SmokeAtomics, MutUntrackedOrigin](
        unsafe_from_address=atomics_addr,
    )

    var i = 0
    while i < n_items:
        var rc = sender_ptr[].try_send(i)
        if Int(rc) == Int(TRY_SEND_OK):
            i = i + 1
        else:
            _ = external_call["sched_yield", Int32]()

    _ = atomics_ptr[].done.fetch_add(Int32(1))
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _consumer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    var typed_arg = arg.bitcast[_SmokeConsArg]()
    var receiver_addr = typed_arg[].receiver_addr
    var total_items = typed_arg[].total_items
    typed_arg.bitcast[UInt8]().free()

    var receiver_ptr = UnsafePointer[MpscReceiver[Int], MutUntrackedOrigin](
        unsafe_from_address=receiver_addr,
    )

    var received = 0
    while received < total_items:
        var r = receiver_ptr[].try_recv()
        if Int(r.status) == Int(TRY_RECV_OK):
            received = received + 1
        elif Int(r.status) == Int(TRY_RECV_EMPTY):
            _ = external_call["sched_yield", Int32]()
        else:
            break

    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _pthread_create(
    ref [_] thread_id_slot: Int64,
    entry: def (UnsafePointer[NoneType, MutUntrackedOrigin]) thin -> UnsafePointer[NoneType, MutUntrackedOrigin],
    arg_addr: UnsafePointer[NoneType, MutUntrackedOrigin],
) -> Int32:
    var slot_addr = UnsafePointer(to=thread_id_slot)
    return external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        entry,
        arg_addr,
    )


def _pthread_join(thread_id: Int64) -> Int32:
    return external_call["pthread_join", Int32](
        thread_id, _null_ptr[UInt8, MutUntrackedOrigin](),
    )


def test_channel_throughput_mt_smoke() raises:
    """4a smoke: N=2 producers + 1 consumer, 100 items each."""

    comptime if not CompilationTarget.is_linux():
        assert_true(True)
        return

    comptime N_PRODUCERS: Int = 2
    comptime N_PER_PRODUCER: Int = 100
    comptime TOTAL: Int = N_PRODUCERS * N_PER_PRODUCER
    comptime CAPACITY: Int = 64

    # Construct channel.
    var pair = mpsc_channel[Int](capacity=UInt(CAPACITY))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()

    # Heap-stash receiver (leaked).
    var recv_raw = alloc[MpscReceiver[Int]](1)
    UnsafePointer(to=recv_raw[]).unsafe_write(receiver^)
    var receiver_addr = Int(recv_raw)

    # Heap-stash N sender clones (leaked).
    var sender_addrs = List[Int](capacity=N_PRODUCERS)
    var p = 0
    while p < N_PRODUCERS:
        var sender_clone = sender.clone()
        var sraw = alloc[MpscSender[Int]](1)
        UnsafePointer(to=sraw[]).unsafe_write(sender_clone^)
        sender_addrs.append(Int(sraw))
        p = p + 1
    _ = sender^

    # Heap-stash atomics (leaked, same as bench).
    var atomics_raw = alloc[_SmokeAtomics](1)
    atomics_raw[] = _SmokeAtomics()
    var atomics_addr = Int(atomics_raw)

    # Per-pthread args.
    var producer_args = List[UnsafePointer[NoneType, MutUntrackedOrigin]]()
    var producer_tids = List[Int64](capacity=N_PRODUCERS)
    p = 0
    while p < N_PRODUCERS:
        var arg_raw = alloc[_SmokeProdArg](1)
        UnsafePointer(to=arg_raw[]).unsafe_write(
            _SmokeProdArg(
                sender_addr=sender_addrs[p],
                atomics_addr=atomics_addr,
                n_items=N_PER_PRODUCER,
            ),
        )
        var arg_void = arg_raw.bitcast[NoneType]().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        producer_args.append(arg_void)
        producer_tids.append(Int64(0))
        p = p + 1

    var cons_arg_raw = alloc[_SmokeConsArg](1)
    UnsafePointer(to=cons_arg_raw[]).unsafe_write(
        _SmokeConsArg(receiver_addr=receiver_addr, total_items=TOTAL),
    )
    var cons_arg_void = (
        cons_arg_raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]()
    )

    var cons_tid: Int64 = 0
    var rc_c = _pthread_create(cons_tid, _consumer_entry, cons_arg_void)
    assert_true(rc_c == Int32(0))

    p = 0
    while p < N_PRODUCERS:
        var rc_p = _pthread_create(
            producer_tids[p], _producer_entry, producer_args[p]
        )
        assert_true(rc_p == Int32(0))
        p = p + 1

    p = 0
    while p < N_PRODUCERS:
        _ = _pthread_join(producer_tids[p])
        p = p + 1
    _ = _pthread_join(cons_tid)

    # Verify all N producers signaled done.
    var atomics_ptr = UnsafePointer[_SmokeAtomics, MutUntrackedOrigin](
        unsafe_from_address=atomics_addr,
    )
    var done_val = atomics_ptr[].done.load()
    assert_true(Int(done_val) == N_PRODUCERS)


def main() raises:
    test_channel_throughput_mt_smoke()
    print("PASS komira_async.perf bench_channel_throughput_mt smoke")
