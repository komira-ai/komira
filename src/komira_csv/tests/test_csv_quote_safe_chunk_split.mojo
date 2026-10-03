# =============================================================================
# test_csv_quote_safe_chunk_split.mojo
# =============================================================================
#
# Falsifiers for `komira_csv/csv_chunk_split.mojo` — the quote-aware CSV body
# partitioner every parallel CSV reader uses instead of a raw-`\n` splitter.
#
# THE ORACLE IS IN THIS FILE, NOT IN THE THING UNDER TEST. `_true_row_starts`
# is a plain byte-at-a-time transcription of the FSA in
# `csv_scanner_phase1.mojo` — including the rule that actually matters, that a
# quote opens a region ONLY at a cell start. The splitter reaches the same
# answer through an entirely different mechanism (64-byte movemasks, `""`
# pre-cancellation, a PCLMULQDQ prefix-parity, a bitwise opener check), so
# agreement between them is evidence and not a tautology.
#
# # What each test proves
#
#   1. `test_split_never_lands_inside_quoted_field` — the REGRESSION GUARD.
#      A row carries a quoted cell holding 300 embedded newlines and spans the
#      middle ~half of the file. `_naive_lf_split` — a newline-snapped
#      splitter with no quote tracking, kept as a negative oracle — is run on
#      the SAME fixture first and asserted to produce a boundary that is NOT a
#      row start. That assertion is what makes this fixture discriminating: a
#      splitter that ignores quoting fails it by construction, so the test
#      proves the fixture can tell the two splitters apart.
#   2. `test_doubled_quote_escape_preserves_parity` — `""` escapes inside the
#      embedded-newline cell. The escape contributes two quote bytes, so a
#      parity model must be unmoved by it; a model that cancelled only one
#      would invert from there and every later boundary would be wrong.
#   3. `test_posix_dialect_emits_one_range` — Posix escapes as `\"`, which
#      flips parity, so the splitter must DECLINE. One range, i.e. serial.
#      Pinned because a silent mis-split of Posix is the failure this
#      exclusion exists to prevent, and nothing else would catch it.
#   4. `test_stray_quote_degrades_to_fewer_ranges` — `12" pipe` is content to
#      the FSA and an opener to parity. The splitter must notice the
#      disagreement, keep the boundaries it proved before it, and stop —
#      fewer ranges, never a boundary the oracle rejects.
#   5. `test_ranges_tile_body_for_every_k` — over k = 1..17, the ranges tile
#      `[data_start, n)` exactly: no gap, no overlap, no empty range. A
#      partition that loses bytes loses ROWS, and a row-count assertion alone
#      would not necessarily see it.
#   6. `test_split_matches_oracle_on_quote_free_input` — the control. With no
#      quote byte anywhere, the quote-aware splitter and the naive one must
#      agree exactly; if they did not, the new machinery would be changing
#      behaviour on the ~every-CSV case for no reason.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_csv import (
    Rfc4180,
    Posix,
    compute_csv_quote_safe_row_ranges,
    csv_split_is_quote_parity_safe,
    find_first_newline_simd,
)


comptime _COMMA: UInt8 = UInt8(44)
comptime _QUOTE: UInt8 = UInt8(34)
comptime _LF: UInt8 = UInt8(10)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


# -----------------------------------------------------------------------------
# The oracle: byte-at-a-time transcription of the phase-1 FSA's row boundaries.
# -----------------------------------------------------------------------------


