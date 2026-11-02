# =============================================================================
# join_key_extract -- render a batch's join-key columns into the composite
# join's key slots (`MultiKeyColumns`), and the parallel string-key hash wave.
# =============================================================================
#
# This is the ONLY place a NULL key is encoded: nullness is read from each
# column's validity bitmap and written as `_NAN_SENTINEL_BITS`, the one value
# every composite build and probe loop skips (`join_multi_key`'s header). An
# INT64 column without a validity bitmap passes through uncopied.
#
# A key pair of an integer and a FLOAT64 compares as FLOAT64, as DuckDB casts
# it: `join_key_pairs_as_float64` says which pairs, and the extraction renders
# their integer side as FLOAT64 keys. A STRING key against a numeric key is
# refused there.
#
# The string hash wave tiles rows into chunks (about four per physical core,
# at least 4,096 rows, and one chunk below 65,536 rows); each chunk writes only
# its own rows' slots.
# =============================================================================

from std.memory import UnsafePointer
from std.sys import num_physical_cores
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.record_batch import RecordBatch
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_async_api.fork_join_shared import fork_join_shared
from komira_async_api.parallel_dispatch import (
    NoDispatch,
    ParallelDispatch,
)
from komira_async_api.shared_chunk_work import SharedChunkWork

from komira_async.runtime.sched_trace import (
    PHASE_JOINKEY_AS_STRING,
    PHASE_JOINKEY_FNV,
    SITE_JOINKEY_HASH,
    sched_trace_add_serial_phase,
    sched_trace_enabled,
    sched_trace_fork_ns_now,
)

from .join_multi_key import (
    MultiKeyColumns,
    _NAN_SENTINEL_BITS,
    _canonicalize_float64_for_hash,
    _decode_dict_to_string_array,
    _fnv1a_hash_bytes,
)


comptime _KEYHASH_MIN_PARALLEL_ROWS: Int = 65_536

comptime _KEYHASH_CHUNKS_PER_CORE: Int = 4

comptime _KEYHASH_MIN_CHUNK_ROWS: Int = 4_096


struct _KeyHashSlots(Movable, Deinitable):
    """Shared payload: the Int64 hash-slot array every chunk scatters into."""

    var slots: Optional[PrimitiveArray[DType.int64]]

    def __init__(out self, var slots: PrimitiveArray[DType.int64]):
        self.slots = Optional[PrimitiveArray[DType.int64]](slots^)


@fieldwise_init
struct _KeyHashWork(SharedChunkWork):
    """Chunk `c` FNV-1a hashes source rows `[chunk_lo[c], chunk_lo[c+1])` into
    the SAME slots of the payload's Int64 array.
    """

    var chunk_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver below instantiates `fork_join_shared` with
        # In=StringArray[HeapRegion] and P=_KeyHashSlots; the bitcasts recover
        # those concrete types. Neither pointer escapes this function.
        var sp = UnsafePointer(to=input).bitcast[StringArray[HeapRegion]]()
        var bp = UnsafePointer(to=payload).bitcast[_KeyHashSlots]()

        var off_view = sp[].offsets.view_ro()
        var off_ptr = off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var data_view = sp[].data.view_ro()
        var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
        var has_validity = sp[].validity.__bool__()

        var dst_view = bp[].slots.value().view_mut()
        var dst = dst_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()

        var lo = self.chunk_lo[chunk_id]
        var hi = self.chunk_lo[chunk_id + 1]
        for r in range(lo, hi):
            if has_validity and not sp[].validity.value().test(r):
                dst[r] = _NAN_SENTINEL_BITS
            else:
                var s_start = Int((off_ptr + r)[])
                var s_end = Int((off_ptr + r + 1)[])
                var s_len = s_end - s_start
                var h = _fnv1a_hash_bytes(data_ptr + s_start, s_len)
                var h_i64 = Int64(h)
                if h_i64 == _NAN_SENTINEL_BITS:
                    dst[r] = Int64(0)
                else:
                    dst[r] = h_i64
        _ = off_view
        _ = data_view
        _ = dst_view


