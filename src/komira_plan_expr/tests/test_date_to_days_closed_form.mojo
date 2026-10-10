# =============================================================================
# Regression test for the closed-form `date_to_days` rewrite.
# =============================================================================
#
# `date_to_days` is the O(1) closed-form Howard Hinnant `days_from_civil`
# formula rather than a ~24-iteration year-accumulation `for` loop, so it is
# `@always_inline` + comptime-foldable (a typed TPC-H Q6 filter predicate
# calls it ~3M times per run). The closed-form is BOTH faster at runtime AND
# folds to a constant when all args are comptime literals.
#
# CORRECTNESS GUARD: `date_to_days` handles dates; leap years are the classic
# bug. This test pins the closed-form against an INDEPENDENT reimplementation
# of the accumulating-loop algorithm (`_reference_date_to_days` below) for
# a wide spread of dates — including leap-year edges (Feb 29 2000, Mar 1 after
# a leap, century non-leap 1900, year boundaries) and the Q6 dates
# (1994-01-01 / 1995-01-01). The closed form MUST be byte-identical to the
# loop for every tested date.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_plan_expr.col_expr import date_to_days


# -----------------------------------------------------------------------------
# Independent reference = the accumulating-loop algorithm. If the closed-form
# ever diverges
# from this loop for any date in the spread, the test fails. This is the
# byte-identity oracle.
# -----------------------------------------------------------------------------
def _ref_is_leap(year: Int) -> Bool:
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)


def _ref_days_in_month(year: Int, month: Int) -> Int:
    if month == 2:
        return 29 if _ref_is_leap(year) else 28
    elif month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    else:
        return 31


def _reference_date_to_days(year: Int, month: Int, day: Int) -> Int:
    var days = 0
    if year >= 1970:
        for y in range(1970, year):
            days += 366 if _ref_is_leap(y) else 365
    else:
        for y in range(year, 1970):
            days -= 366 if _ref_is_leap(y) else 365
    for m in range(1, month):
        days += _ref_days_in_month(year, m)
    days += day - 1
    return days


def test_known_constants() raises:
    # The exact values the loop algorithm produces for the documented examples + the
    # Q6 dates. These are hard pins (not derived from the reference) so a bug
    # in BOTH impls couldn't slip through unnoticed.
    assert_equal(date_to_days(1970, 1, 1), 0)
    assert_equal(date_to_days(1998, 9, 2), 10471)
    # Q6 filter bounds — the hot-loop literals a comptime fold hoists.
    assert_equal(date_to_days(1994, 1, 1), 8766)
    assert_equal(date_to_days(1995, 1, 1), 9131)


def test_leap_year_edges() raises:
    # 2000 is a leap year (divisible by 400). Feb 29 must exist and Mar 1 must
    # be exactly one day later.
    assert_equal(
        date_to_days(2000, 2, 29), _reference_date_to_days(2000, 2, 29)
    )
    assert_equal(
        date_to_days(2000, 3, 1), date_to_days(2000, 2, 29) + 1
    )
    # 1900 is NOT a leap year (divisible by 100, not 400). Note: 1900 < 1970 so
    # this also exercises the pre-epoch (negative-result) branch.
    assert_equal(
        date_to_days(1900, 2, 28), _reference_date_to_days(1900, 2, 28)
    )
    assert_equal(
        date_to_days(1900, 3, 1), date_to_days(1900, 2, 28) + 1
    )
    # 2004 ordinary leap year (div by 4, not 100).
    assert_equal(
        date_to_days(2004, 2, 29), _reference_date_to_days(2004, 2, 29)
    )
    # 1972 — first leap year after the epoch.
    assert_equal(
        date_to_days(1972, 2, 29), _reference_date_to_days(1972, 2, 29)
    )


def test_year_boundaries() raises:
    # Dec 31 -> Jan 1 wraps must be exactly one day apart across boundaries
    # that straddle leap / non-leap years.
    assert_equal(date_to_days(2000, 1, 1), date_to_days(1999, 12, 31) + 1)
    assert_equal(date_to_days(2001, 1, 1), date_to_days(2000, 12, 31) + 1)
    assert_equal(date_to_days(1970, 1, 1), date_to_days(1969, 12, 31) + 1)


