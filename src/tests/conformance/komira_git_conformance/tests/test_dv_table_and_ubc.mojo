# =============================================================================
# komira_git_conformance/tests/test_dv_table_and_ubc.mojo -- komira_git's
# disturbance-vector table and unavoidable-bit-condition check against
# sha1collisiondetection's C.
# =============================================================================
#
# WHAT EACH TEST CATCHES:
#   * test_dv_table: a DV missing, out of order, or with a wrong type, K, b
#     or recompression step; a DV whose mask bit is not its index; any of
#     the 80 words of a DV's message difference that differs from upstream's
#     table (komira_git keeps the first 16 and expands them with its own
#     `_expand`, so this also checks that expansion).
#     It also checks that `_ALL_DVS`, the mask sha1dc checks with the
#     filter off, is the OR of every DV's upstream mask bit, so an edit to
#     that constant that drops a DV is caught (its use in `_process` is
#     pinned by test_recompression).
#   * test_ubc_random_words: any statement of `_ubc_check` that disagrees
#     with upstream's `ubc_check`. The input is 80 arbitrary words (the
#     check reads them as given, expanded or not), 2^20 of them, four words
#     redrawn each time. Every DV's bit must also survive in some mask, so
#     each DV's last conditions (the ones read only while its bit is still
#     set) were evaluated with the bit set, and agreed.
#   * test_ubc_expanded_blocks: the same over expanded message blocks, the
#     input the check gets in sha1dc: random blocks and every block of both
#     SHAttered PDFs.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_git.sha1dc import _expand
from komira_git.sha1dc_ubc import _ALL_DVS, _DV_COUNT, _dv_field, _dv_word, _ubc_check

from komira_git_conformance import c_dv_count, c_dv_field, c_dv_word, c_ubc_check


struct _Rng(Movable):
    var x: UInt64

    def __init__(out self, seed: UInt64):
        self.x = seed

    def next(mut self) -> UInt32:
        self.x = self.x * 6364136223846793005 + 1442695040888963407
        return UInt32(self.x >> 32)


def test_dv_table() raises:
    assert_equal(c_dv_count(), _DV_COUNT)
    var all_bits: UInt32 = 0
    for dv in range(_DV_COUNT):
        for f in range(4):
            assert_equal(
                _dv_field(dv, f),
                c_dv_field(dv, f),
                "DV " + String(dv) + " field " + String(f),
            )
        assert_equal(c_dv_field(dv, 4), 0, "maski of DV " + String(dv))
        assert_equal(c_dv_field(dv, 5), dv, "maskb of DV " + String(dv))
        all_bits |= UInt32(1) << UInt32(c_dv_field(dv, 5))
        var dm = InlineArray[UInt32, 80](fill=0)
        for t in range(16):
            dm[t] = _dv_word(dv, t)
        _expand(dm)
        for t in range(80):
            assert_equal(
                dm[t], c_dv_word(dv, t), "DV " + String(dv) + " dm[" + String(t) + "]"
            )
    assert_equal(all_bits, UInt32(0xFFFFFFFF))
    assert_equal(_ALL_DVS, all_bits, "the filter-off mask")


def test_ubc_random_words() raises:
    var rng = _Rng(0x5DC0FFEE)
    var w = InlineArray[UInt32, 80](fill=0)
    for t in range(80):
        w[t] = rng.next()
    var seen: UInt32 = 0
    for trial in range(1 << 20):
        for _ in range(4):
            w[Int(rng.next() % 80)] = rng.next()
        var want = c_ubc_check(w)
        var got = _ubc_check(w)
        if got != want:
            assert_equal(got, want, "trial " + String(trial))
        seen |= want
    for dv in range(_DV_COUNT):
        assert_true(
            ((seen >> UInt32(dv)) & 1) == 1,
            "DV " + String(dv) + " never survived the check",
        )


def _check_block(w: InlineArray[UInt32, 80], what: String) raises:
    var want = c_ubc_check(w)
    var got = _ubc_check(w)
    if got != want:
        assert_equal(got, want, what)


def test_ubc_expanded_blocks() raises:
    var rng = _Rng(0x0BADC0DE)
    var w = InlineArray[UInt32, 80](fill=0)
    for trial in range(1 << 16):
        for t in range(16):
            w[t] = rng.next()
        _expand(w)
        _check_block(w, "random block " + String(trial))
    for f in range(2):
        var name = String("sha1dc/test/shattered-") + String(f + 1) + ".pdf"
        var data = Path(name).read_bytes()
        var blocks = len(data) // 64
        for b in range(blocks):
            for t in range(16):
                var p = 64 * b + 4 * t
                w[t] = (
                    (UInt32(data[p]) << 24)
                    | (UInt32(data[p + 1]) << 16)
                    | (UInt32(data[p + 2]) << 8)
                    | UInt32(data[p + 3])
                )
            _expand(w)
            _check_block(w, name + " block " + String(b))


def main() raises:
    test_dv_table()
    test_ubc_random_words()
    test_ubc_expanded_blocks()
    print("komira_git_conformance dv table and ubc tests passed")
