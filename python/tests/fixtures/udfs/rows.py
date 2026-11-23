"""Row and frame fixtures: the read set from columns=, annotations and the scan."""

import dataclasses
import inspect
import sys
from typing import TypedDict

from komira._capture import udf


class Pair(TypedDict):
    a: int
    b: int


class Wider(Pair):
    c: int


class Nothing(TypedDict):
    pass


@dataclasses.dataclass
class Point:
    x: int
    y: int


@dataclasses.dataclass
class Unit:
    pass


def helper(row):
    return 1


# ---- bounded reads ----------------------------------------------------------


@udf(kind="row", return_dtype="int64")
def attribute(r):
    return r.a + r.b


@udf(kind="row", return_dtype="int64")
def subscript(r):
    return r["b"] * r["a"]


@udf(kind="row", return_dtype="int64")
def branches(r):
    if r.flag:
        return r.taken
    return r["untaken"]


@udf(kind="row", return_dtype="int64")
def only_untaken(r):
    if r.kind == 0:
        return 0
    return r.late


@udf(kind="row", return_dtype="int64")
def repeated(r):
    return r.a + r.a + r["a"]


@udf(kind="row", return_dtype="int64")
def through_field(r):
    return len(r.text.upper()) + len(f"{r.a}-{r['b']}")


@udf(kind="row", return_dtype="int64")
def many_locals(r):
    first = r.first
    second = r.second
    third = r["third"]
    r2 = first + second
    return r2 + third + r.fourth


@udf(kind="row", return_dtype="int64")
def reads_nothing(r):
    return 1


@udf(kind="row", return_dtype="int64")
def non_ascii(r):
    return r["é"] + r["z"] + r.a + r["日本"] + r["😀"]


# ---- unbounded reads --------------------------------------------------------


@udf(kind="row", return_dtype="int64")
def passed_on(r):
    return helper(r)


@udf(kind="row", return_dtype="int64")
def passed_with_other(r):
    return helper(r.a, r)


@udf(kind="row", return_dtype="int64")
def iterated(r):
    return sum(1 for _ in r)


@udf(kind="row", return_dtype="int64")
def iterated_loop(r):
    total = 0
    for key in r:
        total += 1
    return total


@udf(kind="row", return_dtype="int64")
def unpacked(r):
    a, b = r
    return a + b


@udf(kind="row", return_dtype="int64")
def variable_key(r):
    key = "a"
    return r[key]


@udf(kind="row", return_dtype="int64")
def computed_getattr(r):
    return getattr(r, "a")


@udf(kind="row", return_dtype="int64")
def stored(r):
    kept = r
    return kept.a


@udf(kind="row", return_dtype="int64")
def stored_after_store(r):
    first = r.a
    kept = r
    return first + kept.b


@udf(kind="row", return_dtype="int64")
def reassigned(r):
    r = {"a": 1}
    return r["a"]


@udf(kind="row", return_dtype="int64")
def deleted(r):
    first = r.a
    del r
    return first


@udf(kind="row", return_dtype="int64")
def in_lambda(r):
    return (lambda: r.a)()


@udf(kind="row", return_dtype="int64")
def in_nested_def(r):
    def inner():
        return r.a

    return inner()


@udf(kind="row", return_dtype="int64")
def in_comprehension(r):
    return sum([r.a for _ in range(2)])


@udf(kind="row", return_dtype="int64")
def in_generator(r):
    return sum(r.a for _ in range(2))


@udf(kind="row", return_dtype="int64")
def series_name(r):
    return r.name


@udf(kind="row", return_dtype="int64")
def series_index(r):
    return r.index


@udf(kind="row", return_dtype="int64")
def series_values(r):
    return r.values


@udf(kind="row", return_dtype="int64")
def series_get(r):
    return r.get("a")


@udf(kind="row", return_dtype="int64")
def method_call(r):
    return r.compute(1)


@udf(kind="row", return_dtype="int64")
def dunder(r):
    return r.__class__


