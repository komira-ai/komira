# =============================================================================
# test_fs_value_types.mojo
# =============================================================================
# The small value types the FileSystem / FileFormat surfaces pass around,
# each held to its documented arithmetic:
#
#   * `ByteRange.end` / `is_empty`.
#   * `ColumnSet`: `all` vs `columns`, `num_projected`, `is_projected` (hit at
#     the first, a middle and the last index; miss), `explicit_indices_ref`,
#     `projected_indices` for both modes.
#   * the capability payload handles (`PhysicalPredicate` and friends) carry
#     their fields.
#   * `WriteMode` equality and the three predicates.
#   * `next_footer_window`: the cold window at and below 256 KiB, the 1/8
#     growth rounded UP to 64 KiB, the exact-multiple case, the 16 MiB cap.
#   * `speculative_tail_start`: window floor of 8, file shorter / equal /
#     longer than the window.
#   * `FooterRegion.len` / `covers` at each edge.
#   * `footer_hint_key` and `FooterWindowHints` (cold suggest, per-directory
#     learning, only growth counts, never shrinks, ignores non-positive
#     lengths, `copy` is independent).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_fs.byte_range import ByteRange
from komira_fs.column_set import ColumnSet
from komira_fs.file_format_capabilities import (
    PhysicalPredicate,
    DynamicJoinFilterRef,
    BloomFilterRef,
    DictSinkRef,
)
from komira_fs.file_system import WriteMode
from komira_fs.footer_region import (
    FOOTER_SPECULATIVE_WINDOW,
    FOOTER_WINDOW_MAX,
    FOOTER_WINDOW_GRANULARITY,
    FooterRegion,
    next_footer_window,
    speculative_tail_start,
)
from komira_fs.footer_window_hints import FooterWindowHints, footer_hint_key


def _ranges() -> List[ByteRange]:
    var out = List[ByteRange]()
    out.append(ByteRange(offset=Int64(10), length=Int64(5)))
    out.append(ByteRange(offset=Int64(7), length=Int64(0)))
    return out^


def test_byte_range() raises:
    var rs = _ranges()
    assert_equal(Int(rs[0].end()), 15)
    assert_false(rs[0].is_empty())
    assert_equal(Int(rs[1].end()), 7)
    assert_true(rs[1].is_empty())


def test_column_set_all() raises:
    var cs = ColumnSet.all()
    assert_true(cs.project_all)
    assert_equal(cs.num_projected(6), 6)
    assert_true(cs.is_projected(0))
    assert_true(cs.is_projected(99))
    var idx = cs.projected_indices(4)
    assert_equal(len(idx), 4)
    for i in range(4):
        assert_equal(idx[i], i)
    assert_equal(len(cs.explicit_indices_ref()), 0)


def test_column_set_columns() raises:
    var want = List[Int]()
    want.append(5)
    want.append(2)
    want.append(9)
    var cs = ColumnSet.columns(want.copy())
    assert_false(cs.project_all)
    # The explicit count, whatever the file's width.
    assert_equal(cs.num_projected(100), 3)
    # First, middle and last listed index all hit; others miss.
    assert_true(cs.is_projected(5))
    assert_true(cs.is_projected(2))
    assert_true(cs.is_projected(9))
    assert_false(cs.is_projected(0))
    assert_false(cs.is_projected(3))
    # Order is the caller's, not sorted.
    var idx = cs.projected_indices(100)
    assert_equal(len(idx), 3)
    assert_equal(idx[0], 5)
    assert_equal(idx[1], 2)
    assert_equal(idx[2], 9)
    ref r = cs.explicit_indices_ref()
    assert_equal(len(r), 3)
    assert_equal(r[2], 9)


def _ids() -> List[Int64]:
    var out = List[Int64]()
    out.append(Int64(41))
    out.append(Int64(7))
    out.append(Int64(3))
    return out^


