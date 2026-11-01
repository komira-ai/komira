# =============================================================================
# hugepage_span.mojo — LEVER P: first-touch page-fault tax on large buffers
# =============================================================================
#
# # What this module is
#
# PURE integer math + advice-mode parsing for the large-allocation memory
# advice hint applied by `OwnedAlignedBuffer.__init__`. This module contains
# NO FFI and NO pointers — it takes an address as a plain `Int` and returns a
# RELATIVE `HugepageSpan(offset, length)`. The caller does `ptr + offset` on
# its own live pointer, so no pointer is ever reconstructed from an integer
# (never `unsafe_from_address=Int(...)`) and nothing unsafe
# crosses a module boundary. The `madvise(2)` call itself lives in
# `owned_aligned_buffer.mojo`, the module that OWNS the allocation.
#
# Splitting the math out is what makes the hint TESTABLE: the span contract
# (containment, alignment, maximality) is checked directly by the hugepage
# hint tests without allocating anything.
#
# # Why it exists
#
# A large materialize destination (e.g. a 100M-row concat target: 100M x 8 B +
# 100M x 4 B = 1.2 GB) is ~290,000 separate 4 KiB first-touch fault traps.
#
# # ⚠ CAVEATS — read before enabling
#
#   1. `MADV_HUGEPAGE` is a STRICT NO-OP for any process that has
#      `PR_SET_THP_DISABLE` set. That flag is INHERITED across fork/exec, so a
#      parent that sets it disables the hint for every child it spawns
#      (`THP_enabled: 0` and `THPeligible: 0` on every VMA).
#   2. When THP IS available, the hint is a large win in steady state
#      (768 MiB dense first-touch: roughly 3x faster, 196,608 faults -> 384)
#      but the FIRST large madvised allocation on a fragmented host pays
#      SYNCHRONOUS direct compaction when the host runs `defrag=[madvise]`
#      (several times WORSE than baseline, before the buddy allocator warms
#      up).
#   3. `MADV_POPULATE_WRITE` is the variant that is INDEPENDENT of THP policy:
#      it replaces N individual fault traps with one kernel-side populate loop,
#      and helps even with THP fully disabled. It does NOT modify page contents
#      (man 2 madvise).
#   4. ⚠ RSS AMPLIFICATION — up to 512x on a SPARSELY touched buffer, because a
#      single byte touched inside a 2 MiB range makes the whole 2 MiB resident.
#      On a 768 MiB region with THP enabled:
#
#        touch pattern          RSS without hint   RSS with MADV_HUGEPAGE
#        every 4 KiB (dense)        786,432 kB          786,432 kB   (no cost)
#        one per 2 MiB                1,536 kB          786,432 kB   (512x)
#        one per 16 MiB                 192 kB           98,304 kB   (512x)
#
#      A dense concat destination pays nothing. But `OwnedAlignedBuffer` is the
#      allocator for hundreds of sites and its ctor CANNOT know which of them
#      densely fill their buffer, so the advice is a TARGETED opt-in: the
#      caller of `OwnedAlignedBuffer(capacity, memory_advice=...)` at a
#      known-dense destination supplies it; the plain ctor never advises.
#      `populate` does not have this failure mode in the same way — it
#      pre-faults exactly the range, at 4 KiB granularity.
#
# This is why the default is OFF and the mode is multi-valued.
#
# # `auto` — HOST DETECTION
#
# The `auto` mode resolves from the host's own THP policy
# (`komira_host.thp_policy`), probed once per process and defaulting to
# `ADVICE_OFF` on anything unrecognised, missing or unreadable. The full
# decision table and the reasoning for each row live in that module's header.
# =============================================================================

from komira_host.thp_policy import (
    hugepage_auto_advice_mode,
)
from komira_host.thp_policy import ADVICE_HUGEPAGE as _ADVICE_HUGEPAGE
from komira_host.thp_policy import ADVICE_OFF as _ADVICE_OFF
from komira_host.thp_policy import ADVICE_POPULATE as _ADVICE_POPULATE


# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

comptime HUGEPAGE_BYTES: Int = 2 * 1024 * 1024
"""`x86_64` / aarch64 PMD-order transparent-hugepage size (2 MiB). Matches
`/sys/kernel/mm/transparent_hugepage/hpage_pmd_size` on common hosts."""

comptime HUGEPAGE_MIN_ALLOC_BYTES: Int = 8 * 1024 * 1024
"""Allocation-size floor below which NO advice is applied.

2 MiB is the natural floor (one hugepage), but advising every mid-sized buffer
costs a syscall per allocation for at most one or two hugepages of benefit. 8
MiB (4 hugepages) keeps the hint on the genuinely large materialize
destinations — large concat targets are hundreds of MB — and off the decode
scratch buffers."""

comptime ADVICE_OFF: Int = _ADVICE_OFF
comptime ADVICE_HUGEPAGE: Int = _ADVICE_HUGEPAGE
comptime ADVICE_POPULATE: Int = _ADVICE_POPULATE
"""The advice vocabulary. DEFINED in `komira_host.thp_policy` (which
must not import this module, or the import graph cycles) and aliased here,
which is where every consumer already imports them from."""


