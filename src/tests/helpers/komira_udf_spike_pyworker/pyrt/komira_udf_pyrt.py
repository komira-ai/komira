"""The adapter of the komira-test/python-worker UDF runtime: the code that
runs user code, imported in each worker process
(pyworker/komira_udf_pyworker.py; a forked worker inherits the zygote's
copy). The worker hands it Arrow buffers as memoryviews and takes back
statuses and results; it never sees a language object other than these.

- open_instance(): imports the module in this interpreter and binds the
  function, its hints checked as live objects against the declared types.
- Instance.call(): one batch. SCALAR: the function is called once per row
  over a pure-Python columnar view (memoryviews of the Arrow buffers, no
  copy), and each result written into the output buffer the worker
  allocated. MAP_BATCHES_COLUMN: the function gets whole columns, as Python
  lists (hint `list[float]`) or numpy arrays over the Arrow buffers (hint
  `numpy.ndarray`), and returns one.

Type hints are the only declaration: a plain function, no decorator.
`float` is Arrow float64 and `int` int64 or int32; `X | None` (or Optional[X])
allows None, which is a null; `list[X]` and `numpy.ndarray` (or
`numpy.typing.NDArray[...]`) are the column forms.

Statuses are komira_udf_status values of komira_udf_runtime.h.
"""

import os
import sys
import traceback
import types
import typing

OK = 0
ERR_DESCRIPTOR = 2
ERR_UNSUPPORTED = 3
ERR_LOAD = 5
ERR_RAISED = 6
ERR_RETURN_TYPE = 7
ERR_CANCELLED = 11
ERR_DEADLINE = 12

SHAPE_SCALAR = 1
SHAPE_MAP_BATCHES_COLUMN = 4

# Arrow format -> memoryview code, numpy dtype name, type name, bytes per
# value. An `int` hint (format "l") also fits a declared int32 ("i").
CODE = {"l": "q", "i": "i", "g": "d"}
DTYPE = {"l": "int64", "i": "int32", "g": "float64"}
TYPE = {"l": "int64", "i": "int32", "g": "float64"}
WIDTH = {"l": 8, "i": 4, "g": 8}


_NO_FLAG = memoryview(b"\0\0\0\0").cast("i")


def add_site_dirs(site):
    """Appends each directory under `site` (one per installed wheel), sorted."""
    if os.path.isdir(site):
        for name in sorted(os.listdir(site)):
            path = os.path.join(site, name)
            if os.path.isdir(path) and path not in sys.path:
                sys.path.append(path)


# ---- hints -------------------------------------------------------------------
# A hint maps to (kind, fmt): kind "row" (one value), "list" or "numpy" (a
# column); fmt "l", "g", or None (a numpy array of any dtype).


def _hint_of_object(ann):
    """The (kind, fmt) of a live annotation object, or None."""
    if ann is float:
        return ("row", "g")
    if ann is int:
        return ("row", "l")
    origin = typing.get_origin(ann)
    args = typing.get_args(ann)
    if origin in (typing.Union, types.UnionType):
        rest = [a for a in args if a is not type(None)]
        return _hint_of_object(rest[0]) if len(rest) == 1 and len(args) == 2 else None
    if origin is list and len(args) == 1:
        inner = _hint_of_object(args[0])
        return ("list", inner[1]) if inner and inner[0] == "row" else None
    head = origin if origin is not None else ann
    if getattr(head, "__module__", "").startswith("numpy") and getattr(head, "__name__", "") == "ndarray":
        text = repr(ann)
        return ("numpy", "g" if "float64" in text else "l" if "int64" in text else None)
    return None


def _check_signature(name, params, ret, shape, arg_fmts, result_fmt):
    """"" when hints (each a (kind, fmt) or None, ret too) fit the declared
    types for `shape`; else why not."""
    if ret is None:
        return "{} has no return type hint this runtime maps to an Arrow type".format(name)
    if len(params) != len(arg_fmts):
        return "{} takes {} arguments; {} are declared".format(name, len(params), len(arg_fmts))
    kinds = ("row",) if shape == SHAPE_SCALAR else ("list", "numpy")
    for i, (h, fmt) in enumerate(zip(list(params) + [ret], list(arg_fmts) + [result_fmt])):
        what = "the return type" if i == len(params) else "argument {}".format(i)
        if h is None:
            return "{}: {} has no type hint this runtime maps to an Arrow type".format(name, what)
        if h[0] not in kinds:
            return "{}: {} is a {} hint; shape {} takes {}".format(
                name, what, h[0], "SCALAR" if shape == SHAPE_SCALAR else "MAP_BATCHES_COLUMN", " or ".join(kinds)
            )
        if h[1] is not None and h[1] != fmt and not (h[1] == "l" and fmt == "i"):
            return "{}: {} is hinted {}, declared {}".format(name, what, TYPE[h[1]], TYPE[fmt])
    return ""