def test_capability_handles() raises:
    # Built from values the compiler cannot fold, so the constructors run.
    var ids = _ids()
    var p = PhysicalPredicate(_predicate_id=ids[0], _has_payload=ids[2] > 0)
    assert_equal(Int(p._predicate_id), 41)
    assert_true(p._has_payload)
    var j = DynamicJoinFilterRef(
        _filter_id=ids[1], _key_column_idx=Int32(ids[2])
    )
    assert_equal(Int(j._filter_id), 7)
    assert_equal(Int(j._key_column_idx), 3)
    var b = BloomFilterRef(_filter_id=ids[1] + 1, _column_idx=Int32(ids[2] + 1))
    assert_equal(Int(b._filter_id), 8)
    assert_equal(Int(b._column_idx), 4)
    var d = DictSinkRef(_sink_id=ids[0] - 32)
    assert_equal(Int(d._sink_id), 9)
    var moved = d^
    assert_equal(Int(moved._sink_id), 9)
    var pc = p.copy()
    assert_equal(Int(pc._predicate_id), 41)


def test_write_mode_equality() raises:
    var t = WriteMode.create_truncate()
    var x = WriteMode.create_exclusive()
    var a = WriteMode.append()
    assert_true(t == WriteMode.create_truncate())
    assert_false(t == x)
    assert_true(t != a)
    assert_false(a != WriteMode.append())
    assert_true(t.is_create_truncate() and not t.is_create_exclusive())
    assert_true(x.is_create_exclusive() and not x.is_append())
    assert_true(a.is_append() and not a.is_create_truncate())


def test_next_footer_window() raises:
    assert_equal(FOOTER_SPECULATIVE_WINDOW, 256 * 1024)
    assert_equal(FOOTER_WINDOW_GRANULARITY, 64 * 1024)
    # At or below the cold window: the cold window.
    assert_equal(next_footer_window(0), FOOTER_SPECULATIVE_WINDOW)
    assert_equal(
        next_footer_window(FOOTER_SPECULATIVE_WINDOW), FOOTER_SPECULATIVE_WINDOW
    )
    # One byte over: 262145 * 9/8 = 294913 (integer), rounded UP to 64 KiB
    # = 327680.
    assert_equal(next_footer_window(FOOTER_SPECULATIVE_WINDOW + 1), 327680)
    # 1 MiB: 1 MiB + 128 KiB = 1179648, already a 64 KiB multiple.
    assert_equal(next_footer_window(1024 * 1024), 1179648)
    # 2,439,324 B: + 304,915 = 2,744,239 -> ceil to 64 KiB = 2,752,512.
    assert_equal(next_footer_window(2439324), 2752512)
    # The cap: anything whose grown window passes 16 MiB is 16 MiB.
    assert_equal(next_footer_window(15 * 1024 * 1024), FOOTER_WINDOW_MAX)
    assert_equal(next_footer_window(FOOTER_WINDOW_MAX), FOOTER_WINDOW_MAX)
    # Exactly at the cap after rounding is the cap, not over it.
    # 14913080 * 9/8 = 16777215 -> ceil = 16777216 = FOOTER_WINDOW_MAX.
    assert_equal(next_footer_window(14913080), FOOTER_WINDOW_MAX)


def test_speculative_tail_start() raises:
    # File shorter than / equal to the window: read from 0.
    assert_equal(speculative_tail_start(100, 200), 0)
    assert_equal(speculative_tail_start(200, 200), 0)
    # Longer: the last `window` bytes.
    assert_equal(speculative_tail_start(1000, 200), 800)
    # The window floor is 8 (the Parquet trailer): any window under 8 reads
    # the last 8 bytes, 8 itself too, 9 reads 9.
    assert_equal(speculative_tail_start(100, 3), 92)
    assert_equal(speculative_tail_start(100, 7), 92)
    assert_equal(speculative_tail_start(100, 8), 92)
    assert_equal(speculative_tail_start(100, 9), 91)
    assert_equal(speculative_tail_start(5, 0), 0)
    # Default window.
    assert_equal(
        speculative_tail_start(FOOTER_SPECULATIVE_WINDOW + 10), 10
    )


