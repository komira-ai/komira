# =============================================================================
# join_probe_narrow -- the deferred join drain's match index, written once at
# its final 4-byte width (the MARSHAL FUSE).
# =============================================================================
#
# A deferred record retains its (probe, build) match indices as `Int32` lists.
# Without this module the streaming probe writes each chunk's pairs three
# times on the way there: the kernel into its scratch buffers, a mask walk
# into two `List[Int]`, then `_try_narrow_indices` into the two `List[Int32]`.
# `NarrowMatchSink` reads the kernel's scratch and writes the `Int32` lists
# directly, in one pass; the record it yields (`deferred_chunk_narrowed`) is
# the one `DeferredJoinChunk.deferred_chunk` builds, field for field.
#
# What it does not take over:
#   * A morsel with a selection mask: its walk drops pairs, and the streaming
#     probe keeps the masked walk for it (`narrow_marshal_admits` refuses).
#   * A payload-inline index: its records carry a third list.
#   * The refusal of an index that does not fit `Int32`. The sink cannot
#     refuse once it has written, so `narrow_marshal_admits` proves both index
#     domains fit from the two row counts before the first kernel call, and
#     `finish` checks the OR of every absorbed index and RAISES if one did not
#     fit (gathering from a truncated index would be a different source row).
#   * The non-temporal store arm (`nt_store`), which it keeps.
#
# The setting is a process flag, on by default (`join_narrow_marshal_configure`);
# off, the streaming probe takes the two-pass walk.
# =============================================================================

from std.atomic import Atomic
from std.ffi import _Global
from std.memory import alloc, OwnedPointer, UnsafePointer

from komira_arrow.record_batch import RecordBatch
from komira_simd.fast_copy import nt_release_fence

from komira_op_join_build.join import PROBE_CHUNK_SIZE
from komira_op_join_build.join_probe_phase_split import JOIN_PS_MIN_HEADROOM

from .join_deferred import DeferredJoinChunk
from .join_deferred_idx import IDX32_MAX, note_nt_declined, note_nt_index_write


comptime NARROW_HEADROOM: Int = JOIN_PS_MIN_HEADROOM
"""Spare room reserved beyond the probe row count, for two reasons:

1. The phase-split probe walk declines a chunk buffer smaller than
   `JOIN_PS_MIN_HEADROOM`, so the sink never offers less (the fixed
   `PROBE_CHUNK_SIZE` buffers of the two-pass walk never did either).
2. The kernel returns as soon as its chunk is full, without looking for more
   probe rows; offering exactly the probe row count on a one-to-one join would
   fill it and cost a second kernel call and a growth per morsel."""


def _init_npn_i64() -> OwnedPointer[Atomic[DType.int64]]:
    var raw = alloc[Atomic[DType.int64]](1)
    UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[Atomic[DType.int64]](unsafe_from_raw_pointer=raw)


# 0 = not configured (on), 1 = on, -1 = off.
comptime _NM_CFG = _Global["komira_join_narrow_marshal_cfg", _init_npn_i64]
comptime _NM_FUSED = _Global["komira_join_narrow_marshal_fused", _init_npn_i64]
comptime _NM_LEGACY = _Global["komira_join_narrow_marshal_legacy", _init_npn_i64]
comptime _NM_WIDENED = _Global[
    "komira_join_narrow_marshal_widened", _init_npn_i64
]
comptime _NM_PAIRS = _Global["komira_join_narrow_marshal_pairs", _init_npn_i64]


def join_narrow_marshal_configure(on: Bool) raises:
    """Set the MARSHAL FUSE for this process (on by default). Set once, from
    a flag, before any probe runs; off restores the two-pass walk."""
    # SAFETY: FFI carve-out -- `_Global.get_or_create_ptr` targets KGEN-runtime
    # static storage (process lifetime); the wildcard origin is the stdlib API's
    # own return type and is confined to this function.
    _NM_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](1 if on else -1))


def join_narrow_marshal_enabled() raises -> Bool:
    """Is the MARSHAL FUSE on? On unless configured off."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    return Int(_NM_CFG.get_or_create_ptr()[][].load()) >= 0


def join_narrow_marshal_reset_config() raises:
    """TEST-ONLY. The setting back to its default (on)."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    _NM_CFG.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


def join_narrow_marshal_note(fused: Bool, pairs: Int) raises:
    """Record one deferred drain's route. Both routes count, so a zero on the
    fused one reads as "not taken" rather than "never reached"."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    if fused:
        _ = _NM_FUSED.get_or_create_ptr()[][].fetch_add(Int64(1))
        _ = _NM_PAIRS.get_or_create_ptr()[][].fetch_add(Int64(pairs))
    else:
        _ = _NM_LEGACY.get_or_create_ptr()[][].fetch_add(Int64(1))


def join_narrow_marshal_note_widened(pairs: Int) raises:
    """Pairs a fused drain widened back to `Int` because its morsel then
    declined deferral: the fused route's only added cost."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    _ = _NM_WIDENED.get_or_create_ptr()[][].fetch_add(Int64(pairs))


