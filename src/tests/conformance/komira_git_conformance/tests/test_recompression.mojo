# =============================================================================
# komira_git_conformance/tests/test_recompression.mojo -- the disturbance-
# vector loop of komira_git's `Sha1dc`, one DV at a time, against
# sha1collisiondetection's C.
# =============================================================================
#
# Upstream's SHA1_CTX keeps the expanded message (m2) and the starting
# chaining value (ihv2) of the last DV its block check recompressed; `Sha1dc`
# keeps the same two (`_m2`, `_ihv2`). With the bit-condition filter on, the
# last DV checked is the highest bit of the block's ubc mask.
#
# WHAT THE TEST CATCHES:
#   * test_last_dv_every_dv: for every DV k (0 to 31), two generated blocks
#     whose ubc mask has k as its highest bit, each hashed after a generated
#     first block (so the chaining value is not the IV). After the two blocks
#     both sides must hold the same m2 (all 80 words) and ihv2. The test also
#     checks that upstream's m2 is the block's words xor DV k's difference,
#     so each case pins DV k. It catches a loop that skips DVs or stops
#     early, a mask bit read for the wrong DV, a DV recompressed from the
#     wrong stored state (58 for 65 or the reverse), the wrong difference
#     applied, and a backward recompression that differs from upstream's.
#     Only the last DV recompressed for a block is observable this way,
#     which is why the cases are chosen by highest bit. A missed detection
#     itself (the final comparison) is pinned by test_digests on the
#     SHAttered PDFs, through DV 27 only.
#   * test_filter_off_checks_every_dv: with the filter off on both sides
#     (`set_use_ubc(False)`), upstream recompresses every DV for every
#     block, so its last is DV 31 whatever the block. Random two-block
#     inputs must leave the same m2 and ihv2 on both sides, and upstream's
#     m2 must be DV 31's. It catches a filter-off mask that leaves out
#     DV 31 (one that leaves out another DV is caught by test_dv_table's
#     check of `_ALL_DVS`), and a filter-off path that still applies the
#     filter.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import Sha1dc
from komira_git.sha1dc import _expand
from komira_git.sha1dc_ubc import _DV_COUNT

from komira_git_conformance import CSha1dc, c_dv_word, c_ubc_check

comptime _CASES_PER_DV = 2
comptime _MAX_TRIALS = 1 << 22
comptime _FILTER_OFF_CASES = 16


struct _Rng(Movable):
    var x: UInt64

    def __init__(out self, seed: UInt64):
        self.x = seed

    def next(mut self) -> UInt32:
        self.x = self.x * 6364136223846793005 + 1442695040888963407
        return UInt32(self.x >> 32)


def _top_bit(mask: UInt32) -> Int:
    """The index of the highest set bit of a non-zero `mask`."""
    var k = 31
    while ((mask >> UInt32(k)) & 1) == 0:
        k -= 1
    return k


def _put_word(mut data: List[UInt8], pos: Int, v: UInt32):
    data[pos] = UInt8(v >> 24)
    data[pos + 1] = UInt8((v >> 16) & 0xFF)
    data[pos + 2] = UInt8((v >> 8) & 0xFF)
    data[pos + 3] = UInt8(v & 0xFF)


def _check_case(
    mut rng: _Rng,
    w: InlineArray[UInt32, 80],
    dv: Int,
    use_ubc: Bool,
    what: String,
) raises:
    var data = List[UInt8](length=128, fill=0)
    for t in range(16):
        _put_word(data, 4 * t, rng.next())
        _put_word(data, 64 + 4 * t, w[t])
    var ours = Sha1dc()
    ours.set_use_ubc(use_ubc)
    ours.update(Span(data))
    var theirs = CSha1dc()
    theirs.set_use_ubc(use_ubc)
    theirs.update(Span(data))
    var ihv2 = InlineArray[UInt32, 5](fill=0)
    var m2 = InlineArray[UInt32, 80](fill=0)
    theirs.last_recompression(ihv2, m2)
    for t in range(80):
        if (m2[t] ^ w[t]) != c_dv_word(dv, t):
            assert_equal(
                m2[t] ^ w[t], c_dv_word(dv, t), what + ": upstream's last DV"
            )
        if ours._m2[t] != m2[t]:
            assert_equal(ours._m2[t], m2[t], what + ": m2[" + String(t) + "]")
    for i in range(5):
        if ours._ihv2[i] != ihv2[i]:
            assert_equal(
                ours._ihv2[i], ihv2[i], what + ": ihv2[" + String(i) + "]"
            )


def test_last_dv_every_dv() raises:
    var rng = _Rng(0xD15C0DE5)
    var hits = InlineArray[Int, _DV_COUNT](fill=0)
    var covered = 0
    var w = InlineArray[UInt32, 80](fill=0)
    var trial = 0
    while covered < _DV_COUNT and trial < _MAX_TRIALS:
        trial += 1
        for t in range(16):
            w[t] = rng.next()
        _expand(w)
        var mask = c_ubc_check(w)
        if mask == 0:
            continue
        var dv = _top_bit(mask)
        if hits[dv] >= _CASES_PER_DV:
            continue
        hits[dv] += 1
        if hits[dv] == _CASES_PER_DV:
            covered += 1
        _check_case(
            rng,
            w,
            dv,
            True,
            "DV " + String(dv) + ", trial " + String(trial),
        )
    for dv in range(_DV_COUNT):
        assert_equal(
            hits[dv],
            _CASES_PER_DV,
            "blocks whose highest ubc bit is DV " + String(dv),
        )
    assert_true(covered == _DV_COUNT)


def test_filter_off_checks_every_dv() raises:
    var rng = _Rng(0x0FF0FF0F)
    var w = InlineArray[UInt32, 80](fill=0)
    for n in range(_FILTER_OFF_CASES):
        for t in range(16):
            w[t] = rng.next()
        _expand(w)
        _check_case(
            rng, w, _DV_COUNT - 1, False, "filter off, case " + String(n)
        )


def main() raises:
    test_last_dv_every_dv()
    test_filter_off_checks_every_dv()
    print("komira_git_conformance recompression tests passed")