def _text(s):
    """`s` as text the worker can send: invalid UTF-8 (a lone surrogate)
    escaped."""
    return s.encode("utf-8", "backslashreplace").decode("utf-8")


def _type_name(x):
    try:
        return _text(str(type(x).__name__))
    except BaseException:
        return "?"


def _exception_text(exc):
    """'Type: message' for any exception object; its str() may raise or not
    return a str (user code's), so the message falls back to a placeholder."""
    try:
        msg = str(exc)
    except BaseException:
        msg = "<the exception's str() failed>"
    return _text("{}: {}".format(_type_name(exc), msg))


def _safe_repr(y):
    try:
        return _text(repr(y))
    except BaseException:
        return "<the value's repr() failed>"


def open_instance(entry, shape, arg_fmts, result_fmt, null_mode):
    """(OK, Instance) or (status, message): the function imported and bound
    in this interpreter."""
    import importlib

    module, _, qual = entry.partition(":")
    try:
        mod = importlib.import_module(module)
    except BaseException as exc:
        return (ERR_LOAD, "import {}: {}".format(module, _exception_text(exc)))
    f = getattr(mod, qual, None)
    if not callable(f):
        return (ERR_LOAD, "module {} has no function {}".format(module, qual))
    try:
        hints = typing.get_type_hints(f)
    except BaseException as exc:
        return (ERR_LOAD, "{}: the type hints do not resolve: {}".format(entry, _exception_text(exc)))
    try:
        import inspect

        names = [p.name for p in inspect.signature(f).parameters.values()]
    except (TypeError, ValueError) as exc:
        return (ERR_LOAD, "{}: no signature: {}".format(entry, _exception_text(exc)))
    params = [_hint_of_object(hints[n]) if n in hints else None for n in names]
    ret = _hint_of_object(hints["return"]) if "return" in hints else None
    why = _check_signature(entry, params, ret, shape, arg_fmts, result_fmt)
    if why:
        return (ERR_LOAD, why)
    np = sys.modules.get("numpy") if any(p and p[0] == "numpy" for p in params + [ret]) else None
    return (OK, Instance(f, shape, ret[0], arg_fmts, result_fmt, np))