def key_hash_chunk_bounds(n: Int) -> List[Int]:
    """The chunk tiling for a key-hash wave over `n` rows: `n_chunks + 1`
    monotone bounds starting at 0 and ending at `n`.
    """
    var bounds = List[Int]()
    bounds.append(0)
    if n <= 0:
        return bounds^
    if n < _KEYHASH_MIN_PARALLEL_ROWS:
        bounds.append(n)
        return bounds^
    var nw = num_physical_cores()
    if nw < 1:
        nw = 1
    var target = nw * _KEYHASH_CHUNKS_PER_CORE
    var chunk_rows = (n + target - 1) // target
    if chunk_rows < _KEYHASH_MIN_CHUNK_ROWS:
        chunk_rows = _KEYHASH_MIN_CHUNK_ROWS
    var lo = 0
    while lo < n:
        var hi = lo + chunk_rows
        if hi > n:
            hi = n
        bounds.append(hi)
        lo = hi
    return bounds^


def hash_string_keys[
    in_o: ImmOrigin,
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    ref [in_o] src: StringArray[HeapRegion],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
) raises -> PrimitiveArray[DType.int64]:
    """Hash every row of `src` into a fresh Int64 slot array: a NULL row to
    `_NAN_SENTINEL_BITS`, and a row whose hash happens to equal the sentinel
    to 0 (so a real string is never read as NULL; the chain walk compares
    bytes, so the remap costs no correctness)."""
    var n = src.length
    var slots = PrimitiveArray[DType.int64].allocate(n)
    var bounds = key_hash_chunk_bounds(n)
    var n_chunks = len(bounds) - 1
    if n_chunks < 1:
        return slots^
    var work = _KeyHashWork(bounds^)
    var out = fork_join_shared[
        _KeyHashWork,
        StringArray[HeapRegion],
        _KeyHashSlots,
        in_o,
        D,
        has_pool=has_pool,
        disp_o=disp_o,
    ](
        work^,
        src,
        _KeyHashSlots(slots^),
        n_chunks,
        2,
        0,
        dispatcher_ptr,
        CancellationToken.never(),
        SITE_JOINKEY_HASH,
    )
    return out.slots.take()


comptime _KEY_CLASS_INTEGER: Int = 0
comptime _KEY_CLASS_FLOAT64: Int = 1
comptime _KEY_CLASS_STRING: Int = 2
comptime _KEY_CLASS_OTHER: Int = 3


def _key_class(batch: RecordBatch, name: String) raises -> Int:
    """The comparison class of key column `name`: INT32 / INT64 (plain or a
    numeric dictionary of them), FLOAT64 (plain or numeric dictionary),
    STRING / string DICTIONARY, or any other type (which
    `extract_join_key_columns_typed` refuses on its own)."""
    ref col = batch.column_at(batch.schema.column_index(name))
    if col.is_numeric_dict():
        var vt = col.dict_value_dtype()
        if vt == DType.int64 or vt == DType.int32:
            return _KEY_CLASS_INTEGER
        if vt == DType.float64:
            return _KEY_CLASS_FLOAT64
        return _KEY_CLASS_OTHER
    var at = col.arrow_type
    if at == ArrowType.INT64 or at == ArrowType.INT32:
        return _KEY_CLASS_INTEGER
    if at == ArrowType.FLOAT64:
        return _KEY_CLASS_FLOAT64
    if at == ArrowType.STRING or at == ArrowType.DICTIONARY:
        return _KEY_CLASS_STRING
    return _KEY_CLASS_OTHER


def join_key_is_integer(batch: RecordBatch, name: String) raises -> Bool:
    """True iff key column `name` is INT32 or INT64 (plain, or a numeric
    dictionary of them): the side `join_key_pairs_as_float64` casts."""
    return _key_class(batch, name) == _KEY_CLASS_INTEGER


