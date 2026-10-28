# =============================================================================
# hash_chain_build_state -- the fork-join STATE the parallel chained-hash build
# runs over, the buffers it hands back, and the wave that initialises the
# chain-head table
# =============================================================================
#
# NOTHING HERE KNOWS ABOUT THE INSERT LOOP. The state is a dumb carrier:
# `hash_chain_parallel_build`'s insert task re-derives every pointer it needs
# from a borrowed `ChainBuildState` inside the one module that owns that
# arithmetic, so no pointer crosses this boundary in either direction.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import alloc, memset, OwnedPointer, UnsafePointer

from komira_arrow.primitive_array import PrimitiveArray
from komira_join_assembly.join_payload_inline import JOIN_KN_WORDS_PAY
from komira_async_api.worker_pool_traits import KeepAlive, Segment


# =============================================================================
# ChainBuildBuffers — the raw chained-hash index, ready for either builder type
# =============================================================================


struct ChainBuildBuffers(Movable):
    """The four parallel arrays + capacity that make up a chained-hash join
    index. Produced by `chain_build_parallel`, consumed by a per-builder-type
    adapter that wraps them into its own struct.

    Invariants (identical to the serial `HashJoinBuilder.build`):
      * ON THE DEFAULT LAYOUT,
        `len(build_keys) == len(build_indices) == len(next_chain) == num_rows`.
        Under either layout an elided array has length ZERO -- read
        `num_build`, never `len(build_keys)`, and read `build_indices` only when
        `bi_elided` is False.
      * `build_keys[i]` is the build key at row `i`; `build_indices[i] == i`.
        THAT SECOND EQUALITY IS THE WHOLE BASIS OF THE `bi_elided` LAYOUT: the
        array only ever returned the index used to read it.
      * `hash_table` has `capacity` slots (power of 2), each a chain head or
        `_CHAIN_END`.
      * A NULL build key is RECORDED (so a RIGHT/FULL outer unmatched-build sweep
        still sees it) but NOT linked into a bucket.
    """

    var build_keys: List[Int64]
    var build_indices: List[Int]
    var hash_table: List[Int]
    var next_chain: List[Int]
    # CHAIN-ENTRY LAYOUT. Which of the three
    # per-row arrays above actually EXIST is decided by the caller and reported
    # here, so an adapter cannot wrap a layout it does not understand:
    #   * `bi_elided` -> `build_indices` is EMPTY; the build row IS `chain_idx`.
    #   * `fused`     -> `build_keys` and `next_chain` are EMPTY and `key_next`
    #                    carries both as 16-byte records, [2i] key, [2i+1] link.
    # `num_build` is the row count on BOTH layouts, because `len(build_keys)`
    # stops being it under `fused`.
    var key_next: List[Int64]
    var num_build: Int
    var bi_elided: Bool
    var fused: Bool
    # PAYLOAD-INLINE: `key_next` holds FOUR words per build row
    # -- [4i] key, [4i+1] link, [4i+2] a copy of ONE build column, [4i+3] pad --
    # so the probe's existing chain touch yields the payload and the downstream
    # random gather out of that column is deleted. Implies `fused`.
    var pay_inline: Bool
    var capacity: Int

    def __init__(
        out self,
        var build_keys: List[Int64],
        var build_indices: List[Int],
        var hash_table: List[Int],
        var next_chain: List[Int],
        capacity: Int,
        var key_next: List[Int64] = List[Int64](),
        num_build: Int = -1,
        bi_elided: Bool = False,
        fused: Bool = False,
        pay_inline: Bool = False,
    ):
        var n_rows = num_build if num_build >= 0 else len(build_keys)
        self.build_keys = build_keys^
        self.build_indices = build_indices^
        self.hash_table = hash_table^
        self.next_chain = next_chain^
        self.key_next = key_next^
        self.num_build = n_rows
        self.bi_elided = bi_elided
        self.fused = fused
        self.pay_inline = pay_inline
        self.capacity = capacity

    # Swap-out extractors: move the field out and leave an empty
    # valid List behind, so `self` stays whole and the caller can drop it without
    # a "field destroyed out of the middle of a value" partial-move error. NEVER
    # `UnsafePointer(to=self.field).take_pointee()`.

    def take_build_keys(mut self) -> List[Int64]:
        var v = self.build_keys^
        self.build_keys = List[Int64]()
        return v^

    def take_build_indices(mut self) -> List[Int]:
        var v = self.build_indices^
        self.build_indices = List[Int]()
        return v^

    def take_hash_table(mut self) -> List[Int]:
        var v = self.hash_table^
        self.hash_table = List[Int]()
        return v^

    def take_next_chain(mut self) -> List[Int]:
        var v = self.next_chain^
        self.next_chain = List[Int]()
        return v^

    def take_key_next(mut self) -> List[Int64]:
        var v = self.key_next^
        self.key_next = List[Int64]()
        return v^


# =============================================================================
# Single owned build state (no borrowed mutable buffers)
# =============================================================================


