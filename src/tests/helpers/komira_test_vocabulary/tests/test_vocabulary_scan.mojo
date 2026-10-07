# =============================================================================
# test_vocabulary_scan.mojo — what the scan flags and what it lets through.
# =============================================================================
#
#   - `early_date_at`: each year 2024 and 2025 and 2026 months 01 to 08, with
#     each separator and with none, is found at its offset; September 2026 and
#     later, month 00 or 13, a year that continues a longer number, and a year
#     with one month digit are not.
#   - `scan_text`: a banned word in any case is reported once per word with
#     its line number; a clean line adds nothing; a line with both a word and
#     a date gives two hits, in that order.
# Dates and words are built from parts (see vocabulary.mojo).
# =============================================================================

from std.testing import assert_equal

from komira_test_vocabulary import banned_words, early_date_at, scan_text


def _y(year: Int) -> String:
    return String(year)


def test_early_dates_are_found() raises:
    var seps = List[String]()
    seps.append(String("-"))
    seps.append(String("_"))
    seps.append(String("/"))
    seps.append(String("."))
    seps.append(String(""))
    for s in range(len(seps)):
        var sep = seps[s]
        assert_equal(early_date_at("x " + _y(2026) + sep + "08" + sep + "31"), 2)
        assert_equal(early_date_at(_y(2026) + sep + "01"), 0)
        assert_equal(early_date_at("(" + _y(2025) + sep + "12)"), 1)
        assert_equal(early_date_at(_y(2024) + sep + "06 y"), 0)


def test_late_and_malformed_are_not() raises:
    assert_equal(early_date_at(_y(2026) + "-09-01"), -1)
    assert_equal(early_date_at(_y(2026) + "_10"), -1)
    assert_equal(early_date_at(_y(2026) + "12"), -1)
    assert_equal(early_date_at(_y(2027) + "-01"), -1)
    assert_equal(early_date_at(_y(2023) + "-12"), -1)
    assert_equal(early_date_at(_y(2026) + "-00"), -1)
    assert_equal(early_date_at(_y(2025) + "-13"), -1)
    assert_equal(early_date_at("1" + _y(2026) + "-03"), -1)
    assert_equal(early_date_at(_y(2026) + "-3"), -1)
    assert_equal(early_date_at(_y(2026) + "-"), -1)
    assert_equal(early_date_at(String("")), -1)
    assert_equal(early_date_at("a " + _y(2025) + " b"), -1)


def test_scan_text_reports_words_and_dates() raises:
    var org = String("org") + "_id"
    var mgr = String("Job") + " Manager"
    var text = (
        "clean line\n"
        + "  var "
        + org.upper()
        + ": String\n"
        + "a "
        + mgr
        + " on "
        + _y(2026)
        + "-04-01\n"
        + "late "
        + _y(2026)
        + "-10-07\n"
    )
    var hits = List[String]()
    scan_text(String("p.mojo"), text, banned_words(), hits)
    assert_equal(len(hits), 3)
    assert_equal(hits[0], "p.mojo:2: " + org)
    assert_equal(hits[1], "p.mojo:3: " + mgr.lower())
    assert_equal(hits[2], String("p.mojo:3: a date before September 2026"))


def main() raises:
    test_early_dates_are_found()
    test_late_and_malformed_are_not()
    test_scan_text_reports_words_and_dates()
    print("PASS test_vocabulary_scan")
