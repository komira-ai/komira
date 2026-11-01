# =============================================================================
# join_multi_key_filter -- the composite-key SEMI and ANTI probes, free
# functions over a `MultiKeyHashJoinBuilder`. Each returns the probe row
# indices it keeps, in probe order.
# =============================================================================
#
# SEMI keeps a probe row with at least one match (the chain walk stops at the
# first); ANTI keeps a probe row with none. A probe row with a NULL key matches
# nothing: SEMI drops it, ANTI keeps it. (This is the hash join's NULL rule; a
# NOT IN anti-join, where one NULL on the build side empties the result, is the
# caller's to plan.)
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray

from .join_multi_key import (
    MK_ARM_DICT,
    MK_ARM_INT,
    MK_ARM_MIXED,
    MK_ARM_STRING,
    MultiKeyColumns,
    _CHAIN_END,
    _NAN_SENTINEL_BITS,
    _composite_hash_int64,
    _string_bytes_equal,
    _null_ptr,
    mk_uniform_arm,
)
from .join_multi_key_builder import MultiKeyHashJoinBuilder


def multi_key_probe_semi(
    ref builder: MultiKeyHashJoinBuilder,
    probe_keys: MultiKeyColumns,
) raises -> List[Int]:
    """Semi-join: the probe rows with at least one build match, in order."""
    var n_keys = builder._num_keys
    if probe_keys.num_keys != n_keys:
        raise Error(
            "multi_key_probe_semi: probe key count "
            + String(probe_keys.num_keys)
            + " != build key count "
            + String(n_keys)
        )
    var n = probe_keys.int_keys.value()[0].length
    var result = List[Int](capacity=min(n, builder._num_inserted))
    var mask = UInt64(builder._capacity - 1)

    # SAFETY: per-key probe and build pointers, each re-tagged with the
    # origin of the container it was read from; `probe_keys` and
    # `builder` are borrowed for the whole call, and the keepalives at
    # the end pin every pointer past the loop. None leaves this function.
    comptime po = origin_of(probe_keys.int_keys.value())
    comptime bo = origin_of(builder._build_keys)
    comptime pso = origin_of(probe_keys.string_keys.value())
    comptime bso = origin_of(builder._build_string_keys)
    comptime pdo = origin_of(probe_keys.dict_keys.value())
    comptime bdo = origin_of(builder._build_dict_keys)
    var probe_ptrs = List[UnsafePointer[Scalar[DType.int64], po]]()
    var build_ptrs = List[UnsafePointer[Scalar[DType.int64], bo]]()
    var is_string = List[Bool]()
    var p_str_offs = List[UnsafePointer[Scalar[DType.int32], pso]]()
    var p_str_data = List[UnsafePointer[Scalar[DType.uint8], pso]]()
    var b_str_offs = List[UnsafePointer[Scalar[DType.int32], bso]]()
    var b_str_data = List[UnsafePointer[Scalar[DType.uint8], bso]]()
    var is_same_dict = List[Bool]()
    var p_dict_idx = List[UnsafePointer[Scalar[DType.int32], pdo]]()
    var b_dict_idx = List[UnsafePointer[Scalar[DType.int32], bdo]]()
    for k in range(n_keys):
        ref pref = probe_keys.int_keys.value()[k]
        probe_ptrs.append(
            pref.view_ro()
                ._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[po.mut]()
                .unsafe_origin_cast[po]()
        )
        _ = pref
        ref bref = builder._build_keys[k]
        build_ptrs.append(
            bref.view_ro()
                ._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[bo.mut]()
                .unsafe_origin_cast[bo]()
        )
        _ = bref
        ref pstr_slot = probe_keys.string_keys.value()[k]
        ref bstr_slot = builder._build_string_keys[k]
        if pstr_slot.__bool__() and bstr_slot.__bool__():
            is_string.append(True)
            ref pstr = pstr_slot.value()
            p_str_offs.append(
                pstr.offsets.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_mut_cast[pso.mut]()
                    .unsafe_origin_cast[pso]()
            )
            p_str_data.append(
                pstr.data.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.uint8]]()
                    .unsafe_mut_cast[pso.mut]()
                    .unsafe_origin_cast[pso]()
            )
            _ = pstr
            ref bstr = bstr_slot.value()
            b_str_offs.append(
                bstr.offsets.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_mut_cast[bso.mut]()
                    .unsafe_origin_cast[bso]()
            )
            b_str_data.append(
                bstr.data.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.uint8]]()
                    .unsafe_mut_cast[bso.mut]()
                    .unsafe_origin_cast[bso]()
            )
            _ = bstr
        else:
            is_string.append(False)
            p_str_offs.append(_null_ptr[Scalar[DType.int32], pso]())
            p_str_data.append(_null_ptr[Scalar[DType.uint8], pso]())
            b_str_offs.append(_null_ptr[Scalar[DType.int32], bso]())
            b_str_data.append(_null_ptr[Scalar[DType.uint8], bso]())
        _ = pstr_slot
        _ = bstr_slot
        ref pdict_slot = probe_keys.dict_keys.value()[k]
        ref bdict_slot = builder._build_dict_keys[k]
        var same_dict = False
        if pdict_slot.__bool__() and bdict_slot.__bool__():
            if probe_keys.dict_fingerprints.value()[k] == builder._build_dict_fingerprints[k]:
                same_dict = True
        is_same_dict.append(same_dict)
        if same_dict:
            ref pdict = pdict_slot.value()
            p_dict_idx.append(
                pdict.indices.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_mut_cast[pdo.mut]()
                    .unsafe_origin_cast[pdo]()
            )
            _ = pdict
            ref bdict = bdict_slot.value()
            b_dict_idx.append(
                bdict.indices.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_mut_cast[bdo.mut]()
                    .unsafe_origin_cast[bdo]()
            )
            _ = bdict
        else:
            p_dict_idx.append(_null_ptr[Scalar[DType.int32], pdo]())
            b_dict_idx.append(_null_ptr[Scalar[DType.int32], bdo]())
        _ = pdict_slot
        _ = bdict_slot

    var _arm_u = mk_uniform_arm(is_same_dict, is_string, n_keys)
    var ht_ptr = builder._hash_table.unsafe_ptr()
    var nc_ptr = builder._next_chain.unsafe_ptr()

    var probe_buf = List[Int64](capacity=n_keys)
    for _ in range(n_keys):
        probe_buf.append(Int64(0))
    var probe_buf_ptr = probe_buf.unsafe_ptr()

    for probe_idx in range(n):
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
        if not builder._bloom.check_hash(h):
            continue
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
                result.append(probe_idx)
                break
            chain_idx = (nc_ptr + chain_idx)[]

    _ = builder._hash_table
    _ = builder._next_chain
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
    return result^


