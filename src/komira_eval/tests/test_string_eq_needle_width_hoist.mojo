# =============================================================================
# test_string_eq_needle_width_hoist.mojo — the string ==/!= kernels must reach
# their byte comparison through a COMPTIME width, not through a per-row
# runtime ladder; and the hoist must not change one answer.
# =============================================================================
#
# WHY THIS TEST EXISTS
# --------------------
# `_string_eq_kernel` rejects a row on length and then compares exactly
# `val_len` bytes. `val_len` is LOOP-INVARIANT — it is the needle. Reaching
# that comparison through `bytes_equal`'s RUNTIME ladder (`i + W <= n`, then
# `rem >= 16 / 8 / 4 / 2`) walks FOUR compare-and-branch pairs PER ROW to
# select the same block width millions of times: on a 6,000,000-row string
# equality with needle `'g0'`, the emitted inner loop walks
# `cmp $0x10 / cmp $0x8 / cmp $0x4 / cmp $0x2` to reach ONE `movzwl`, at
# ~40 instructions per row against DuckDB's ~7 for the same job.
#
# ⭐ THE DEFECT IS INVISIBLE TO EVERY VALUE TEST, WHICH IS WHY THIS FILE IS
# NOT ONE. The ladder arm and the hoisted arm are value-identical BY
# CONSTRUCTION — that is the whole point of the change. A value-only test
# would stay green through a refactor that silently restored the per-row
# ladder, and the regression would be unattributable: same answers, old
# instruction count, nothing red. So the load-bearing leg here is
# `test_short_needle_never_takes_the_runtime_ladder`, which reads the ARM the
# kernel took out of `string_eq_arm_counter` — the same process-global
# `_Global` instrument idiom `komira_parquet.dict_mat_counter` uses to
# pin the dict-preserving decode's route.
#
# ⛔ AND THE COUNTER IS NOT ASSERTED IN ONE DIRECTION ONLY. The runtime ladder
# is the CORRECT and permanent answer for an empty needle and for a needle
# wider than the hoist covers, so `test_long_needle_still_takes_the_runtime_
# ladder` asserts it IS taken there. Deleting the ladder to make the first leg
# green reds the second.
#
# THE VALUE ORACLE IS INDEPENDENT OF BOTH ARMS. Every expectation below is
# `rows[i] == needle` evaluated by Mojo's own `String.__eq__` over the same
# `List[String]` the fixture was built from — not by the other arm of the
# kernel, and not by `bytes_equal_scalar`. A "new arm == old arm" check would
# be blind to any defect the two share.
#
# THE ADVERSARIAL SHAPE. The hoist compares two OVERLAPPING `W`-byte blocks,
# `[0, W)` and `[len-W, len)`, with `W` the largest power of two <= len capped
# at `_EQ_HOIST_MAX_BLOCK`. Its characteristic defect is therefore a HOLE in
# the middle at lengths that are not a power of two, and an off-by-one at each
# rung boundary. So the sweep runs EVERY needle length from 0 to
# `_EQ_HOIST_MAX_NEEDLE + 8` — both sides of every rung boundary (1|2, 3|4,
# 7|8, and the top rung's own |+1) plus a margin above the hoist's domain —
# and, at each, a row that differs at EVERY position p in [0, len). Nothing
# weaker finds a hole.
#
# ⚠ EVERY BOUND IN THIS FILE IS DERIVED FROM `_EQ_HOIST_MAX_BLOCK_LOG2`, AND
# THAT IS LOAD-BEARING, NOT TIDINESS. The block comment above
# `_EQ_HOIST_MAX_BLOCK` INVITES widening the cap. A literal `range(1, 17)`
# here would keep passing after that widening while asserting nothing about
# the widths the widening added — a sweep that has stopped covering its own
# subject and still says GREEN.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.string_array import StringArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.boolean_array import BooleanArray
from komira_counters.string_eq_arm_counter import (
    reset_string_eq_ladder_call_count,
    string_eq_ladder_call_count,
)
from komira_column_kernels.string_comparison import eval_string_eq, eval_string_ne
from komira_column_kernels.string_comparison import (
    eval_large_string_eq,
    eval_large_string_ne,
    _eq_block_width,
    _EQ_HOIST_MAX_BLOCK,
    _EQ_HOIST_MAX_BLOCK_LOG2,
    _EQ_HOIST_MAX_NEEDLE,
)