def test_byte_identical_spread() raises:
    # Sweep a wide spread of (year, month, day) and assert byte-identity with
    # the reference loop. Covers pre-epoch (1900-1969), epoch-forward
    # (1970-2099), every month, the 1st/15th/28th of each month, plus Feb 29
    # on each leap year encountered. ~tens of thousands of comparisons.
    for year in range(1900, 2100):
        for month in range(1, 13):
            var dim = _ref_days_in_month(year, month)
            # day 1, 15, 28, last-day-of-month (covers Feb 29 on leap years).
            var days_to_check = List[Int]()
            days_to_check.append(1)
            days_to_check.append(15)
            days_to_check.append(28)
            days_to_check.append(dim)
            for di in range(len(days_to_check)):
                var day = days_to_check[di]
                if day > dim:
                    continue
                assert_equal(
                    date_to_days(year, month, day),
                    _reference_date_to_days(year, month, day),
                )


# =============================================================================
# BC / ASTRONOMICAL-YEAR COVERAGE — what every fixture above this line
# structurally CANNOT see.
# =============================================================================
#
# ⛔ EVERY ASSERTION ABOVE THIS LINE IS AD (1900..2100), AND THE DEFECT BELOW
# IS INVISIBLE ON AN AD ROW. That is not a coincidence, it is the shape of the
# defect class: two candidate spellings of one formula that agree for y >= 0.
#
# The C idiom `(y if y >= 0 else y - 399) // 400` is the trick for recovering
# a FLOOR from a division that TRUNCATES. Mojo's `//` ALREADY floors
# (`-401 // 400 == -2`, `-7 // 2 == -4`), so that correction subtracts a
# SECOND era, `yoe` leaves its [0, 399] domain, and the leap-day term
# `yoe // 4 - yoe // 100` under-counts by exactly one day. `date_to_days`
# therefore uses the plain floored `y // 400`; the eval kernels' copies of the
# same formula must match.
#
# The idiom (and its `(z - 146096) // 146097` twin) misfires ONLY for a BC
# instant, and no clock reading, RFC3339 stamp, AWS signing date or iCalendar
# timestamp can BE one — so a copy elsewhere is a defect only
# once a BC input can actually reach it. Prove reachability with an executing
# call before changing one.
#
# ⚠ THE DAY COUNTS BELOW ARE RAW LITERALS, NEVER `date_to_days(...)` CALLS.
# Composing a fixture from the function under test asserts a tautology; worse,
# with the bug live it would assert against a DIFFERENT DATE than the comment
# claims. Each literal is DuckDB v1.5.3's own answer.


def _div_floor(a: Int, b: Int) -> Int:
    """Explicit floor-division, used ONLY by the round-trip oracle below.

    ⚠ THIS IS DELIBERATELY NOT THE SPELLING USED IN `date_to_days`. Mojo's
    `//` already floors, so in this tree the `q -= 1` correction below never
    fires and this is an identity. It is written the long way HERE, and only
    here, so that the oracle cannot inherit the very divide semantics the
    round trip is trying to falsify.
    """
    var q = a // b
    var r = a - q * b
    if r != 0 and ((r < 0) != (b < 0)):
        q -= 1
    return q


def _civil_from_days(z_in: Int) -> Tuple[Int, Int, Int]:
    """Howard Hinnant `civil_from_days` — the INVERSE of `date_to_days`.

    A second independent oracle, structurally different from
    `_reference_date_to_days` above (closed-form inverse vs. accumulating
    loop). `date_to_days(_civil_from_days(d)) == d` must hold for every `d`.
    """
    var z = z_in + 719468
    var era = _div_floor(z, 146097)
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (y, m, d)


