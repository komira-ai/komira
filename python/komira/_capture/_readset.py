"""The read set of a `row` or `map_batches_frame` function (docs/design/
optimized_plan_udfs.md section 10.2, udf_python_worker.md section 6.1).

It comes from the first of: `columns=[...]`; a TypedDict or dataclass
annotation of the function's first parameter (given together, the two must
name the same set); for a `row` only, a static scan of the function's bytecode
for `r.name` and `r["name"]` reads of the row parameter. A function whose reads
are not bounded by one of these is refused: the set never defaults to every
column. The result ascends by UTF-8 bytes.
"""

from __future__ import annotations

import dataclasses
import dis
import sys
import types
import typing

from komira._errors import UnsupportedOperation

# The names the design lists as pandas Series attributes as well as possible
# fields (udf_runtime_interface.md §6.1): `r.name` may be the Series' own
# attribute, not a column, so a read of one is never counted as a column read.
SERIES_ATTRIBUTES = frozenset({"name", "index", "values", "get"})

# Names whose call reads the caller's local variables, the row among them.
_FRAME_READERS = frozenset({"locals", "vars", "eval", "exec"})

_COMPREHENSIONS = frozenset({"<listcomp>", "<setcomp>", "<dictcomp>", "<genexpr>"})

# Python 3.11 compiles a comprehension to a nested function and 3.12 and later
# inline all but a generator expression; any of them is refused the same way.
_COMPREHENSION = "it contains a comprehension or generator expression, which may read the row"

_PLAIN_LOADS = frozenset({"LOAD_FAST", "LOAD_FAST_CHECK", "LOAD_FAST_BORROW"})
_PAIR_LOADS = frozenset({"LOAD_FAST_LOAD_FAST", "LOAD_FAST_BORROW_LOAD_FAST_BORROW"})

# Every opcode whose argument is a variable name, from the running Python's
# `dis` and the names the supported minors use.
_VARIABLE_OPS = (
    frozenset(dis.opname[o] for o in dis.haslocal)
    | frozenset(dis.opname[o] for o in dis.hasfree)
    | _PLAIN_LOADS
    | _PAIR_LOADS
    | frozenset(
        {
            "STORE_FAST", "DELETE_FAST", "STORE_FAST_LOAD_FAST", "STORE_FAST_STORE_FAST", "LOAD_FAST_AND_CLEAR",
            "STORE_FAST_MAYBE_NULL", "LOAD_DEREF", "STORE_DEREF", "DELETE_DEREF", "LOAD_CLOSURE", "MAKE_CELL",
            "LOAD_CLASSDEREF", "LOAD_FROM_DICT_OR_DEREF",
        }
    )
)

_METHOD_FLAG_IN_LOAD_ATTR = sys.version_info >= (3, 12)


def utf8_sorted(names) -> tuple:
    return tuple(sorted(set(names), key=lambda n: n.encode("utf-8")))


def check_columns(columns) -> tuple:
    """`columns=` as a tuple in the order given, or the refusal."""
    if isinstance(columns, (str, bytes)) or not isinstance(columns, (list, tuple)):
        raise TypeError(f"columns= must be a list or tuple of column names, not {type(columns).__name__}")
    for column in columns:
        if not isinstance(column, str):
            raise TypeError(f"columns= holds only str names, not {type(column).__name__}")
        if column == "":
            raise UnsupportedOperation("UDF_READ_SET_INVALID: columns= holds an empty column name")
    for column in columns:
        if columns.count(column) > 1:
            raise UnsupportedOperation(f"UDF_READ_SET_INVALID: columns= names {column!r} more than once")
    return tuple(columns)


def row_type_columns(tp):
    """The field names of a TypedDict or dataclass type, else None."""
    if typing.is_typeddict(tp):
        return list(tp.__annotations__)
    if isinstance(tp, type) and dataclasses.is_dataclass(tp):
        return [f.name for f in dataclasses.fields(tp)]
    return None


def refuse_row_types(name: str, kind: str, hints: dict) -> None:
    """A TypedDict or dataclass hint on a function that does not read a set of
    columns."""
    for parameter, hint in hints.items():
        if parameter != "return" and row_type_columns(hint) is not None:
            raise UnsupportedOperation(
                f"UDF_READ_SET_INVALID: `{name}()` is a {kind} function and reads its argument expressions, "
                f"but its parameter `{parameter}` is annotated with the row type `{hint.__qualname__}`; "
                f"only a row or map_batches_frame function reads a set of columns"
            )