def test_footer_region_covers() raises:
    var bytes = List[UInt8]()
    bytes.resize(10, UInt8(0))
    var fr = FooterRegion(bytes^, 100, 110)
    assert_equal(fr.len(), 10)
    assert_equal(fr.offset, 100)
    assert_equal(fr.file_size, 110)
    assert_true(fr.covers(100, 10))  # the whole region
    assert_true(fr.covers(105, 5))  # ends exactly at the end
    assert_true(fr.covers(109, 0))
    assert_false(fr.covers(99, 1))  # starts before
    assert_false(fr.covers(105, 6))  # ends one past


def test_footer_hint_key() raises:
    assert_equal(footer_hint_key("/data/tpch/lineitem.parquet"), "/data/tpch/")
    assert_equal(footer_hint_key("s3://b/k/x.parquet"), "s3://b/k/")
    assert_equal(footer_hint_key("/x"), "/")
    assert_equal(footer_hint_key("noslash.parquet"), "")
    assert_equal(footer_hint_key(""), "")


def test_footer_window_hints_learn() raises:
    var h = FooterWindowHints()
    assert_equal(h.dataset_count(), 0)
    assert_equal(h.adaptation_count(), 0)
    assert_equal(h.suggest("/d/a.parquet"), FOOTER_SPECULATIVE_WINDOW)

    # Non-positive lengths teach nothing.
    h.observe("/d/a.parquet", 0)
    h.observe("/d/a.parquet", -5)
    assert_equal(h.dataset_count(), 0)

    # A small footer files the key at the cold window: not an adaptation.
    h.observe("/small/a.parquet", 1000)
    assert_equal(h.dataset_count(), 1)
    assert_equal(h.adaptation_count(), 0)
    assert_equal(h.suggest("/small/b.parquet"), FOOTER_SPECULATIVE_WINDOW)

    # A big footer on a new directory: learned for its siblings.
    h.observe("/d/a.parquet", 1024 * 1024)
    assert_equal(h.dataset_count(), 2)
    assert_equal(h.adaptation_count(), 1)
    assert_equal(h.suggest("/d/sibling.parquet"), 1179648)
    # Other directories are untouched.
    assert_equal(h.suggest("/e/a.parquet"), FOOTER_SPECULATIVE_WINDOW)

    # A smaller footer never shrinks the window and is not counted.
    h.observe("/d/b.parquet", 300 * 1024)
    assert_equal(h.suggest("/d/c.parquet"), 1179648)
    assert_equal(h.adaptation_count(), 1)

    # A larger one grows it and counts.
    h.observe("/d/b.parquet", 2439324)
    assert_equal(h.suggest("/d/c.parquet"), 2752512)
    assert_equal(h.adaptation_count(), 2)
    assert_equal(h.dataset_count(), 2)

    # The known-small key grows too (an existing key, raised).
    h.observe("/small/c.parquet", 1024 * 1024)
    assert_equal(h.suggest("/small/z.parquet"), 1179648)
    assert_equal(h.adaptation_count(), 3)


def test_footer_window_hints_copy_is_independent() raises:
    var h = FooterWindowHints()
    h.observe("/d/a.parquet", 1024 * 1024)
    var c = h.copy()
    assert_equal(c.dataset_count(), 1)
    assert_equal(c.adaptation_count(), 1)
    assert_equal(c.suggest("/d/x"), 1179648)
    c.observe("/e/a.parquet", 2439324)
    c.observe("/d/a.parquet", 2439324)
    assert_equal(c.dataset_count(), 2)
    assert_equal(c.adaptation_count(), 3)
    # The original saw none of it.
    assert_equal(h.dataset_count(), 1)
    assert_equal(h.adaptation_count(), 1)
    assert_equal(h.suggest("/d/x"), 1179648)


def main() raises:
    var suite = TestSuite()
    suite.test[test_byte_range]()
    suite.test[test_column_set_all]()
    suite.test[test_column_set_columns]()
    suite.test[test_capability_handles]()
    suite.test[test_write_mode_equality]()
    suite.test[test_next_footer_window]()
    suite.test[test_speculative_tail_start]()
    suite.test[test_footer_region_covers]()
    suite.test[test_footer_hint_key]()
    suite.test[test_footer_window_hints_learn]()
    suite.test[test_footer_window_hints_copy_is_independent]()
    suite^.run()
