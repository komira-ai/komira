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
#     m2 and ihv2 show only the last DV recompressed for a block, which is
#     why the cases are chosen by highest bit. The set of DVs recompressed
#     (`_recompressed`) must also equal upstream's ubc_check mask for the
#     block; here a lower bit is only whatever the random block happened
#     to set, so dropping a DV below the highest is pinned by the next leg.
#   * test_every_dv_below_a_higher_one: for every DV k (0 to 30), two
#     blocks whose ubc mask has k set and a higher DV set too, with
#     `_recompressed` equal to upstream's mask and m2/ihv2 equal to its
#     last DV's. Random blocks almost never set two of DVs 27 to 31 (none
#     of DVs 27 to 30 below a higher DV in 2^22 trials), so the blocks are
#     sampled from those meeting the unavoidable bit conditions of DV 31,
#     then 30, 29, 28 and 27 (`_ubc_conditions`, linear in the 512 input
#     bits, solved over GF(2)). Every sample must have that DV in C's
#     mask, so a misread condition fails the test rather than skipping
#     cases. It catches a loop or mask that drops any DV while a higher
#     one is set.
#     A missed detection itself (the final comparison) is pinned by
#     test_digests on the SHAttered PDFs, through DV 27 only.
#   * test_filter_off_checks_every_dv: with the filter off on both sides
#     (`set_use_ubc(False)`), upstream recompresses every DV for every
#     block, so its last is DV 31 whatever the block. Random two-block
#     inputs must leave the same m2 and ihv2 on both sides, upstream's m2
#     must be DV 31's, and `_recompressed` must have all 32 bits set.
#     It catches a filter-off mask that leaves out any DV, whether the
#     constant `_ALL_DVS` or the line in `_process` that uses it is
#     narrowed, and a filter-off path that still applies the filter.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import Sha1dc
from komira_git.sha1dc import _expand
from komira_git.sha1dc_ubc import _DV_COUNT

from komira_git_conformance import CSha1dc, c_dv_word, c_ubc_check

