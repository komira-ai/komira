"""The key-staging window of the vectorised upsert: the shipped budget in
KiB (`AGG_KBUF_CHUNK_DEFAULT_KIB`) and the rows-per-window arithmetic."""


# -----------------------------------------------------------------------------
# AGGKBUFCHUNK (2026-09-08, env `AGG_KBUF_CHUNK`, **DEFAULT ON** since
# 2026-09-09 — `AGG_KBUF_CHUNK=0` is the kill switch)
#
# ⭐ PROMOTED ON `bench/results/aggrowslot_0908/kbuf/`: q10 **-4.50% / -11.34 ms**
# against a -0.03% inert floor and hc2 **-0.88% / -15.33 ms**, credible sum
# **-26.67 ms**, one binary / three env arms / K=6, 19/19 VALUE_IDENTICAL in
# every sweep of every arm. The shipped budget is `AGG_KBUF_CHUNK_DEFAULT_KIB`
# (256 KiB), which is where the derivation and the one-value caveat live.
#
# THE MEASURED PROBLEM. The HASHAGG-VEC route stages the whole batch before it
# consumes any of it: `_vec_build_kbufs_hashes` widens every key column into
# `kbufs[k]` and SIMD-pre-hashes every row, and only then does the probe loop
# read `kbufs[k][row]`. A morsel is 122,880 rows (the parquet row-group cap), so
# on a 6-key table that staging is `6 x 122,880 x 8 = 5.9 MB` of lanes plus
# 983 KB of hashes — PER WORKER, 20 workers wide. It does not fit L2 and it does
# not fit a worker's L3 share, so every lane is written out to DRAM and read
# back from it before a single one is used.
#
# ⭐ NOT MODELLED — the IP is named. `upsert_vec_w+0x175`, which IS
# `kbufs[k][row]`, is **24.8% of h2o/q10's DRAM-served loads**
# (`bench/results/q10_aos_kill_0908/` §3, four perf recordings at periods
# 101/251/1009 agreeing to 0.46 pp).
#
# THE LEVER. Fuse the widen with its consumer over a window sized so the
# staging stays resident, i.e. process `[lo, hi)` at a time instead of
# `[0, n_rows)`. Nothing about the ANSWER changes: rows are still visited in
# ascending order, each row still probes and folds exactly once, the hash is
# still the same pure function of the same lanes, and `kbufs`/`hashes` stay
# GLOBALLY indexed by batch row so every consumer keeps the index it already
# had.
#
# ⚠ THE VALUE IS A BUDGET IN KiB, NOT A ROW COUNT, and that is the point: the
# staging footprint is `(nk + 1) * rows * 8` bytes, so one budget expresses the
# same intent for a 1-key table and a 6-key one, where one row count would mean
# six times the bytes on the second. `agg_kbuf_chunk_rows` does the division.
#
# ⛔ READ AS AN INTEGER, NEVER THROUGH `_env_is_set` — same reason
# `_agg_merge_tile` states above: `_env_is_set` fires on the string `"0"`, so
# the OFF point of a sweep would arm the chunking and BOTH arms of the A/B
# would be ON. Since the promotion that is no longer only an A/B hazard: `=0`
# is the KILL SWITCH, and a presence-reader would make it unspellable.
#
# ⛔⛔ THE PROMOTION MADE TWO OTHER LEVERS INERT BY DEFAULT, AND NEITHER WENT
# RED WHEN IT HAPPENED. `_appendfold_batch` and `_radixvecfold_batch` were both
# DECLINED by a chunked batch — the conditions were literally `row_lo == 0 and
# acct_rows == n_rows` and `lo == 0 and hi >= n_rows`
# (`radix_hash_agg_untyped.mojo`) — so on any batch larger than the window,
# turning `AGG_APPENDFOLD=1` or `AGG_RADIXVECFOLD=1` on a
# shipped binary did NOTHING AT ALL. Both are `_env_default_off` and both are
# REFUTED (`docs/perf/env_default_on_lever_ledger.tsv` APPENDIX B), so nothing
# shipped broken by it; what broke is a RE-MEASUREMENT.
#
# ⭐ RADIXVECFOLD IS NO LONGER ONE OF THEM (RVFWIN, 2026-09-18): its clause is
# gone and `_radixvecfold_batch` now takes `[row_lo, row_hi)` and runs once per
# WINDOW, so `=1` fires on a shipped binary. ⛔ A re-measurement of it must
# therefore NOT pin `AGG_KBUF_CHUNK=0` — that would measure the OLD,
# unwindowed arm, which amortises the fold over ~1,920 rows per partition
# instead of the ~256 (nk=1) / ~73 (nk=6) a windowed run produces, i.e. a
# different lever. Route witness:
# `test_radix_vecfold_fires_at_the_SHIPPED_window_on_a_production_morsel`.
#
# ⛔ APPENDFOLD IS STILL DECLINED AND ITS RULE IS UNCHANGED: anyone re-running
# that A/B on a promoted trunk measures a no-op and will read it as "the arm is
# neutral". **Set `AGG_KBUF_CHUNK=0` for the whole of any such board**,
# and say in its witness that you did.
# -----------------------------------------------------------------------------


