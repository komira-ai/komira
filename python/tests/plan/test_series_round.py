"""`Series.round` (komira/_series.py) with no libkomira: a frame over a Parquet
scan whose schema is made here, on a session stand-in that records the plan
bytes it is given. Checked:

- the node `round(decimals)` builds, by equality with a hand-built
  `RoundDigits("round_half_even", ...)`: the default of 0, a positive and a
  negative count, the bounds of int32, and a count given by keyword;
- the type of the result: the column's, for int32, int64, float32 and float64,
  and the result is a Series that takes part in operators and filters;
- every refusal by class and full message: a float, a bool and a str count, a
  count outside int32, extra positional and keyword arguments, a string, bool,
  date, unsigned, float16 and decimal column, and a stale Series;
- the wire form: the plan the frame encodes holds a `round_digits` arm with the
  rule RDG_ROUND_HALF_EVEN, the digit count and the column as its child.

    test_series_round.py
"""

import decimal
import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import ColRef, Field, RoundDigits
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, pb, vocab

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "series_round_test_input.parquet")
FIELDS = (
    ("i", "int64"),
    ("n", "int32"),
    ("f", "float64"),
    ("g", "float32"),
    ("s", "string"),
    ("ok", "bool"),
    ("d", "date32"),
    ("u", "uint32"),
    ("h", "float16"),
)


class Stub:
    """A session that records what the plan door is given."""

    def __init__(self):
        self.calls = []
        self.stream = object()

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))
        return self.stream


class Env:
    def __init__(self):
        self.stub = Stub()
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in FIELDS])
        self.sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        self.scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in FIELDS))
        self.df = DataFrame._new(self.stub, self.scan, self.sources)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def test_round_builds_a_half_even_node_over_the_column():
    df = Env().df
    for name in ("i", "n", "f", "g"):
        for count in (-3, -1, 0, 1, 7, _ops.INT32_MIN, _ops.INT32_MAX):
            got = df[name].round(count)
            assert got._node == RoundDigits("round_half_even", ColRef(name), count), (name, count, got._node)
    assert df["f"].round()._node == RoundDigits("round_half_even", ColRef("f"), 0)
    assert df["f"].round(decimals=2)._node == RoundDigits("round_half_even", ColRef("f"), 2)
    assert df["f"].round(2)._node != df["f"].round(1)._node


def test_round_keeps_the_type_of_the_column():
    df = Env().df
    for name, dtype in (("i", "int64"), ("n", "int32"), ("f", "float64"), ("g", "float32")):
        assert df[name].round(2).dtype == dtype, name
        assert df[name].round(-1).dtype == dtype, name
    assert df.assign(r=df["f"].round(1)).dtypes["r"] == "float64"


def test_a_rounded_series_takes_part_in_operators_and_filters():
    df = Env().df
    doubled = df["f"].round(1) * 2
    assert isinstance(doubled._node, _ops.Arith) and doubled._node.left == RoundDigits(
        "round_half_even", ColRef("f"), 1
    )
    kept = df[df["f"].round() == 2.0]
    assert kept.columns == df.columns
    assert df["f"].round(1).round(0)._node == RoundDigits(
        "round_half_even", RoundDigits("round_half_even", ColRef("f"), 1), 0
    )


def test_a_count_that_is_not_an_int_within_int32_is_refused():
    s = Env().df["f"]
    refuses(lambda: s.round(1.0), TypeError, "round() decimals must be an int, not a float")
    refuses(lambda: s.round(True), TypeError, "round() decimals must be an int, not a bool")
    refuses(lambda: s.round("1"), TypeError, "round() decimals must be an int, not a str")
    refuses(lambda: s.round(None), TypeError, "round() decimals must be an int, not a NoneType")
    refuses(lambda: s.round(_ops.INT32_MAX + 1), ValueError, "round() decimals must be within int32, not 2147483648")
    refuses(lambda: s.round(_ops.INT32_MIN - 1), ValueError, "round() decimals must be within int32, not -2147483649")


def test_extra_arguments_are_refused_by_name():
    s = Env().df["f"]
    extra = "round() takes only decimals, and was given the extra arguments {}: pandas ignores them and komira refuses them"
    refuses(lambda: s.round(1, 2), UnsupportedOperation, extra.format("2"))
    refuses(lambda: s.round(1, "a", None), UnsupportedOperation, extra.format("'a', None"))
    refuses(lambda: s.round(1, out=None), UnsupportedOperation, extra.format("out=..."))
    refuses(lambda: s.round(1, 2, axis=0), UnsupportedOperation, extra.format("2, axis=..."))


def test_a_column_that_is_not_a_rounded_type_is_refused_by_name():
    env = Env()
    df = env.df
    tail = ": it rounds int8, int16, int32, int64, float32 and float64 columns"
    for name, dtype in (("s", "string"), ("ok", "bool"), ("d", "date32"), ("u", "uint32"), ("h", "float16")):
        refuses(lambda name=name: df[name].round(1), UnsupportedOperation, f"round() of a {dtype} column is not built" + tail)
    money = df.assign(m=decimal.Decimal("1.50"))
    assert money.dtypes["m"] == "decimal128"
    refuses(lambda: money["m"].round(1), UnsupportedOperation, "round() of a decimal128 column is not built" + tail)
    assert env.stub.calls == []


def test_a_stale_series_is_refused():
    df = Env().df
    s = df["f"]
    df["z"] = 1
    refuses(
        lambda: s.round(1),
        UnsupportedOperation,
        'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
        "take it from the frame again",
    )
    assert df["f"].round(1)._node == RoundDigits("round_half_even", ColRef("f"), 1)


def test_the_encoded_plan_holds_the_round_digits_arm():
    env = Env()
    out = env.df.assign(r=env.df["f"].round(-2))
    plan = encode_plan(out._plan, env.sources).plan
    assert plan.WhichOneof("node") == "project", plan.WhichOneof("node")
    arms = []
    for e in plan.project.exprs:
        inner = e.alias.child if e.WhichOneof("node") == "alias" else e
        if inner.WhichOneof("node") == "round_digits":
            arms.append(inner.round_digits)
    assert len(arms) == 1, plan.project.exprs
    arm = arms[0]
    assert arm.op == vocab.RDG_ROUND_HALF_EVEN and arm.digits == -2
    assert arm.child.col_ref.name == "f"
    assert plan.output_schema.fields[-1].name == "r"
    assert plan.output_schema.fields[-1].arrow_type_id == arrow_id("float64")
    assert env.stub.calls == []


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("series round: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
