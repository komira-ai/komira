"""In-memory Arrow columns with nulls, for the UDF end-to-end tests.

Each builder takes the values and a parallel validity list (`True` = valid,
`False` = null) and returns a `Column` that carries a real Arrow validity
bitmap. A null slot holds 0 in the data buffer (`ColumnBuilder.append_null`),
so a test whose valid data never holds 0 can tell a null that leaked into a
UDF as a value from one that was kept out.
"""

from komira_arrow.column import Column
from komira_arrow.column_builder import ColumnBuilder
from komira_buffer.heap_region import HeapRegion


def _check_lengths(n_vals: Int, n_valid: Int, what: String) raises:
    if n_vals != n_valid:
        raise Error(
            what + ": " + String(n_vals) + " values but " + String(n_valid)
            + " validity flags"
        )


def nullable_column[
    dt: DType
](vals: List[Scalar[dt]], valid: List[Bool]) raises -> Column[HeapRegion]:
    """A `dt` column whose row `i` is `vals[i]` when `valid[i]`, else NULL."""
    _check_lengths(len(vals), len(valid), "nullable_column")
    var b = ColumnBuilder[dt].with_capacity(len(vals))
    for i in range(len(vals)):
        if valid[i]:
            b.append(vals[i])
        else:
            b.append_null()
    return b^.materialize()


def i64_column(
    vals: List[Int64], valid: List[Bool]
) raises -> Column[HeapRegion]:
    var xs = List[Scalar[DType.int64]]()
    for i in range(len(vals)):
        xs.append(vals[i])
    return nullable_column[DType.int64](xs, valid)


def f64_column(
    vals: List[Float64], valid: List[Bool]
) raises -> Column[HeapRegion]:
    var xs = List[Scalar[DType.float64]]()
    for i in range(len(vals)):
        xs.append(vals[i])
    return nullable_column[DType.float64](xs, valid)


def i32_column(
    vals: List[Int32], valid: List[Bool]
) raises -> Column[HeapRegion]:
    var xs = List[Scalar[DType.int32]]()
    for i in range(len(vals)):
        xs.append(vals[i])
    return nullable_column[DType.int32](xs, valid)


def f32_column(
    vals: List[Float32], valid: List[Bool]
) raises -> Column[HeapRegion]:
    var xs = List[Scalar[DType.float32]]()
    for i in range(len(vals)):
        xs.append(vals[i])
    return nullable_column[DType.float32](xs, valid)


def all_valid(n: Int) -> List[Bool]:
    """`n` validity flags, every one valid."""
    var v = List[Bool]()
    for _ in range(n):
        v.append(True)
    return v^
