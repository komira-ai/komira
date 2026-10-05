# =============================================================================
# rxcensus — REACH census for the regexp-replace memo and the compiler-side
#            dictionary densification
# =============================================================================
#
# WHY THIS EXISTS
#
# Two questions need a witness rather than an assumption:
#
#   1. `_ReplaceMemo` (komira_column_kernels/regexp_functions.mojo) is built ONCE PER
#      CALL, i.e. once per BATCH, and its reuse rises with the window. Whether
#      widening the memo from per-CALL to per-WORKER pays depends on the batch
#      grain, so the grain has to be printed, not inferred.
#
#   2. `compiler_dict_mat_counter` counts `_materialize_dict_to_string` CALLS.
#      The parquet-side densification counter
#      (`komira_parquet/dict_mat_counter`) is structurally blind to a
#      compiler-side densification (for example a dictionary column densified
#      once per batch inside a CASE arm), so a zero there does NOT mean nothing
#      was densified anywhere. These slots count the compiler-side ones.
#
# COST MODEL — this is what makes it always-on rather than comptime-gated.
# Every counter here is flushed ONCE PER CALL (per batch), never per row. A
# query issues a few thousand of them, against kernels that each walk millions
# of bytes. `keyeq_census`'s warning ("never quote a wall time from a census
# build") applies to its PER-COMPARISON atomics and does NOT apply here.
#
# ⚠ THE ONE EXCEPTION IS `RXCENSUS_ROWS_ENABLED`, WHICH IS PER-ROW AND IS OFF.
# The memo's hit/miss/hashed-bytes split cannot be derived without three integer
# adds inside the per-row loop. They are cheap, but "cheap" is not "free" on the
# loop being measured, so they are comptime-erased by default and a census
# build flips them on. ⛔ A wall time taken with them ON is not comparable to
# one taken with them OFF.
#
# Storage mechanism: `GlobalCounterTable` (`global_counter.mojo`), the shared
# process-lifetime counter primitive (the same one `keyeq_census` uses) — no
# `unsafe_from_address`, no wildcard-origin field.
# =============================================================================

from komira_counters.global_counter import GlobalCounterTable


# -----------------------------------------------------------------------------
# THE PER-ROW GATE. False by default; flip to True for a memo-grain census run.
# -----------------------------------------------------------------------------
comptime RXCENSUS_ROWS_ENABLED: Bool = False


# Slot ids. Stable — APPEND only.
comptime RXC_N_SLOTS: Int = 16

comptime RXC_REPLACE_CALLS: Int = 0    # eval_regexp_replace invocations
comptime RXC_REPLACE_ROWS: Int = 1     # rows those invocations saw (incl. NULLs)
comptime RXC_MEMO_HITS: Int = 2        # rows answered from the memo   (ROWS gate)
comptime RXC_MEMO_VM: Int = 3          # rows that ran the Pike VM     (ROWS gate)
comptime RXC_MEMO_KEYBYTES: Int = 4    # subject bytes hashed by the memo (ROWS gate)
comptime RXC_MEMO_OFF_CALLS: Int = 5   # calls whose memo was never/no-longer on
comptime RXC_PROG_COMPILES: Int = 6    # RegexProgram.compile in the EXPR_REGEXP arm
comptime RXC_ARM_CALLS: Int = 7        # EXPR_REGEXP arm entries
comptime RXC_ARM_DICT: Int = 8         # ...of which the child was a DICTIONARY
comptime RXC_DICTMAT_ROWS: Int = 9     # rows densified by _materialize_dict_to_string
comptime RXC_DICTMAT_BYTES: Int = 10   # bytes those densifications produced


comptime _RXCENSUS_COUNTERS = GlobalCounterTable[
    "komira_core_instr_rxcensus_counters", RXC_N_SLOTS
]


@always_inline
def rxcensus_add(slot: Int, n: Int):
    """Add `n` to counter `slot`. NON-RAISING on purpose: an instrument must
    never change the control flow of the code it observes. A swallowed error
    can only mean the table failed to allocate, which reads as a zero slot."""
    _RXCENSUS_COUNTERS.try_add(slot, n)


def rxcensus_read(slot: Int) raises -> Int:
    """Read one counter."""
    return _RXCENSUS_COUNTERS.read(slot)


def rxcensus_reset() raises:
    """Zero every counter (harness setup between cells/reps)."""
    _RXCENSUS_COUNTERS.reset()
