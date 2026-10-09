"""The Python side of the komira-test/python-row UDF runtime (row_runtime.c).

One copy of this module is imported in each interpreter the runtime runs.
The C side hands it the read set's Arrow buffers as memoryviews and takes
back statuses; it never sees a language object other than these.

A ROW UDF is a plain function of one row: `def f(row) -> float`. Its read
set (the spec's argument struct: the field names user code reads, and their
Arrow types) is decided by the producer when the plan is built
(producer/komira_udf_readset.py), never here.

- validate(): the static check: the module's source is found on sys.path
  and parsed (ast), never run. The function takes one positional parameter
  and its return hint maps to the declared result type.
- open_instance(): imports the module in this interpreter, binds the
  function and builds the row type for the read set.
- RowInstance.call(): one batch. One row object per row, a view of the
  read set's columns at that row: `row.price` and `row["price"]` read the
  field's value (None for a null). Reading any other name raises
  FieldNotDeclared (an AttributeError, or a KeyError for a subscript) and
  fails the batch with ERR_FIELD_NOT_DECLARED naming the field, the read set
  and the row, also when user code catches the exception. A row kept past
  its batch raises RowExpired when read: after the call returned, and in a
  later batch of the same instance, where the instance's columns hold that
  batch's buffers (each row carries the number of the batch that made it).

Statuses are komira_udf_status values of komira_udf_runtime.h.
"""

import ast
import os
import sys
import traceback
import typing

OK = 0
ERR_DESCRIPTOR = 2
ERR_UNSUPPORTED = 3
ERR_LOAD = 5
ERR_RAISED = 6
ERR_RETURN_TYPE = 7
ERR_CANCELLED = 11
ERR_FIELD_NOT_DECLARED = 16

# Arrow format -> memoryview code, type name.
CODE = {"l": "q", "g": "d"}
TYPE = {"l": "int64", "g": "float64"}

_NO_FLAG = memoryview(b"\0\0\0\0").cast("i")


class FieldNotDeclared(AttributeError):
    """A row read a field outside its read set."""


class FieldNotDeclaredKey(KeyError):
    """A row was subscripted by a name outside its read set."""


class RowExpired(RuntimeError):
    """A row was read after the batch it belongs to returned."""


# ---- validate ------------------------------------------------------------------