@udf(kind="row", return_dtype="int64")
def membership(r):
    return "a" in r


@udf(kind="row", return_dtype="int64")
def item_assignment(r):
    r["a"] = 1
    return 1


@udf(kind="row", return_dtype="int64")
def attribute_assignment(r):
    r.a = 1
    return 1


@udf(kind="row", return_dtype="int64")
def item_deletion(r):
    del r["a"]
    return 1


@udf(kind="row", return_dtype="int64")
def sliced(r):
    return r[0:1]


@udf(kind="row", return_dtype="int64")
def integer_key(r):
    return r[0]


@udf(kind="row", return_dtype="int64")
def merged_branches(r):
    other = None
    return (other or r).a


@udf(kind="row", return_dtype="int64")
def returns_row(r):
    return r


@udf(kind="row", return_dtype="int64")
def reads_locals(r):
    return len(locals())


@udf(kind="row", return_dtype="int64")
def reads_vars(r):
    return len(vars())


@udf(kind="row", return_dtype="int64")
def no_parameter():
    return 1


# ---- declared read sets -----------------------------------------------------


@udf(kind="row", return_dtype="int64", columns=["b", "a"])
def declared_columns(r):
    return helper(r)


@udf(kind="row", return_dtype="int64", columns=[])
def declared_empty(r):
    return helper(r)


@udf(kind="row", return_dtype="int64", columns=["é", "a", "z"])
def declared_non_ascii(r):
    return helper(r)


@udf(kind="row", return_dtype="int64")
def typed(r: Pair):
    return r["a"]


@udf(kind="row", return_dtype="int64")
def typed_wider(r: Wider):
    return helper(r)


@udf(kind="row", return_dtype="int64")
def typed_nothing(r: Nothing):
    return 1


@udf(kind="row", return_dtype="int64", columns=["b", "a"])
def typed_and_columns(r: Pair):
    return helper(r)


@udf(kind="row", return_dtype="int64", columns=["a", "c"])
def typed_disagrees(r: Pair):
    return helper(r)


@udf(kind="row", return_dtype="int64")
def dataclass_row(r: Point):
    return helper(r)


@udf(kind="row", return_dtype="int64")
def dataclass_empty(r: Unit):
    return helper(r)


@udf(kind="row", return_dtype="int64", columns=["y"])
def dataclass_disagrees(r: Point):
    return helper(r)


@udf(kind="row", return_dtype="int64")
def annotated_other(r: dict):
    return r["a"]


# ---- frames -----------------------------------------------------------------

SCHEMA = {"total": "int64", "mean": "float64"}


@udf(kind="map_batches_frame", schema=SCHEMA, columns=["y", "x"])
def frame_columns(df):
    return df


@udf(kind="map_batches_frame", schema=SCHEMA, columns=[])
def frame_empty(df):
    return df


@udf(kind="map_batches_frame", schema=SCHEMA)
def frame_typed(df: Pair):
    return df


@udf(kind="map_batches_frame", schema=SCHEMA)
def frame_dataclass(df: Point):
    return df


@udf(kind="map_batches_frame", schema=SCHEMA, columns=["a", "q"])
def frame_disagrees(df: Pair):
    return df


@udf(kind="map_batches_frame", schema=SCHEMA)
def frame_unbounded(df):
    return df


@udf(kind="map_batches_frame", columns=["a"])
def frame_no_schema(df):
    return df


@udf(kind="map_batches_frame", schema=[("total", "int64")], columns=["a"], null_mode="propagate", stability="volatile")
def frame_pairs(df):
    return df


# ---- row types on a function that reads argument expressions ----------------


@udf(return_dtype="int64")
def scalar_with_row_type(x: Point):
    return 1


@udf(kind="row", return_dtype="int64")
def reads_frame(r):
    return len(sys._getframe().f_locals)


@udf(kind="row", return_dtype="int64")
def reads_current_frame(r):
    return len(inspect.currentframe().f_locals)
