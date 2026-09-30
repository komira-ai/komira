# =============================================================================
# keyeq_census — the per-site FIRE + WIDTH census for the byte-walk
#                key-equality family
# =============================================================================
#
# WHY THIS EXISTS
# The dataplane holds a family of key-equality kernels that compare two byte
# runs. Deciding whether a kernel is worth rewriting needs three facts per
# kernel: whether a workload REACHES it, how many comparisons it runs, and how
# WIDE its keys are. This census records all three.
#
# Width matters as much as the call count. A site can be hot and still be a
# poor candidate for a vectorized compare: the vector compare
# (`komira_core.simd.byte_class.byte_equal.bytes_equal`) issues no call at any
# width, so its remaining cost is CODE SIZE at the call site, and inlining a
# ~60-instruction ladder into a loop whose keys are 1 byte wide can still
# lose. The width histogram buckets below are fixed edges for comparing runs;
# they do not encode an eligibility criterion.
#
# WHAT IT MEASURES, per site, per (cell, rep):
#   calls   — invocations of the comparison
#   bytes   — byte-compare iterations ACTUALLY executed (early-exit aware)
#   hits    — invocations returning "equal"
#   wsum    — sum of the compared WIDTHS (nominal length, pre-early-exit), so
#             wsum/calls is the mean key width
#   hist[8] — width histogram, buckets 0 / 1-3 / 4-7 / 8-15 / 16-31 / 32-63 /
#             64-255 / 256+.
#
# GATE — a comptime constant, deliberately NOT an env var.
# These sites are per-COMPARISON, up to tens of millions of times in one
# query, and an environment read allocates a `String` and calls `getenv` on
# every invocation — an env gate here would cost more than the kernels being
# measured and would corrupt the very run it is instrumenting.
# `KEYEQ_CENSUS_ENABLED = False` is compiler-erased (the arm does not exist in
# the OFF binary), so the shipped cost is exactly zero.
#
# ⚠ WHEN ON, THIS BINARY'S TIMINGS ARE NOT A PERF MEASUREMENT. Five atomic
# read-modify-writes per comparison, contended across all workers. Use it for
# REACH and WIDTH only. Never quote a wall time from a census build.
#
# HOW TO RUN THE CENSUS
#   1. flip `KEYEQ_CENSUS_ENABLED` to True below and rebuild
#   2. run the workload; call `keyeq_dump(tag)` after each query (and
#      `keyeq_reset()` between queries)
#   3. flip it back to False
# The `KEYEQ` lines `keyeq_dump` emits are the artifact.
#
# Storage mechanism: the `_Global` + `Atomic` process-lifetime counter idiom
# (the same one `rxcensus` uses) — no `unsafe_from_address`, no
# wildcard-origin field.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


# -----------------------------------------------------------------------------
# THE GATE. Flip to True for a census run; MUST be False when committed.
# -----------------------------------------------------------------------------
comptime KEYEQ_CENSUS_ENABLED: Bool = False


# -----------------------------------------------------------------------------
# Site ids. Stable — consumers of the dump join on these numbers, so APPEND only.
#
# Classes:
#   TWIN  — a runtime byte-at-a-time equality loop; a conversion candidate
#   BORD  — borderline: already-optimal or comptime-unrolled, measured for reach
#   CTL   — a control whose expected outcome is known BEFORE the run
# -----------------------------------------------------------------------------
comptime KEYEQ_N_SITES: Int = 24
comptime KEYEQ_SLOT_STRIDE: Int = 16  # calls, bytes, hits, wsum, hist[8], 4 spare