def _return_fmt_of_source(node):
    """'g' or 'l' for a return annotation's AST (float, int, X | None,
    Optional[X]), or None."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        try:
            node = ast.parse(node.value, mode="eval").body
        except SyntaxError:
            return None
    if isinstance(node, ast.Name) and node.id in ("float", "int"):
        return "g" if node.id == "float" else "l"
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
        rest = [s for s in (node.left, node.right) if not (isinstance(s, ast.Constant) and s.value is None)]
        return _return_fmt_of_source(rest[0]) if len(rest) == 1 else None
    if isinstance(node, ast.Subscript) and ast.unparse(node.value) in ("Optional", "typing.Optional"):
        return _return_fmt_of_source(node.slice)
    return None


def _return_fmt_of_object(ann):
    if ann is float:
        return "g"
    if ann is int:
        return "l"
    args = typing.get_args(ann)
    rest = [a for a in args if a is not type(None)]
    if len(args) == 2 and len(rest) == 1:
        return _return_fmt_of_object(rest[0])
    return None


def _find_source(module):
    parts = module.split(".")
    for d in sys.path:
        base = os.path.join(d, *parts)
        for cand in (base + ".py", os.path.join(base, "__init__.py")):
            if os.path.isfile(cand):
                return cand
    return None


def _check(entry, n_params, has_varargs, ret_fmt, result_fmt):
    if has_varargs or n_params != 1:
        return (ERR_UNSUPPORTED, "{}: a ROW function takes exactly one positional parameter, the row".format(entry))
    if ret_fmt is None:
        return (ERR_UNSUPPORTED, "{} has no return type hint this runtime maps to an Arrow type".format(entry))
    if ret_fmt != result_fmt:
        return (ERR_UNSUPPORTED, "{}: the return type is hinted {}, declared {}".format(entry, TYPE[ret_fmt], TYPE[result_fmt]))
    return (OK, "")


def validate(entry, names, fmts, result_fmt):
    """(status, message) for a ROW UDF reference, from the source alone."""
    module, _, qual = entry.partition(":")
    path = _find_source(module)
    if path is None:
        return (ERR_DESCRIPTOR, "module {} is not on the runtime's path".format(module))
    with open(path, "rb") as f:
        try:
            tree = ast.parse(f.read(), filename=path)
        except SyntaxError as e:
            return (ERR_DESCRIPTOR, "module {} does not parse: {}".format(module, e))
    fn = None
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == qual:
            fn = node
    if fn is None:
        return (ERR_DESCRIPTOR, "module {} has no top-level function {}".format(module, qual))
    if isinstance(fn, ast.AsyncFunctionDef):
        return (ERR_UNSUPPORTED, "{} is async; this runtime calls plain functions".format(entry))
    a = fn.args
    ret = _return_fmt_of_source(fn.returns) if fn.returns is not None else None
    return _check(entry, len(a.posonlyargs + a.args), bool(a.vararg or a.kwarg or a.kwonlyargs), ret, result_fmt)


# ---- the row type ----------------------------------------------------------------


def _row_type(names):
    """A row class over the read set `names`, and the per-call state it
    reads: `slots[j]` is (values, validity or None, offset) of field j while
    a batch runs, else None; `batch[0]` numbers the latest batch (a row's
    `_b` is the number of the batch that made it) and `batch[1]` says
    whether it is running; `seen[0]` is the first (name, row) read outside
    the read set in the running batch, else None."""
    slots = [None] * len(names)
    batch = [0, False]
    seen = [None]
    index = {n: j for j, n in enumerate(names)}

    def live(r):
        # The slots hold the running batch's buffers: a row of an earlier
        # batch of this instance would read them at its old index.
        if not batch[1] or r._b != batch[0]:
            raise RowExpired("a row was read after its batch returned; keep the field's value, not the row")

    def read(r, j):
        # live(r), inlined on the per-field path: slots are None exactly
        # when no batch runs.
        c = slots[j]
        if c is None or r._b != batch[0]:
            raise RowExpired("a row was read after its batch returned; keep the field's value, not the row")
        v, valid, off = c
        p = off + r._i
        if valid is not None and not (valid[p >> 3] >> (p & 7)) & 1:
            return None
        return v[p]

    def violation(r, name):
        live(r)
        if seen[0] is None:
            seen[0] = (name, r._i)
        return "field {!r} is not in this ROW UDF's read set {}; add it to columns=[...]".format(name, list(names))

    def field(j):
        return property(lambda self: read(self, j))

    def __getattr__(self, name):
        # Only names no property or slot answers reach here.
        if (name.startswith("__") and name.endswith("__")) or name in ("_i", "_b"):
            raise AttributeError(name)
        raise FieldNotDeclared(violation(self, name))

    def __getitem__(self, key):
        j = index.get(key) if isinstance(key, str) else None
        if j is None:
            raise FieldNotDeclaredKey(violation(self, key))
        return read(self, j)

    def __iter__(self):
        raise TypeError("a ROW row is not iterable: it holds only its read set {}".format(list(names)))

    def __repr__(self):
        return "Row({})".format(", ".join("{}={!r}".format(n, read(self, j)) for j, n in enumerate(names)))

    ns = {
        "__slots__": ("_i", "_b"),
        "__getattr__": __getattr__,
        "__getitem__": __getitem__,
        "__iter__": __iter__,
        "__repr__": __repr__,
    }
    for j, n in enumerate(names):
        # A field whose name is not an attribute name (or would shadow the
        # row's own) is read by subscript only.
        if n.isidentifier() and not n.startswith("_"):
            ns[n] = field(j)
    return type("Row", (), ns), slots, batch, seen


# ---- open_instance and calls ------------------------------------------------------


def open_instance(entry, names, fmts, result_fmt):
    """(OK, RowInstance) or (status, message)."""
    import importlib
    import inspect

    module, _, qual = entry.partition(":")
    try:
        mod = importlib.import_module(module)
    except BaseException as exc:
        return (ERR_LOAD, "import {}: {}: {}".format(module, type(exc).__name__, exc))
    f = getattr(mod, qual, None)
    if not callable(f):
        return (ERR_LOAD, "module {} has no function {}".format(module, qual))
    try:
        hints = typing.get_type_hints(f)
        params = list(inspect.signature(f).parameters.values())
    except BaseException as exc:
        return (ERR_LOAD, "{}: {}: {}".format(entry, type(exc).__name__, exc))
    varargs = any(p.kind not in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD) for p in params)
    ret = _return_fmt_of_object(hints["return"]) if "return" in hints else None
    st = _check(entry, len(params), varargs, ret, result_fmt)
    if st[0] != OK:
        return (ERR_LOAD, st[1])
    return (OK, RowInstance(f, list(names), result_fmt))


class RowInstance:
    """One ROW UDF bound in one interpreter."""

    __slots__ = ("f", "names", "result_fmt", "row", "slots", "batch", "seen")

    def __init__(self, f, names, result_fmt):
        self.f = f
        self.names = names
        self.result_fmt = result_fmt
        self.row, self.slots, self.batch, self.seen = _row_type(names)

    def call(self, n, cols, out, outv, cancel):
        """One batch. `cols`: one (fmt, values view, validity view or None,
        offset) per read-set field, the views over the Arrow buffers from
        offset 0. `out`, `outv`: writable views of the output column.
        `cancel`: a view of the host's int32 cancel flag, or None. Returns
        (OK, null_count) or (status, message, trace or None, row)."""
        slots = self.slots
        self.batch[0] += 1
        self.seen[0] = None
        try:
            for j, (fmt, data, valid, off) in enumerate(cols):
                slots[j] = (data.cast(CODE[fmt]), valid, off)
            self.batch[1] = True
            return self._rows(n, out, outv, cancel.cast("i") if cancel is not None else _NO_FLAG)
        finally:
            self.batch[1] = False
            for j in range(len(slots)):
                slots[j] = None

    def _not_declared(self):
        name, row = self.seen[0]
        return (
            ERR_FIELD_NOT_DECLARED,
            "UDF_FIELD_NOT_DECLARED: row {} read field {!r}, which is not in the read set {}; "
            "add it to columns=[...]".format(row, name, self.names),
            None,
            row,
        )

    def _rows(self, n, out, outv, flag):
        f = self.f
        Row = self.row
        seen = self.seen
        b = self.batch[0]
        o = out.cast(CODE[self.result_fmt])
        nulls = 0
        for i in range(n):
            if flag[0]:
                return (ERR_CANCELLED, "cancelled at row {}".format(i), None, i)
            r = Row()
            r._i = i
            r._b = b
            try:
                y = f(r)
            except BaseException as exc:
                if seen[0] is not None:
                    return self._not_declared()
                trace = "".join(traceback.format_exception(exc))
                if exc.__traceback__ is not None:
                    traceback.clear_frames(exc.__traceback__)
                return (ERR_RAISED, "{}: {}".format(type(exc).__name__, exc), trace, i)
            if seen[0] is not None:
                # The read outside the read set was caught by user code.
                return self._not_declared()
            if y is None:
                nulls += 1
                outv[i >> 3] &= ~(1 << (i & 7)) & 0xFF
                continue
            try:
                o[i] = y
            except (TypeError, ValueError, OverflowError):
                if self.result_fmt == "g" and type(y) is int:
                    o[i] = float(y)
                else:
                    return (
                        ERR_RETURN_TYPE,
                        "row {}: {} {!r} is not {}".format(i, type(y).__name__, y, TYPE[self.result_fmt]),
                        None,
                        i,
                    )
        o.release()
        return (OK, nulls)