struct ChainBuildState(KeepAlive):
    """The one state the build dispatch runs over. OWNS the source key column,
    the `build_keys` / `build_indices` output arrays, the `hash_table` chain
    heads, the `next_chain` links, the atomic morsel counter and the
    `workers_active` witness.

    Fork-join contract:
      * `build_keys[i]` / `build_indices[i]` / `next_chain[i]` (or the fused
        record of row `i`) are written by exactly the worker owning build row
        `i` (disjoint) and never read during the build. The ONLY contended
        location is the `hash_table[slot]` chain head, updated by lock-free
        atomic compare-exchange.
      * `morsel_counter` serialises morsel claims.

    TWO DISPATCHES when the chain-head fill is fanned (`ChainFillTask`, then
    the insert task), with `reset_phase()` rewinding the counter between
    them at the barrier; ONE when the driver fills the table itself.
    Multiple dispatches per operator call are safe on this substrate.

    A stuck dispatch does not park the driver: the barrier spins in 1 ms
    waits and prints one `[BARRIER-STALL]` line after ~10 s. Triage a wedge
    by that line and a spinning driver, not by a parked one.
    """

    var num_build_morsels: Int
    var morsel_size: Int
    var n: Int
    var mask: UInt64
    var has_nulls: Bool
    # `cap` is the chain-head table's OWN slot count, NOT `Int(mask) + 1`. The
    # same value today (`cap` is a power of two), but reconstructing it from
    # the MASK would couple this wave's region geometry to the hashing.
    var cap: Int
    # The fill grain in SLOTS and the morsel count derived FROM IT. Both
    # resolved ONCE by the driver (`ht_fill_morsel_slots()`) and read by every
    # worker from here, so driver and workers cannot disagree about the tiling.
    # Zero `num_fill_morsels` == the fan declined; the driver did the `memset`.
    var fill_morsel: Int
    var num_fill_morsels: Int
    var keys: PrimitiveArray[DType.int64]
    var build_keys: List[Int64]
    var build_indices: List[Int]
    # `hash_table` is the builders' OWN `List[Int]`, CAS'd through a
    # `bitcast[Scalar[DType.int64]]` of its data pointer (`Int` and `Int64` are
    # layout-identical on every supported target). An earlier revision kept a
    # separate `List[Int64]` and converted in `take_buffers`, a driver-serial
    # read and write of the whole table after the parallel wave. Building in
    # place deletes that pass.
    var hash_table: List[Int]
    var next_chain: List[Int]
    # CHAIN-ENTRY LAYOUT: the FUSED alternative to the
    # `build_keys` + `next_chain` pair. Pre-sized to `2 * n` and written by the
    # build wave iff the driver chose that layout; empty otherwise. WHICH arrays
    # a worker writes is a COMPTIME parameter of `_ChainBuildTask`, not a field,
    # so the default arm's build loop is byte-for-byte the pre-lever one.
    var key_next: List[Int64]
    # The chosen layout, recorded so `take_buffers` STATES it rather than
    # inferring it from a length -- an inferred flag is wrong for n == 0, where
    # every array is legitimately empty on every arm.
    var elide_bi: Bool
    var fused_layout: Bool
    # PAYLOAD-INLINE. The build-side column being copied into
    # word 2 of each 32-byte entry, one Int64 per build row; EMPTY when the
    # layout is the shipped 16-byte one. Read-only across the fork-join window.
    var pay_values: List[Int64]
    var morsel_counter: OwnedPointer[AtomicI64]
    var workers_active: OwnedPointer[AtomicI64]

    def __init__(
        out self,
        num_build_morsels: Int,
        morsel_size: Int,
        n: Int,
        mask: UInt64,
        has_nulls: Bool,
        cap: Int,
        fill_morsel: Int,
        num_fill_morsels: Int,
        var keys: PrimitiveArray[DType.int64],
        var build_keys: List[Int64],
        var build_indices: List[Int],
        var hash_table: List[Int],
        var next_chain: List[Int],
        var key_next: List[Int64],
        elide_bi: Bool,
        fused_layout: Bool,
        var pay_values: List[Int64] = List[Int64](),
    ):
        self.num_build_morsels = num_build_morsels
        self.morsel_size = morsel_size
        self.n = n
        self.mask = mask
        self.has_nulls = has_nulls
        self.cap = cap
        self.fill_morsel = fill_morsel
        self.num_fill_morsels = num_fill_morsels
        self.keys = keys^
        self.build_keys = build_keys^
        self.build_indices = build_indices^
        self.hash_table = hash_table^
        self.next_chain = next_chain^
        self.key_next = key_next^
        self.elide_bi = elide_bi
        self.fused_layout = fused_layout
        self.pay_values = pay_values^
        # SAFETY: one `AtomicI64` cell, zero-initialised on the next line, then
        # handed to the `OwnedPointer` that owns and frees it.
        var raw = alloc[AtomicI64](1)
        raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
        self.morsel_counter = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw
        )
        # SAFETY: as `raw`: one zero-initialised cell owned by `workers_active`.
        var raw2 = alloc[AtomicI64](1)
        raw2.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
        self.workers_active = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw2
        )

    def take_buffers(mut self) raises -> ChainBuildBuffers:
        """Extract the owned build buffers.

        Uses the swap-out idiom (move each field out, leave an empty valid List)
        so `self` stays whole — the caller consumes it afterwards without a
        partial-move destroy error."""
        var bk = self.build_keys^
        self.build_keys = List[Int64]()
        var bi = self.build_indices^
        self.build_indices = List[Int]()
        var ht = self.hash_table^
        self.hash_table = List[Int]()
        var nc = self.next_chain^
        self.next_chain = List[Int]()
        var kn = self.key_next^
        self.key_next = List[Int64]()
        var cap = len(ht)
        # ⚠ Read the flags BEFORE the moves below consume the lists.
        var elided = self.elide_bi
        var fused = self.fused_layout
        var rows = self.n
        # PAYLOAD-INLINE is inferred from the ENTRY WIDTH the wave ACTUALLY
        # WROTE, not from a second flag: `key_next` is `kn_words * n` long by
        # construction, so this cannot disagree with the layout the tasks used.
        # ⚠ Read BEFORE the move below consumes `kn`.
        var pay = fused and rows > 0 and len(kn) == JOIN_KN_WORDS_PAY * rows
        return ChainBuildBuffers(
            bk^,
            bi^,
            ht^,
            nc^,
            cap,
            key_next=kn^,
            num_build=rows,
            bi_elided=elided,
            fused=fused,
            pay_inline=pay,
        )

    def reset_phase(mut self):
        """Rewind the morsel counter + worker-span witness between the FILL wave
        and the BUILD wave, so the build claims morsels from 0 and records its
        OWN span.

        SAFE ONLY AT A BARRIER. `run_with_state` has returned, every fill worker
        has finished, and the driver thread is the sole writer — the same
        precondition every multi-wave state's rewind states."""
        self.morsel_counter[].store(Scalar[DType.int64](0))
        self.workers_active[].store(Scalar[DType.int64](0))