comptime KEYEQ_AGGCD_SERIAL: Int = 0           # TWIN agg_count_distinct.mojo
comptime KEYEQ_AGGCD_PARALLEL: Int = 1         # TWIN agg_count_distinct_parallel
comptime KEYEQ_AGGCD_STRENC: Int = 2           # TWIN agg_count_distinct_strenc
comptime KEYEQ_COLAGG_MAP: Int = 3             # TWIN columnar_agg_map._keys_match
comptime KEYEQ_FLATHASH_KEYS_N: Int = 4        # TWIN flat_hash_agg._keys_match_n
comptime KEYEQ_HASHAGG_UNTYPED_STR: Int = 5    # TWIN hash_agg_untyped._str_cell_eq_slot
comptime KEYEQ_JOINBUILD_UNTYPED: Int = 6      # TWIN join_build_untyped._bytes_eq
#   ⚠ NOT ONE FILE. `_bytes_eq` lives in join_build_untyped but is IMPORTED
#   and called by distinct_state_untyped and by hash_agg_untyped's combine
#   arms, so this tag aggregates all three. join_build_untyped's
#   `_str_cell_eq_slot` and `_storage_key_eq_single_col` record under the
#   same tag, including the length-mismatch arm's (len(FIRST arg), 0, False).
comptime KEYEQ_SORTLEX_VERIFY: Int = 7         # TWIN sort_lex._encode_string_key
comptime KEYEQ_SORTSTR_RUN_IDENT: Int = 8      # TWIN sort_string._prefix_key_sort_segment
comptime KEYEQ_BHEAP_SLOTS_EQUAL: Int = 9      # TWIN bounded_heap.slots_equal
comptime KEYEQ_DISTINCT_DICTARM: Int = 10      # TWIN distinct_state._equals_bytes dict
comptime KEYEQ_DISTINCT_DENSEARM: Int = 11     # TWIN distinct_state._equals_bytes dense
comptime KEYEQ_DISTINCT_ROWBYTES: Int = 12     # TWIN distinct_state.equals_row_bytes
comptime KEYEQ_DISTINCT_COMBINE: Int = 13      # TWIN distinct_state.equals_stored
comptime KEYEQ_PARTKEY_BATCH_TOK: Int = 14     # TWIN part_key_block.equals_batch_row_to_token
comptime KEYEQ_PARTKEY_ROWS: Int = 15          # TWIN part_key_block.equals_rows
comptime KEYEQ_SLAB_CK_MEMCMP: Int = 16        # TWIN slab_storage_ck_helpers._ck_memcmp_keys
comptime KEYEQ_DICTRANK_ROWBYTES: Int = 17     # TWIN parallel_dictrank_sort._row_bytes_equal
comptime KEYEQ_ROWBLOCK_SHORT: Int = 18        # RESERVED -- always 0.
#   No kernel records under this id: `row_block` equality routes every width to
#   the one `byte_class.byte_equal.bytes_equal` kernel, recorded as slot 19.
#   The id is kept, not renumbered, because ids are APPEND-ONLY. A zero here
#   is EXPECTED and is NOT evidence that the row_block path is cold; read
#   slot 19 for that.
comptime KEYEQ_ROWBLOCK_MEMCMP: Int = 19       # BORD row_block equality (ALL strides)
comptime KEYEQ_COMPOSITEKEY_UNROLL: Int = 20   # BORD composite_key.equals (@parameter for)
comptime KEYEQ_JOINMK_MEMCMP: Int = 21         # CTL  join_multi_key._string_bytes_equal
comptime KEYEQ_SLAB_STRIDE8: Int = 22          # CTL  slab_storage stride==8 Int64 arm
comptime KEYEQ_SLAB_STRIDE16: Int = 23         # CTL  slab_storage stride==16 2xInt64 arm


