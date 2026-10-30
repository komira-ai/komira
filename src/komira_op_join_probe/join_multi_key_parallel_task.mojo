# =============================================================================
# join_multi_key_parallel_task -- one worker's share of the parallel
# composite-key INNER probe: the shared probe state and the task each worker
# runs over the morsels it claims.
# =============================================================================
#
# A worker claims probe morsels from one atomic counter and walks each row's
# chain with the builder's equality arms (`join_multi_key_builder`), writing
# its matches into its own pair of output lists through a cached cursor (one
# length, one capacity, both lists grown together by `_mk_grow_output_pair`).
#
# THE BATCHED WALK (the default, `mk_probe_batch_width()` rows). The worker
# seeds up to B probe rows' chain heads, then advances all live chains one step
# per round: gather each candidate, compare, emit, compact the rows still
# walking. Rounds of B independent loads let the memory system overlap the
# misses a row-at-a-time walk serialises. A width of 0 selects the row-at-a-time
# walk. Both emit the same pairs; within a morsel the batched walk emits a
# row's matches in chain order but interleaves rows by round.
#
# THE BLOOM LATCH. Over its first `bloomsel_window_rows()` probe rows a task
# counts how many the bloom admits; if the pass rate reaches
# `bloomsel_pass_pct()` percent (the bloom rejects almost nothing), the task
# stops consulting it (`komira_op_join_build.join_bloom_selectivity`).
# Unconfigured, the window is 0 and the bloom is always consulted.
# =============================================================================

from std.atomic import Atomic
from std.memory import alloc, OwnedPointer, UnsafePointer

from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_collections.slab import Slab
from komira_op_join_build.join_bloom_selectivity import (
    bloomsel_note_disarmed,
    bloomsel_note_kept,
    bloomsel_note_saved,
    bloomsel_pass_pct,
    bloomsel_should_disarm,
    bloomsel_trace_enabled,
    bloomsel_window_rows,
    bloomsel_witness,
)

from .join_multi_key import (
    MK_ARM_DICT,
    MK_ARM_INT,
    MK_ARM_MIXED,
    MK_ARM_STRING,
    MultiKeyColumns,
    _CHAIN_END,
    _NAN_SENTINEL_BITS,
    _composite_hash_int64,
    _null_ptr,
    _string_bytes_equal,
    mk_uniform_arm,
)
from .join_multi_key_builder import MultiKeyHashJoinBuilder


@no_inline
def _mk_grow_output_pair(
    mut lb: List[Int], mut lp: List[Int], cur_len: Int
) raises -> Int:
    """Publish `cur_len` cursor-written elements on BOTH lists and grow both.

    Returns:
        The new shared capacity. This is the REQUESTED size, not
        `List.capacity()`: an allocator that rounds up gives both lists at
        least this much, so using the request is conservative in the safe
        direction (the cursor stops early, never late).
    """
    lb.resize(unsafe_uninit_length=cur_len)
    lp.resize(unsafe_uninit_length=cur_len)
    var want = cur_len * 2
    if want < cur_len + 4096:
        want = cur_len + 4096
    lb.reserve(want)
    lp.reserve(want)
    return want



struct MultiKeyParallelProbeState[
    probe_origin: ImmOrigin,
    builder_origin: ImmOrigin,
](KeepAlive):
    """The shared state of one parallel composite probe: the morsel geometry,
    the borrowed builder and probe keys, one output-list pair per worker and
    the morsel counter."""
    var num_morsels: Int
    var morsel_size: Int
    var num_probe_rows: Int
    var n_keys: Int
    var mask: UInt64

    var worker_cap: Int
    var batch_width: Int

    var worker_build: Slab[List[Int]]
    var worker_probe: Slab[List[Int]]

    var builder: Pointer[MultiKeyHashJoinBuilder, Self.builder_origin]
    var probe_keys: Pointer[MultiKeyColumns, Self.probe_origin]

    var morsel_counter: OwnedPointer[Atomic[DType.int64]]

    def __init__(
        out self,
        num_morsels: Int,
        morsel_size: Int,
        num_probe_rows: Int,
        n_keys: Int,
        mask: UInt64,
        worker_cap: Int,
        batch_width: Int,
        var worker_build: Slab[List[Int]],
        var worker_probe: Slab[List[Int]],
        builder: Pointer[MultiKeyHashJoinBuilder, Self.builder_origin],
        probe_keys: Pointer[MultiKeyColumns, Self.probe_origin],
    ):
        self.num_morsels = num_morsels
        self.morsel_size = morsel_size
        self.num_probe_rows = num_probe_rows
        self.n_keys = n_keys
        self.mask = mask
        self.worker_cap = worker_cap
        self.batch_width = batch_width
        self.worker_build = worker_build^
        self.worker_probe = worker_probe^
        self.builder = builder
        self.probe_keys = probe_keys
        var raw = alloc[Atomic[DType.int64]](1)
        UnsafePointer(to=raw[].value).unsafe_write(
            Scalar[DType.int64](0)
        )
        self.morsel_counter = OwnedPointer[Atomic[DType.int64]](
            unsafe_from_raw_pointer=raw
        )


