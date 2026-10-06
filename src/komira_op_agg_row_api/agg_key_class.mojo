"""The ingest probe's once-per-batch monomorphic key class (`IKM_*`,
`ingest_key_mono_class`) and the directory-size gate of the vectorised
multi-int-key upsert (`VEC_MIN_DIR_CAP`)."""


from komira_column_format.column_format_storage import (
    DT_I64,
    DT_DATE64,
    DT_I32,
    DT_DATE32,
    DT_U32,
)


comptime VEC_MIN_DIR_CAP: Int = 1 << 10
"""HASHAGG-VEC: minimum directory bucket count for the vectorized multi-int-key
upsert. 1024 buckets is the directory a RADIX sub-table has at birth
(`_RADIX_PER_PARTITION_INITIAL_CAPACITY` 256, sized 4x), so in practice every
multi-int-key table qualifies and the residual purpose of the gate is to keep a
tiny table (a unit-test fixture, a 16-slot scratch partial) off a path whose
per-batch widen allocation would dominate it.

★ WHY IT IS 1024 AND NOT 65536 — a premise this constant used to assert, and the
measurement that falsified it.

The value was 1 << 16, justified as: "the vec path's win is ENTIRELY the software
prefetch, which only pays on a past-cache directory." That is FALSE. A/B of
1<<16 vs 1<<10, interleaved x3, warm manifest, 7 reps, medians of n=18:

    clickbench/cb17   209.93 -> 183.49 ms   -26.44  (-12.6%)  18/18 separation
    tpch/q7            62.79 ->  59.38 ms    -3.41   (-5.4%)  3/3 rounds
    tpch/q20           75.85 ->  73.38 ms    -2.47   (-3.3%)  inside noise
    tpch/q3            33.25 ->  33.08 ms    -0.17   (-0.5%)  inside noise

cb17's radix sub-tables sit at capacity 1024..4096 — comfortably cache-resident,
where the prefetch cannot be buying anything — and the vec path still takes 26 ms
off it. So the win is NOT the prefetch: it is the columnar widen + 8-wide SIMD
pre-hash + hoisted-dtype probe replacing a per-row, per-column runtime dtype
cascade (`_hash_single_col`) and BatchView accessor. That half pays at ANY
directory size, which is why the gate had to come down rather than up.

Row counts identical in every arm of every run. A 12-cell safety sweep (cb10,
cb12, cb13, cb16, cb19, j5, q04, q06, h2o q10, tpch q9/q10/q16) found no
reproducible regression: the three cells that looked negative on one round
(cb13 +3.5%, tpch q9 +1.8%, tpch q10 +4.7%) all SIGN-FLIP across rounds, and all
three are cells the vec path cannot reach (single key, or a STRING key col which
fails `_vec_key_dtype_ok` regardless of capacity). The noise floor those runs
establish is ~2.5 ms / ~3% on a 100 ms cell.

★ FIRE-SET AT THE OLD VALUE, printed from runs (this is how the above was found).
Per-fold-decision trace over all 21 corpus cells that can reach the gate:

    cb17          4067 decisions, 2600 FIRE, every one at cap=65536
    tpch q20/q3/q7/q9/q10, h2o q10   reach the gate, 0 FIRE (cap 1024..8192)
    j5, cb10, cb12, cb13, cb15, cb16, cb18, cb19,
    q02, q04, q06, q09, q16, b5      0 DECISIONS — never consulted

At 1<<16 the fire-set was EXACTLY {cb17}, and only its FLAT pre-promote partial:
`_make_agg_partial` builds that table at 16384 slots and the ctor sizes the
directory at 4x = 65536, i.e. precisely ON the old threshold, and it promotes to
radix before it ever doubles. One notch either way and the whole lever went dark
corpus-wide with no test failure. Two things follow that are worth keeping:

  (a) The eight cells a prior A/B reported as vec REGRESSIONS (j5 +4.1%, cb10,
      q06, cb13, cb16, cb15, cb19, q04) record ZERO fold decisions. Those deltas
      were noise, and the "tighten the gate to separate cb17 from j5"
      recommendation they motivated had nothing to separate — tightening would
      have emptied the fire-set instead.
  (b) A gate whose threshold coincides with one caller's constant is a fire-set
      of one by accident. `_make_agg_partial` still carries a comptime assert
      tying the two together, now with a lot more headroom.

The remaining declines are all `_vec_key_dtype_ok` declines (a string key col),
not capacity declines: tpch q9 (n_name), tpch q10 (n_name), h2o q10 (id1..id3).
Extending the vec envelope to dict-encoded STRING keys is the next reachability
step, and it is a different change — it needs a widen that produces a comparable
integer lane per string, not a lower threshold."""