def join_key_pairs_as_float64(
    probe_batch: RecordBatch,
    probe_keys: List[String],
    build_batch: RecordBatch,
    build_keys: List[String],
) raises -> List[Bool]:
    """For each key pair (`probe_keys[k]`, `build_keys[k]`), True iff the pair
    compares as FLOAT64: one side FLOAT64 and the other INT32 or INT64.

    This is DuckDB's rule: the common type of an integer and a DOUBLE is
    DOUBLE, so the integer side is cast to DOUBLE (rounded to nearest) and
    the pair compares as doubles; `1 = 1.0` matches, and so does
    9007199254740993 with 9007199254740992.0. INT32 against INT64 needs no
    cast (the INT32 slot is sign-extended). A STRING key against a numeric
    key raises, as DuckDB refuses to compare VARCHAR with a number without an
    explicit cast; a type outside these classes is left to
    `extract_join_key_columns_typed`, which refuses it.

    Raises:
        On a string-against-number pair, a key name that is not a column, or
        key lists of different lengths.
    """
    if len(build_keys) != len(probe_keys):
        raise Error(
            "join_key_pairs_as_float64: " + String(len(probe_keys))
            + " probe keys but " + String(len(build_keys)) + " build keys"
        )
    var out = List[Bool](capacity=len(probe_keys))
    for k in range(len(probe_keys)):
        var pc = _key_class(probe_batch, probe_keys[k])
        var bc = _key_class(build_batch, build_keys[k])
        if pc == _KEY_CLASS_OTHER or bc == _KEY_CLASS_OTHER or pc == bc:
            out.append(False)
            continue
        if pc == _KEY_CLASS_STRING or bc == _KEY_CLASS_STRING:
            raise Error(
                "join key pair ('" + probe_keys[k] + "', '" + build_keys[k]
                + "'): a STRING key cannot be compared with a numeric key"
                " without an explicit cast"
            )
        out.append(True)
    return out^


def _numeric_key_slots[
    dt: DType, as_float64: Bool = False
](ref src: PrimitiveArray[dt]) raises -> PrimitiveArray[DType.int64]:
    """Render a numeric key column into the Int64 key-slot domain: INT64 as
    is, INT32 sign-extended (injective, so a mixed INT32/INT64 pair compares
    by value), FLOAT64 by `_canonicalize_float64_for_hash`; every NULL row,
    read from the validity bitmap, to `_NAN_SENTINEL_BITS`. The validity
    bitmap is carried onto the result, rebased to offset 0.

    With `as_float64` an integer column is cast to Float64 (rounded to
    nearest) and rendered as a FLOAT64 key, for a pair whose other side is
    FLOAT64 (`join_key_pairs_as_float64`).
    """
    var n = src.length
    var out = PrimitiveArray[DType.int64].allocate(n)
    if n > 0:
        # SAFETY: both views are origin-tied to their own array and neither
        # pointer escapes this function. `src` is borrowed for the frame; `out`
        # is a fresh local allocation, so the two cannot alias even when the
        # caller's source was itself an Int64 array.
        var sv = src.view_ro()
        var sp = sv._unsafe_ptr().bitcast[Scalar[dt]]()
        var dv = out.view_mut()
        var dp = dv._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var has_validity = src.validity.__bool__()
        var soff = src.offset
        for r in range(n):
            if has_validity and not src.validity.value().test(soff + r):
                dp[r] = _NAN_SENTINEL_BITS
                continue
            comptime if dt == DType.float64 or as_float64:
                dp[r] = _canonicalize_float64_for_hash(
                    sp[r].cast[DType.float64]()
                )
            else:
                dp[r] = Int64(Int(sp[r]))
        _ = sv
        _ = dv
    if src.validity and n > 0:
        var bm = Bitmap.create(n)
        Bitmap.copy_bits_into(bm, 0, src.validity.value(), src.offset, n)
        out.null_count = n - bm.popcount()
        out.validity = bm^
    return out^


def _int_key_slots[
    dt: DType
](ref src: PrimitiveArray[dt], as_float64: Bool) raises -> PrimitiveArray[
    DType.int64
]:
    """`_numeric_key_slots` for an integer column, cast to Float64 when
    `as_float64`."""
    if as_float64:
        return _numeric_key_slots[dt, True](src)
    return _numeric_key_slots[dt](src)


