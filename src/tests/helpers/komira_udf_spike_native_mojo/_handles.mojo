# =============================================================================
# FFI-BOUNDARY: the handles of this native UDF library and the host memory
# they are reserved from.
# =============================================================================
# The runtime, udf, context, instance, groups and frame handles of the table
# (_table.mojo, _frames.mojo): one heap struct each, made by its open entry
# with _box and freed by its close entry with _unbox. Every block, handles
# and scratch alike, is reserved from the host (mem_reserve) while it lives
# and released when it is freed, so the host's reserved bytes show a block
# this library never frees.
# =============================================================================

from std.memory import alloc
from std.sys import size_of

from komira_udf_spike_abi._cabi import CUdfHost, Void, free_zeroed, zeroed

from ._fixtures import Fixture

comptime _DEVICE_ARRAY = 128
"""Bytes of a struct ArrowDeviceArray."""
comptime _STREAM = 48
"""Bytes of a struct ArrowDeviceArrayStream."""


@fieldwise_init
struct _Rt(Movable):
    var host: Void
    var table: Void
    var id: Void
    var abi: Void


@fieldwise_init
struct _Udf(Movable):
    var host: Void
    var fx: Fixture
    var fields: List[String]
    var flags: List[Int64]
    var n_args: Int
    """The argument schema's children, bound at load."""


@fieldwise_init
struct _Ctx(Movable):
    var rt: Void
    var slot: UInt32


@fieldwise_init
struct _Inst(Movable):
    var host: Void
    var fx: Fixture
    var fields: List[String]
    var flags: List[Int64]
    var scratch: Void
    var group_sets: Int
    var n_args: Int
    var runs: Int64
    """volatile_count_raise: the batches it ran."""


@fieldwise_init
struct _Groups(Movable):
    var host: Void
    var fx: Int
    var st: List[Int64]
    var scratch: Void
    var n_args: Int


@fieldwise_init
struct _Frame(Movable):
    var host: Void
    var fx: Int
    var stream: Void
    var done: Bool
    var running: Int64
    var group: Int64
    var max: Int64
    var yielded: Bool
    var want: Int
    """Each input batch's children: the bound arguments, after a group
    ordinal for a plain aggregate."""
    var call: Void
    """The frame_next in progress: its cancel flag and deadline."""
    var in_failed: Bool
    """The input failed: nothing but release is called on it again."""


def _reserve(host: Void, n: Int):
    # SAFETY: `host` is the komira_udf_host native_init got, alive until
    # shutdown returns.
    var h = host.bitcast[CUdfHost]()
    _ = h[].mem_reserve(h[].host_data, Int64(n))


def _release(host: Void, n: Int):
    # SAFETY: as _reserve.
    var h = host.bitcast[CUdfHost]()
    h[].mem_release(h[].host_data, Int64(n))


def _box[T: Movable & ImplicitlyDestructible](host: Void, var v: T) -> Void:
    # SAFETY: a heap slot of this library, untracked because the host holds
    # it across calls; written before the pointer leaves, freed by _unbox.
    _reserve(host, size_of[T]())
    var p = alloc[T](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p.unsafe_write(v^)
    return p.bitcast[NoneType]()


def _unbox[T: Movable & ImplicitlyDestructible](host: Void, p: Void):
    # SAFETY: `p` came from _box[T] and is freed once, by its close entry.
    var q = p.bitcast[T]()
    q.destroy_pointee()
    q.free()
    _release(host, size_of[T]())


def _scratch(host: Void, n: Int) -> Void:
    """`n` zeroed bytes, reserved from the host until _free_scratch."""
    _reserve(host, n)
    return zeroed(n)


def _free_scratch(host: Void, p: Void, n: Int):
    free_zeroed(p)
    _release(host, n)


def _set_out_slot(slot: Void, v: Void):
    # SAFETY: `slot` is the host's `komira_udf_xxx** out`.
    slot.bitcast[Void]()[] = v

