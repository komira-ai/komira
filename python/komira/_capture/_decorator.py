"""The `@udf` decorator and the `Udf` it returns (private).

`Udf` is the user's function: calling it runs the function unchanged, so the
komira/python worker, which imports `module:qualname` and calls the module
attribute, gets the function. Capture is lazy, because at decoration time the
function's module is still executing: `spec()` reads the function, its hints
and its module on first use and keeps the result.
"""

from __future__ import annotations

import dataclasses
import functools

from komira._errors import UnsupportedOperation
from komira._ops import _vocab
from komira._ops._expr import ColRef, UdfCall, UdfSpec, as_node

from . import _code, _readset, _types

_BATCH_FORMAT = {"scalar": "values", "row": "values", "map_batches_column": "arrow", "map_batches_frame": "arrow"}
_NULL_MODE = {"scalar": "propagate", "map_batches_column": "propagate", "row": "manual", "map_batches_frame": "manual"}


def _one_of(value, vocab, what):
    if not isinstance(value, str):
        raise TypeError(f"{what} must be a str, not {type(value).__name__}")
    if value not in vocab:
        raise ValueError(f"{what} must be one of {', '.join(sorted(vocab))}, not {value!r}")


@dataclasses.dataclass(frozen=True)
class _Declaration:
    kind: str
    return_dtype: str | None
    schema: tuple | None
    columns: tuple | None
    stability: str
    null_mode: str


def _declare(kind, return_dtype, schema, columns, stability, null_mode) -> _Declaration:
    _one_of(kind, _vocab.UDF_KINDS, "kind")
    _one_of(stability, _vocab.UDF_STABILITIES, "stability")
    if null_mode is None:
        null_mode = _NULL_MODE[kind]
    _one_of(null_mode, _vocab.UDF_NULL_MODES, "null_mode")
    if kind == "row" and null_mode != "manual":
        raise ValueError("a row function takes null_mode='manual': under 'propagate' a null in a field read on some branches would drop rows")
    if kind == "map_batches_frame":
        if return_dtype is not None:
            raise ValueError("return_dtype= is for a column function; a map_batches_frame function takes schema=")
    elif schema is not None:
        raise ValueError(f"schema= is for a map_batches_frame function; a {kind} function takes return_dtype=")
    if return_dtype is not None:
        return_dtype = _types.check_dtype(return_dtype, "return_dtype=")
    if schema is not None:
        schema = _types.check_schema(schema)
    if columns is not None:
        if kind not in _vocab.UDF_READ_SET_KINDS:
            raise UnsupportedOperation(
                f"UDF_READ_SET_INVALID: columns= is for a row or map_batches_frame function; "
                f"a {kind} function reads its argument expressions"
            )
        columns = _readset.check_columns(columns)
    return _Declaration(kind, return_dtype, schema, columns, stability, null_mode)