# =============================================================================
# Fixture helpers — strings are built from a char LIST, so a single position
# can be perturbed without any string indexing.
# =============================================================================


def _letters() raises -> List[String]:
    var alpha: List[String] = [
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
        "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    ]
    return alpha^


def _chars(n: Int) raises -> List[String]:
    """The canonical n-char body: a, b, c, ... cycling at 26."""
    var alpha = _letters()
    var out = List[String]()
    for i in range(n):
        out.append(alpha[i % 26])
    return out^


def _join(c: List[String]) raises -> String:
    var s = String("")
    for i in range(len(c)):
        s += c[i]
    return s^


def _body(n: Int) raises -> String:
    return _join(_chars(n))


def _perturbed(n: Int, pos: Int) raises -> String:
    """The canonical n-char body with position `pos` replaced by a byte that
    appears nowhere in it ('Z'), so the result differs from the needle at
    EXACTLY `pos` and nowhere else."""
    var c = _chars(n)
    c[pos] = String("Z")
    return _join(c)


def _corpus_for(n: Int) raises -> List[String]:
    """An adversarial row set for a needle of length `n`.

    Holds the needle itself (three times), a near-miss at EVERY byte position,
    both off-by-one lengths, the empty string and an all-different string of
    the same length. Padded so the row count is never a multiple of 8, which
    exercises the kernel's trailing partial bitmap byte at every needle width.
    """
    var needle = _body(n)
    var out = List[String]()
    out.append(needle)
    for p in range(n):
        out.append(_perturbed(n, p))
    out.append(needle)
    if n > 0:
        out.append(_body(n - 1))              # one byte SHORT
    out.append(_body(n + 1))                  # one byte LONG
    out.append(String(""))
    var allz = List[String]()
    for _i in range(n):
        allz.append(String("Z"))
    out.append(_join(allz))
    out.append(needle)
    while len(out) % 8 == 0:
        out.append(String("Z"))
    return out^


def _count_true(mask: BooleanArray) raises -> Int:
    var count = 0
    for i in range(mask.length):
        if mask.get(i):
            count += 1
    return count


# =============================================================================
# LEG 1 — THE ARM. This is the leg that fails on the pre-hoist kernel.
# =============================================================================


def test_short_needle_never_takes_the_runtime_ladder() raises:
    """A needle the hoist covers must reach its comparison through a COMPTIME
    width — the runtime ladder arm must not be entered at all.

    ⭐ THIS IS THE REGRESSION ASSERTION. On the pre-hoist kernel every call
    took the ladder, so this leg reports a non-zero count at needle length 1
    and stops. It is the only leg here that can see the defect: the answers
    were always right.
    """
    var checked = 0
    # ⭐ THE BOUND IS DERIVED, NOT `range(1, 17)`. It is the SELECTOR's arm
    # list — end #4 of the hoist invariant — that this sweep pins, and a
    # literal bound cannot see the arm list go stale: widen
    # `_EQ_HOIST_MAX_BLOCK_LOG2` without growing the arms and every needle at
    # the new top rung silently falls to the generic path with the right
    # answers. Swept over the derived domain, that reds BY NAME instead.
    for n in range(1, _EQ_HOIST_MAX_NEEDLE + 1):
        var rows = _corpus_for(n)
        var needle = _body(n)
        var col = StringArray.from_strings(rows)

        reset_string_eq_ladder_call_count()
        var m_eq = eval_string_eq(col, needle)
        assert_equal(
            string_eq_ladder_call_count(), 0,
            "eval_string_eq took the per-row runtime width ladder for a "
            + String(n) + "-byte needle",
        )
        assert_equal(len(m_eq), len(rows))

        reset_string_eq_ladder_call_count()
        var m_ne = eval_string_ne(col, needle)
        assert_equal(
            string_eq_ladder_call_count(), 0,
            "eval_string_ne took the per-row runtime width ladder for a "
            + String(n) + "-byte needle",
        )
        assert_equal(len(m_ne), len(rows))

        # The Int64-offset siblings share the body, so they must share the
        # arm — BOTH of them. `eval_large_string_ne`'s arm choice is
        # asserted here because the value leg answers a different question:
        # a kernel that quietly stopped hoisting would stay green there.
        var lcol = LargeStringArray.from_strings(rows)
        reset_string_eq_ladder_call_count()
        var lm_eq = eval_large_string_eq(lcol, needle)
        assert_equal(
            string_eq_ladder_call_count(), 0,
            "eval_large_string_eq took the runtime width ladder for a "
            + String(n) + "-byte needle",
        )
        assert_equal(len(lm_eq), len(rows))

        reset_string_eq_ladder_call_count()
        var lm_ne = eval_large_string_ne(lcol, needle)
        assert_equal(
            string_eq_ladder_call_count(), 0,
            "eval_large_string_ne took the runtime width ladder for a "
            + String(n) + "-byte needle",
        )
        assert_equal(len(lm_ne), len(rows))
        checked += 1
    # The sweep must be the sweep it claims: every width the hoist covers.
    assert_equal(
        checked, _EQ_HOIST_MAX_NEEDLE, "needle-width sweep did not run every width"
    )


def test_long_needle_still_takes_the_runtime_ladder() raises:
    """⛔ THE OTHER DIRECTION, so leg 1 cannot be made green by deleting the
    ladder. An empty needle and a needle wider than the hoist covers have no
    comptime arm and MUST fall to the generic runtime-width path.
    """
    # DERIVED, for the same reason leg 1's bound is: at the shipped cap this
    # is 20 bytes, but pinning the literal 20 makes this leg red on a WIDENING
    # (which would hoist it, correctly) rather than on the deletion it exists
    # to catch.
    var too_long = _EQ_HOIST_MAX_NEEDLE + 4
    var rows = _corpus_for(too_long)
    var col = StringArray.from_strings(rows)

    reset_string_eq_ladder_call_count()
    var m0 = eval_string_eq(col, String(""))
    assert_equal(len(m0), len(rows))
    assert_equal(
        string_eq_ladder_call_count(), 1,
        "an EMPTY needle must take the generic runtime-width arm",
    )

    var long_needle = _body(too_long)
    reset_string_eq_ladder_call_count()
    var m1 = eval_string_eq(col, long_needle)
    assert_equal(len(m1), len(rows))
    assert_equal(
        string_eq_ladder_call_count(), 1,
        "a " + String(too_long)
        + "-byte needle must take the generic runtime-width arm",
    )

    reset_string_eq_ladder_call_count()
    var m2 = eval_string_ne(col, long_needle)
    assert_equal(len(m2), len(rows))
    assert_equal(
        string_eq_ladder_call_count(), 1,
        "a " + String(too_long)
        + "-byte needle must take the generic runtime-width arm for !=",
    )


# =============================================================================
# LEG 1b — THE POST-CONDITION `_eq_block_width` OWES ITS CALLER.
# =============================================================================


def test_eq_block_width_enforces_its_own_post_condition() raises:
    """⛔ THE LATENT OUT-OF-BOUNDS READ, PINNED AT THE FUNCTION THAT CAUSED IT.

    `_string_eqne_kernel_w[W]` loads `[0, W)` and `[val_len - W, val_len)` of
    BOTH the needle and the element. Its whole safety argument is the caller's
    promise `W <= val_len <= 2 * W`: below it `tail = val_len - W` goes
    NEGATIVE and the kernel reads before both objects; above it the two blocks
    leave a HOLE in the middle and the answer is silently wrong.

    ⚠ THE DEFECT THIS GUARDS IS LATENT AT THE SHIPPED CAP, AND THAT IS THE
    POINT. A selector of the form `if val_len < 8: return 4` then
    `return _EQ_HOIST_MAX_BLOCK` satisfies the post-condition at a cap of 8
    and violates it at ANY LARGER CAP, so widening the constant would break
    it. At cap 16 plus a `w == 16` arm, the value leg reds at
    `eq missed a match: n=8 row=0 'abcdefgh'`, i.e. after
    `_eq_block_width(8)` returned 16 and the kernel had already read 16 bytes
    at `val_ptr - 8`. A read that has happened is not caught by the assertion
    that notices its result.

    So this leg asserts the CONTRACT over the whole input domain, including
    outside it, rather than asserting the shipped cap's answers:
      * `0` (decline -> the generic arm) or a value satisfying
        `W <= val_len <= 2 * W`. Never anything else.
      * `0` for every `val_len` the hoist does not cover.
      * a power of two no greater than the cap, so the selector's derived arm
        list can enumerate it.
    """
    # Well past the top of the domain, so the decline branch is exercised too.
    var probed = 0
    for val_len in range(-3, 4 * _EQ_HOIST_MAX_BLOCK + 5):
        var w = _eq_block_width(val_len)
        probed += 1
        var tag = "val_len=" + String(val_len) + " -> W=" + String(w)
        if w == 0:
            continue
        # A returned width is a PROMISE. Both halves, both directions.
        assert_true(
            w <= val_len,
            "⛔ OUT-OF-BOUNDS: W > val_len means tail < 0 and the kernel "
            "reads BEFORE the needle and the element: " + tag,
        )
        assert_true(
            val_len <= 2 * w,
            "⛔ HOLE: val_len > 2W means the two blocks do not cover "
            "[0, val_len): " + tag,
        )
        assert_true(
            w <= _EQ_HOIST_MAX_BLOCK,
            "W exceeds the cap the module instantiates arms for: " + tag,
        )
        # Power of two — the selector enumerates 1 << k, so anything else is
        # a width with no arm.
        assert_equal(w & (w - 1), 0, "W is not a power of two: " + tag)
        assert_true(
            val_len <= _EQ_HOIST_MAX_NEEDLE,
            "a needle wider than _EQ_HOIST_MAX_NEEDLE was accepted: " + tag,
        )
    assert_true(probed > 4 * _EQ_HOIST_MAX_BLOCK, "post-condition sweep shrank")

    # And the declines are declines for a REASON, not because the function
    # stopped hoisting anything. Every width in the covered domain must get a
    # real arm — this is what makes the assertions above non-vacuous.
    assert_equal(_eq_block_width(0), 0, "an empty needle has no block")
    assert_equal(
        _eq_block_width(_EQ_HOIST_MAX_NEEDLE + 1), 0,
        "a needle past the max must decline",
    )
    var hoisted = 0
    for val_len in range(1, _EQ_HOIST_MAX_NEEDLE + 1):
        if _eq_block_width(val_len) != 0:
            hoisted += 1
    assert_equal(
        hoisted, _EQ_HOIST_MAX_NEEDLE,
        "_eq_block_width declined a width inside its own covered domain",
    )
    # The cap and its log are one declaration; if they ever diverge the
    # selector's `comptime for k in range(LOG2 + 1)` stops matching the ladder.
    assert_equal(
        _EQ_HOIST_MAX_BLOCK, 1 << _EQ_HOIST_MAX_BLOCK_LOG2,
        "_EQ_HOIST_MAX_BLOCK is no longer 1 << _EQ_HOIST_MAX_BLOCK_LOG2",
    )
    assert_equal(
        _EQ_HOIST_MAX_NEEDLE, 2 * _EQ_HOIST_MAX_BLOCK,
        "_EQ_HOIST_MAX_NEEDLE is no longer 2 * the cap",
    )


# =============================================================================
# LEG 2 — VALUE IDENTITY, against an oracle that is neither arm.
# =============================================================================


def test_every_needle_width_is_value_identical_to_string_eq() raises:
    """For EVERY needle length 0..24 and EVERY row of the adversarial corpus,
    the kernel's bit must equal `row == needle` computed by `String.__eq__`.

    This is what proves the two overlapping W-byte blocks leave no HOLE: at a
    length that is not a power of two the blocks overlap, and at every length
    the corpus carries a row differing at exactly one position p for every p.
    """
    var rows_checked = 0
    var widths = 0
    comptime _VALUE_SWEEP_MAX = _EQ_HOIST_MAX_NEEDLE + 9
    for n in range(0, _VALUE_SWEEP_MAX):
        var rows = _corpus_for(n)
        var needle = _body(n)
        var col = StringArray.from_strings(rows)
        var m_eq = eval_string_eq(col, needle)
        var m_ne = eval_string_ne(col, needle)

        var lcol = LargeStringArray.from_strings(rows)
        var lm_eq = eval_large_string_eq(lcol, needle)
        var lm_ne = eval_large_string_ne(lcol, needle)

        assert_equal(len(m_eq), len(rows))
        var want_true = 0
        for i in range(len(rows)):
            var tag = "n=" + String(n) + " row=" + String(i) + " '" + rows[i] + "'"
            var want = rows[i] == needle
            if want:
                want_true += 1
                assert_true(m_eq.get(i), "eq missed a match: " + tag)
                assert_false(m_ne.get(i), "ne selected a match: " + tag)
                assert_true(lm_eq.get(i), "large eq missed a match: " + tag)
                assert_false(lm_ne.get(i), "large ne selected a match: " + tag)
            else:
                assert_false(m_eq.get(i), "eq selected a non-match: " + tag)
                assert_true(m_ne.get(i), "ne missed a non-match: " + tag)
                assert_false(lm_eq.get(i), "large eq selected a non-match: " + tag)
                assert_true(lm_ne.get(i), "large ne missed a non-match: " + tag)
            rows_checked += 1
        assert_equal(_count_true(m_eq), want_true)
        # ⛔ NOT VACUOUS: every corpus carries matching AND non-matching rows,
        # at every width.
        assert_true(
            want_true >= 3, "corpus lost its matching rows at n=" + String(n)
        )
        assert_true(
            want_true < len(rows),
            "corpus lost its non-matching rows at n=" + String(n),
        )
        widths += 1
    assert_equal(
        widths, _VALUE_SWEEP_MAX, "value sweep did not run every needle width"
    )
    # ANTI-SHRINK, IN TWO PINS, because the total moves with the cap and the
    # per-width fixture does not. Neither replaces the other: the first
    # catches the FIXTURE losing rows, the second is the exact
    # count for this corpus and is checked wherever it still applies.
    assert_equal(
        len(_corpus_for(8)), 15, "the adversarial corpus lost rows at n=8"
    )
    comptime if _VALUE_SWEEP_MAX == 25:
        assert_equal(rows_checked, 477, "value sweep row count changed")


def test_needle_longer_than_every_row_matches_nothing() raises:
    """A degenerate guard on the length short-circuit: a needle longer than
    every row must select no row, at a width inside the hoist AND outside it.
    """
    var rows: List[String] = ["a", "bb", "ccc", "", "dddd", "ee", "f"]
    var col = StringArray.from_strings(rows)
    for n in range(5, 22):
        var needle = _body(n)
        var m = eval_string_eq(col, needle)
        assert_equal(
            _count_true(m), 0, "n=" + String(n) + " matched a shorter row"
        )
        var mn = eval_string_ne(col, needle)
        assert_equal(_count_true(mn), len(rows), "ne n=" + String(n))


# =============================================================================
# LEG 4 — NULLS, ON THE NEW ARM. Three-valued logic at every hoisted width.
# =============================================================================


def test_hoisted_arm_is_three_valued_at_every_width() raises:
    """⛔ THE SHIPPED FILE HAD ZERO NULL COVERAGE OF THE ARM IT ADDED.

    The only null coverage that touched the hoisted path was
    `test_string_eq_null_is_not_empty`, and it touched it BY ACCIDENT: its
    literal is 'bob', 3 bytes, so it lands on W=2 and says nothing about the
    other rungs. A null leg belongs here, at every width, not resting on a
    sibling file's choice of name.

    THE CONTRACT. Nulls are not the kernel's business — `_string_eqne_kernel_w`
    never sees a validity bitmap, and `_apply_validity` masks afterwards
    exactly as it does for the generic arm. That is precisely why this needs
    asserting per width: the `!=` half is where a kernel-level change bites.
    `_string_ne_kernel` is `_string_eq_kernel` modulo one `not`, so a NULL row
    (an `(offset, length=0)` slot) compares UNEQUAL to a non-empty needle and
    the kernel reports TRUE; only the mask turns that into the SQL answer.
    Under 3VL both `NULL = x` and `NULL <> x` are FALSE.

    ⚠ ONE SHAPE THE ARROW LAYOUT MAKES INEXPRESSIBLE, stated so nobody looks
    for it: a NULL row whose BYTES are the needle. `from_strings_with_validity`
    stores an Arrow-conformant EMPTY slot for a null (`length = 0`, zero bytes
    contributed), so a null row never carries content and the kernel's length
    check rejects it before any load. The hazard that leaves is the mask, and
    the mask is what this asserts.
    """
    var widths = 0
    for n in range(1, _EQ_HOIST_MAX_NEEDLE + 1):
        var needle = _body(n)
        var near = _perturbed(n, n - 1)      # differs at the LAST byte only
        var rows: List[String] = [
            needle,          # 0  valid match
            needle,          # 1  NULL (content dropped by the Arrow layout)
            String(""),      # 2  NULL, empty slot
            near,            # 3  valid near-miss at the last byte
            _body(n + 1),    # 4  valid, one byte LONG
            needle,          # 5  valid match
        ]
        var valid: List[Bool] = [True, False, False, True, True, True]
        var col = StringArray.from_strings_with_validity(rows, valid)

        reset_string_eq_ladder_call_count()
        var m_eq = eval_string_eq(col, needle)
        # ⭐ This leg is only about the HOISTED arm, so assert
        # the hoisted arm was the one taken.
        assert_equal(
            string_eq_ladder_call_count(), 0,
            "the null leg did not exercise the hoisted arm at n=" + String(n),
        )
        var m_ne = eval_string_ne(col, needle)

        var tag = " at n=" + String(n)
        assert_true(m_eq.get(0), "a valid match must be TRUE" + tag)
        assert_false(m_ne.get(0), "a valid match must be FALSE for !=" + tag)

        assert_false(m_eq.get(1), "NULL = needle must not be TRUE" + tag)
        assert_false(m_ne.get(1), "NULL <> needle must not be TRUE" + tag)
        assert_false(m_eq.get(2), "NULL(empty slot) = needle" + tag)
        assert_false(m_ne.get(2), "NULL(empty slot) <> needle" + tag)

        assert_false(m_eq.get(3), "a last-byte near-miss matched" + tag)
        assert_true(m_ne.get(3), "a last-byte near-miss failed !=" + tag)
        assert_false(m_eq.get(4), "an off-by-length row matched" + tag)
        assert_true(m_ne.get(4), "an off-by-length row failed !=" + tag)
        assert_true(m_eq.get(5), "the second valid match" + tag)
        assert_false(m_ne.get(5), "the second valid match, !=" + tag)

        assert_equal(_count_true(m_eq), 2, "exactly two rows match" + tag)
        assert_equal(_count_true(m_ne), 2, "exactly two rows differ" + tag)
        widths += 1
    assert_equal(widths, _EQ_HOIST_MAX_NEEDLE, "null sweep did not run every width")


# =============================================================================
# LEG 5 — NON-ASCII. `byte_length()` is bytes; a char-count would hide here.
# =============================================================================


def test_non_ascii_needle_is_measured_in_bytes_not_characters() raises:
    """A multi-byte UTF-8 needle must pick its rung off BYTES.

    Nothing else in this file uses a byte outside ASCII, so a char-vs-byte
    confusion anywhere on the width path — `_eq_block_width`'s argument, the
    `tail` displacement, the two block loads — is invisible to every other
    leg. 'é' is the sharpest case: ONE character, TWO bytes, so a char-length
    reading gives `val_len = 1` and `W = 1`, which compares only the LEAD BYTE
    (0xC3) and matches every other two-byte character starting with it.

    The needles below sit on three different rungs by BYTE length (2, 3, 4)
    and would ALL read as one character.
    """
    var e_acute = String("é")          # 2 bytes: C3 A9        -> W=2
    var e_grave = String("è")          # 2 bytes: C3 A8        -> W=2, same lead
    var euro = String("€")             # 3 bytes: E2 82 AC     -> W=2, overlap
    var yen_wide = String("￥")        # 3 bytes: EF BF A5     -> W=2
    var emoji = String("🙂")           # 4 bytes: F0 9F 99 82  -> W=4

    # The premise, asserted rather than assumed: these are multi-BYTE.
    assert_equal(e_acute.byte_length(), 2, "'é' is not 2 bytes")
    assert_equal(e_grave.byte_length(), 2, "'è' is not 2 bytes")
    assert_equal(euro.byte_length(), 3, "'€' is not 3 bytes")
    assert_equal(yen_wide.byte_length(), 3, "'￥' is not 3 bytes")
    assert_equal(emoji.byte_length(), 4, "'🙂' is not 4 bytes")
    assert_equal(_eq_block_width(2), 2, "a 2-byte needle is not on rung W=2")
    assert_equal(_eq_block_width(3), 2, "a 3-byte needle is not on rung W=2")
    assert_equal(_eq_block_width(4), 4, "a 4-byte needle is not on rung W=4")

    var rows: List[String] = [
        e_acute, e_grave, euro, yen_wide, emoji, String("a"), String(""),
        e_acute, String("ée"), String("e"),
    ]
    var col = StringArray.from_strings(rows)
    var lcol = LargeStringArray.from_strings(rows)

    var needles: List[String] = [e_acute, e_grave, euro, yen_wide, emoji]
    var checked = 0
    for j in range(len(needles)):
        ref needle = needles[j]
        reset_string_eq_ladder_call_count()
        var m_eq = eval_string_eq(col, needle)
        assert_equal(
            string_eq_ladder_call_count(), 0,
            "a multi-byte needle fell to the runtime ladder: j=" + String(j),
        )
        var m_ne = eval_string_ne(col, needle)
        var lm_eq = eval_large_string_eq(lcol, needle)

        for i in range(len(rows)):
            var want = rows[i] == needle
            var tag = "j=" + String(j) + " row=" + String(i)
            assert_equal(m_eq.get(i), want, "eq " + tag)
            assert_equal(m_ne.get(i), not want, "ne " + tag)
            assert_equal(lm_eq.get(i), want, "large eq " + tag)
            checked += 1
    assert_equal(checked, 5 * len(rows), "the non-ASCII sweep shrank")

    # ⭐ THE ASSERTION A CHAR-LENGTH READING FAILS. 'é' and 'è' share their
    # LEAD BYTE (0xC3) and differ only in the second, so a W=1 compare calls
    # them equal. Exactly one row of each may match.
    assert_equal(_count_true(eval_string_eq(col, e_acute)), 2, "'é' count")
    assert_equal(_count_true(eval_string_eq(col, e_grave)), 1, "'è' count")
    # '€' and '￥' are both 3 bytes and differ in their FIRST byte, which the
    # W=2 lead block sees; 'ée' is 3 bytes too and differs in the last, which
    # only the overlapping TAIL block sees.
    assert_equal(_count_true(eval_string_eq(col, euro)), 1, "'€' count")
    assert_equal(_count_true(eval_string_eq(col, String("ée"))), 1, "'ée' count")


# =============================================================================
# Main
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