def test_bc_round_trip_over_civil_from_days() raises:
    """`date_to_days` is the inverse of `civil_from_days` at EVERY sign.

    ⛔ With the double-era correction, 11,453 of the 118,572 day counts
    sampled here fail this round trip — EVERY ONE OF THEM BC, and ZERO of the
    AD ones, which is why no AD fixture sees it. The first failure is day
    -800000 (`-0221-09-04`), answered one day early as -800001.

    This is the STRONG form of the falsifier: it does not depend on picking
    the right handful of spot dates.
    """
    var bad = 0
    var bad_bc = 0
    var bad_ad = 0
    var first_bad = 0
    var n = 0
    for d in range(-800000, 30000, 7):
        n += 1
        var ymd = _civil_from_days(d)
        if date_to_days(ymd[0], ymd[1], ymd[2]) != d:
            if bad == 0:
                first_bad = d
            bad += 1
            if ymd[0] <= 0:
                bad_bc += 1
            else:
                bad_ad += 1
    assert_equal(n, 118572, "sample size drifted -- the counts below are keyed to it")
    assert_equal(
        bad,
        0,
        "date_to_days/civil_from_days round trip broke on "
        + String(bad)
        + " of "
        + String(n)
        + " day counts ("
        + String(bad_bc)
        + " BC / "
        + String(bad_ad)
        + " AD), first at day "
        + String(first_bad),
    )


def test_bc_known_constants_duckdb() raises:
    """Hard pins, read off duckdb v1.5.3 — not derived from either oracle.

    January 1st of four years straddling the era boundary, plus three
    dated rows around 44 BC. The `WAS` column is what the double-era
    spelling answers.

        civil          DuckDB       WAS
        -0045-12-29   -735602   -735603
        -0044-01-01   -735599   -735600
        -0044-03-15   -735525   -735526
        -0001-01-01   -719893   -719894
        0000-01-01    -719528   -719528   <- y_adj == -1, ACCIDENTALLY RIGHT
        0000-12-31    -719163   -719163   <- y_adj ==  0, AD branch
        0001-01-01    -719162   -719162   <- y_adj ==  0, AD branch
    """
    assert_equal(date_to_days(-45, 12, 29), -735602, "-0045-12-29")
    assert_equal(date_to_days(-44, 1, 1), -735599, "-0044-01-01")
    assert_equal(date_to_days(-44, 3, 15), -735525, "-0044-03-15")
    assert_equal(date_to_days(-1, 1, 1), -719893, "-0001-01-01")
    assert_equal(date_to_days(0, 1, 1), -719528, "0000-01-01")
    assert_equal(date_to_days(0, 12, 31), -719163, "0000-12-31")
    assert_equal(date_to_days(1, 1, 1), -719162, "0001-01-01")


def test_era_boundary_and_the_y_adj_minus_one_trap() raises:
    """The rows the BROKEN spelling already got right, plus the day-contiguity
    that its being right about only SOME of them destroys.

    ⚠ `y_adj == -1` IS THE SINGLE NEGATIVE VALUE WHERE THE C IDIOM IS
    ACCIDENTALLY CORRECT: `(-1 - 399) // 400 == -1`, which IS floor(-1/400).
    So a BC fixture drawn only from Mar..Dec of year 0 (or Jan/Feb of year 1)
    passes against the BUGGY spelling, and would certify this defect fixed
    while it is still live. Those rows are pinned here to stay put.

    ★ AND THAT IS EXACTLY WHY THE CONTIGUITY PAIRS BELOW BITE. A formula
    correct at y_adj == -1 and one day short at y_adj == -2 is DISCONTINUOUS
    across that boundary: with it, `date_to_days(-1, 3, 1)` (y_adj == -1, so
    right) and `date_to_days(-1, 2, 28)` (y_adj == -2, so short) are the SAME
    day rather than consecutive ones. Two adjacent calendar days collapsing
    onto one day number is the most legible statement of this bug there is.
    """
    # y_adj == -1 (Mar..Dec of year 0, and Jan/Feb of year 1).
    assert_equal(date_to_days(0, 3, 1), -719468, "0000-03-01 == the H.H. epoch")
    assert_equal(date_to_days(0, 12, 31), -719163, "0000-12-31")
    assert_equal(date_to_days(1, 2, 28), -719104, "0001-02-28 (y_adj == -1)")
    # y_adj == -1 reached from Jan/Feb of year 0.
    assert_equal(date_to_days(0, 1, 31), -719498, "0000-01-31")
    assert_equal(date_to_days(0, 2, 28), -719470, "0000-02-28")
    # Contiguity across the year-0 boundary, both directions.
    assert_equal(date_to_days(0, 1, 1), date_to_days(-1, 12, 31) + 1)
    assert_equal(date_to_days(1, 1, 1), date_to_days(0, 12, 31) + 1)
    # Year 0 IS a leap year astronomically (0 % 400 == 0) -- Feb 29 exists.
    assert_equal(date_to_days(0, 3, 1), date_to_days(0, 2, 29) + 1)
    # Year -1 is NOT (-1 % 4 != 0); Feb has 28 days.
    assert_equal(date_to_days(-1, 3, 1), date_to_days(-1, 2, 28) + 1)