def _true_row_starts(
    imm data: List[UInt8], data_start: Int, delim: UInt8, quote: UInt8
) -> List[Int]:
    """Every offset at which a data row begins, per the FSA in
    `csv_scanner_phase1.mojo`.

    The load-bearing clause is `if b == quote and pos == cell_start`: a quote
    opens a quoted region ONLY as the first byte of a cell. Anywhere else it
    is ordinary content. That is the exact rule the splitter's opener check
    enforces, arrived at here by simulation instead of by bit tricks.
    """
    var out = List[Int]()
    var n = len(data)
    if data_start >= n:
        return out^
    out.append(data_start)
    var pos = data_start
    var in_q = False
    var at_cell_start = True
    while pos < n:
        var b = data[pos]
        if in_q:
            if b == quote:
                if pos + 1 < n and data[pos + 1] == quote:
                    pos = pos + 2  # `""` — literal quote, still inside.
                    continue
                in_q = False
                at_cell_start = False
            pos = pos + 1
            continue
        if b == quote:
            if at_cell_start:
                in_q = True
            at_cell_start = False
            pos = pos + 1
            continue
        if b == _LF:
            if pos + 1 < n:
                out.append(pos + 1)
            at_cell_start = True
            pos = pos + 1
            continue
        at_cell_start = (b == delim) or (b == UInt8(13))
        pos = pos + 1
    return out^


