# komira_core.instr — process-lifetime INSTRUMENTATION counters.
#
# Reach/fire-set witnesses that must be readable from a harness at a coarse
# boundary (per query, per rep) while being written from many worker threads.
# Everything here uses the `_Global` + `Atomic` process-lifetime idiom.
# `keyeq_census` is comptime-gated OFF, so the shipped binary pays exactly
# nothing for it. ⚠ `rxcensus` is NOT wholly gated, and that is deliberate: its
# counters are flushed ONCE PER CALL (per batch) — a few thousand relaxed
# atomics per query, against kernels that walk gigabytes — and a reach witness
# nobody can read without a rebuild is a witness nobody reads. Only its PER-ROW
# half (`RXCENSUS_ROWS_ENABLED`) is comptime-gated, because that half does sit
# inside the loop it measures.
#
# This is deliberately NOT `komira_obs` (the runtime metrics tier): these
# counters exist to answer "does this code path RUN, on which query, on how wide
# a key" during a measurement run, and they are expected to be flipped on,
# read once, and flipped off again.

from .rxcensus import (
    RXCENSUS_ROWS_ENABLED,
    RXC_N_SLOTS,
    RXC_REPLACE_CALLS,
    RXC_REPLACE_ROWS,
    RXC_MEMO_HITS,
    RXC_MEMO_VM,
    RXC_MEMO_KEYBYTES,
    RXC_MEMO_OFF_CALLS,
    RXC_PROG_COMPILES,
    RXC_ARM_CALLS,
    RXC_ARM_DICT,
    RXC_DICTMAT_ROWS,
    RXC_DICTMAT_BYTES,
    rxcensus_add,
    rxcensus_read,
    rxcensus_reset,
)

from .keyeq_census import (
    KEYEQ_CENSUS_ENABLED,
    KEYEQ_N_SITES,
    keyeq_record,
    keyeq_read,
    keyeq_reset,
    keyeq_dump,
    keyeq_site_name,
)