# -----------------------------------------------------------------------------
# KEYMONO (2026-09-18) — the INGEST probe's once-per-BATCH monomorphic key
# class. The ingest-side counterpart of `combine_key_plan.probe_mono_class`,
# which performs exactly this hoist for the COMBINE probe, is byte-equivalence
# tested, has been default-ON since 2026-09-04 — and has exactly ONE call site.
# This is the arm that runs once per input ROW rather than once per GROUP.
#
# ⭐ WHAT IT DELETES. `_read_slot_key_i64_w` and `_write_int_key_slot_w` each
# carry an 8-arm `dtype_tag` cascade — eight or nine instructions of dispatch to
# reach a load or store of one, two, four or eight bytes. The ingest probe pays
# it PER ROW, PER KEY COLUMN, and on the compare side PER CHAIN CANDIDATE.
# Measured in `docs/perf/hot_loop_dispatch_census_2026_09_18.tsv`: the table is
# `DISPATCH_NARROW` with one jump table in `_probe_or_insert_row_prehashed_vec_w`
# (cb17's #1 symbol) and in `_upsert_one_row_prehashed_vec_w` (cb17's #3).
#
# ⭐ MEASURED, `objdump -d`, the linux-x86-64 farm build of
# `//src/komira:test_agg_keymono_byte_equiv`, over
# `_upsert_one_row_prehashed_vec_w`'s own symbol — the incumbent instantiation
# against the `IKM_I64` one:
#
#     kc=0 (cascade)   4,147 B   892 instructions   2 x `jmpq *%r12`   6 movzbl
#     kc=1 (IKM_I64)   3,507 B   750 instructions   0 indirect jumps   1 movzbl
#
# Each indirect jump is preceded by `cmpl $0xe, %ebp` — a **15-way** jump table,
# one for the compare side and one for the insert store — and both are GONE from
# every monomorphic instantiation, along with five of the six byte loads (the
# dtype tags and the `self._rowkeys` reloads the `_m` helpers now take as a
# caller-hoisted local). ⚠ THAT BINARY IS `fastbuild`, NOT the `-O3` /
# `ASSERT=none` configuration the census measured, so the COUNTS are not
# comparable to a per-row bench figure; what transfers is the STRUCTURE — the
# table is present in one body and absent from the other.
#
# ⛔ AND NO CYCLE CLAIM IS MADE HERE. This tree's own measurement of the nearest
# lever puts the instruction->cycle transfer on a latency-bound probe at 0.12,
# so an instruction count is not a wall prediction. The A/B that would price it
# is named in the landing note, and it has not been run.
#
# ⭐ THE TAG IS A SCHEMA PROPERTY, FIXED FOR THE WHOLE QUERY. `key_tags` is
# already built ONCE per batch by `_upsert_batch_vec_packed` out of
# `key_descriptors` and threaded down as a parameter, so there is nothing to
# discover: this is a pure hoist of a value already in scope at the call site.
#
# ⛔ THE SET IS BOUNDED BY WHAT THE GENERIC READER CAN ALREADY *READ*, NOT BY
# WHAT THE TYPE SYSTEM CAN SPELL (the MINMAXFOLD rule, one campaign day
# earlier). `_read_slot_key_i64_w` has arms for I64/DATE64, I32/DATE32, U32,
# I16, U16, I8 and U8 — and **NO U64 ARM**: a DT_U64 tag falls through its
# cascade into the DT_U8 arm and reads ONE byte. That is not a live defect,
# because `_vec_key_dtype_ok` excludes DT_U64 from the whole vec envelope, and
# it is exactly why there is no `IKM_U64` below. An 8-byte U64 class would be a
# DIFFERENT answer from the incumbent, not a faster one.
#
# ⛔ AND IT IS UNIFORM-OR-NOTHING, for `probe_mono_class`'s stated reason: Mojo
# cannot spell a comptime LIST of per-key classes, so a per-key comptime
# cascade would be the very thing this removes. A table whose keys do not all
# share one class DECLINES to `IKM_NONE` and runs the identical incumbent arm.
# The census cells are uniform: cb17 groups by (counter_id, region_id), both
# CAST to BIGINT by `bench/datagen/gen_clickbench.sh` — DT_I64 — and tpch
# q13/q18 group by BIGINT keys.
#
# ⚠ NARROW KEYS (I16 / U16 / I8 / U8) DECLINE, DELIBERATELY. They are inside
# the envelope and their arms carry the SIGNED-NARROW arithmetic
# reconstruction, so a class for each is mechanical; they are left on the
# cascade because no census cell uses one and each class costs an instantiation
# of every dispatching loop. Adding one is an `IKM_*` value, an arm in each
# `_m` helper, and a branch in each dispatcher.
# -----------------------------------------------------------------------------