def resolve(name: str, kind: str, fn, columns, hints: dict) -> tuple:
    """The read set of `fn`, a `row` or `map_batches_frame` function."""
    code = fn.__code__
    parameter = code.co_varnames[0] if code.co_argcount >= 1 else None
    annotation = hints.get(parameter) if parameter is not None else None
    annotated = row_type_columns(annotation)
    if columns is not None and annotated is not None:
        if set(columns) != set(annotated):
            raise UnsupportedOperation(
                f"UDF_READ_SET_INVALID: columns= and the annotation of `{parameter}` in `{name}()` name "
                f"different sets: columns= has {list(utf8_sorted(columns))}, "
                f"{annotation.__qualname__} has {list(utf8_sorted(annotated))}; give one of them, "
                f"or make them equal"
            )
        return utf8_sorted(columns)
    if columns is not None:
        return utf8_sorted(columns)
    if annotated is not None:
        return utf8_sorted(annotated)
    if kind == "row":
        names, problem = scan_row(code)
        if problem is None:
            return names
        raise UnsupportedOperation(
            f"UDF_READ_SET_REQUIRED: cannot tell which columns the row function `{name}()` reads: {problem}. "
            f"Pass columns=[...] to udf, naming every column it reads"
        )
    raise UnsupportedOperation(
        f"UDF_READ_SET_REQUIRED: the map_batches_frame function `{name}()` has no read set. "
        f"Pass columns=[...] to udf, naming every column it reads, or annotate its first parameter "
        f"with a TypedDict or dataclass of those columns"
    )


class _Op:
    """One instruction, with the `EXTENDED_ARG` prefix folded into it."""

    __slots__ = ("opname", "arg", "argval", "argrepr", "target")

    def __init__(self, instruction, target):
        self.opname = instruction.opname
        self.arg = instruction.arg
        self.argval = instruction.argval
        self.argrepr = instruction.argrepr
        self.target = target


def _ops(code) -> list:
    ops = []
    pending = False
    for instruction in dis.get_instructions(code):
        # A missing attribute counts as a jump target, so nothing is recognized.
        target = pending or getattr(instruction, "is_jump_target", True)
        if instruction.opname == "EXTENDED_ARG":
            pending = target
            continue
        pending = False
        ops.append(_Op(instruction, target))
    return ops


def _is_method_load(op) -> bool:
    if op.opname == "LOAD_METHOD":
        return True
    return op.opname == "LOAD_ATTR" and _METHOD_FLAG_IN_LOAD_ATTR and op.arg is not None and bool(op.arg & 1)


def _is_subscript(op) -> bool:
    if op.opname == "BINARY_SUBSCR":
        return True
    # CPython 3.14 spells a subscript as BINARY_OP with the `[]` operator.
    return op.opname == "BINARY_OP" and op.argrepr == "[]"


def _read_after(ops: list, k: int, p: str):
    """`(column, None)` when the load of the row at `ops[k]` is the start of a
    bounded read, else `(None, problem)`."""
    whole = f"the row `{p}` is used as a whole, not as {p}.field or {p}[\"field\"]"
    following = ops[k + 1] if k + 1 < len(ops) else None
    if following is None or following.target:
        return None, whole
    if _is_method_load(following):
        return None, f"`{p}.{following.argval}(...)` calls a method on the row"
    if following.opname == "LOAD_ATTR":
        attribute = following.argval
        if attribute in SERIES_ATTRIBUTES:
            return None, f"`{p}.{attribute}` is also an attribute of a pandas Series, so it may not name a column"
        if attribute.startswith("__") and attribute.endswith("__"):
            return None, f"`{p}.{attribute}` is a special attribute, not a column"
        return attribute, None
    if following.opname == "LOAD_CONST" and isinstance(following.argval, str) and k + 2 < len(ops):
        after = ops[k + 2]
        if not after.target and _is_subscript(after):
            return following.argval, None
    return None, whole


def scan_row(code):
    """`(names, None)`: the columns the row function `code` reads, ascending by
    UTF-8 bytes; or `((), problem)` when its reads are not all bounded.

    Only a load of the first parameter followed at once by an attribute read or
    a constant-string subscript counts. Every other use of the parameter, and
    every construct that could reach it unseen, is a problem."""
    if code.co_argcount < 1:
        return (), "it takes no parameter to receive the row"
    p = code.co_varnames[0]
    if any(isinstance(c, types.CodeType) and c.co_name in _COMPREHENSIONS for c in code.co_consts):
        return (), _COMPREHENSION
    if p in code.co_cellvars:
        return (), f"the row `{p}` is used by a nested function"
    ops = _ops(code)
    names = []
    for k, op in enumerate(ops):
        if op.opname == "LOAD_FAST_AND_CLEAR":
            return (), _COMPREHENSION
        if op.opname in ("LOAD_GLOBAL", "LOAD_NAME") and op.argval in _FRAME_READERS:
            return (), f"it calls {op.argval}(), which can read the row by any name"
        if op.opname not in _VARIABLE_OPS:
            continue
        variables = op.argval if isinstance(op.argval, tuple) else (op.argval,)
        if p not in variables:
            continue
        whole = f"the row `{p}` is used as a whole, not as {p}.field or {p}[\"field\"]"
        if op.opname in _PLAIN_LOADS:
            pass
        elif op.opname in _PAIR_LOADS:
            if variables[0] == p:
                return (), whole
        elif op.opname == "STORE_FAST_LOAD_FAST":
            if variables[0] == p:
                return (), f"the row `{p}` is assigned, deleted or kept under another name"
        else:
            return (), f"the row `{p}` is assigned, deleted or kept under another name"
        column, problem = _read_after(ops, k, p)
        if problem is not None:
            return (), problem
        names.append(column)
    return utf8_sorted(names), None