comptime _CASES_PER_DV = 2
comptime _MAX_TRIALS = 1 << 22
comptime _FILTER_OFF_CASES = 16
comptime _MAX_SAMPLES = 1 << 20


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
    # Upstream's loop recompresses exactly the DVs of its mask: ubc_check's
    # with the filter on, every bit with it off.
    var expected = c_ubc_check(w) if use_ubc else UInt32(0xFFFFFFFF)
    assert_equal(
        ours._recompressed, expected, what + ": the DVs recompressed"
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


# A linear form over the 512 bits of a block's 16 input words is 8 UInt64s:
# bit 32 * t + b is bit b of input word t.
comptime _LIMBS = 8


def _parity(v: UInt64) -> UInt64:
    var p = v ^ (v >> 32)
    p ^= p >> 16
    p ^= p >> 8
    p ^= p >> 4
    p ^= p >> 2
    p ^= p >> 1
    return p & 1


def _word_forms() -> List[UInt64]:
    """Bit b of expanded word t, as a linear form over the input bits, at
    limbs _LIMBS * (32 * t + b). SHA-1's expansion is linear: bit b of
    rotl1(x) is bit b - 1 of x."""
    var f = List[UInt64](length=80 * 32 * _LIMBS, fill=0)
    for t in range(16):
        for b in range(32):
            var i = 32 * t + b
            f[_LIMBS * i + i // 64] = UInt64(1) << UInt64(i % 64)
    for t in range(16, 80):
        for b in range(32):
            var src = (b + 31) % 32
            for l in range(_LIMBS):
                f[_LIMBS * (32 * t + b) + l] = (
                    f[_LIMBS * (32 * (t - 3) + src) + l]
                    ^ f[_LIMBS * (32 * (t - 8) + src) + l]
                    ^ f[_LIMBS * (32 * (t - 14) + src) + l]
                    ^ f[_LIMBS * (32 * (t - 16) + src) + l]
                )
    return f^


struct _AffineSet(Movable):
    """The blocks meeting a set of conditions `bit pa of W[a] xor bit pc of
    W[c] == v`, kept as equations over the input bits in reduced row
    echelon form (each row's pivot bit appears in no other row)."""

    var forms: List[UInt64]
    var rows: List[UInt64]
    var rhs: List[UInt64]
    var pivot: List[Int]

    def __init__(out self):
        self.forms = _word_forms()
        self.rows = List[UInt64]()
        self.rhs = List[UInt64]()
        self.pivot = List[Int]()

    def add(mut self, a: Int, pa: Int, c: Int, pc: Int, v: Int) raises:
        var row = InlineArray[UInt64, _LIMBS](fill=0)
        for l in range(_LIMBS):
            row[l] = (
                self.forms[_LIMBS * (32 * a + pa) + l]
                ^ self.forms[_LIMBS * (32 * c + pc) + l]
            )
        var r = UInt64(v)
        for i in range(len(self.pivot)):
            var p = self.pivot[i]
            if ((row[p // 64] >> UInt64(p % 64)) & 1) == 1:
                for l in range(_LIMBS):
                    row[l] ^= self.rows[_LIMBS * i + l]
                r ^= self.rhs[i]
        var p = -1
        for i in range(64 * _LIMBS):
            if ((row[i // 64] >> UInt64(i % 64)) & 1) == 1:
                p = i
                break
        if p < 0:
            # Implied by the rows already kept; a contradiction is an error.
            assert_equal(
                r,
                UInt64(0),
                "condition W["
                + String(a)
                + "]."
                + String(pa)
                + " ^ W["
                + String(c)
                + "]."
                + String(pc)
                + " == "
                + String(v)
                + " contradicts the others",
            )
            return
        for i in range(len(self.pivot)):
            var word = _LIMBS * i + p // 64
            if ((self.rows[word] >> UInt64(p % 64)) & 1) == 1:
                for l in range(_LIMBS):
                    self.rows[_LIMBS * i + l] ^= row[l]
                self.rhs[i] ^= r
        for l in range(_LIMBS):
            self.rows.append(row[l])
        self.rhs.append(r)
        self.pivot.append(p)

    def sample(self, mut rng: _Rng, mut w: InlineArray[UInt32, 80]):
        """A random block meeting every condition, its 16 words in w[0:16]:
        random bits, then each row's pivot bit flipped if the row fails."""
        var x = InlineArray[UInt64, _LIMBS](fill=0)
        for l in range(_LIMBS):
            x[l] = (UInt64(rng.next()) << 32) | UInt64(rng.next())
        for i in range(len(self.pivot)):
            var acc: UInt64 = 0
            for l in range(_LIMBS):
                acc ^= self.rows[_LIMBS * i + l] & x[l]
            if _parity(acc) != self.rhs[i]:
                var p = self.pivot[i]
                x[p // 64] ^= UInt64(1) << UInt64(p % 64)
        for t in range(16):
            w[t] = UInt32((x[t // 2] >> UInt64(32 * (t % 2))) & 0xFFFFFFFF)


def _ubc_conditions(dv: Int) raises -> _AffineSet:
    """The unavoidable bit conditions of DV `dv` (27 to 31: II(52,0) to
    II(56,0)) in upstream's ubc_check, read off it as `bit pa of W[a] xor
    bit pc of W[c] == v`. Only a sampling aid: every sample is checked
    against C's mask."""
    var s = _AffineSet()
    if dv == 31:
        s.add(49, 29, 50, 29, 0)
        s.add(47, 4, 50, 29, 0)
        s.add(40, 29, 41, 29, 0)
        s.add(54, 29, 55, 29, 0)
        s.add(50, 29, 51, 29, 0)
        s.add(40, 4, 43, 29, 0)
        s.add(38, 4, 41, 29, 0)
        s.add(55, 29, 56, 29, 0)
        s.add(52, 4, 55, 29, 0)
        s.add(40, 4, 42, 4, 1)
        s.add(38, 4, 40, 4, 1)
        s.add(60, 4, 64, 29, 0)
        s.add(44, 3, 48, 28, 0)
        s.add(44, 4, 48, 29, 0)
    elif dv == 30:
        s.add(49, 29, 50, 29, 0)
        s.add(48, 29, 49, 29, 0)
        s.add(46, 4, 49, 29, 0)
        s.add(54, 29, 55, 29, 0)
        s.add(53, 29, 54, 29, 0)
        s.add(39, 4, 42, 29, 0)
        s.add(37, 4, 40, 29, 0)
        s.add(51, 4, 54, 29, 0)
        s.add(39, 4, 41, 4, 1)
        s.add(37, 4, 39, 4, 1)
        s.add(59, 4, 63, 29, 0)
        s.add(57, 4, 59, 29, 0)
        s.add(43, 3, 47, 28, 0)
        s.add(43, 4, 47, 29, 0)
    elif dv == 29:
        s.add(48, 29, 49, 29, 0)
        s.add(47, 29, 48, 29, 0)
        s.add(45, 4, 48, 29, 0)
        s.add(53, 29, 54, 29, 0)
        s.add(52, 29, 53, 29, 0)
        s.add(50, 4, 53, 29, 0)
        s.add(38, 4, 41, 29, 0)
        s.add(38, 4, 40, 4, 1)
        s.add(58, 29, 59, 29, 0)
        s.add(56, 4, 59, 29, 0)
        s.add(36, 4, 38, 4, 1)
        s.add(58, 4, 62, 29, 0)
        s.add(42, 3, 46, 28, 0)
        s.add(42, 4, 46, 29, 0)
    elif dv == 28:
        s.add(47, 29, 48, 29, 0)
        s.add(46, 29, 47, 29, 0)
        s.add(44, 4, 47, 29, 0)
        s.add(52, 29, 53, 29, 0)
        s.add(49, 4, 52, 29, 0)
        s.add(37, 4, 40, 29, 0)
        s.add(51, 29, 52, 29, 0)
        s.add(37, 4, 39, 4, 1)
        s.add(57, 29, 58, 29, 0)
        s.add(55, 4, 58, 29, 0)
        s.add(58, 29, 61, 29, 1)
        s.add(57, 4, 61, 29, 0)
        s.add(41, 3, 45, 28, 0)
        s.add(41, 4, 45, 29, 0)
    elif dv == 27:
        s.add(46, 29, 47, 29, 0)
        s.add(45, 29, 46, 29, 0)
        s.add(43, 4, 46, 29, 0)
        s.add(50, 29, 51, 29, 0)
        s.add(48, 4, 51, 29, 0)
        s.add(51, 29, 52, 29, 0)
        s.add(56, 4, 59, 29, 0)
        s.add(56, 29, 59, 29, 1)
        s.add(56, 29, 57, 29, 0)
        s.add(54, 4, 57, 29, 0)
        s.add(36, 4, 38, 4, 1)
        s.add(59, 29, 60, 29, 0)
        s.add(40, 3, 44, 28, 0)
        s.add(40, 4, 44, 29, 0)
        s.add(39, 30, 44, 28, 1)
    else:
        raise Error("no conditions transcribed for DV " + String(dv))
    return s^


def test_every_dv_below_a_higher_one() raises:
    var rng = _Rng(0x10E5B175)
    var hits = InlineArray[Int, _DV_COUNT](fill=0)
    var covered = 0
    var w = InlineArray[UInt32, 80](fill=0)
    var sample = 0
    for top in [31, 30, 29, 28, 27]:
        var meets = _ubc_conditions(top)
        var n = 0
        while covered < _DV_COUNT - 1 and n < _MAX_SAMPLES:
            n += 1
            sample += 1
            meets.sample(rng, w)
            _expand(w)
            var mask = c_ubc_check(w)
            if ((mask >> UInt32(top)) & 1) != 1:
                assert_equal(
                    (mask >> UInt32(top)) & 1,
                    UInt32(1),
                    "DV " + String(top) + " in C's mask, sample " + String(n),
                )
            var high = _top_bit(mask)
            var wanted = False
            for k in range(high):
                if ((mask >> UInt32(k)) & 1) == 1 and hits[k] < _CASES_PER_DV:
                    wanted = True
                    hits[k] += 1
                    if hits[k] == _CASES_PER_DV:
                        covered += 1
            if not wanted:
                continue
            _check_case(
                rng,
                w,
                high,
                True,
                "mask " + String(mask) + ", sample " + String(sample),
            )
    var short = String()
    for k in range(_DV_COUNT - 1):
        if hits[k] != _CASES_PER_DV:
            short += " " + String(k) + ":" + String(hits[k])
    assert_equal(
        short,
        String(),
        "DVs short of blocks below a higher DV after "
        + String(sample)
        + " samples",
    )


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
    test_every_dv_below_a_higher_one()
    test_filter_off_checks_every_dv()
    print("komira_git_conformance recompression tests passed")