comptime IKM_NONE: Int = 0
"""KEYMONO: no monomorphic ingest class — run the incumbent dtype cascade."""

comptime IKM_I64: Int = 1
"""KEYMONO: every key of the batch is DT_I64 or DT_DATE64 — 8-byte signed."""

comptime IKM_I32: Int = 2
"""KEYMONO: every key of the batch is DT_I32 or DT_DATE32 — 4-byte signed."""

comptime IKM_U32: Int = 3
"""KEYMONO: every key of the batch is DT_U32 — 4-byte unsigned.

⛔ SEPARATE FROM `IKM_I32` AND NOT FOLDABLE INTO IT. The widen differs:
`Int64(Int(u32))` is never negative where `Int64(Int(i32))` is, so one class
covering both would compare a high-bit-set key against the wrong widened lane
and silently re-group it — the same class of defect `PMK_F64` is kept separate
from `PMK_U64` to avoid."""


@always_inline
def _ingest_key_class_of(tag: UInt8) -> Int:
    """The KEYMONO class of ONE key dtype tag, or `IKM_NONE`.

    Each arm names EXACTLY the tags the corresponding arm of
    `_read_slot_key_i64_w` takes. That correspondence is what makes the
    monomorphic bodies verbatim copies of a cascade arm rather than a second
    derivation of the widening rules."""
    if tag == DT_I64 or tag == DT_DATE64:
        return IKM_I64
    if tag == DT_I32 or tag == DT_DATE32:
        return IKM_I32
    if tag == DT_U32:
        return IKM_U32
    return IKM_NONE


def ingest_key_mono_class(imm key_tags: List[UInt8]) -> Int:
    """KEYMONO: the ONE comptime key class this batch's key tags admit, or
    `IKM_NONE`.

    Total — never raises. A decline is a routing fact, not an error, and the
    caller runs the identical incumbent arm for it.

    ⭐ EVERY TEST HERE IS ONE THE INCUMBENT PROBE PAYS **PER ROW PER KEY** — and
    on the compare side per CANDIDATE — AND THIS PAYS IT **ONCE PER BATCH**.

    ⚠ IT DELIBERATELY DOES NOT CHECK `key_widths`, and that is not an oversight
    in the shape of `probe_mono_class_bytes`. The width and the tag come from
    the SAME `ColDescriptor` (`_key_cell_stride` -> `slots.cell_bytes_of(col)`
    -> `_dtype_cell_bytes(kind, dtype_tag)`), and under AGGROWKEYS the hoisted
    stride is the ROW WIDTH by design — so a `width == class bytes` assertion
    would be vacuous on one layout and would silently disable the lever on the
    other. The address arithmetic stays `slot * cell_bytes + _kbase(col)` on
    both arms, exactly as the incumbent computes it."""
    var nk = len(key_tags)
    if nk <= 0:
        return IKM_NONE
    var cls = _ingest_key_class_of(key_tags[0])
    if cls == IKM_NONE:
        return IKM_NONE
    for k in range(1, nk):
        if _ingest_key_class_of(key_tags[k]) != cls:
            return IKM_NONE
    return cls
