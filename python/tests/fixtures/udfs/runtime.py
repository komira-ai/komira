"""Functions that test_udf_plan_run.py captures, encodes and runs in the
komira/python runtime. The scalar ones return None for a None argument: the
runtime passes a null to the function as None."""

import datetime
import decimal
from typing import TypedDict

import pyarrow.compute as pc

from komira._capture import udf


class Pair(TypedDict):
    a: int
    b: str


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


@udf
def shout(s: str) -> str:
    return None if s is None else s.upper() + "!"


@udf
def tagged(s: str) -> bytes:
    return None if s is None else s.encode("utf-8") + b"\x00"


@udf
def is_positive(x: int) -> bool:
    return None if x is None else x > 0


@udf
def next_day(d: datetime.date) -> datetime.date:
    return None if d is None else d + datetime.timedelta(days=1)


@udf
def at_noon(d: datetime.date) -> datetime.datetime:
    return None if d is None else datetime.datetime(d.year, d.month, d.day, 12)


@udf(return_dtype="decimal128(12, 2)")
def with_fee(price):
    return None if price is None else price * 2 + decimal.Decimal("0.50")


@udf
def three_from(x: int) -> list[int]:
    return None if x is None else [x, x + 1, x + 2]


@udf
def pair_of(x: int, s: str) -> Pair:
    return None if x is None or s is None else {"a": x, "b": s}


@udf(return_dtype="timestamp[ms, tz=UTC]")
def instant(x):
    if x is None:
        return None
    return datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(milliseconds=x)


@udf
def label(x: int, s: str, price) -> str:
    return None if x is None or s is None or price is None else "%d/%s/%s" % (x, s, price)


@udf
def total_of(xs) -> int:
    return None if xs is None else sum(v for v in xs if v is not None)


@udf
def pair_label(p) -> str:
    return None if p is None else "%s=%s" % (p["b"], p["a"])