def extract_join_key_columns_typed[
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    batch: RecordBatch,
    key_names: List[String],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    as_float64: List[Bool] = List[Bool](),
) raises -> MultiKeyColumns:
    """Extract N join-key columns from a RecordBatch into a MultiKeyColumns bundle.

    A STRING key whose column can be shared is borrowed, not copied; its bytes
    (and a DICTIONARY key's decoded bytes) are hashed in a fork-join wave over
    `dispatcher_ptr` when one is given and the column is large enough, inline
    otherwise. A NULL key of any type becomes `_NAN_SENTINEL_BITS`.

    Args:
        batch: Source batch.
        key_names: List of column names to extract (1..MAX_JOIN_KEYS).
        as_float64: Per key, True to render an INT32 or INT64 key as a
            FLOAT64 key (its value cast to Float64), for a pair whose other
            side is FLOAT64 (`join_key_pairs_as_float64`). Empty: none.

    Returns:
        A MultiKeyColumns bundle. `int_keys[k]` holds Int64 bit patterns
        regardless of input dtype (the value for INT64 and INT32, the
        float-model canonical bits for FLOAT64 and for an integer key cast by
        `as_float64`, the byte hash for STRING /
        DICT; `_NAN_SENTINEL_BITS` for a NULL key).
        `string_keys[k]` is `Some(StringArray)` for STRING and DICT
        keys (the DICT case decodes to a fresh StringArray) and `None`
        otherwise. `dict_keys[k]` is `Some(StringDictionaryArray)` for
        DICT keys only and `None` otherwise. `dict_fingerprints[k]`
        is the FNV-1a hash of the dictionary's data buffer for DICT
        keys; 0 otherwise.

    Raises:
        Error if any key column has a dtype other than INT64 / INT32 /
        FLOAT64 / STRING / DICTIONARY.
    """
    var n_keys = len(key_names)
    var out_int = Slab[PrimitiveArray[DType.int64]].with_capacity(n_keys)
    var out_str = Slab[Optional[StringArray[HeapRegion]]].with_capacity(n_keys)
    var out_dict = Slab[Optional[StringDictionaryArray]].with_capacity(n_keys)
    var out_fp = List[UInt64](capacity=n_keys)
    for _ in range(n_keys):
        out_fp.append(UInt64(0))
    for i in range(n_keys):
        var promote = len(as_float64) > i and as_float64[i]
        var idx = batch.schema.column_index(key_names[i])
        if batch.column_at(idx).is_numeric_dict():
            var flat = batch.column_at(idx).resolve_numeric_dict_to_flat()
            if flat.arrow_type == ArrowType.INT64:
                var src = flat.as_primitive[DType.int64]()
                out_int.append(_int_key_slots[DType.int64](src, promote))
            elif flat.arrow_type == ArrowType.INT32:
                var src = flat.as_primitive[DType.int32]()
                out_int.append(_int_key_slots[DType.int32](src, promote))
            elif flat.arrow_type == ArrowType.FLOAT64:
                var src = flat.as_primitive[DType.float64]()
                out_int.append(_numeric_key_slots[DType.float64](src))
            else:
                raise Error(
                    "join_multi_key: unsupported numeric-dict value dtype "
                    + String(flat.arrow_type)
                    + " for join key '"
                    + key_names[i]
                    + "'"
                )
            out_str.append(None)
            out_dict.append(None)
            out_fp[i] = UInt64(0)
            continue
        ref col = batch.column_at(idx)
        var col_dtype = col.arrow_type
        if col_dtype == ArrowType.INT64:
            var i64 = col.as_primitive[DType.int64]()
            if i64.validity or promote:
                out_int.append(_int_key_slots[DType.int64](i64, promote))
            else:
                out_int.append(i64^)
            out_str.append(None)
            out_dict.append(None)
        elif col_dtype == ArrowType.INT32:
            var i32 = col.as_primitive[DType.int32]()
            out_int.append(_int_key_slots[DType.int32](i32, promote))
            out_str.append(None)
            out_dict.append(None)
        elif col_dtype == ArrowType.FLOAT64:
            var f64 = col.as_primitive[DType.float64]()
            out_int.append(_numeric_key_slots[DType.float64](f64))
            out_str.append(None)
            out_dict.append(None)
        elif col_dtype == ArrowType.STRING:
            var _st = sched_trace_enabled()
            var _tm = _st
            var _xp_t0 = perf_counter_ns() if _tm else 0
            var _shared = col.can_share_as_string()
            var sa = (
                col.share_as_string() if _shared else col.as_string()
            )
            var _xp_t1 = perf_counter_ns() if _tm else 0
            if _st:
                sched_trace_add_serial_phase(
                    PHASE_JOINKEY_AS_STRING,
                    UInt64(_xp_t1 - _xp_t0),
                    UInt64(0),
                )
            var _xp_t2 = perf_counter_ns() if _tm else 0
            var _fnv_fork0 = sched_trace_fork_ns_now() if _st else UInt64(0)
            var i64 = hash_string_keys[
                origin_of(sa), has_pool, D, disp_o
            ](sa, dispatcher_ptr)
            var _xp_t3 = perf_counter_ns() if _tm else 0
            if _st:
                sched_trace_add_serial_phase(
                    PHASE_JOINKEY_FNV,
                    UInt64(_xp_t3 - _xp_t2),
                    sched_trace_fork_ns_now() - _fnv_fork0,
                )
            out_int.append(i64^)
            var sa_opt: Optional[StringArray[HeapRegion]] = sa^
            out_str.append(sa_opt^)
            out_dict.append(None)
        elif col_dtype == ArrowType.DICTIONARY:
            var _st_d = sched_trace_enabled()
            var _d_t0 = perf_counter_ns() if _st_d else 0
            var da = col.as_dictionary()
            var dict_data_len = da.dictionary.data_length
            var dict_data_view_fp = da.dictionary.data.view_ro()
            var dict_data_ptr = dict_data_view_fp._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
            var fp = _fnv1a_hash_bytes(dict_data_ptr, dict_data_len)
            _ = da.dictionary.data  # keepalive for fingerprint loop
            var decoded = _decode_dict_to_string_array(da)

            var _d_t1 = perf_counter_ns() if _st_d else 0
            if _st_d:
                sched_trace_add_serial_phase(
                    PHASE_JOINKEY_AS_STRING,
                    UInt64(_d_t1 - _d_t0),
                    UInt64(0),
                )
            var _d_fork0 = sched_trace_fork_ns_now() if _st_d else UInt64(0)
            var i64 = hash_string_keys[
                origin_of(decoded), has_pool, D, disp_o
            ](decoded, dispatcher_ptr)
            if _st_d:
                sched_trace_add_serial_phase(
                    PHASE_JOINKEY_FNV,
                    UInt64(perf_counter_ns() - _d_t1),
                    sched_trace_fork_ns_now() - _d_fork0,
                )
            out_int.append(i64^)
            var sa_opt: Optional[StringArray[HeapRegion]] = decoded^
            out_str.append(sa_opt^)
            var da_opt: Optional[StringDictionaryArray] = da^
            out_dict.append(da_opt^)
            out_fp[i] = fp
        else:
            raise Error(
                "extract_join_key_columns_typed: unsupported key dtype "
                + String(col_dtype)
                + " for column '" + key_names[i] + "'. "
                + "The supported key types are INT64, INT32, FLOAT64, STRING "
                + "and DICTIONARY."
            )
    return MultiKeyColumns(
        int_keys=out_int^,
        string_keys=out_str^,
        dict_keys=out_dict^,
        dict_fingerprints=out_fp^,
        num_keys=n_keys,
    )


def extract_join_key_columns_serial(
    batch: RecordBatch,
    key_names: List[String],
    as_float64: List[Bool] = List[Bool](),
) raises -> MultiKeyColumns:
    """`extract_join_key_columns_typed` for a caller that has NO dispatcher to
    thread — the key-hash wave runs inline on the calling thread.
    """
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return extract_join_key_columns_typed[False, NoDispatch, nd_o](
        batch, key_names, Optional[Pointer[NoDispatch, nd_o]](None), as_float64
    )
