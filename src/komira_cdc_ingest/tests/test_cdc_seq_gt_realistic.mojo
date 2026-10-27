# =============================================================================
# test_cdc_seq_gt_realistic.mojo — seq_gt over realistic sequence numbers.
# =============================================================================
#
# `seq_gt` orders bare decimal sequence numbers by numeric magnitude (strip
# leading zeros; the value with more significant digits is larger; equal widths
# compare lexicographically). Real stream sequence numbers are about 28-digit bare
# decimals that are not zero-padded to a fixed width, so different records can
# have different digit widths. That is the branch a plain lexicographic compare
# gets wrong.
#
# Fixtures that use equal-width strings never exercise the significant-digit-count
# branch. These tests use realistic non-zero-padded sequences of different widths,
# including a shorter-but-larger-leading-digit against a longer-but-smaller pair:
# a lexicographic compare calls the 28-digit "9..." greater than the 29-digit
# "1...", which is numerically wrong.
# =============================================================================

from std.testing import assert_true, assert_false

from komira_cdc_ingest import seq_gt


def test_seq_gt_shorter_but_larger_leading_digit_is_smaller() raises:
    """A SHORTER-but-larger-leading-digit sequence vs a LONGER-but-smaller-
    leading-digit one: the LONGER (more significant digits) is numerically
    larger, even though its leading digit is smaller.

    This is the case a naive lexicographic compare gets WRONG: byte-wise "9" >
    "1", so a lexicographic compare would call the 28-digit "9..." greater than
    the 29-digit "1...", but numerically the 29-digit value is larger."""
    # 28 digits, leading 9.
    var shorter = String("9876543210987654321098765432")
    # 29 digits, leading 1 (numerically LARGER than any 28-digit value).
    var longer = String("10000000000000000000000000000")
    assert_true(
        shorter.byte_length() == 28, "shorter is 28 digits"
    )
    assert_true(
        longer.byte_length() == 29, "longer is 29 digits"
    )
    # longer (more significant digits) > shorter — numerically correct.
    assert_true(
        seq_gt(longer, shorter),
        "29-digit value > 28-digit value (more significant digits wins)",
    )
    # And the reverse is false.
    assert_false(
        seq_gt(shorter, longer),
        "28-digit value is NOT > 29-digit value (a lexicographic compare would"
        " wrongly say it is, because byte '9' > '1')",
    )


def test_seq_gt_same_width_realistic_28_digit() raises:
    """Two realistic ~28-digit sequences of the SAME width order by their first
    differing digit (== numeric for equal-width bare decimals)."""
    # Realistic 28-digit sequences (not zero-padded, differ mid-
    # string). a > b: they share a long prefix then a's digit is larger.
    var a = String("4966146960000000000000000123457")
    var b = String("4966146960000000000000000123456")
    assert_true(a.byte_length() == b.byte_length(), "same width")
    assert_true(seq_gt(a, b), "a > b at the last differing digit")
    assert_false(seq_gt(b, a), "b is not > a")


def test_seq_gt_advancing_realistic_stream() raises:
    """An ADVANCING realistic stream: a later record's sequence (one more digit
    of magnitude, or a larger same-width value) is strictly greater than the
    committed position — the exactly-once idempotence gate's real input shape."""
    # Committed position ~28 digits; the next record crosses to 29 digits.
    var committed = String("4966146960000000000000000999999")
    var next_rec = String("49661469600000000000000010000000")
    assert_true(committed.byte_length() == 31, "committed width")
    assert_true(next_rec.byte_length() == 32, "next_rec is one digit wider (advanced)")
    assert_true(
        seq_gt(next_rec, committed),
        "the advanced record is > the committed position (would be APPLIED)",
    )
    assert_false(
        seq_gt(committed, next_rec),
        "the committed position is NOT > the advanced record",
    )


def test_seq_gt_empty_committed_admits_everything() raises:
    """A cold start (empty committed position) means every real sequence is
    greater — the record is applied (the documented `seq_gt(a, "")` contract)."""
    var real = String("4966146960000000000000000123456")
    assert_true(seq_gt(real, String("")), "any real seq > empty (cold start)")
    assert_false(seq_gt(String(""), real), "empty is not > a real seq")


def main() raises:
    test_seq_gt_shorter_but_larger_leading_digit_is_smaller()
    test_seq_gt_same_width_realistic_28_digit()
    test_seq_gt_advancing_realistic_stream()
    test_seq_gt_empty_committed_admits_everything()
    print("test_cdc_seq_gt_realistic: ALL PASS")