def _init_keyeq_counters() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: allocate the whole counter table once per process
    (all slots zeroed)."""
    var n = KEYEQ_N_SITES * KEYEQ_SLOT_STRIDE
    var raw = alloc[AtomicI64](n)
    for i in range(n):
        (raw + i).unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(
            Scalar[DType.int64](0)
        )
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _KEYEQ_COUNTERS = _Global[
    "komira_core_instr_keyeq_census_counters",
    _init_keyeq_counters,
]


@always_inline
def _keyeq_bucket(width: Int) -> Int:
    """Width -> histogram bucket (0 / 1-3 / 4-7 / 8-15 / 16-31 / 32-63 /
    64-255 / 256+). The edges are fixed so dumps from different runs stay
    comparable. Read the distribution, not the mean: a bimodal site can have
    a large mean and almost no wide comparisons."""
    if width <= 0:
        return 0
    if width < 4:
        return 1
    if width < 8:
        return 2
    if width < 16:
        return 3
    if width < 32:
        return 4
    if width < 64:
        return 5
    if width < 256:
        return 6
    return 7


@always_inline
def _keyeq_record_impl(
    site: Int, width: Int, bytes_touched: Int, matched: Bool
) raises:
    """The raising body of `keyeq_record`. Split out because `_Global`'s
    `get_or_create_ptr` is `raises` while most of the instrumented kernels
    sit in non-raising contexts."""
    # SAFETY: FFI boundary — `get_or_create_ptr` targets KGEN-runtime
    # static storage (process-lifetime); the wildcard origin is the stdlib
    # `_Global` API's own return type and is confined to this helper.
    var gp = _KEYEQ_COUNTERS.get_or_create_ptr()
    var base = UnsafePointer(to=gp[][]) + site * KEYEQ_SLOT_STRIDE
    _ = base[].fetch_add(Int64(1))
    _ = (base + 1)[].fetch_add(Int64(bytes_touched))
    if matched:
        _ = (base + 2)[].fetch_add(Int64(1))
    _ = (base + 3)[].fetch_add(Int64(width))
    _ = (base + 4 + _keyeq_bucket(width))[].fetch_add(Int64(1))


@always_inline
def keyeq_record(site: Int, width: Int, bytes_touched: Int, matched: Bool):
    """Record ONE key-equality comparison at `site`.

    `width` is the NOMINAL compared length (what a memcmp would be handed);
    `bytes_touched` is what the byte loop actually executed, which is smaller
    whenever the loop early-exits on a mismatch. Both are needed: `width`
    says which compare shape fits the site, `bytes_touched` sizes the work a
    faster compare could save.

    NON-RAISING on purpose. The instrumented kernels include non-raising
    equality helpers, and an instrument must never change the control flow of
    the code it observes — a census that could throw would be a different
    experiment. A swallowed error can only mean the counter table failed to
    allocate, which shows up as a site with zero calls and is caught by the
    dump's own `KEYEQEND` accounting.

    No-op unless `KEYEQ_CENSUS_ENABLED`; the body is compiler-erased when False.
    """
    comptime if KEYEQ_CENSUS_ENABLED:
        try:
            _keyeq_record_impl(site, width, bytes_touched, matched)
        except:
            pass


def keyeq_read(site: Int, field: Int) raises -> Int:
    """Read one counter. `field`: 0=calls 1=bytes 2=hits 3=wsum 4+b=hist[b]."""
    var gp = _KEYEQ_COUNTERS.get_or_create_ptr()
    var base = UnsafePointer(to=gp[][]) + site * KEYEQ_SLOT_STRIDE
    return Int((base + field)[].load())


def keyeq_reset() raises:
    """Zero every counter (called by the harness between cells/reps)."""
    comptime if KEYEQ_CENSUS_ENABLED:
        var gp = _KEYEQ_COUNTERS.get_or_create_ptr()
        var base = UnsafePointer(to=gp[][])
        for i in range(KEYEQ_N_SITES * KEYEQ_SLOT_STRIDE):
            (base + i)[].store(Scalar[DType.int64](0))


def _write_keyeq_site_name[W: Writer](mut writer: W, site: Int):
    """WRITE what `keyeq_site_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a shared library
    that binds such a pair crossed returns the wrong bytes for the wrong
    length."""
    if site == KEYEQ_AGGCD_SERIAL:
        writer.write(String("aggcd_serial"))
        return
    if site == KEYEQ_AGGCD_PARALLEL:
        writer.write(String("aggcd_parallel"))
        return
    if site == KEYEQ_AGGCD_STRENC:
        writer.write(String("aggcd_strenc"))
        return
    if site == KEYEQ_COLAGG_MAP:
        writer.write(String("colagg_map_keys"))
        return
    if site == KEYEQ_FLATHASH_KEYS_N:
        writer.write(String("flathash_keys_n"))
        return
    if site == KEYEQ_HASHAGG_UNTYPED_STR:
        writer.write(String("hashagg_untyped_strslot"))
        return
    if site == KEYEQ_JOINBUILD_UNTYPED:
        writer.write(String("joinbuild_untyped_bytes"))
        return
    if site == KEYEQ_SORTLEX_VERIFY:
        writer.write(String("sortlex_dict_verify"))
        return
    if site == KEYEQ_SORTSTR_RUN_IDENT:
        writer.write(String("sortstr_run_identical"))
        return
    if site == KEYEQ_BHEAP_SLOTS_EQUAL:
        writer.write(String("bheap_slots_equal"))
        return
    if site == KEYEQ_DISTINCT_DICTARM:
        writer.write(String("distinct_dictarm"))
        return
    if site == KEYEQ_DISTINCT_DENSEARM:
        writer.write(String("distinct_densearm"))
        return
    if site == KEYEQ_DISTINCT_ROWBYTES:
        writer.write(String("distinct_row_bytes"))
        return
    if site == KEYEQ_DISTINCT_COMBINE:
        writer.write(String("distinct_combine"))
        return
    if site == KEYEQ_PARTKEY_BATCH_TOK:
        writer.write(String("partkey_batch_token"))
        return
    if site == KEYEQ_PARTKEY_ROWS:
        writer.write(String("partkey_rows"))
        return
    if site == KEYEQ_SLAB_CK_MEMCMP:
        writer.write(String("slab_ck_memcmp_keys"))
        return
    if site == KEYEQ_DICTRANK_ROWBYTES:
        writer.write(String("dictrank_row_bytes"))
        return
    if site == KEYEQ_ROWBLOCK_SHORT:
        writer.write(String("rowblock_byte_arm_RETIRED"))
        return
    if site == KEYEQ_ROWBLOCK_MEMCMP:
        writer.write(String("rowblock_equality"))
        return
    if site == KEYEQ_COMPOSITEKEY_UNROLL:
        writer.write(String("compositekey_unrolled"))
        return
    if site == KEYEQ_JOINMK_MEMCMP:
        writer.write(String("joinmk_string_memcmp"))
        return
    if site == KEYEQ_SLAB_STRIDE8:
        writer.write(String("slab_ck_stride8"))
        return
    if site == KEYEQ_SLAB_STRIDE16:
        writer.write(String("slab_ck_stride16"))
        return
    writer.write(String("site_") + String(site))
    return


def keyeq_site_name(site: Int) -> String:
    """Stable short name per site id, for the emitted `KEYEQ` lines."""
    var out = String()
    _write_keyeq_site_name(out, site)
    return out^


def keyeq_dump(tag: String) raises:
    """Emit one `KEYEQ <tag> <site> <name> ...` line per site with a NON-ZERO
    call count, then a `KEYEQEND <tag> <n_fired>` terminator.

    Sites with zero calls are DELIBERATELY omitted from the per-cell lines: the
    fire SET is the deliverable and a silent site is the informative case. The
    terminator makes a truncated dump detectable — a missing `KEYEQEND` means
    the process died mid-cell and the counts for that cell must be discarded
    rather than read as zeros."""

    comptime if KEYEQ_CENSUS_ENABLED:
        var fired = 0
        for s in range(KEYEQ_N_SITES):
            var calls = keyeq_read(s, 0)
            if calls == 0:
                continue
            fired += 1
            var line = (
                String("KEYEQ ")
                + tag
                + " "
                + String(s)
                + " "
                + keyeq_site_name(s)
                + " calls="
                + String(calls)
                + " bytes="
                + String(keyeq_read(s, 1))
                + " hits="
                + String(keyeq_read(s, 2))
                + " wsum="
                + String(keyeq_read(s, 3))
                + " hist="
            )
            for b in range(8):
                if b > 0:
                    line += ","
                line += String(keyeq_read(s, 4 + b))
            print(line)
        print(String("KEYEQEND ") + tag + " " + String(fired))