class Udf:
    """A user function with its declaration. Calling it calls the function."""

    def __init__(self, fn, declaration: _Declaration):
        if isinstance(fn, Udf):
            raise TypeError("udf() was given a Udf; decorate the function once")
        if not callable(fn):
            raise TypeError(f"udf() decorates a function, not {type(fn).__name__}")
        self._fn = fn
        self._declaration = declaration
        self._captured = None
        functools.update_wrapper(self, fn)

    def __call__(self, *args, **kwargs):
        return self._fn(*args, **kwargs)

    def __repr__(self):
        return f"<Udf {self._declaration.kind} {getattr(self._fn, '__qualname__', self._fn)!r}>"

    def _capture(self):
        fn = self._fn
        d = self._declaration
        where = _code.locate(fn, (self, fn))
        name = fn.__qualname__
        hints = _types.hints_of(fn, name)
        if d.kind == "map_batches_frame":
            if d.schema is None:
                raise _types.schema_missing(name)
            return_type = d.schema
        else:
            return_type = d.return_dtype or _types.dtype_from_hints(name, fn.__name__, hints)
        if d.kind in _vocab.UDF_READ_SET_KINDS:
            read_set = _readset.resolve(name, d.kind, fn, d.columns, hints)
        else:
            _readset.refuse_row_types(name, d.kind, hints)
            read_set = None
        form, code, objects = _code.code_of(where)
        _code.register_objects(objects)
        spec = UdfSpec(
            name=name,
            kind=d.kind,
            form=form,
            entry=where.entry,
            code=code,
            return_type=return_type,
            stability=d.stability,
            null_mode=d.null_mode,
            batch_format=_BATCH_FORMAT[d.kind],
            read_set=read_set,
        )
        return spec, objects

    def spec(self) -> UdfSpec:
        """The captured spec: built on first use, then the same object."""
        if self._captured is None:
            self._captured = self._capture()
        return self._captured[0]

    def code_objects(self) -> dict:
        """`{sha256: bytes}` of the code objects the spec names: the bundle's zip
        for a bundle, none for a package."""
        self.spec()
        return dict(self._captured[1])

    def bundle_bytes(self):
        """The bundle's zip bytes, or None when the code is a package."""
        objects = self.code_objects()
        return next(iter(objects.values()), None)

    def expr(self, *args) -> UdfCall:
        """The call of this function as an expression. A `scalar` or
        `map_batches_column` function takes its argument expressions (a value
        that is not a node is a literal); a `row` function takes none and is
        passed its read set's columns."""
        d = self._declaration
        name = getattr(self._fn, "__qualname__", repr(self._fn))
        if d.kind == "map_batches_frame":
            raise UnsupportedOperation(
                f"`{name}()` is a map_batches_frame function and has no expression form; "
                f"apply it to a plan with komira._ops.map_batches(plan, udf_spec)"
            )
        spec = self.spec()
        if d.kind == "row":
            if args:
                raise ValueError(f"the row function `{name}()` takes no arguments: it is passed the columns of its read set")
            return UdfCall(spec, tuple(ColRef(c) for c in spec.read_set))
        return UdfCall(spec, tuple(as_node(a) for a in args))


def udf(
    fn=None,
    *,
    kind="scalar",
    return_dtype=None,
    schema=None,
    columns=None,
    stability="stable",
    null_mode=None,
):
    """Declare a user function, as `@udf` or `@udf(...)`.

    - `kind`: `scalar`, `map_batches_column`, `row` or `map_batches_frame`.
    - `return_dtype`: a column function's type, else taken from its return hint;
      `schema`: a frame function's output, a dict or `(name, dtype)` pairs.
      A dtype is the text of the pyarrow type, except that the floats are
      `float32` and `float64` (pyarrow's `str()` gives `float` and `double`,
      which are accepted too): `bool`, `int8` to `int64`, `float32`, `float64`,
      `string`, `large_string`, `binary`, `large_binary`, `date32[day]`,
      `timestamp[s]`, `[ms]`, `[us]` or `[ns]` (with `, tz=ZONE` for a zone),
      `decimal128(p, s)`, `list<item: T>`, `large_list<item: T>` and
      `struct<a: T, ...>`, where an item or field is not a list, a struct, a
      decimal or a zoned timestamp. `utf8`, `large_utf8`, `date32`, `float`,
      `double` and `list<T>` are accepted and kept as `string`, `large_string`,
      `date32[day]`, `float32`, `float64` and `list<item: T>`. A `scalar` or
      `row` function cannot take a `timestamp[ns]` argument.
    - `columns`: the read set of a `row` or `map_batches_frame` function, else a
      TypedDict or dataclass annotation of its first parameter, else (`row`
      only) a scan of its reads.
    - `stability`: `immutable`, `stable` or `volatile`. `null_mode`: `manual` or
      `propagate`; the default is `propagate` for the two column kinds and
      `manual` for `row` and `map_batches_frame`.
    """
    declaration = _declare(kind, return_dtype, schema, columns, stability, null_mode)
    if fn is None:
        return lambda f: Udf(f, declaration)
    return Udf(fn, declaration)


def write_code(code_root, udf: Udf) -> None:
    """Write the code objects of `udf` under `code_root` by sha256 hex."""
    _code.write_objects(code_root, udf.code_objects())
