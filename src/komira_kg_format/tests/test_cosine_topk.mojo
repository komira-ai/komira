# =============================================================================
# test_cosine_topk.mojo -- ranking the rows of a packed-embedding column.
# =============================================================================
#
#   ranking     rows come back score descending, with the stated rows and scores.
#   ties        rows with equal scores come back lower row first, whatever the
#               position of the best row, and the same input gives the same
#               order every time.
#   k           k larger than the row count returns every row; k of zero or less
#               returns none; k of one returns the single best row; an empty
#               column returns none.
#   null bytes  a cell whose packed bytes contain 0x00 (every zero component)
#               is scored in full, not cut at the first 0x00.
#   nulls       a null cell scores 0.0 and ranks after every positive score.
#   non-finite  a row holding a NaN never ranks above an honest row.
#   scale       a 1000-dimension column ranks the same rows.
# No test reads a clock or the environment.
# =============================================================================

from std.math import nan
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_kg_format import (
    Hit,
    cosine_topk,
    pack_embedding,
    pack_embedding_f32,
)


comptime _DIM = 1000


def _column(rows: List[List[Float64]]) raises -> StringArray[HeapRegion]:
    var cells = List[String]()
    for i in range(len(rows)):
        cells.append(pack_embedding(rows[i]))
    return StringArray.from_strings(cells)


def _rows(hits: List[Hit]) -> List[Int]:
    var r = List[Int]()
    for i in range(len(hits)):
        r.append(hits[i].row)
    return r^


def test_orders_by_score_descending() raises:
    var rows: List[List[Float64]] = [
        [0.0, 1.0, 0.0],  # orthogonal to the query: 0.0
        [1.0, 1.0, 0.0],  # 45 degrees: 0.7071...
        [1.0, 0.0, 0.0],  # parallel: 1.0
        [-1.0, 0.0, 0.0],  # opposite: -1.0
    ]
    var query: List[Float64] = [1.0, 0.0, 0.0]
    var hits = cosine_topk(_column(rows), query, 4)
    assert_equal(len(hits), 4)
    assert_equal(hits[0].row, 2)
    assert_equal(hits[1].row, 1)
    assert_equal(hits[2].row, 0)
    assert_equal(hits[3].row, 3)
    assert_equal(hits[0].score, 1.0)
    assert_true(abs(hits[1].score - 0.7071067811865476) < 1.0e-12)
    assert_equal(hits[2].score, 0.0)
    assert_equal(hits[3].score, -1.0)


def test_takes_the_top_k() raises:
    var rows: List[List[Float64]] = [
        [0.0, 1.0],
        [1.0, 1.0],
        [1.0, 0.0],
        [-1.0, 0.0],
    ]
    var query: List[Float64] = [1.0, 0.0]
    var hits = cosine_topk(_column(rows), query, 2)
    assert_equal(len(hits), 2)
    assert_equal(hits[0].row, 2)
    assert_equal(hits[1].row, 1)


def test_ties_rank_lower_row_first() raises:
    # Rows 1, 3 and 4 are the same vector: equal scores.
    var rows: List[List[Float64]] = [
        [0.0, 1.0],
        [1.0, 0.0],
        [0.0, -1.0],
        [1.0, 0.0],
        [1.0, 0.0],
    ]
    var query: List[Float64] = [1.0, 0.0]
    var hits = cosine_topk(_column(rows), query, 5)
    var got = _rows(hits)
    assert_equal(got[0], 1)
    assert_equal(got[1], 3)
    assert_equal(got[2], 4)
    assert_equal(got[3], 0)  # rows 0 and 2 both score 0.0: lower row first
    assert_equal(got[4], 2)
    # Same input, same order.
    var again = _rows(cosine_topk(_column(rows), query, 5))
    for i in range(5):
        assert_equal(again[i], got[i])


def test_all_rows_tied_come_back_in_row_order() raises:
    var rows = List[List[Float64]]()
    for _ in range(9):
        rows.append([2.0, 2.0, 2.0])
    var query: List[Float64] = [1.0, 1.0, 1.0]
    var got = _rows(cosine_topk(_column(rows), query, 9))
    for i in range(9):
        assert_equal(got[i], i)
    var top3 = _rows(cosine_topk(_column(rows), query, 3))
    assert_equal(len(top3), 3)
    assert_equal(top3[0], 0)
    assert_equal(top3[1], 1)
    assert_equal(top3[2], 2)


