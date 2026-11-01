# =============================================================================
# join_parallel_build_counter -- reachability + parallel-fire witness for the
# parallel hash-join build (`hash_chain_parallel_build`)
# =============================================================================
#
# A byte-oracle (parallel-built index == serial-built index as a match
# multiset) is BLIND to WHICH build ran and to HOW MANY workers did work, so a
# process-global counter is the only falsifier that proves the parallel build
# (a) FIRED and (b) genuinely fanned across more than one worker.
#
#   * FIRE -- incremented once per parallel chained-hash build (above the
#            threshold, not the serial fallback).
#   * SPAN -- the MAX `workers_active` observed (task instances that claimed at
#            least one morsel); SPAN > 1 proves the build genuinely partitioned.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_jpb_i64() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate one zeroed counter once per process."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _JPB_FIRE = _Global["komira_join_parallel_build_fire", _init_jpb_i64]
comptime _JPB_SPAN = _Global["komira_join_parallel_build_span", _init_jpb_i64]


@always_inline
def join_parallel_build_fire_incr() raises:
    """Record one parallel hash-join build invocation (parallel path taken)."""
    # SAFETY: FFI carve-out — `_Global.get_or_create_ptr` targets KGEN-runtime
    # static storage (process-lifetime); the wildcard is the stdlib API's own
    # return type, confined to this helper.
    var gp = _JPB_FIRE.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def join_parallel_build_fire_count() raises -> Int:
    """Read the process-wide parallel-build fire count."""
    # SAFETY: FFI carve-out (see `join_parallel_build_fire_incr`).
    var gp = _JPB_FIRE.get_or_create_ptr()
    return Int(gp[][].load())


@always_inline
def join_parallel_build_record_worker_span(span: Int) raises:
    """Record a build worker span (task instances that did work), keeping the
    process-wide MAXIMUM via a monotone compare-exchange loop."""
    # SAFETY: FFI carve-out (see `join_parallel_build_fire_incr`).
    var gp = _JPB_SPAN.get_or_create_ptr()
    var target = Int64(span)
    while True:
        var cur = gp[][].load()
        if target <= cur:
            break
        # `compare_exchange` writes the observed value into `cur` on failure;
        # the loop re-reads it at the top either way.
        if gp[][].compare_exchange(cur, target):
            break


def join_parallel_build_worker_span() raises -> Int:
    """Read the process-wide MAX build worker span."""
    # SAFETY: FFI carve-out (see `join_parallel_build_fire_incr`).
    var gp = _JPB_SPAN.get_or_create_ptr()
    return Int(gp[][].load())


def reset_join_parallel_build() raises:
    """Reset both process-wide counters to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `join_parallel_build_fire_incr`).
    var gf = _JPB_FIRE.get_or_create_ptr()
    gf[][].store(Scalar[DType.int64](0))
    var gs = _JPB_SPAN.get_or_create_ptr()
    gs[][].store(Scalar[DType.int64](0))
