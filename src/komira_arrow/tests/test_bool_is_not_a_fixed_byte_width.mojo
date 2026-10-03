# =============================================================================
# BOOL IS BIT-PACKED, AND THE FIXED-BYTE-WIDTH ORACLE MUST SAY SO
# =============================================================================
#
# THE ONE MECHANISM BEHIND TWO FAILURE MODES, pinned here as a falsifier.
#
# Several operator-surface paths ask a FIXED-BYTE-WIDTH oracle for a per-row
# width and then do `num_rows * width` byte arithmetic. BOOL has no such width
# — its buffer is `(n + 7) >> 3` bytes — so for BOOL that arithmetic is not
# imprecise, it is the WRONG SHAPE. Two regimes follow, and they are the same
# defect, not two:
#
#   REGIME 1 (the oracle GUESSES).  An `element_size` ending in
#   `else: return 8` gives BOOL 8 bytes/row: a **64x over-read** of a
#   bit-packed buffer. That is the process-killer half — a carried BOOL
#   column rebuilt by a morsel filter (`element_size(at)` in the engine
#   scheduler) copies `num_rows * 8` bytes out of a buffer holding
#   `(num_rows + 7) >> 3`. More columns = more over-reads.
#
#   REGIME 2 (the oracle REFUSES).  With no `return 8` fallback, the SAME
#   input RAISES and names the type. That is the
#   width-oracle-consumers-that-RAISE half.
#
# ⚠ SO THE TWO HALVES ARE ONE MECHANISM IN TWO REGIMES, and which regime a
# given site is in is decided by ONE thing: whether it routes through
# `arrow_fixed_byte_width`. This test pins the oracle's refusal, because the
# refusal is what holds regime 2 in place. If someone "fixes" a BOOL raise by
# restoring a byte-width answer, the over-read comes back everywhere at once
# and this test is what goes red.
#
# ⚠ THE REFUSAL IS NOT THE FIX, AND MUST NOT BE READ AS ONE. A raise means a
# carried BOOL column cannot flow through the path at all. The fix is a
# bit-packed ARM at each site (`_copy_column`, `scan_source.next_morsel`,
# `gather_batch_dispatch`, the morsel filter, the pipeline column gather and
# the parquet empty-column ladder each have one, via
# `copy_bits_aligned_buffer`).
#
# ⇒ THIS FILE'S JOB IS PURELY THE ORACLE'S REFUSAL; the arms are pinned by the
# carried-BOOL gather/filter tests and the zero-row parquet BOOL column test.
# The two are complementary and BOTH are needed: without the arm tests, "BOOL
# raises" is satisfied by an engine that cannot process bool at all; without
# this one, an arm test is satisfied by re-adding `return 8` and reinstating
# the 64x over-read everywhere at once.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_arrow.arrow_types import ArrowType, arrow_fixed_byte_width


def test_bool_has_no_fixed_byte_width() raises:
    """`arrow_fixed_byte_width(BOOL)` must RAISE, not answer.

    Any answer at all is wrong: 1 makes a caller copy 8x too few bytes, 8
    makes it over-read 64x. This is the assertion that keeps regime 2 in
    place tree-wide.
    """
    var raised = False
    try:
        var _w = arrow_fixed_byte_width(ArrowType.BOOL)
    except e:
        raised = True
        # The message must NAME the type — a caller that hits this needs to
        # know which column, not merely that something was unsupported.
        assert_true("BOOL" in String(e) or "bit-packed" in String(e))
    assert_true(
        raised,
        "arrow_fixed_byte_width(BOOL) returned a width. BOOL is bit-packed;"
        " a per-row byte width re-enables the 64x over-read.",
    )


def test_the_neighbouring_fixed_width_types_still_answer() raises:
    """The control: refusing BOOL must not have broken the real fixed widths.

    Without this leg the test above is satisfied by an oracle that raises for
    everything.
    """
    assert_equal(arrow_fixed_byte_width(ArrowType.INT8), 1)
    assert_equal(arrow_fixed_byte_width(ArrowType.INT32), 4)
    assert_equal(arrow_fixed_byte_width(ArrowType.INT64), 8)
    assert_equal(arrow_fixed_byte_width(ArrowType.FLOAT64), 8)
    # DATE32 is 4, not 8 — a `return 8` fallback gives it a silently wrong
    # width too.
    assert_equal(arrow_fixed_byte_width(ArrowType.DATE32), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
