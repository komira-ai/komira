"""The argument handling and literals of the pandas-shaped frame's `fillna`,
`add_prefix`, `add_suffix` and `komira.concat` (komira/_frame.py calls these).

- `fillna` puts a literal of the column's own type where a value is missing:
  an int for an int32 or int64 column, an int or a float for a float32 or
  float64 one, a bool, a str; a value or column of another type is refused
  by name rather than changing the column's type.
- `concat` checks, before it builds the union, that the frames are on one
  session and have the same column set, one type per column and the same
  nullability, so that the encoder's own refusal is never what a user reads.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import _groupby, _ops
from ._errors import UnsupportedOperation
from ._series import Series, _fits

if TYPE_CHECKING:
    from ._frame import DataFrame

__all__ = ["check_label_axis", "concat_frames", "fill_literal", "no_series_fill"]

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
    missing: `value` as a literal of that type, or the refusal."""
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
        return _ops.Lit(value) if dtype == "int64" else _ops.Cast(_ops.Lit(value), "int32")
    if dtype in ("float32", "float64"):
        try:
            number = float(value)
        except OverflowError:
            raise UnsupportedOperation(
                f"fillna() cannot fill the {dtype} column {name!r} with an int that is too large for a float: "
                f"fill it with a smaller value{pick}"
            ) from None
        return _ops.Lit(number) if dtype == "float64" else _ops.Cast(_ops.Lit(number), "float32")
    return _ops.Lit(value)


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