def _contains(imm xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


# -----------------------------------------------------------------------------
# The pre-fix splitter, verbatim, so the fixtures can be shown to discriminate.
# -----------------------------------------------------------------------------


def _naive_lf_split(
    imm data: List[UInt8],
    data_start_byte: Int,
    k_desired: Int,
    mut los: List[Int],
    mut his: List[Int],
):
    """A newline-snapped splitter with no quote tracking: snap each
    equal-split candidate forward to the next raw LF.

    Kept as a negative oracle, so each fixture proves it can tell this
    splitter and the quote-safe one apart.
    """
    los.clear()
    his.clear()
    var bytes = Span(data)
    var n = len(data)
    if data_start_byte >= n:
        return
    if k_desired <= 1:
        los.append(data_start_byte)
        his.append(n)
        return
    var data_len = n - data_start_byte
    var boundaries = List[Int]()
    boundaries.append(data_start_byte)
    var i = 1
    while i < k_desired:
        var candidate = data_start_byte + (data_len * i) // k_desired
        var lf_pos = find_first_newline_simd(bytes, candidate)
        if lf_pos < n:
            var p = lf_pos + 1
            if p > boundaries[len(boundaries) - 1]:
                boundaries.append(p)
        i = i + 1
    boundaries.append(n)
    var b = 0
    while b + 1 < len(boundaries):
        if boundaries[b + 1] > boundaries[b]:
            los.append(boundaries[b])
            his.append(boundaries[b + 1])
        b = b + 1


# -----------------------------------------------------------------------------
# Shared assertions.
# -----------------------------------------------------------------------------


def _assert_tiles(
    imm los: List[Int],
    imm his: List[Int],
    data_start: Int,
    n: Int,
    imm label: String,
) raises:
    assert_equal(len(los), len(his), label + ": los/his length mismatch")
    assert_true(len(los) >= 1, label + ": at least one range")
    assert_equal(los[0], data_start, label + ": first range starts at data")
    assert_equal(his[len(his) - 1], n, label + ": last range ends at EOF")
    for i in range(len(los)):
        assert_true(his[i] > los[i], label + ": empty range emitted")
        if i + 1 < len(los):
            assert_equal(
                his[i], los[i + 1], label + ": gap or overlap between ranges"
            )


def _assert_every_start_is_a_row_start(
    imm los: List[Int], imm truth: List[Int], imm label: String
) raises:
    for i in range(len(los)):
        assert_true(
            _contains(truth, los[i]),
            label
            + ": range start "
            + String(los[i])
            + " is not a real row boundary",
        )


# -----------------------------------------------------------------------------
# Fixtures.
# -----------------------------------------------------------------------------


def _fixture_embedded_newlines(doubled_quotes: Bool) -> List[UInt8]:
    """`a,b,c` with one row whose middle cell is a quoted ~2.7 KB blob holding
    300 embedded newlines, flanked by 100 plain rows on each side.

    Sized so that a 4-way equal split puts the 50% candidate INSIDE the blob:
    the flanks are ~1.5 KB each and the blob ~2.7 KB, so the blob covers
    roughly the 26%-74% band of the body.
    """
    var s = String("a,b,c\n")
    for r in range(100):
        s += String(r) + ",plain" + String(r) + ",x\n"
    s += "9999,\""
    for i in range(300):
        if doubled_quotes:
            # `li""ne<i>` — an RFC-4180 escaped quote INSIDE the quoted cell.
            s += "li\"\"ne" + String(i) + "\n"
        else:
            s += "line" + String(i) + "\n"
    s += "\",y\n"
    for r in range(100):
        s += String(1000 + r) + ",plain" + String(r) + ",z\n"
    return _bytes(s)


def _fixture_stray_quote() -> List[UInt8]:
    """A quote in the MIDDLE of an unquoted cell — `12" pipe` — which the FSA
    reads as content and a parity model reads as an opener."""
    var s = String("a,b\n")
    for r in range(200):
        s += String(r) + ",fitting" + String(r) + "\n"
    s += "500,12\" pipe\n"
    for r in range(200):
        s += String(1000 + r) + ",fitting" + String(r) + "\n"
    return _bytes(s)


def _fixture_quote_free() -> List[UInt8]:
    var s = String("a,b\n")
    for r in range(500):
        s += String(r) + "," + String(r * 7 + (r % 13)) + "\n"
    return _bytes(s)


# =============================================================================
# 1. The regression guard.
# =============================================================================
def test_split_never_lands_inside_quoted_field() raises:
    var data = _fixture_embedded_newlines(False)
    var n = len(data)
    var data_start = 6  # past "a,b,c\n"
    var truth = _true_row_starts(data, data_start, _COMMA, _QUOTE)

    # (a) The fixture DISCRIMINATES: the pre-fix splitter picks a boundary the
    #     oracle rejects. Without this the test below could pass vacuously on
    #     a fixture whose quoted cell never straddled a candidate.
    var nlos = List[Int]()
    var nhis = List[Int]()
    _naive_lf_split(data, data_start, 4, nlos, nhis)
    var naive_has_bad_start = False
    for i in range(len(nlos)):
        if not _contains(truth, nlos[i]):
            naive_has_bad_start = True
    assert_true(
        naive_has_bad_start,
        "fixture is not discriminating: the raw-LF split happened to land on"
        " row boundaries, so this test would pass on the pre-fix code",
    )

    # (b) The quote-aware splitter lands only on real row boundaries.
    var los = List[Int]()
    var his = List[Int]()
    compute_csv_quote_safe_row_ranges[Rfc4180](
        Span(data), data_start, 4, _COMMA, _QUOTE, los, his
    )
    _assert_tiles(los, his, data_start, n, String("embedded_nl"))
    _assert_every_start_is_a_row_start(los, truth, String("embedded_nl"))
    assert_true(
        len(los) >= 2,
        "the flanks are splittable, so this must still be parallel",
    )


# =============================================================================
# 2. Doubled-quote escapes must not move the parity.
# =============================================================================
def test_doubled_quote_escape_preserves_parity() raises:
    var data = _fixture_embedded_newlines(True)
    var n = len(data)
    var data_start = 6
    var truth = _true_row_starts(data, data_start, _COMMA, _QUOTE)
    var los = List[Int]()
    var his = List[Int]()
    compute_csv_quote_safe_row_ranges[Rfc4180](
        Span(data), data_start, 6, _COMMA, _QUOTE, los, his
    )
    _assert_tiles(los, his, data_start, n, String("doubled_quotes"))
    _assert_every_start_is_a_row_start(los, truth, String("doubled_quotes"))


# =============================================================================
# 3. Posix declines, at comptime, and says so.
# =============================================================================
def test_posix_dialect_emits_one_range() raises:
    assert_true(
        csv_split_is_quote_parity_safe[Rfc4180](),
        "RFC-4180 doubles its quote escape, so parity is a valid model",
    )
    assert_true(
        not csv_split_is_quote_parity_safe[Posix](),
        "Posix escapes as \\\" — one quote byte — so parity is NOT valid",
    )
    var data = _fixture_embedded_newlines(False)
    var n = len(data)
    var los = List[Int]()
    var his = List[Int]()
    compute_csv_quote_safe_row_ranges[Posix](
        Span(data), 6, 8, _COMMA, _QUOTE, los, his
    )
    assert_equal(
        len(los), 1, "Posix must decline to split rather than mis-split"
    )
    _assert_tiles(los, his, 6, n, String("posix"))


# =============================================================================
# 4. A stray quote costs parallelism, never correctness.
# =============================================================================
def test_stray_quote_degrades_to_fewer_ranges() raises:
    var data = _fixture_stray_quote()
    var n = len(data)
    var data_start = 4  # past "a,b\n"
    var truth = _true_row_starts(data, data_start, _COMMA, _QUOTE)
    var los = List[Int]()
    var his = List[Int]()
    compute_csv_quote_safe_row_ranges[Rfc4180](
        Span(data), data_start, 8, _COMMA, _QUOTE, los, his
    )
    _assert_tiles(los, his, data_start, n, String("stray_quote"))
    _assert_every_start_is_a_row_start(los, truth, String("stray_quote"))
    assert_true(
        len(los) < 8,
        "the stray quote is un-modelable, so the split must stop short of the"
        " 8 ranges asked for",
    )
    assert_true(
        len(los) >= 2,
        "everything BEFORE the stray quote was proven, so those boundaries"
        " must be kept — degrading all the way to serial would be a needless"
        " loss",
    )


# =============================================================================
# 5. The ranges tile the body for every k.
# =============================================================================
def test_ranges_tile_body_for_every_k() raises:
    var data = _fixture_embedded_newlines(True)
    var n = len(data)
    var data_start = 6
    var truth = _true_row_starts(data, data_start, _COMMA, _QUOTE)
    for k in range(1, 18):
        var los = List[Int]()
        var his = List[Int]()
        compute_csv_quote_safe_row_ranges[Rfc4180](
            Span(data), data_start, k, _COMMA, _QUOTE, los, his
        )
        var label = String("k=") + String(k)
        _assert_tiles(los, his, data_start, n, label)
        _assert_every_start_is_a_row_start(los, truth, label)
        assert_true(len(los) <= k, label + ": more ranges than requested")


# =============================================================================
# 6. Control — no quotes anywhere means no behaviour change.
# =============================================================================
def test_split_matches_oracle_on_quote_free_input() raises:
    var data = _fixture_quote_free()
    var n = len(data)
    var data_start = 4
    for k in range(2, 10):
        var los = List[Int]()
        var his = List[Int]()
        compute_csv_quote_safe_row_ranges[Rfc4180](
            Span(data), data_start, k, _COMMA, _QUOTE, los, his
        )
        var nlos = List[Int]()
        var nhis = List[Int]()
        _naive_lf_split(data, data_start, k, nlos, nhis)
        var label = String("quote_free k=") + String(k)
        assert_equal(len(los), len(nlos), label + ": range count differs")
        for i in range(len(los)):
            assert_equal(los[i], nlos[i], label + ": range start differs")
            assert_equal(his[i], nhis[i], label + ": range end differs")
        _assert_tiles(los, his, data_start, n, label)


def main() raises:
    test_split_never_lands_inside_quoted_field()
    test_doubled_quote_escape_preserves_parity()
    test_posix_dialect_emits_one_range()
    test_stray_quote_degrades_to_fewer_ranges()
    test_ranges_tile_body_for_every_k()
    test_split_matches_oracle_on_quote_free_input()
    print("test_csv_quote_safe_chunk_split: 6/6 PASS")