def test_tie_with_the_best_row_last() raises:
    # The best score is shared by the first and last rows; the first wins.
    var rows: List[List[Float64]] = [[1.0, 0.0], [0.0, 1.0], [1.0, 0.0]]
    var query: List[Float64] = [1.0, 0.0]
    var got = _rows(cosine_topk(_column(rows), query, 1))
    assert_equal(len(got), 1)
    assert_equal(got[0], 0)


def test_k_beyond_the_row_count_returns_every_row() raises:
    var rows: List[List[Float64]] = [[1.0, 0.0], [0.0, 1.0]]
    var query: List[Float64] = [1.0, 0.0]
    assert_equal(len(cosine_topk(_column(rows), query, 50)), 2)


def test_k_of_zero_or_less_returns_nothing() raises:
    var rows: List[List[Float64]] = [[1.0, 0.0], [0.0, 1.0]]
    var query: List[Float64] = [1.0, 0.0]
    assert_equal(len(cosine_topk(_column(rows), query, 0)), 0)
    assert_equal(len(cosine_topk(_column(rows), query, -1)), 0)
    assert_equal(len(cosine_topk(_column(rows), query, -1000000)), 0)


def test_empty_column_returns_nothing() raises:
    var rows = List[List[Float64]]()
    var query: List[Float64] = [1.0, 0.0]
    assert_equal(len(cosine_topk(_column(rows), query, 3)), 0)


def test_cells_with_zero_bytes_are_scored_in_full() raises:
    # [0, 0, 0, 5] packs to 12 zero bytes and then 5.0; cut at the first 0x00 it
    # would read as an empty vector and score 0.0. Row 1 is the wrong direction.
    var rows: List[List[Float64]] = [[0.0, 0.0, 0.0, 5.0], [5.0, 0.0, 0.0, 0.0]]
    var query: List[Float64] = [0.0, 0.0, 0.0, 1.0]
    var hits = cosine_topk(_column(rows), query, 2)
    assert_equal(hits[0].row, 0)
    assert_equal(hits[0].score, 1.0)
    assert_equal(hits[1].row, 1)
    assert_equal(hits[1].score, 0.0)


def test_a_null_cell_scores_zero_and_ranks_last() raises:
    var cells = List[String]()
    var v0: List[Float64] = [1.0, 0.0]
    var v1: List[Float64] = [1.0, 1.0]
    cells.append(pack_embedding(v0))
    cells.append(String(""))
    cells.append(pack_embedding(v1))
    var valid: List[Bool] = [True, False, True]
    var col = StringArray.from_strings_with_validity(cells, valid)
    var query: List[Float64] = [1.0, 0.0]
    var hits = cosine_topk(col, query, 3)
    assert_equal(hits[0].row, 0)
    assert_equal(hits[1].row, 2)
    assert_equal(hits[2].row, 1)
    assert_equal(hits[2].score, 0.0)


def test_a_nan_row_does_not_outrank_honest_rows() raises:
    var cells = List[String]()
    var bad: List[Float32] = [Float32(nan[DType.float32]()), 1.0]
    var good: List[Float32] = [1.0, 0.0]
    cells.append(pack_embedding_f32(bad))  # row 0 holds a NaN, listed first
    cells.append(pack_embedding_f32(good))
    cells.append(pack_embedding_f32(good))
    var col = StringArray.from_strings(cells)
    var query: List[Float64] = [1.0, 0.0]
    var hits = cosine_topk(col, query, 3)
    for i in range(3):
        assert_true(hits[i].score == hits[i].score, "no NaN score is returned")
    assert_equal(hits[0].row, 1)
    assert_equal(hits[1].row, 2)
    assert_equal(hits[2].row, 0)


def test_wide_column() raises:
    var rows = List[List[Float64]]()
    for r in range(6):
        var v = List[Float64](capacity=_DIM)
        for i in range(_DIM):
            v.append(1.0 if i == r else 0.0)
        rows.append(v^)
    var query = List[Float64](capacity=_DIM)
    for i in range(_DIM):
        query.append(1.0 if i == 4 else 0.0)
    var hits = cosine_topk(_column(rows), query, 2)
    assert_equal(hits[0].row, 4)
    assert_equal(hits[0].score, 1.0)
    # The rest tie at 0.0: lowest row first.
    assert_equal(hits[1].row, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
