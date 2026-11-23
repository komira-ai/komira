"""Functions that test_udf_plan_run.py captures, encodes and runs in the
komira/python runtime. The scalar ones return None for a None argument: the
runtime passes a null to the function as None."""

import pyarrow.compute as pc

from komira._capture import udf


@udf
def double(x: int) -> int:
    return None if x is None else x * 2


@udf
def halve(x: float) -> float:
    return None if x is None else x / 2


@udf(kind="map_batches_column", return_dtype="int64")
def mapped_double(values):
    return pc.multiply(values, 2)


@udf(kind="row", return_dtype="int64")
def row_sum(r):
    return r.a + r.b