class Instance:
    """One UDF bound in one interpreter."""

    __slots__ = ("f", "shape", "kind", "arg_fmts", "result_fmt", "np")

    def __init__(self, f, shape, kind, arg_fmts, result_fmt, np):
        self.f = f
        self.shape = shape
        self.kind = kind
        self.arg_fmts = arg_fmts
        self.result_fmt = result_fmt
        self.np = np

    def call(self, n, cols, out, outv, cancel, now, deadline):
        """One batch. `cols`: one (fmt, values view, validity view or None,
        offset) per argument, the views over the Arrow buffers from offset 0.
        `out`, `outv`: writable views of the output column (SCALAR only).
        `cancel`: a view of the host's int32 cancel flag, or None. `now`:
        the host clock. Returns (OK, null_count) for SCALAR, (OK, values,
        validity or None, null_count, length) for a column, or (status,
        message, trace or None, row) on failure."""
        flag = cancel.cast("i") if cancel is not None else _NO_FLAG
        if self.shape == SHAPE_SCALAR:
            return self._rows(n, cols, out, outv, flag, now, deadline)
        if flag[0]:
            return (ERR_CANCELLED, "cancelled before the batch", None, 0)
        if self.kind == "numpy":
            res = self._numpy(n, cols)
        else:
            res = self._lists(n, cols)
        if res[0] == OK and flag[0]:
            # The whole batch ran: no row of it is the one cancelled.
            return (ERR_CANCELLED, "cancelled during the batch", None, -1)
        return res

    def _raised(self, exc, row):
        """User code's exception, raised in the function or while its result
        was converted: ERR_RAISED at `row` (design section 4.5)."""
        try:
            trace = _text("".join(traceback.format_exception(exc)))
        except BaseException:
            trace = None
        tb = exc.__traceback__
        if tb is not None:
            traceback.clear_frames(tb)
        return (ERR_RAISED, _exception_text(exc), trace, row)

    def _bad_value(self, y, row):
        return (
            ERR_RETURN_TYPE,
            "row {}: {} {} is not {}".format(row, _type_name(y), _safe_repr(y), TYPE[self.result_fmt]),
            None,
            row,
        )

    def _rows(self, n, cols, out, outv, flag, now, deadline):
        f = self.f
        o = out.cast(CODE[self.result_fmt])
        ov = outv
        xs = [c[1].cast(CODE[c[0]]) for c in cols]
        vs = [c[2] for c in cols]
        offs = [c[3] for c in cols]
        k = len(cols)
        nulls = 0
        simple = k == 1 and vs[0] is None
        x0 = xs[0] if k else None
        off0 = offs[0] if k else 0
        for i in range(n):
            if flag[0]:
                return (ERR_CANCELLED, "cancelled at row {}".format(i), None, i)
            try:
                if simple:
                    y = f(x0[off0 + i])
                else:
                    args = []
                    for j in range(k):
                        p = offs[j] + i
                        v = vs[j]
                        args.append(None if v is not None and not (v[p >> 3] >> (p & 7)) & 1 else xs[j][p])
                    y = f(*args)
            except BaseException as exc:
                return self._raised(exc, i)
            if y is None:
                nulls += 1
                ov[i >> 3] &= ~(1 << (i & 7)) & 0xFF
            else:
                try:
                    o[i] = y
                except (TypeError, ValueError, OverflowError):
                    return self._bad_value(y, i)
                except BaseException as exc:
                    # The value's own conversion code raised: user code's.
                    return self._raised(exc, i)
            # The host clock is read after row 0 (where a host may raise the
            # cancel flag) and, with a deadline, after every row (design
            # 4.7: checked between rows). A deadline seen after the last
            # row ends nothing: the batch is complete.
            if i == 0 or deadline:
                t = now()
                if deadline and t > deadline and i + 1 < n:
                    return (ERR_DEADLINE, "the deadline passed at row {}".format(i + 1), None, i + 1)
        return (OK, nulls)

    def _lists(self, n, cols):
        lists = []
        for fmt, data, valid, off in cols:
            x = data.cast(CODE[fmt])[off : off + n].tolist()
            if valid is not None:
                for i in range(n):
                    p = off + i
                    if not (valid[p >> 3] >> (p & 7)) & 1:
                        x[i] = None
            lists.append(x)
        try:
            res = self.f(*lists)
        except BaseException as exc:
            return self._raised(exc, -1)
        if not isinstance(res, (list, tuple)):
            return (ERR_RETURN_TYPE, "the result is a {}, not a list".format(_type_name(res)), None, -1)
        try:
            # A list subclass's own __len__ or __iter__ is user code.
            m = len(res)
            it = iter(res)
        except BaseException as exc:
            return self._raised(exc, -1)
        buf = bytearray(WIDTH[self.result_fmt] * m)
        o = memoryview(buf).cast(CODE[self.result_fmt])
        valid = None
        nulls = 0
        i = -1
        while True:
            try:
                y = next(it)
            except StopIteration:
                break
            except BaseException as exc:
                return self._raised(exc, -1)
            i += 1
            if y is None:
                if valid is None:
                    valid = bytearray(b"\xff" * ((m + 7) // 8))
                valid[i >> 3] &= ~(1 << (i & 7)) & 0xFF
                nulls += 1
                continue
            try:
                o[i] = y
            except (TypeError, ValueError, OverflowError, IndexError):
                return self._bad_value(y, i)
            except BaseException as exc:
                return self._raised(exc, i)
        o.release()
        return (OK, buf, valid, nulls, m)

    def _numpy(self, n, cols):
        np = self.np
        arrays = []
        for fmt, data, valid, off in cols:
            a = np.frombuffer(data, dtype=DTYPE[fmt], count=off + n)[off:]
            if valid is not None:
                bits = np.unpackbits(np.frombuffer(valid, dtype=np.uint8), bitorder="little")[off : off + n]
                a = np.ma.masked_array(a, mask=bits == 0)
            arrays.append(a)
        try:
            res = self.f(*arrays)
        except BaseException as exc:
            return self._raised(exc, -1)
        del arrays
        try:
            return self._numpy_result(np, res)
        except BaseException as exc:
            # A result object's own conversion code (__array__, a masked
            # array subclass, ...) raised: user code's, for the batch.
            return self._raised(exc, -1)

    def _numpy_result(self, np, res):
        mask = None
        if isinstance(res, np.ma.MaskedArray):
            mask = np.ma.getmaskarray(res)
            res = res.filled(0)
        try:
            res = np.asarray(res)
        except (TypeError, ValueError) as exc:
            return (ERR_RETURN_TYPE, "the result is no array: " + _exception_text(exc), None, -1)
        want = np.dtype(DTYPE[self.result_fmt])
        if res.ndim != 1:
            return (ERR_RETURN_TYPE, "the result has {} dimensions, not 1".format(res.ndim), None, -1)
        if res.dtype != want:
            if not np.can_cast(res.dtype, want, "safe"):
                return (ERR_RETURN_TYPE, "the result is {}, not {}".format(res.dtype, want), None, -1)
            res = res.astype(want)
        res = np.ascontiguousarray(res)
        valid = None
        nulls = 0
        if mask is not None and mask.any():
            nulls = int(mask.sum())
            valid = np.packbits(~mask, bitorder="little")
        return (OK, res, valid, nulls, len(res))
