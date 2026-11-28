"""The argument handling and literals of the pandas-shaped frame's `fillna`,
`add_prefix`, `add_suffix`, `komira.concat` and `melt` (komira/_frame.py calls
these).

- `fillna` puts a value of the column's own type where a value is missing:
  an int for an int32 or int64 column, an int or a float for a float32 or
  float64 one, a bool, a str; a value or column of another type is refused
  by name rather than changing the column's type. The engine's CASE gives
  int64, float64 or string only, so an int64, float64 or string column is
  `CASE WHEN present THEN x ELSE fill END`, an int32 or float32 one is that
  CASE over the column widened to int64 or float64 and cast back, and a bool
  one is no CASE: `x IS NULL OR x = true` fills with True and
  `x IS NOT NULL AND x = true` with False.
- `concat` checks, before it builds the union, that the frames are on one
  session and have the same column set, one type per column and the same
  nullability, so that the encoder's own refusal is never what a user reads.
- `melt` resolves pandas' arguments to the id and value columns and the two
  new names, with pandas' own errors where pandas has them, and hands them to
  komira/_unpivot.py, which builds the plan.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import _groupby, _ops
from ._errors import UnsupportedOperation
from ._missing import present
from ._series import Series, _fits
from ._unpivot import unpivot_plan

if TYPE_CHECKING:
    from ._frame import DataFrame

__all__ = ["check_label_axis", "concat_frames", "fill_column", "fill_literal", "melt_frame", "no_series_fill"]

# What `fillna` fills, and with what: a literal of the column's own type.
_FILL_TYPES = "int32, int64, float32, float64, bool and string"
_FILL_WITH = {
    "int32": "an int",
    "int64": "an int",
    "float32": "an int or a float",
    "float64": "an int or a float",
    "bool": "a bool",
    "string": "a str",
}


def no_series_fill(value: object) -> None:
    from ._frame import DataFrame

    if isinstance(value, (Series, DataFrame)):
        raise UnsupportedOperation(
            f"fillna(value=a {type(value).__name__}) fills each row from the value at its index, and a komira "
            "frame has no index to align by: fill with a literal, or with a dict of literals by column"
        )


def fill_literal(name: str, dtype: str, value: object, scalar: bool) -> _ops.Node:
    """The literal `fillna` puts where the column `name`, of type `dtype`, is
    missing: `value` as a literal of the type the CASE computes in (int64 for
    an int column, float64 for a float one, else the column's), or the
    refusal."""
    if dtype not in _FILL_WITH:
        pick = ", or pass a dict to fill only the other columns" if scalar else ""
        raise UnsupportedOperation(
            f"fillna() fills {_FILL_TYPES} columns, and the column {name!r} is {dtype}: "
            f"cast it first with astype(){pick}"
        )
    is_int = isinstance(value, int) and not isinstance(value, bool)
    if dtype in ("int32", "int64"):
        fits = is_int
    elif dtype in ("float32", "float64"):
        fits = is_int or isinstance(value, float)
    elif dtype == "bool":
        fits = isinstance(value, bool)
    else:
        fits = isinstance(value, str)
    pick = ", or pass a dict to fill only some columns" if scalar else ""
    if not fits:
        given = "None" if value is None else f"a {type(value).__name__}"
        raise UnsupportedOperation(
            f"fillna() cannot fill the {dtype} column {name!r} with {given}: the column keeps its type, "
            f"so fill it with {_FILL_WITH[dtype]}, or cast the column first with astype(){pick}"
        )
    if dtype in ("int32", "int64"):
        if not _fits(value, dtype):
            raise UnsupportedOperation(
                f"fillna() cannot fill the {dtype} column {name!r} with {value}: it is out of the range of "
                f"{dtype}, so fill it with a value in range, or cast the column first with astype(){pick}"
            )
        return _ops.Lit(value)
    if dtype in ("float32", "float64"):
        try:
            number = float(value)
        except OverflowError:
            raise UnsupportedOperation(
                f"fillna() cannot fill the {dtype} column {name!r} with an int that is too large for a float: "
                f"fill it with a smaller value{pick}"
            ) from None
        return _ops.Lit(number)
    return _ops.Lit(value)


# The type the CASE of a narrower column is computed in.
_WIDE = {"int32": "int64", "float32": "float64"}


def fill_column(name: str, dtype: str, value: object, scalar: bool) -> _ops.Node:
    """The column `name`, of type `dtype`, with `value` where it is missing,
    as an expression of the column's type."""
    fill = fill_literal(name, dtype, value, scalar)
    column = _ops.ColRef(name)
    if dtype == "bool":
        is_true = _ops.Compare("eq", column, _ops.Lit(True))
        if value:
            return _ops.BoolOp("or", _ops.Unary("is_null", column), is_true)
        return _ops.BoolOp("and", _ops.Unary("is_not_null", column), is_true)
    wide = _WIDE.get(dtype)
    if wide is None:
        return _ops.When(((present(column, dtype), column),), fill)
    return _ops.Cast(_ops.When(((present(column, dtype), _ops.Cast(column, wide)),), fill), dtype)


def check_label_axis(axis: object, verb: str) -> None:
    """The `axis` of `add_prefix` and `add_suffix`: the columns (None, 1 or
    "columns"), never the row labels a frame lacks."""
    if isinstance(axis, bool) or (axis is not None and axis not in (0, 1, "index", "columns")):
        raise ValueError(f"No axis named {axis} for object type DataFrame")
    if axis in (0, "index"):
        raise UnsupportedOperation(
            f"{verb}(axis={axis!r}) changes row labels, and komira frames have no index: use axis=1, or leave it out"
        )


def _label(i: int) -> str:
    return "the first frame" if i == 0 else f"frame {i}"


def _quoted(names: list[str]) -> str:
    listed = ", ".join(repr(name) for name in names)
    return f"the column {listed}" if len(names) == 1 else f"the columns {listed}"


def concat_frames(
    objs: list[DataFrame] | tuple[DataFrame, ...],
    *,
    axis: int | str = 0,
    join: str = "outer",
    ignore_index: bool = False,
    keys: object = None,
    levels: object = None,
    names: object = None,
    verify_integrity: bool = False,
    sort: bool = False,
    copy: bool | None = None,
) -> DataFrame:
    """The rows of the frames one after another: a union of inputs of one
    schema. The frames are on one session; their columns are the same set
    (one in another order is reordered to the first frame's by a projection),
    of one type each, and allow missing values alike. pandas would fill
    missing columns with NaN and upcast types, and this refuses both. The
    answer has no row order. `ignore_index` and `copy` are accepted and do
    nothing, since a frame has no index and a plan holds no rows; with equal
    column sets `join` "outer" and "inner" mean the same."""
    from ._frame import DataFrame

    if not isinstance(objs, (list, tuple)):
        raise TypeError(f"concat() takes a list or tuple of DataFrames, not a {type(objs).__name__}")
    if not objs:
        raise ValueError("No objects to concatenate")
    for i, frame in enumerate(objs):
        if not isinstance(frame, DataFrame):
            raise TypeError(f"concat() takes DataFrames, and {_label(i)} is of type {type(frame).__name__}")
    if isinstance(axis, bool) or axis not in (0, 1, "index", "columns"):
        raise ValueError(f"No axis named {axis} for object type DataFrame")
    if axis in (1, "columns"):
        raise UnsupportedOperation(
            f"concat(axis={axis!r}) sets frames side by side by their rows' index, and komira frames have no "
            "index: add columns with assign(), or join the frames with merge()"
        )
    if join not in ("outer", "inner"):
        raise ValueError(f"concat join must be 'outer' or 'inner', not {join!r}")
    for label, value in (("keys", keys), ("levels", levels), ("names", names)):
        if value is not None:
            raise UnsupportedOperation(
                f"concat({label}=...) builds a row index from the frames, and komira frames have no index: "
                f"leave {label} out"
            )
    for label, value in (("ignore_index", ignore_index), ("verify_integrity", verify_integrity), ("sort", sort)):
        _groupby._check_bool(value, label, "concat")
    if copy is not None:
        _groupby._check_bool(copy, "copy", "concat")
    if verify_integrity:
        raise UnsupportedOperation(
            "concat(verify_integrity=True) checks the row index for duplicates, and komira frames have no "
            "index: use verify_integrity=False"
        )
    if sort:
        raise UnsupportedOperation(
            "concat(sort=True) sorts the columns by name, which this release does not build: "
            "order the columns in every frame yourself, as df[sorted(df.columns)]"
        )
    first = objs[0]
    for frame in objs[1:]:
        if frame._session is not first._session:
            raise UnsupportedOperation(
                "concat() takes frames of one session, and frames of two sessions never meet: "
                "read every frame on the same session"
            )
    first_columns = first._plan.columns
    first_types = first.dtypes
    first_null = {f.name: f.nullable for f in first._fields}
    plans = []
    sources: dict[str, object] = {}
    for i, frame in enumerate(objs):
        columns = frame._plan.columns
        if set(columns) != set(first_columns):
            missing = [name for name in first_columns if name not in columns]
            extra = [name for name in columns if name not in first_columns]
            parts = []
            if missing:
                parts.append(f"lacks {_quoted(missing)}")
            if extra:
                parts.append(f"has {_quoted(extra)}, which the first frame does not")
            raise UnsupportedOperation(
                f"concat() needs every frame to have the same columns, and {_label(i)} {' and '.join(parts)}: "
                "pandas would fill the missing columns with NaN, which komira does not: "
                "select the same columns in every frame"
            )
        types = frame.dtypes
        nullable = {f.name: f.nullable for f in frame._fields}
        for name in first_columns:
            if types[name] != first_types[name]:
                raise UnsupportedOperation(
                    f"concat() needs each column to have one type, and the column {name!r} is "
                    f"{first_types[name]} in the first frame and {types[name]} in {_label(i)}: "
                    "cast one of them first with astype()"
                )
            if nullable[name] != first_null[name]:
                allows, refuses = (0, i) if first_null[name] else (i, 0)
                raise UnsupportedOperation(
                    f"concat() needs a column to allow missing values in every frame or in none, and the column "
                    f"{name!r} allows them in {_label(allows)} but not in {_label(refuses)}: "
                    f"apply fillna() to that column in {_label(refuses)}, which makes it allow them"
                )
        plans.append(frame._plan if columns == first_columns else _ops.select(frame._plan, first_columns))
        for path, source in frame._sources.items():
            sources.setdefault(path, source)
    return DataFrame._new(first._session, _ops.concat(plans), sources)


# ---- melt -------------------------------------------------------------------


def _labels(value: object, label: str) -> list[str]:
    """`id_vars` or `value_vars` as a list of names: None is none, a str is
    one, and any other iterable (a list, a tuple, a set, `df.columns`) is its
    items, as pandas takes them."""
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    try:
        names = list(value)
    except TypeError:
        raise TypeError(
            f"melt() takes {label} as a column name or a list of them, not {type(value).__name__}"
        ) from None
    for name in names:
        if isinstance(name, tuple):
            raise UnsupportedOperation(
                f"melt({label}=...) names {name!r}, a column of a column MultiIndex, and a komira frame's "
                "columns have one level of names: name the columns as strings"
            )
    return names


def _melt_name(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise TypeError(f"melt() takes {label} as a str, not {type(value).__name__}")
    return value


def _type_text(field: object, name: str) -> str:
    """The type `name` of `field` as a melt refusal names it: with a
    decimal's precision and scale, or a timestamp's zone."""
    if name == "decimal128":
        return f"decimal128({field.decimal_precision}, {field.decimal_scale})"
    if field.tz:
        return f"{name} ({field.tz})"
    return name


def melt_frame(
    frame: DataFrame,
    id_vars: object = None,
    value_vars: object = None,
    var_name: object = None,
    value_name: object = "value",
    col_level: object = None,
    ignore_index: bool = True,
) -> DataFrame:
    """pandas' `melt` of `frame` (komira/_unpivot.py builds the plan). The
    checks and their messages are pandas' own where pandas has them: a
    `value_name` that is a column of the frame, a column named twice in
    `id_vars`, a name the frame lacks, and a `var_name` that is not a
    scalar. A `value_vars` column that is also in `id_vars` is an id column,
    and one named twice is melted once, as in pandas. Refused by name: a
    row index (`ignore_index=False`), a column MultiIndex (`col_level`, or
    a tuple name), no value column (pandas gives a frame of no rows whose
    value column is of object type), value columns of two types (pandas
    gives object), and a `var_name` that is an id column's or
    `value_name`'s name (pandas gives two columns of one name)."""
    from ._frame import DataFrame

    if not isinstance(frame, DataFrame):
        raise TypeError(f"melt() takes a komira DataFrame, not {type(frame).__name__}")
    _groupby._check_bool(ignore_index, "ignore_index", "melt")
    if not ignore_index:
        raise UnsupportedOperation(
            "melt(ignore_index=False) repeats the row index, and komira frames have no index: "
            "leave ignore_index out"
        )
    if col_level is not None:
        raise UnsupportedOperation(
            "melt(col_level=...) picks a level of a column MultiIndex, and a komira frame's columns "
            "have one level of names: leave col_level out"
        )
    columns = frame._plan.columns
    if value_name in columns:
        raise ValueError(f"value_name ({value_name}) cannot match an element in the DataFrame columns.")
    ids = _labels(id_vars, "id_vars")
    named = _labels(value_vars, "value_vars")
    if len(set(ids)) < len(ids):
        raise ValueError("id_vars cannot contain duplicate columns.")
    missing = [name for name in ids + named if name not in columns]
    if missing:
        raise KeyError(f"The following id_vars or value_vars are not present in the DataFrame: {missing}")
    if isinstance(var_name, (list, tuple, set, dict)):
        raise ValueError(f"{var_name=} must be a scalar.")
    variable = "variable" if var_name is None else _melt_name(var_name, "var_name")
    value = _melt_name(value_name, "value_name")
    if value_vars is None:
        values = [name for name in columns if name not in ids]
    else:
        values = [name for name in dict.fromkeys(named) if name not in ids]
    if not values:
        raise UnsupportedOperation(
            "melt() with no value column gives no rows and a value column of no type, which a komira "
            "frame cannot hold: name at least one column in value_vars that is not in id_vars"
        )
    if variable in ids or variable == value:
        taken = "an id column's" if variable in ids else "value_name's"
        raise UnsupportedOperation(
            f"melt(var_name={variable!r}) is {taken} name too, and pandas would give two columns of one "
            "name, which a komira frame cannot hold: pick another var_name"
        )
    plan = unpivot_plan(
        frame._plan,
        frame._fields,
        ids,
        values,
        variable,
        value,
        verb="melt()",
        type_text=lambda f: _type_text(f, frame._type_name(f)),
    )
    return DataFrame._new(frame._session, plan, frame._sources)