def join_narrow_marshal_fused_drains() raises -> Int:
    """Deferred drains that wrote the index at 4-byte width in one pass."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    return Int(_NM_FUSED.get_or_create_ptr()[][].load())


def join_narrow_marshal_legacy_drains() raises -> Int:
    """Deferred drains that took the two-pass walk."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    return Int(_NM_LEGACY.get_or_create_ptr()[][].load())


def join_narrow_marshal_widened_pairs() raises -> Int:
    """Pairs widened back to `Int` because the morsel declined deferral."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    return Int(_NM_WIDENED.get_or_create_ptr()[][].load())


def join_narrow_marshal_fused_pairs() raises -> Int:
    """Match pairs absorbed through the fused pass."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    return Int(_NM_PAIRS.get_or_create_ptr()[][].load())


def reset_join_narrow_marshal_counters() raises:
    """TEST-ONLY. Zero every counter; the setting is left as it is."""
    # SAFETY: FFI carve-out (see `join_narrow_marshal_configure`).
    var z = Scalar[DType.int64](0)
    _NM_FUSED.get_or_create_ptr()[][].store(z)
    _NM_LEGACY.get_or_create_ptr()[][].store(z)
    _NM_WIDENED.get_or_create_ptr()[][].store(z)
    _NM_PAIRS.get_or_create_ptr()[][].store(z)


def narrow_marshal_admits(
    gate_on: Bool,
    has_selection_mask: Bool,
    pay_inline: Bool,
    num_probe_rows: Int,
    num_build_rows: Int,
) -> Bool:
    """May this morsel's deferred drain write its index at 4-byte width?

    Only with the setting on (`gate_on`), no selection mask, no inlined
    payload, and both index domains inside `Int32`: a probe index is below
    the morsel's row count and a build index below the build side's. A
    zero-row build side passes; it yields no pair and no record."""
    if not gate_on or has_selection_mask or pay_inline:
        return False
    if num_probe_rows < 0 or num_probe_rows > IDX32_MAX:
        return False
    if num_build_rows < 0 or num_build_rows > IDX32_MAX:
        return False
    return True


