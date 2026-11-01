# =============================================================================
# join_deferred_idx -- narrowing a deferred record's match indices to 4 bytes,
# and the counters of how they were written.
# =============================================================================
#
# A deferred join record retains its probe and build match indices until the
# final gather. They are narrowed from `Int` to `Int32` when every index fits
# (a refusal keeps the 8-byte lists; nothing is lost), halving what the
# record holds and what the gather re-reads. The narrowed lists are written
# with non-temporal stores by default, since nothing reads them before the
# gather; `nt_store=False` takes ordinary stores and the same lists.
# =============================================================================

from std.ffi import _Global
from std.memory import alloc, OwnedPointer

from komira_atomic_alias import AtomicI64

from komira_simd.fast_copy import nt_release_fence


def _init_ctr() -> OwnedPointer[AtomicI64]:
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is a fresh one-element allocation; zeroing it as the
    # counter's int64 initialises it, and the `OwnedPointer` then owns and
    # frees it.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _NT_BYTES = _Global["komira_join_nt_index_bytes", _init_ctr]
comptime _NT_DECLINED = _Global["komira_join_nt_declined", _init_ctr]
comptime _NT_OUT_BYTES = _Global["komira_join_nt_out_bytes", _init_ctr]
comptime _NT_OUT_DECL = _Global["komira_join_nt_out_declined", _init_ctr]


def note_nt_index_write(bytes: Int) raises:
    """Bytes written through the non-temporal arm, as modelled (4 bytes per
    narrowed index), not measured."""
    # SAFETY: FFI carve-out -- `get_or_create_ptr` targets KGEN-runtime
    # static storage; the wildcard origin is the stdlib API's own return type
    # and never leaves this frame.
    var g = _NT_BYTES.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(bytes))


def note_nt_declined(records: Int) raises:
    """Records that narrowed WITHOUT the NT arm."""
    # SAFETY: FFI carve-out (see `note_nt_index_write`).
    var g = _NT_DECLINED.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(records))


def note_nt_out_write(bytes: Int) raises:
    """Bytes written non-temporally into the FINAL OUTPUT columns."""
    # SAFETY: FFI carve-out (see `note_nt_index_write`).
    var g = _NT_OUT_BYTES.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(bytes))


def note_nt_out_declined(items: Int) raises:
    """Work items that filled the output on the ORDINARY-store arm."""
    # SAFETY: FFI carve-out (see `note_nt_index_write`).
    var g = _NT_OUT_DECL.get_or_create_ptr()
    _ = g[][].fetch_add(Int64(items))


def join_nt_out_bytes() raises -> Int:
    """Modelled bytes written non-temporally into the output columns."""
    # SAFETY: FFI carve-out (see `note_nt_index_write`).
    var g = _NT_OUT_BYTES.get_or_create_ptr()
    return Int(g[][].load())


def join_nt_out_declined_items() raises -> Int:
    """Work items filled on the ordinary-store arm."""
    # SAFETY: FFI carve-out (see `note_nt_index_write`).
    var g = _NT_OUT_DECL.get_or_create_ptr()
    return Int(g[][].load())


def join_nt_index_bytes() raises -> Int:
    """Modelled bytes written through the NT arm."""
    # SAFETY: FFI carve-out (see `note_nt_index_write`).
    var g = _NT_BYTES.get_or_create_ptr()
    return Int(g[][].load())


def join_nt_declined_records() raises -> Int:
    """Records narrowed on the ORDINARY-store arm."""
    # SAFETY: FFI carve-out (see `note_nt_index_write`).
    var g = _NT_DECLINED.get_or_create_ptr()
    return Int(g[][].load())


def reset_join_nt_counters() raises:
    """Reset the four counters (index bytes, declined records, output bytes,
    output declined items; test setup)."""
    # SAFETY: FFI carve-out (see `note_nt_index_write`).
    var a = _NT_BYTES.get_or_create_ptr()
    a[][].store(Scalar[DType.int64](0))
    var b = _NT_DECLINED.get_or_create_ptr()
    b[][].store(Scalar[DType.int64](0))
    var c = _NT_OUT_BYTES.get_or_create_ptr()
    c[][].store(Scalar[DType.int64](0))
    var d = _NT_OUT_DECL.get_or_create_ptr()
    d[][].store(Scalar[DType.int64](0))


comptime IDX32_MAX: Int = 2147483647
"""Largest value an `Int32` match index can carry. A probe index is bounded by
the morsel's row count and a build index by the build side's; both are CHECKED
rather than assumed, because "no join has 2^31 build rows" is a claim about
today's fixtures, not about the type.
"""