def test_bc_byte_identical_spread() raises:
    """The same byte-identity sweep as `test_byte_identical_spread`, over BC
    years, against the SAME independent accumulating-loop oracle.

    ⛔ With the double-era correction, 2,456 of these 2,592 comparisons
    mismatch. `_reference_date_to_days` needs no change to serve BC —
    `_ref_is_leap` only ever tests `% == 0`, which is sign-agnostic, and the
    loop's `for y in range(year, 1970)` already walks negative years.

    ⚠ FOUR NARROW BANDS, NOT ONE WIDE ONE, AND THE REASON IS COST, NOT TASTE.
    `_reference_date_to_days` is O(1970 - year), so a contiguous -500..0 sweep
    is ~53M loop iterations and takes **~28 seconds** — for coverage that
    is almost entirely redundant. Each band below buys something the others do
    not:
        [-500, -480)  era == -2, well inside the second negative era
        [-410, -390)  straddles y_adj == -400, the era -1 / -2 BOUNDARY
        [ -50,  -40)  the years the duckdb pins above are drawn from
        [  -3,    1)  the year-0 boundary, where y_adj first goes negative
    The dense broad coverage is `test_bc_round_trip_over_civil_from_days`,
    which is O(1) per sample and walks every 7th day from year -221 to 2052.
    """
    var lo = List[Int]()
    var hi = List[Int]()
    lo.append(-500)
    hi.append(-480)
    lo.append(-410)
    hi.append(-390)
    lo.append(-50)
    hi.append(-40)
    lo.append(-3)
    hi.append(1)
    var checked = 0
    for bi in range(len(lo)):
        for year in range(lo[bi], hi[bi]):
            for month in range(1, 13):
                var dim = _ref_days_in_month(year, month)
                var days_to_check = List[Int]()
                days_to_check.append(1)
                days_to_check.append(15)
                days_to_check.append(28)
                days_to_check.append(dim)
                for di in range(len(days_to_check)):
                    var day = days_to_check[di]
                    if day > dim:
                        continue
                    checked += 1
                    assert_equal(
                        date_to_days(year, month, day),
                        _reference_date_to_days(year, month, day),
                    )
    # Guard the guard: a sweep that silently stopped covering anything would
    # otherwise pass green having asserted nothing.
    assert_equal(checked, 2592, "BC spread coverage drifted")


def main() raises:
    var suite = TestSuite()
    suite.test[test_known_constants]()
    suite.test[test_leap_year_edges]()
    suite.test[test_year_boundaries]()
    suite.test[test_byte_identical_spread]()
    suite.test[test_bc_round_trip_over_civil_from_days]()
    suite.test[test_bc_known_constants_duckdb]()
    suite.test[test_era_boundary_and_the_y_adj_minus_one_trap]()
    suite.test[test_bc_byte_identical_spread]()
    suite^.run()