# =============================================================================
# Phase FILL — the chain-head table initialisation, off the driver
# =============================================================================


@fieldwise_init
struct ChainFillTask(Segment):
    """Fill the chain-head table with `_CHAIN_END`, one disjoint slot range per
    claimed morsel. Memory-bandwidth + first-touch-page-fault bound; both fan
    out linearly.

    Fork-join contract:
      * Every write is DISJOINT: morsel `m` owns the half-open slot range
        `[m*M, min((m+1)*M, cap))`, and those ranges PARTITION `[0, cap)`.
      * NOTHING is read, so there is no ordering constraint between morsels and
        the resulting table is independent of claim order — which is what makes
        this byte-identical to the driver's single `memset`.
      * `hash_table` is pre-sized by the driver
        (`resize(unsafe_uninit_length=cap)`) and never grows during the wave.

    ⚠ THE TABLE IS UNINITIALISED ON ENTRY. This wave is what initialises it, and
    the BUILD wave that follows READS `ht[slot]` as its Treiber `old`. A gap
    here is a garbage chain head, and because `resize(unsafe_uninit_length=)`
    hands back a recycled allocation whose slots hold plausible in-range row
    indices, the failure mode is a SILENT WRONG ANSWER, not a segfault, so the
    falsifier for this wave is poison-and-read-back, never the result batch.

    The wave is stamped with its own site id, `SITE_JOIN_HT_FILL`, not the id
    of the insert wave it precedes, so the fill's fork span is not folded into
    the row a reader uses to judge whether the fill left the driver."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: `run_with_state` erases the concrete state type; the driver
        # below is the only dispatcher of this Segment and always pairs it with
        # `ChainBuildState`. Borrowed for the fork-join window only.
        var sp = UnsafePointer(to=state).bitcast[ChainBuildState]()
        var num_fill = sp[].num_fill_morsels
        # THE STATE'S OWN `cap` and `fill_morsel` — the SAME fields the driver
        # derived `num_fill_morsels` from. See those fields' declarations.
        var cap = sp[].cap
        var M = sp[].fill_morsel
        # SAFETY: the chain-head table is the builders' `List[Int]`, owned by the
        # borrowed state and pre-sized to `cap`; the pointer never leaves this
        # method.
        var ht_ptr = sp[].hash_table.unsafe_ptr()

        var did_work = False
        while True:
            var idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
            if idx >= num_fill:
                break
            if not did_work:
                did_work = True
                _ = sp[].workers_active[].fetch_add(Int64(1))
            var start = idx * M
            var end = min(start + M, cap)
            if end <= start:
                continue
            # `_CHAIN_END` is -1 == all-ones, so a 0xFF byte fill materialises it
            # exactly — the identical bytes the driver's single `memset` writes.
            # SAFETY: `[start, end)` is this morsel's disjoint slot range inside
            # the owned, pre-sized table.
            memset(
                (ht_ptr + start).bitcast[UInt8](),
                UInt8(0xFF),
                (end - start) * 8,
            )