def multi_key_probe_anti(
    ref builder: MultiKeyHashJoinBuilder,
    probe_keys: MultiKeyColumns,
) raises -> List[Int]:
    """Anti-join: the probe rows with no build match (a NULL key included),
    in order."""
    var n_keys = builder._num_keys
    if probe_keys.num_keys != n_keys:
        raise Error(
            "multi_key_probe_anti: probe key count "
            + String(probe_keys.num_keys)
            + " != build key count "
            + String(n_keys)
        )
    var n = probe_keys.int_keys.value()[0].length
    var result = List[Int](capacity=max(n // 64, 256))
    var mask = UInt64(builder._capacity - 1)

    # SAFETY: per-key probe and build pointers, each re-tagged with the
    # origin of the container it was read from; `probe_keys` and
    # `builder` are borrowed for the whole call, and the keepalives at
    # the end pin every pointer past the loop. None leaves this function.
    comptime po = origin_of(probe_keys.int_keys.value())
    comptime bo = origin_of(builder._build_keys)
    comptime pso = origin_of(probe_keys.string_keys.value())
    comptime bso = origin_of(builder._build_string_keys)
    comptime pdo = origin_of(probe_keys.dict_keys.value())
    comptime bdo = origin_of(builder._build_dict_keys)
    var probe_ptrs = List[UnsafePointer[Scalar[DType.int64], po]]()
    var build_ptrs = List[UnsafePointer[Scalar[DType.int64], bo]]()
    var is_string = List[Bool]()
    var p_str_offs = List[UnsafePointer[Scalar[DType.int32], pso]]()
    var p_str_data = List[UnsafePointer[Scalar[DType.uint8], pso]]()
    var b_str_offs = List[UnsafePointer[Scalar[DType.int32], bso]]()
    var b_str_data = List[UnsafePointer[Scalar[DType.uint8], bso]]()
    var is_same_dict = List[Bool]()
    var p_dict_idx = List[UnsafePointer[Scalar[DType.int32], pdo]]()
    var b_dict_idx = List[UnsafePointer[Scalar[DType.int32], bdo]]()
    for k in range(n_keys):
        ref pref = probe_keys.int_keys.value()[k]
        probe_ptrs.append(
            pref.view_ro()
                ._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[po.mut]()
                .unsafe_origin_cast[po]()
        )
        _ = pref
        ref bref = builder._build_keys[k]
        build_ptrs.append(
            bref.view_ro()
                ._unsafe_ptr()
                .bitcast[Scalar[DType.int64]]()
                .unsafe_mut_cast[bo.mut]()
                .unsafe_origin_cast[bo]()
        )
        _ = bref
        ref pstr_slot = probe_keys.string_keys.value()[k]
        ref bstr_slot = builder._build_string_keys[k]
        if pstr_slot.__bool__() and bstr_slot.__bool__():
            is_string.append(True)
            ref pstr = pstr_slot.value()
            p_str_offs.append(
                pstr.offsets.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_mut_cast[pso.mut]()
                    .unsafe_origin_cast[pso]()
            )
            p_str_data.append(
                pstr.data.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.uint8]]()
                    .unsafe_mut_cast[pso.mut]()
                    .unsafe_origin_cast[pso]()
            )
            _ = pstr
            ref bstr = bstr_slot.value()
            b_str_offs.append(
                bstr.offsets.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_mut_cast[bso.mut]()
                    .unsafe_origin_cast[bso]()
            )
            b_str_data.append(
                bstr.data.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.uint8]]()
                    .unsafe_mut_cast[bso.mut]()
                    .unsafe_origin_cast[bso]()
            )
            _ = bstr
        else:
            is_string.append(False)
            p_str_offs.append(_null_ptr[Scalar[DType.int32], pso]())
            p_str_data.append(_null_ptr[Scalar[DType.uint8], pso]())
            b_str_offs.append(_null_ptr[Scalar[DType.int32], bso]())
            b_str_data.append(_null_ptr[Scalar[DType.uint8], bso]())
        _ = pstr_slot
        _ = bstr_slot
        ref pdict_slot = probe_keys.dict_keys.value()[k]
        ref bdict_slot = builder._build_dict_keys[k]
        var same_dict = False
        if pdict_slot.__bool__() and bdict_slot.__bool__():
            if probe_keys.dict_fingerprints.value()[k] == builder._build_dict_fingerprints[k]:
                same_dict = True
        is_same_dict.append(same_dict)
        if same_dict:
            ref pdict = pdict_slot.value()
            p_dict_idx.append(
                pdict.indices.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_mut_cast[pdo.mut]()
                    .unsafe_origin_cast[pdo]()
            )
            _ = pdict
            ref bdict = bdict_slot.value()
            b_dict_idx.append(
                bdict.indices.view_ro()
                    ._unsafe_ptr()
                    .bitcast[Scalar[DType.int32]]()
                    .unsafe_mut_cast[bdo.mut]()
                    .unsafe_origin_cast[bdo]()
            )
            _ = bdict
        else:
            p_dict_idx.append(_null_ptr[Scalar[DType.int32], pdo]())
            b_dict_idx.append(_null_ptr[Scalar[DType.int32], bdo]())
        _ = pdict_slot
        _ = bdict_slot

    var _arm_u = mk_uniform_arm(is_same_dict, is_string, n_keys)
    var ht_ptr = builder._hash_table.unsafe_ptr()
    var nc_ptr = builder._next_chain.unsafe_ptr()

    var probe_buf = List[Int64](capacity=n_keys)
    for _ in range(n_keys):
        probe_buf.append(Int64(0))
    var probe_buf_ptr = probe_buf.unsafe_ptr()

    for probe_idx in range(n):
        var has_nan = False
        for k in range(n_keys):
            var v = Int64((probe_ptrs[k] + probe_idx)[])
            if v == _NAN_SENTINEL_BITS:
                has_nan = True
                break
            probe_buf[k] = v
        if has_nan:
            result.append(probe_idx)
            continue

        var h = _composite_hash_int64(probe_buf_ptr, n_keys)
        var slot = Int(h & mask)
        var chain_idx = (ht_ptr + slot)[]
        var found = False
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
                found = True
                break
            chain_idx = (nc_ptr + chain_idx)[]
        if not found:
            result.append(probe_idx)

    _ = builder._hash_table
    _ = builder._next_chain
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
    return result^