struct NarrowedIndexPair(Movable):
    """The 4-byte form of one record's two match-index lists, or a refusal."""

    var probe32: Optional[List[Int32]]
    var build32: Optional[List[Int32]]
    var ok: Bool

    def __init__(out self):
        self.probe32 = Optional[List[Int32]](None)
        self.build32 = Optional[List[Int32]](None)
        self.ok = False


def try_narrow_index_pair(
    imm probe_idx: List[Int],
    imm build_idx: List[Int],
    n: Int,
    nt_store: Bool = True,
) raises -> NarrowedIndexPair:
    """Narrow `n` (probe, build) index pairs to `Int32`, or REFUSE (any index
    negative or above `IDX32_MAX`). With `nt_store` the narrowed lists are
    written with non-temporal stores (a retained index is not read again until
    the final gather), else with ordinary appends; the lists are the same.

    Returns:
        A `NarrowedIndexPair` whose `ok` says whether the narrow lists are
        usable. On refusal both lists are empty.
    """
    var out = NarrowedIndexPair()
    if n <= 0:
        return out^

    var nt = nt_store
    var p32 = List[Int32](capacity=n)
    var b32 = List[Int32](capacity=n)

    if not nt:
        for i in range(n):
            var pv = probe_idx[i]
            var bv = build_idx[i]
            if pv < 0 or pv > IDX32_MAX or bv < 0 or bv > IDX32_MAX:
                _ = p32^
                _ = b32^
                note_nt_declined(1)
                return out^
            p32.append(Int32(pv))
            b32.append(Int32(bv))
        out.probe32 = Optional[List[Int32]](p32^)
        out.build32 = Optional[List[Int32]](b32^)
        out.ok = True
        note_nt_declined(1)
        return out^

    # ---- NT arm -----------------------------------------------------------
    # SAFETY: module-internal pointer arithmetic, and the two preconditions a
    # raw write into a `List` needs are both established above rather than
    # hoped for: the capacity is EXACTLY `n` (so no append can reallocate and
    # move the storage out from under these pointers) and the loop index is
    # `< n`, so every write lands inside that capacity; the VALUES written are
    # the ones the check in the loop keeps within `0..IDX32_MAX`, so each
    # converts to `Int32` exactly. The pointers are read out of the Lists we just created, never
    # escape this frame, and the length is set through the List's own API
    # afterwards so the object is never observed in a half-initialised state.
    var pp = p32.unsafe_ptr()
    var bp = b32.unsafe_ptr()
    for i in range(n):
        var pv = probe_idx[i]
        var bv = build_idx[i]
        if pv < 0 or pv > IDX32_MAX or bv < 0 or bv > IDX32_MAX:
            nt_release_fence()
            _ = p32^
            _ = b32^
            return out^
        (pp + i).unsafe_store[non_temporal=True](Int32(pv))
        (bp + i).unsafe_store[non_temporal=True](Int32(bv))

    nt_release_fence()
    p32.resize(unsafe_uninit_length=n)
    b32.resize(unsafe_uninit_length=n)
    out.probe32 = Optional[List[Int32]](p32^)
    out.build32 = Optional[List[Int32]](b32^)
    out.ok = True
    note_nt_index_write(2 * n * 4)
    return out^


def try_narrow_index_single(
    imm probe_idx: List[Int],
    n: Int,
    nt_store: Bool = True,
) raises -> NarrowedIndexPair:
    """`try_narrow_index_pair` for a record that retains ONE index list.

    Returns:
        A `NarrowedIndexPair` whose `probe32` is usable iff `ok`.
    """
    var out = NarrowedIndexPair()
    if n <= 0:
        return out^

    var nt = nt_store
    var p32 = List[Int32](capacity=n)

    if not nt:
        for i in range(n):
            var pv = probe_idx[i]
            if pv < 0 or pv > IDX32_MAX:
                _ = p32^
                note_nt_declined(1)
                return out^
            p32.append(Int32(pv))
        out.probe32 = Optional[List[Int32]](p32^)
        out.ok = True
        note_nt_declined(1)
        return out^

    # SAFETY: module-internal pointer arithmetic; the capacity is EXACTLY `n`
    # (so no append can reallocate) and the loop index is `< n`, so every
    # write lands inside that capacity; the values written are the ones the
    # check in the loop keeps within `0..IDX32_MAX`. The
    # pointer is read out of the List we just created and never escapes.
    var pp = p32.unsafe_ptr()
    for i in range(n):
        var pv = probe_idx[i]
        if pv < 0 or pv > IDX32_MAX:
            nt_release_fence()
            _ = p32^
            return out^
        (pp + i).unsafe_store[non_temporal=True](Int32(pv))

    nt_release_fence()
    p32.resize(unsafe_uninit_length=n)
    out.probe32 = Optional[List[Int32]](p32^)
    out.ok = True
    note_nt_index_write(n * 4)
    return out^
