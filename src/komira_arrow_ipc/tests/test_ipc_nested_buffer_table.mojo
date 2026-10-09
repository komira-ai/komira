# =============================================================================
# test_ipc_nested_buffer_table.mojo: the per-type Buffer-descriptor counts of
# `nested_node_buffer_count`, arm by arm, on both decoders.
# =============================================================================
#
# The nested decoders refuse a node before its arm reads
# `buffers[buffer_idx + k]` when the message carries fewer descriptors than
# `nested_node_buffer_count` returns. A count one lower than what the arm
# reads lets the arm index past a short Buffer list again, which aborts the
# process. The decode tests in test_ipc_nested_buffer_count.mojo reach only
# STRUCT, the INT64 leaf, LIST and BINARY_VIEW; this table pins the exact
# count for every arm, under zerocopy=False (copy-on-read) and zerocopy=True.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow_ipc.ipc_nested_buffer_check import nested_node_buffer_count


comptime COPY = False
comptime ZC = True


def _count(
    t: ArrowType,
    zerocopy: Bool,
    n_children: Int = 0,
    inner_size: Int = 0,
    fixed_width: Int = 0,
    view_col_idx: Int = -1,
    variadic: List[Int64] = List[Int64](),
) -> Int:
    return nested_node_buffer_count(
        t, n_children, inner_size, fixed_width, view_col_idx, variadic,
        zerocopy,
    )


def _one(n: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(n)
    return out^


def test_leaf_counts() raises:
    for zc in range(2):
        var z = zc == 1
        assert_equal(_count(ArrowType.NULL, z), 0)
        assert_equal(_count(ArrowType.INT64, z, fixed_width=8), 2)
        assert_equal(_count(ArrowType.INT8, z, fixed_width=1), 2)
        assert_equal(_count(ArrowType.DECIMAL128, z, fixed_width=16), 2)
        assert_equal(_count(ArrowType.STRING, z), 3)
        assert_equal(_count(ArrowType.BINARY, z), 3)
        assert_equal(_count(ArrowType.LARGE_STRING, z), 3)
        assert_equal(_count(ArrowType.LARGE_BINARY, z), 3)
        # Unsupported here: the arm raises before reading a buffer.
        assert_equal(_count(ArrowType.DICTIONARY, z), 0)
        # An id past the declared space reaches the catch-all.
        assert_equal(_count(ArrowType(50), z), 0)
    # BOOL: validity + bit-packed values when copied; the zero-copy arm
    # refuses BOOL before reading.
    assert_equal(_count(ArrowType.BOOL, COPY), 2)
    assert_equal(_count(ArrowType.BOOL, ZC), 0)


def test_fixed_size_counts() raises:
    for zc in range(2):
        var z = zc == 1
        assert_equal(_count(ArrowType.FIXED_SIZE_BINARY, z, inner_size=4), 2)
        assert_equal(_count(ArrowType.FIXED_SIZE_BINARY, z, inner_size=1), 2)
        assert_equal(_count(ArrowType.FIXED_SIZE_BINARY, z, inner_size=0), 0)
        assert_equal(_count(ArrowType.FIXED_SIZE_BINARY, z, inner_size=-1), 0)
        assert_equal(
            _count(ArrowType.FIXED_SIZE_LIST, z, n_children=1, inner_size=3),
            1,
        )
        assert_equal(
            _count(ArrowType.FIXED_SIZE_LIST, z, n_children=1, inner_size=1),
            1,
        )
        assert_equal(
            _count(ArrowType.FIXED_SIZE_LIST, z, n_children=1, inner_size=0),
            0,
        )
        assert_equal(
            _count(ArrowType.FIXED_SIZE_LIST, z, n_children=2, inner_size=3),
            0,
        )
        assert_equal(
            _count(ArrowType.FIXED_SIZE_LIST, z, n_children=0, inner_size=3),
            0,
        )


def test_list_and_map_counts() raises:
    var kinds = List[ArrowType]()
    kinds.append(ArrowType.LIST)
    kinds.append(ArrowType.LARGE_LIST)
    kinds.append(ArrowType.MAP)
    for i in range(len(kinds)):
        var t = kinds[i]
        assert_equal(_count(t, COPY, n_children=1), 2)
        assert_equal(_count(t, ZC, n_children=1), 2)
        # The copy-on-read arm reads validity and offsets before it checks
        # the child count; the zero-copy arm checks the count first.
        assert_equal(_count(t, COPY, n_children=2), 2)
        assert_equal(_count(t, ZC, n_children=2), 0)


def test_struct_and_union_counts() raises:
    for zc in range(2):
        var z = zc == 1
        assert_equal(_count(ArrowType.STRUCT, z, n_children=2), 1)
        assert_equal(_count(ArrowType.UNION_SPARSE, z, n_children=2), 1)
        assert_equal(_count(ArrowType.UNION_DENSE, z, n_children=2), 2)


def test_view_counts() raises:
    var kinds = List[ArrowType]()
    kinds.append(ArrowType.BINARY_VIEW)
    kinds.append(ArrowType.UTF8_VIEW)
    for i in range(len(kinds)):
        var t = kinds[i]
        assert_equal(_count(t, COPY, view_col_idx=0, variadic=_one(0)), 2)
        assert_equal(_count(t, COPY, view_col_idx=0, variadic=_one(3)), 5)
        # A view index the message does not carry: the arm raises first.
        assert_equal(_count(t, COPY, view_col_idx=1, variadic=_one(3)), 0)
        assert_equal(_count(t, COPY, view_col_idx=-1, variadic=_one(3)), 0)
        assert_equal(_count(t, COPY, view_col_idx=0), 0)
        # A negative count: the arm raises first.
        assert_equal(_count(t, COPY, view_col_idx=0, variadic=_one(-1)), 0)
        # 2^62 is added; anything above saturates at 2^62.
        assert_equal(
            _count(t, COPY, view_col_idx=0, variadic=_one(Int64(1) << 62)),
            (1 << 62) + 2,
        )
        assert_equal(
            _count(
                t,
                COPY,
                view_col_idx=0,
                variadic=_one(Int64(9223372036854775807)),
            ),
            1 << 62,
        )
        # The zero-copy decoder refuses view types before reading.
        assert_equal(_count(t, ZC, view_col_idx=0, variadic=_one(3)), 0)


def test_list_view_counts() raises:
    var kinds = List[ArrowType]()
    kinds.append(ArrowType.LIST_VIEW)
    kinds.append(ArrowType.LARGE_LIST_VIEW)
    for i in range(len(kinds)):
        var t = kinds[i]
        assert_equal(_count(t, COPY, n_children=1), 3)
        assert_equal(_count(t, COPY, n_children=2), 0)
        assert_equal(_count(t, ZC, n_children=1), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