@fieldwise_init
struct MultiKeyParallelProbeTask[
    probe_origin: ImmOrigin,
    builder_origin: ImmOrigin,
](Segment):
    """One worker's probe: claim morsels until none are left, emit matches into
    the worker's own output lists."""
    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        # SAFETY: parallel_multi_key_inner_probe_into dispatches with
        # run_with_state[MultiKeyParallelProbeState[Self.probe_origin,
        # Self.builder_origin], ...]. The bitcast below recovers that
        # concrete State type.
        var sp = UnsafePointer(to=state).bitcast[
            MultiKeyParallelProbeState[Self.probe_origin, Self.builder_origin]
        ]()
        var wid = Int(task_id)
        var num_morsels = sp[].num_morsels
        var morsel_size = sp[].morsel_size
        var num_probe_rows = sp[].num_probe_rows
        var n_keys = sp[].n_keys
        var mask = sp[].mask

        ref b = sp[].builder[]
        ref pk = sp[].probe_keys[]

        var ht_ptr = b._hash_table.unsafe_ptr()
        var nc_ptr = b._next_chain.unsafe_ptr()

        # SAFETY: per-key pointers re-tagged with the state's two origins (the
        # probe keys and the builder the driver borrows for the whole
        # dispatch); none leaves this task.
        comptime po = Self.probe_origin
        comptime bo = Self.builder_origin
        var probe_ptrs = List[UnsafePointer[Scalar[DType.int64], po]]()
        var build_ptrs = List[UnsafePointer[Scalar[DType.int64], bo]]()
        var is_string = List[Bool]()
        var p_str_offs = List[UnsafePointer[Scalar[DType.int32], po]]()
        var p_str_data = List[UnsafePointer[Scalar[DType.uint8], po]]()
        var b_str_offs = List[UnsafePointer[Scalar[DType.int32], bo]]()
        var b_str_data = List[UnsafePointer[Scalar[DType.uint8], bo]]()
        var is_same_dict = List[Bool]()
        var p_dict_idx = List[UnsafePointer[Scalar[DType.int32], po]]()
        var b_dict_idx = List[UnsafePointer[Scalar[DType.int32], bo]]()

        for k in range(n_keys):
            ref pref = pk.int_keys.value()[k]
            probe_ptrs.append(
                pref._typed_ptr_ro()
                    .unsafe_mut_cast[po.mut]()
                    .unsafe_origin_cast[po]()
            )
            _ = pref
            ref bref = b._build_keys[k]
            build_ptrs.append(
                bref._typed_ptr_ro()
                    .unsafe_mut_cast[bo.mut]()
                    .unsafe_origin_cast[bo]()
            )
            _ = bref
            ref pstr_slot = pk.string_keys.value()[k]
            ref bstr_slot = b._build_string_keys[k]
            if pstr_slot.__bool__() and bstr_slot.__bool__():
                is_string.append(True)
                ref pstr = pstr_slot.value()
                p_str_offs.append(
                    pstr.offsets.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[po.mut]()
                        .unsafe_origin_cast[po]()
                )
                p_str_data.append(
                    pstr.data.view_ro()
                        ._unsafe_ptr()
                        .unsafe_mut_cast[po.mut]()
                        .unsafe_origin_cast[po]()
                )
                _ = pstr
                ref bstr = bstr_slot.value()
                b_str_offs.append(
                    bstr.offsets.view_ro()
                        ._unsafe_ptr()
                        .bitcast[Scalar[DType.int32]]()
                        .unsafe_mut_cast[bo.mut]()
                        .unsafe_origin_cast[bo]()
                )
                b_str_data.append(
                    bstr.data.view_ro()
                        ._unsafe_ptr()
                        .unsafe_mut_cast[bo.mut]()
                        .unsafe_origin_cast[bo]()
                )
                _ = bstr
            else:
                is_string.append(False)
                p_str_offs.append(_null_ptr[Scalar[DType.int32], po]())
                p_str_data.append(_null_ptr[Scalar[DType.uint8], po]())
                b_str_offs.append(_null_ptr[Scalar[DType.int32], bo]())
                b_str_data.append(_null_ptr[Scalar[DType.uint8], bo]())
            _ = pstr_slot
            _ = bstr_slot
            ref pdict_slot = pk.dict_keys.value()[k]
            ref bdict_slot = b._build_dict_keys[k]
            var same_dict = False
            if pdict_slot.__bool__() and bdict_slot.__bool__():
                if pk.dict_fingerprints.value()[k] == b._build_dict_fingerprints[k]:
                    same_dict = True
            is_same_dict.append(same_dict)
            if same_dict:
                ref pdict = pdict_slot.value()
                p_dict_idx.append(
                    pdict.indices._typed_ptr_ro()
                        .unsafe_mut_cast[po.mut]()
                        .unsafe_origin_cast[po]()
                )
                _ = pdict
                ref bdict = bdict_slot.value()
                b_dict_idx.append(
                    bdict.indices._typed_ptr_ro()
                        .unsafe_mut_cast[bo.mut]()
                        .unsafe_origin_cast[bo]()
                )
                _ = bdict
            else:
                p_dict_idx.append(_null_ptr[Scalar[DType.int32], po]())
                b_dict_idx.append(_null_ptr[Scalar[DType.int32], bo]())
            _ = pdict_slot
            _ = bdict_slot

        var _arm_u = mk_uniform_arm(is_same_dict, is_string, n_keys)
        var probe_buf = List[Int64](capacity=n_keys)
        for _ in range(n_keys):
            probe_buf.append(Int64(0))
        var probe_buf_ptr = probe_buf.unsafe_ptr()

        var bl_window = bloomsel_window_rows()
        var bl_pct = bloomsel_pass_pct()
        var bl_trace = bloomsel_trace_enabled()
        var bl_sampling = bl_window > 0
        var bl_active = True
        var bl_seen = 0
        var bl_passed = 0
        var bl_saved = 0

        # PER-WORKER OUTPUT CURSOR: this worker's two output lists, written
        # through a cached base pointer with one shared length and capacity.
        #
        # SAFETY (`Slab.get_mut_interior`): (1) worker `wid` touches only slot
        # `wid` (task ids are unique); (2) the Slabs are fields of the state and
        # the dispatch barrier ends every worker before the driver drops it;
        # (3) the Slabs are filled before the dispatch and never resized during
        # it; `_mk_grow_output_pair` reallocates the element List's buffer,
        # which does not move the slot, and the cursor re-reads the base
        # pointer after every growth; (4) no other thread reads slot `wid`
        # before the barrier.
        ref wb_list = sp[].worker_build.get_mut_interior(wid)
        ref wp_list = sp[].worker_probe.get_mut_interior(wid)
        if len(wb_list) != len(wp_list):
            raise Error(
                "MultiKeyParallelProbeTask: per-worker output lists out of"
                " sync at entry (build="
                + String(len(wb_list))
                + ", probe="
                + String(len(wp_list))
                + ")"
            )
        var out_len = len(wb_list)
        var out_cap = sp[].worker_cap
        if out_cap < out_len:
            out_cap = out_len
        # SAFETY: base pointers into the two per-worker lists. Not stored, not
        # returned, never crossing a module boundary; re-read after every
        # growth.
        var wb_ptr = wb_list.unsafe_ptr()
        var wp_ptr = wp_list.unsafe_ptr()

        var batch_w = sp[].batch_width

        if batch_w > 0:
            # PER-WORKER BATCH SCRATCH: four dense arrays of `batch_w` slots,
            # allocated once per task and never cleared (the active count is
            # the length), 25 bytes a slot (12.5 KB at the default width).
            #
            # SAFETY: function locals of `execute`, like `probe_buf` and the
            # output cursor: one per task, concrete origins, never stored,
            # returned or shared.
            var act_probe = List[Int](capacity=batch_w)
            var act_chain = List[Int](capacity=batch_w)
            var cand_brow = List[Int](capacity=batch_w)
            var match_flag = List[UInt8](capacity=batch_w)
            for _ in range(batch_w):
                act_probe.append(0)
                act_chain.append(0)
                cand_brow.append(0)
                match_flag.append(UInt8(0))
            var ap_ptr = act_probe.unsafe_ptr()
            var ac_ptr = act_chain.unsafe_ptr()
            var cb_ptr = cand_brow.unsafe_ptr()
            var mf_ptr = match_flag.unsafe_ptr()

            while True:
                var morsel_idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
                if morsel_idx >= num_morsels:
                    break

                var start = morsel_idx * morsel_size
                var end = min(start + morsel_size, num_probe_rows)

                var seg_start = start
                while seg_start < end:
                    var seg_end = min(seg_start + batch_w, end)

                    var n_act = 0
                    for probe_idx in range(seg_start, seg_end):
                        var has_nan = False
                        for k in range(n_keys):
                            var v = Int64((probe_ptrs[k] + probe_idx)[])
                            if v == _NAN_SENTINEL_BITS:
                                has_nan = True
                                break
                            probe_buf[k] = v
                        if has_nan:
                            continue


                        var h = _composite_hash_int64(probe_buf_ptr, n_keys)
                        if bl_active:
                            var bl_ok = b._bloom.check_hash(h)
                            if bl_sampling:
                                bl_seen += 1
                                if bl_ok:
                                    bl_passed += 1
                                if bl_seen >= bl_window:
                                    bl_sampling = False
                                    if bloomsel_should_disarm(
                                        bl_passed, bl_seen, bl_pct
                                    ):
                                        bl_active = False
                                        bloomsel_note_disarmed()
                                    else:
                                        bloomsel_note_kept()
                            if not bl_ok:
                                continue
                        else:
                            bl_saved += 1

                        var head = (ht_ptr + Int(h & mask))[]
                        if head == _CHAIN_END:
                            continue
                        (ap_ptr + n_act)[] = probe_idx
                        (ac_ptr + n_act)[] = head
                        n_act += 1

                    while n_act > 0:
                        for j in range(n_act):
                            var cur = (ac_ptr + j)[]
                            (cb_ptr + j)[] = cur
                            (ac_ptr + j)[] = (nc_ptr + cur)[]

                        for j in range(n_act):
                            var brow = (cb_ptr + j)[]
                            var probe_idx = (ap_ptr + j)[]
                            var matched = True
                            if _arm_u == MK_ARM_INT:
                                for k in range(n_keys):
                                    if Int64((build_ptrs[k] + brow)[]) != Int64(
                                        (probe_ptrs[k] + probe_idx)[]
                                    ):
                                        matched = False
                                        break
                            elif _arm_u == MK_ARM_STRING:
                                for k in range(n_keys):
                                    if not _string_bytes_equal(
                                        p_str_offs[k], p_str_data[k], probe_idx,
                                        b_str_offs[k], b_str_data[k], brow,
                                    ):
                                        matched = False
                                        break
                            elif _arm_u == MK_ARM_DICT:
                                for k in range(n_keys):
                                    if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                                        matched = False
                                        break
                            else:
                                for k in range(n_keys):
                                    if is_same_dict[k]:
                                        if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                                            matched = False
                                            break
                                    elif is_string[k]:
                                        if not _string_bytes_equal(
                                            p_str_offs[k], p_str_data[k], probe_idx,
                                            b_str_offs[k], b_str_data[k], brow,
                                        ):
                                            matched = False
                                            break
                                    else:
                                        if Int64((build_ptrs[k] + brow)[]) != Int64(
                                            (probe_ptrs[k] + probe_idx)[]
                                        ):
                                            matched = False
                                            break
                            (mf_ptr + j)[] = UInt8(1) if matched else UInt8(0)


                        for j in range(n_act):
                            if (mf_ptr + j)[] != UInt8(0):
                                if out_len >= out_cap:
                                    out_cap = _mk_grow_output_pair(
                                        wb_list, wp_list, out_len
                                    )
                                    wb_ptr = wb_list.unsafe_ptr()
                                    wp_ptr = wp_list.unsafe_ptr()
                                (wb_ptr + out_len)[] = (cb_ptr + j)[]
                                (wp_ptr + out_len)[] = (ap_ptr + j)[]
                                out_len += 1

                        var w = 0
                        for j in range(n_act):
                            if (ac_ptr + j)[] != _CHAIN_END:
                                (ap_ptr + w)[] = (ap_ptr + j)[]
                                (ac_ptr + w)[] = (ac_ptr + j)[]
                                w += 1
                        n_act = w

                    seg_start = seg_end

            _ = act_probe
            _ = act_chain
            _ = cand_brow
            _ = match_flag
        else:
            while True:
                var morsel_idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
                if morsel_idx >= num_morsels:
                    break

                var start = morsel_idx * morsel_size
                var end = min(start + morsel_size, num_probe_rows)

                for probe_idx in range(start, end):
                    var has_nan = False
                    for k in range(n_keys):
                        var v = Int64((probe_ptrs[k] + probe_idx)[])
                        if v == _NAN_SENTINEL_BITS:
                            has_nan = True
                            break
                        probe_buf[k] = v
                    if has_nan:
                        continue


                    var h = _composite_hash_int64(probe_buf_ptr, n_keys)
                    if bl_active:
                        var bl_ok = b._bloom.check_hash(h)
                        if bl_sampling:
                            bl_seen += 1
                            if bl_ok:
                                bl_passed += 1
                            if bl_seen >= bl_window:
                                bl_sampling = False
                                if bloomsel_should_disarm(
                                    bl_passed, bl_seen, bl_pct
                                ):
                                    bl_active = False
                                    bloomsel_note_disarmed()
                                else:
                                    bloomsel_note_kept()
                        if not bl_ok:
                            continue
                    else:
                        bl_saved += 1

                    var slot = Int(h & mask)
                    var chain_idx = (ht_ptr + slot)[]
                    while chain_idx != _CHAIN_END:
                        var brow = chain_idx
                        var matched = True
                        if _arm_u == MK_ARM_INT:
                            for k in range(n_keys):
                                if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                                    matched = False
                                    break
                        elif _arm_u == MK_ARM_STRING:
                            for k in range(n_keys):
                                if not _string_bytes_equal(
                                    p_str_offs[k], p_str_data[k], probe_idx,
                                    b_str_offs[k], b_str_data[k], brow,
                                ):
                                    matched = False
                                    break
                        elif _arm_u == MK_ARM_DICT:
                            for k in range(n_keys):
                                if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                                    matched = False
                                    break
                        else:
                            for k in range(n_keys):
                                if is_same_dict[k]:
                                    if (p_dict_idx[k] + probe_idx)[] != (b_dict_idx[k] + brow)[]:
                                        matched = False
                                        break
                                elif is_string[k]:
                                    if not _string_bytes_equal(
                                        p_str_offs[k], p_str_data[k], probe_idx,
                                        b_str_offs[k], b_str_data[k], brow,
                                    ):
                                        matched = False
                                        break
                                else:
                                    if Int64((build_ptrs[k] + brow)[]) != probe_buf[k]:
                                        matched = False
                                        break
                        if matched:
                            if out_len >= out_cap:
                                out_cap = _mk_grow_output_pair(
                                    wb_list, wp_list, out_len
                                )
                                wb_ptr = wb_list.unsafe_ptr()
                                wp_ptr = wp_list.unsafe_ptr()
                            (wb_ptr + out_len)[] = brow
                            (wp_ptr + out_len)[] = probe_idx
                            out_len += 1
                        chain_idx = (nc_ptr + chain_idx)[]

        wb_list.resize(unsafe_uninit_length=out_len)
        wp_list.resize(unsafe_uninit_length=out_len)

        bloomsel_note_saved(bl_saved)
        if bl_trace:
            bloomsel_witness(
                wid, bl_window, bl_pct, bl_seen, bl_passed,
                not bl_active, bl_saved,
            )


        _ = probe_buf
        _ = probe_ptrs
        _ = build_ptrs
        _ = p_str_offs
        _ = p_str_data
        _ = b_str_offs
        _ = b_str_data
        _ = is_string
        _ = p_dict_idx
        _ = b_dict_idx
        _ = is_same_dict