comptime AGG_KBUF_CHUNK_DEFAULT_KIB: Int = 256
"""AGGKBUFCHUNK: the staging-window budget, in KiB, that an UNSET
`AGG_KBUF_CHUNK` resolves to. **DEFAULT ON since 2026-09-09**;
`AGG_KBUF_CHUNK=0` is the kill switch.

⭐ WHY 256 AND NOT A ROUNDER NUMBER: **256 IS THE ONLY NON-ZERO VALUE ANY
BOARD HAS EVER SCORED.** `bench/results/aggrowslot_0908/kbuf/` is ONE binary
(its md5 pinned before, between and after every round) under THREE ENV ARMS — `A=000` off, `B=256` on,
`T=-64` inert — palindromic order `A B T T B A x 3`, K=6/arm, 18/18 rc=0,
19/19 VALUE_IDENTICAL in every sweep of every arm. Re-derive rather than
trusting this paragraph:

    # point `analyse_board.py`'s glob at `*_s*.cells.txt` (it was written
    # against `*_s*.log`) and run it over `bench/results/aggrowslot_0908/kbuf`

⛔ THERE WAS NO SWEEP OVER SEVERAL CHUNK SIZES, AND SAYING SO IS THE POINT:
256 is the measured best of the values TRIED, which is a set of size one. It is
NOT a tuned optimum, and this constant carries no claim that 128 or 512 would
be worse. Anyone who wants that claim owes a board.

WHAT IT BOUGHT, min-of-6 per arm:
  * `h2o/q10_groupby_6key`  252.05 -> 240.71 ms  **-4.50% / -11.34 ms**, against
    an A/T inert floor of **-0.03%** on the same cell — the effect is 150x the
    floor that cell resolves.
  * `hc/hc2_agg_100m_multi` 1740.87 -> 1725.54 ms  **-0.88% / -15.33 ms** (floor
    -0.12%).
  Credible sum **-26.67 ms**. `hc1` also moved -1.60% but on a +1.21% floor, so
  it is NOT counted. The worst regression on the 19-cell board is
  `h2o/j2_join_medium` +1.45% (+0.71 ms) on a -1.31% floor — inside its own
  noise, and a join cell has no hash-agg staging pre-pass to window.

⚠ WHY A BUDGET IN KiB AND NOT A ROW COUNT: the staging footprint is
`(nk + 1) * rows * 8` bytes, so one budget expresses the same intent on a
1-key table and a 6-key one, where one row count would mean six times the
bytes on the second. `agg_kbuf_chunk_rows` does the division — and at 256 KiB
it yields 16,384 rows at `nk=1` and 4,681 at `nk=6`, both under the
122,880-row morsel, which is what makes the default actually engage."""


@always_inline
def agg_kbuf_chunk_rows(kib: Int, nk: Int, n_rows: Int) -> Int:
    """Rows per staging window for a `kib`-KiB budget on an `nk`-key table.

    Returns `n_rows` — i.e. ONE window, the whole-batch shape — when the lever
    is killed (`kib == 0`), when the batch already fits the budget, or when the
    derived window would be so small that the per-window fixed costs (the
    `nk` widen dispatches and the SIMD prologue) stop amortising. **A window
    that is not smaller than the batch must return exactly `n_rows`**, because
    the driver's fast path keys on that equality to run the single-pass code
    rather than a loop that happens to have one iteration.

    ⚠ THE `kib` ARGUMENT IS NOW NON-ZERO ON A DEFAULT RUN
    (`AGG_KBUF_CHUNK_DEFAULT_KIB`, 256), so the `return n_rows` arms above are
    reached by the SECOND and THIRD conditions in production, not the first.
    A unit fixture is under the 4096-row floor and therefore takes them at ANY
    budget — which is why the tests drive `_set_kbuf_chunk_kib` and why the
    default is pinned on THIS function and on `_agg_kbuf_chunk_kib`, at
    production scale, rather than through a fixture that cannot see it.

    ⛔ THE FLOOR IS 4096 AND IT IS NOT COSMETIC. The window also bounds the
    software prefetch distance the probe loops use (`_VEC_PREFETCH_DIST_RADIX`
    lookahead cannot cross a window because the next window's hashes do not
    exist yet), so a small window silently disarms the prefetch this route
    depends on."""
    if kib <= 0 or nk <= 0 or n_rows <= 0:
        return n_rows
    var bytes_per_row = (nk + 1) * 8
    var rows = (kib * 1024) // bytes_per_row
    if rows < 4096:
        rows = 4096
    if rows >= n_rows:
        return n_rows
    return rows