# -----------------------------------------------------------------------------
# HugepageSpan
# -----------------------------------------------------------------------------


struct HugepageSpan(Copyable, Movable):
    """The hugepage-aligned sub-interval of an allocation, expressed RELATIVE
    to the allocation's base.

    `offset` is a byte offset from the base pointer; `length` is the byte
    count. Both are 0 for the empty span (no advice should be applied).

    Deliberately carries no pointer: the caller reconstitutes the target as
    `base_ptr + offset` from the live pointer it already holds.
    """

    var offset: Int
    var length: Int

    @always_inline
    def __init__(out self, offset: Int, length: Int):
        self.offset = offset
        self.length = length

    @always_inline
    def is_empty(self) -> Bool:
        """True when no advice should be applied."""
        return self.length <= 0


# -----------------------------------------------------------------------------
# The span computation — pure, total, and the thing the oracle tests
# -----------------------------------------------------------------------------


def hugepage_span(base_addr: Int, size: Int) -> HugepageSpan:
    """Return the MAXIMAL hugepage-aligned sub-interval of
    `[base_addr, base_addr + size)`, relative to `base_addr`.

    Contract (each clause is asserted by the hugepage hint tests):

      * CONTAINMENT — `0 <= offset` and `offset + length <= size`. The returned
        interval NEVER extends past the allocation. This is the load-bearing
        safety property: `madvise` on a range that leaves the mapping returns
        ENOMEM, and on a range that reaches into an ADJACENT mapping would
        apply the advice to memory we do not own.
      * ALIGNMENT — `(base_addr + offset) % HUGEPAGE_BYTES == 0`, so the kernel
        can back the interval with PMD-order pages.
      * WHOLE PAGES — `length % HUGEPAGE_BYTES == 0`.
      * MAXIMALITY — no larger interval satisfies the above.
      * THRESHOLD — empty whenever `size < HUGEPAGE_MIN_ALLOC_BYTES`.

    Total: returns the empty span rather than raising for non-positive or
    degenerate inputs.

    Args:
        base_addr: Address of the allocation's first byte, as an integer. Only
            used for modular arithmetic; no pointer is derived from it.
        size: Usable byte count starting at `base_addr`.

    Returns:
        The relative aligned interval, or an empty span when none qualifies.
    """
    if base_addr <= 0 or size < HUGEPAGE_MIN_ALLOC_BYTES:
        return HugepageSpan(0, 0)

    var end_addr = base_addr + size
    # Round the start UP and the end DOWN so the result is strictly interior.
    var start = ((base_addr + HUGEPAGE_BYTES - 1) // HUGEPAGE_BYTES) * (
        HUGEPAGE_BYTES
    )
    var end = (end_addr // HUGEPAGE_BYTES) * HUGEPAGE_BYTES
    if end <= start:
        return HugepageSpan(0, 0)
    return HugepageSpan(start - base_addr, end - start)


# -----------------------------------------------------------------------------
# Mode parsing
# -----------------------------------------------------------------------------


def parse_memory_advice(value: String) raises -> Int:
    """Parse a memory-advice mode name into an ADVICE_* bitmask.

    The caller (a binary's flag parser, or a test) turns the configured value
    into the mode once and passes the mode to
    `OwnedAlignedBuffer(capacity, memory_advice=...)`; no allocation reads a
    global to find it.

        "" / 0 / off / false / no / none  -> ADVICE_OFF
        1 / on / true / yes / hugepage    -> ADVICE_HUGEPAGE
        populate                          -> ADVICE_POPULATE
        both                              -> ADVICE_HUGEPAGE | ADVICE_POPULATE
        auto                              -> whatever THIS HOST supports, or OFF

    The explicit values WIN over detection in both directions: `0` forces OFF
    on a capable host, and `1` forces the advice on an incapable one (where
    `madvise` is a harmless no-op that returns an error we already ignore).
    Only `auto` touches the host probe, and that probe is frozen per process
    (`thp_probe_count()` is its falsifier).

    Args:
        value: The configured mode name.

    Returns:
        The ADVICE_* bitmask.

    Raises:
        Error: naming the value, when it is not one of the spellings above.
    """
    if value.byte_length() == 0:
        return ADVICE_OFF
    if (
        value == "0"
        or value == "off"
        or value == "false"
        or value == "no"
        or value == "none"
    ):
        return ADVICE_OFF
    if (
        value == "1"
        or value == "on"
        or value == "true"
        or value == "yes"
        or value == "hugepage"
    ):
        return ADVICE_HUGEPAGE
    if value == "auto":
        return hugepage_auto_advice_mode()
    if value == "populate":
        return ADVICE_POPULATE
    if value == "both":
        return ADVICE_HUGEPAGE | ADVICE_POPULATE
    raise Error(
        String("unknown memory advice mode: '")
        + value
        + String(
            "' (expected one of: off, 0, false, no, none, on, 1, true, yes,"
            " hugepage, populate, both, auto)"
        )
    )