struct NarrowMatchSink(Movable):
    """Accumulates (probe, build) match pairs directly at `Int32` width.

    `chunk_capacity` is the room to offer the kernel for its next chunk;
    `absorb` narrows and appends what the kernel wrote; `finish` checks the
    index domain. The lists' lengths always equal the pairs absorbed.
    """

    var probe32: List[Int32]
    var build32: List[Int32]
    var n: Int
    var cap: Int
    var acc: Int64
    var nt: Bool

    def __init__(out self, num_probe_rows: Int, nt_store: Bool = True):
        """Reserve for a one-to-one morsel plus `NARROW_HEADROOM`; a morsel
        with more matches grows. A negative `num_probe_rows` is the INERT sink
        a drain that does not take this route declares: nothing reserved."""
        if num_probe_rows < 0:
            self.probe32 = List[Int32]()
            self.build32 = List[Int32]()
            self.n = 0
            self.cap = 0
            self.acc = Int64(0)
            self.nt = False
            return
        var c = num_probe_rows + NARROW_HEADROOM
        self.probe32 = List[Int32](capacity=c)
        self.build32 = List[Int32](capacity=c)
        self.n = 0
        self.cap = c
        self.acc = Int64(0)
        self.nt = nt_store

    def chunk_capacity(mut self) raises -> Int:
        """Room to offer the kernel for the next chunk, growing first if less
        than `NARROW_HEADROOM` is left; never 0, never above
        `PROBE_CHUNK_SIZE`, never below `NARROW_HEADROOM`."""
        if self.cap - self.n < NARROW_HEADROOM:
            self._grow()
        var room = self.cap - self.n
        if room > PROBE_CHUNK_SIZE:
            return PROBE_CHUNK_SIZE
        return room

    def _grow(mut self) raises:
        """Double the room, by at least one chunk, keeping what is written.

        On the non-temporal arm the stores are fenced first: the reallocation
        copies the written prefix and frees the old storage, and both must see
        every store drained."""
        if self.nt:
            nt_release_fence()
        var nc = self.cap * 2
        if nc < self.n + PROBE_CHUNK_SIZE:
            nc = self.n + PROBE_CHUNK_SIZE
        self.probe32.reserve(nc)
        self.build32.reserve(nc)
        self.cap = nc

    def absorb(
        mut self,
        probe_src: Span[Int, _],
        build_src: Span[Int, _],
        count: Int,
    ) raises:
        """Narrow and append the first `count` pairs of the kernel's two
        scratch buffers. `count` is at most the room `chunk_capacity` last
        offered; a larger one raises."""
        if count <= 0:
            return
        if self.n + count > self.cap or count > len(probe_src) \
           or count > len(build_src):
            raise Error(
                "NarrowMatchSink.absorb: " + String(count)
                + " pairs exceed the room offered or the scratch buffers"
            )
        var base = self.n
        self.probe32.resize(unsafe_uninit_length=base + count)
        self.build32.resize(unsafe_uninit_length=base + count)
        # SAFETY: the two lists were just sized to `base + count` within their
        # reserved capacity (checked above), so every write below is inside
        # them; the pointers are taken after the resize and do not outlive
        # this call. The sources are the caller's scratch spans, `count` long.
        var pd = self.probe32.unsafe_ptr() + base
        var bd = self.build32.unsafe_ptr() + base
        var ps = probe_src.unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var bs = build_src.unsafe_ptr().bitcast[Scalar[DType.int64]]()

        if self.nt:
            # Scalar non-temporal stores; the fence is issued once per record
            # in `finish` (and before a growth).
            var acc = Int64(0)
            for i in range(count):
                var pv = (ps + i)[]
                var bv = (bs + i)[]
                acc |= pv | bv
                (pd + i).unsafe_store[non_temporal=True](Int32(pv))
                (bd + i).unsafe_store[non_temporal=True](Int32(bv))
            self.acc |= acc
            self.n += count
            note_nt_index_write(2 * count * 4)
            return

        # A branch-free 64-to-32 narrowing copy; the range check is the OR
        # accumulator, which vectorises.
        comptime W = 8
        var vacc = SIMD[DType.int64, W](0)
        var i = 0
        while i + W <= count:
            var pv = (ps + i).load[width=W]()
            var bv = (bs + i).load[width=W]()
            vacc |= pv | bv
            (pd + i).store(pv.cast[DType.int32]())
            (bd + i).store(bv.cast[DType.int32]())
            i += W
        var acc = vacc.reduce_or()
        while i < count:
            var pv = (ps + i)[]
            var bv = (bs + i)[]
            acc |= pv | bv
            (pd + i)[] = Int32(pv)
            (bd + i)[] = Int32(bv)
            i += 1
        self.acc |= acc
        self.n += count

    def finish(mut self) raises:
        """Fence the non-temporal stores and check the index domain.

        Raises if any absorbed index was negative or above `IDX32_MAX` (the OR
        of them all has the sign bit or a bit at 31 or above):
        `narrow_marshal_admits` proved that impossible, so a producer emitted
        an index outside its own table, and gathering from the truncated value
        would read a different row."""
        if self.nt:
            nt_release_fence()
        if self.acc < Int64(0) or self.acc > Int64(IDX32_MAX):
            raise Error(
                "NarrowMatchSink.finish: a match index outside the Int32"
                " domain reached the fused narrow pass (or-accumulator "
                + String(self.acc)
                + " over "
                + String(self.n)
                + " pairs); a producer emitted an index outside its own table"
            )
        if not self.nt:
            note_nt_declined(1)

    def take_probe(mut self) -> List[Int32]:
        """Move the probe-side list out."""
        var out = self.probe32^
        self.probe32 = List[Int32]()
        return out^

    def take_build(mut self) -> List[Int32]:
        """Move the build-side list out."""
        var out = self.build32^
        self.build32 = List[Int32]()
        return out^


def deferred_chunk_narrowed(
    var probe_batch: RecordBatch,
    var probe32: List[Int32],
    var build32: List[Int32],
    partition_id: Int,
    origin_hint: Int,
    seq: Int,
    cse_ok: Bool,
) raises -> DeferredJoinChunk:
    """The record `DeferredJoinChunk.deferred_chunk` builds for these pairs,
    from lists already at 4-byte width: `idx32` set, no wide lists, no
    payload. Raises if the two lists differ in length."""
    if len(probe32) != len(build32):
        raise Error(
            "deferred_chunk_narrowed: index lists disagree -- probe "
            + String(len(probe32))
            + " vs build "
            + String(len(build32))
        )
    var out = DeferredJoinChunk()
    out.num_rows = len(probe32)
    out.probe_batch = probe_batch^
    out.probe_idx32 = probe32^
    out.build_idx32 = build32^
    out.idx32 = True
    out.pay_col = -1
    out.partition_id = partition_id
    out.origin_hint = origin_hint
    out.seq = seq
    out.deferred = True
    out.cse_ok = cse_ok
    return out^


def widen_narrow_index(imm src: List[Int32], n: Int) raises -> List[Int]:
    """The first `n` entries of `src` as `Int`: a fused drain whose morsel
    declined deferral hands the staged assembly wide indices."""
    var out = List[Int](capacity=n)
    for i in range(n):
        out.append(Int(src[i]))
    return out^
