"""An `Aggregate` as a `WireAggregateNode`, with the fields the engine derives.

The group keys are column references, and each aggregate is a `WireAggExpr`
under its item name (`alias_name`), as the SQL binder names every aggregate.
Its arguments fill the child slots in order, except that the regression and
covariance functions take `(y, x)`, the SQL order, and the engine's slots hold
x first (`AggExpr`, src/plan_expr/agg_expr.mojo). `count()` fills no slot.
`quantile_cont(x, q)` fills slot 0 with x and slot 1 with q, a float literal
in [0, 1].

The output is the keys' fields, then one field per aggregate, typed by the
engine's rules (`_infer_agg_field`, src/plan_ir/logical_plan.mojo):

    count, count_distinct, regr_count   int64, never null
    mean and the statistics             float64
    bool_and, bool_or                   bool
    count_if                            int64
    sum                                 int64 over a signed int or a bool,
                                        uint64 over an unsigned int, float64
                                        over a float32, decimal(38, s) over a
                                        decimal(p, s), the input's type
                                        otherwise
    min, max, first, last, any_value    the input's type, its zone and its
                                        decimal precision and scale

Every aggregate but the counts may be NULL (an empty group).
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation
from komira._ops._expr import ColRef, Lit
from komira._ops._rel import Agg, Aggregate

from ._expr import encode_expr
from ._field import expr_field
from ._wire import arrow_id, field, member, pb

__all__ = ["encode_aggregate"]

_NEVER_NULL_COUNTS = frozenset({"count", "count_distinct", "regr_count"})

_FLOAT64_RESULTS = frozenset(
    {
        "mean",
        "stddev_samp",
        "var_samp",
        "corr",
        "median",
        "largest_k",
        "covar_pop",
        "covar_samp",
        "regr_avgx",
        "regr_avgy",
        "regr_sxx",
        "regr_sxy",
        "regr_syy",
        "regr_slope",
        "regr_intercept",
        "regr_r2",
        "var_pop",
        "stddev_pop",
        "sem",
        "product",
        "kahan_sum",
        "kahan_avg",
        "skewness",
        "kurtosis",
        "kurtosis_pop",
        "quantile_cont",
    }
)

# The two-argument functions whose engine slots hold x, then y.
_X_FIRST = frozenset(
    {
        "covar_pop",
        "covar_samp",
        "regr_avgx",
        "regr_avgy",
        "regr_count",
        "regr_sxx",
        "regr_sxy",
        "regr_syy",
        "regr_slope",
        "regr_intercept",
        "regr_r2",
    }
)

# The k the engine's largest-k aggregate keeps (`AGG_LARGEST_K`, a heap of two).
_LARGEST_K = 2

_SUM_TO_INT64 = frozenset(arrow_id(t) for t in ("bool", "int8", "int16", "int32"))
_SUM_TO_UINT64 = frozenset(arrow_id(t) for t in ("uint8", "uint16", "uint32"))
_FLOAT32 = arrow_id("float32")
_DECIMAL128 = arrow_id("decimal128")
_DECIMAL256 = arrow_id("decimal256")
_TIMESTAMPS = frozenset(
    arrow_id(t) for t in ("timestamp", "timestamp_s", "timestamp_ms", "timestamp_us", "timestamp_ns")
)
_DECIMAL_MAX = {_DECIMAL128: 38, _DECIMAL256: 76}


def _valid_decimal(f: pb.WireField) -> bool:
    top = _DECIMAL_MAX.get(f.arrow_type_id)
    return top is not None and 1 <= f.decimal_precision <= top and 0 <= f.decimal_scale <= f.decimal_precision


def _sum_field(name: str, arg: pb.WireField) -> pb.WireField:
    t = arg.arrow_type_id
    if t in _SUM_TO_INT64:
        return field(name, arrow_id("int64"), True)
    if t in _SUM_TO_UINT64:
        return field(name, arrow_id("uint64"), True)
    if t == _FLOAT32:
        return field(name, arrow_id("float64"), True)
    out = field(name, t, True)
    if t == _DECIMAL128 and _valid_decimal(arg):
        out.decimal_precision = 38
        out.decimal_scale = arg.decimal_scale
    return out


def _pick_field(name: str, arg: pb.WireField) -> pb.WireField:
    """min, max, first, last and any_value return one of the input's values."""
    out = field(name, arg.arrow_type_id, True)
    if arg.arrow_type_id in _TIMESTAMPS:
        out.tz = arg.tz
    if _valid_decimal(arg):
        out.decimal_precision = arg.decimal_precision
        out.decimal_scale = arg.decimal_scale
    return out


def agg_field(name: str, agg: Agg, schema) -> pb.WireField:
    """The output field the engine derives for the aggregate `agg` named
    `name` over the input columns `schema`."""
    func = agg.func
    if func in _NEVER_NULL_COUNTS:
        return field(name, arrow_id("int64"), False)
    if func in _FLOAT64_RESULTS:
        return field(name, arrow_id("float64"), True)
    if func in ("bool_and", "bool_or"):
        return field(name, arrow_id("bool"), True)
    if func == "count_if":
        return field(name, arrow_id("int64"), True)
    arg = expr_field(agg.args[0], schema)
    if func == "sum":
        return _sum_field(name, arg)
    return _pick_field(name, arg)


def _agg_expr(name: str, agg: Agg, schema, udfs) -> pb.WireAggExpr:
    if agg.func == "largest_k" and agg.k != _LARGEST_K:
        raise UnsupportedOperation(
            f"the aggregate {name!r} keeps the largest {agg.k} values, and the engine's "
            f"largest_k keeps {_LARGEST_K}: use largest_k with k={_LARGEST_K}"
        )
    args = agg.args
    if agg.func == "quantile_cont":
        # The fraction fills slot 1 as a FLOAT64 literal, the one shape the engine reads.
        q = args[1]
        if not (isinstance(q, Lit) and type(q.value) is float and 0.0 <= q.value <= 1.0):
            raise UnsupportedOperation(
                f"the aggregate {name!r} is quantile_cont, whose second argument is the "
                f"fraction: a float literal in [0, 1], not {q!r}"
            )
    if agg.func in _X_FIRST:
        args = (args[1], args[0])
    out = pb.WireAggExpr(func=member("AGG_", agg.func))
    for slot, arg in enumerate(args):
        setattr(out, f"has_child{slot}", True)
        getattr(out, f"child{slot}").CopyFrom(encode_expr(arg, schema, udfs))
    out.has_alias_name = True
    out.alias_name = name
    return out


def encode_aggregate(node: Aggregate, child: pb.WirePlan, udfs) -> pb.WirePlan:
    """`node` over its encoded child: group keys, then aggregates. The user
    functions its aggregates call are added to `udfs`."""
    schema = list(child.output_schema.fields)
    out = pb.WirePlan()
    for key in node.keys:
        ref = ColRef(key)
        out.aggregate.group_by.append(encode_expr(ref, schema))
        out.output_schema.fields.append(expr_field(ref, schema))
    for name, agg in node.aggs:
        out.aggregate.agg_exprs.append(_agg_expr(name, agg, schema, udfs))
        out.output_schema.fields.append(agg_field(name, agg, schema))
    out.aggregate.child.CopyFrom(child)
    return out
