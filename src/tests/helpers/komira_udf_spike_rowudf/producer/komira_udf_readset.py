"""The read set of a row-shaped UDF, as a producer determines it when the plan
is built (docs/design/udf_runtime_interface.md section 3.1, "ROW", and
section 6.1, item 6). Test-only spike code.

A row-shaped function takes one row object and reads its fields by name:

    def f(row) -> float:
        return row.price * row.qty

Its read set is the fields it may read. The plan carries it (the ROW
UdfRef's arg_types, one named field each), the optimizer keeps only those
columns live, and the runtime builds rows from them alone.

read_set() decides it, in this order:
  1. `columns=[...]`, when the user declares it;
  2. else a scan of the function's bytecode: every place the row parameter
     is loaded must be followed at once by an attribute load of a constant
     name (`row.price`) or a subscript by a constant string (`row["qty"]`).
     Every such name is in the read set, on every branch, taken or not.
     Any other use of the row (passing it to a call, iterating it, storing
     it, a computed key, a method call on it, a nested function that
     captures it) makes the scan undetermined;
  3. else every input column, with a note saying why.

A sample of rows, when given, is a cross-check only: the function runs over
it with a recording row, and a field it reads outside the read set fails
here (ReadSetError UDF_ROW_READ_SET_MISSED) rather than at run time. The
runtime's by-name error (ERR_FIELD_NOT_DECLARED) is the safety net for
what neither sees.
"""

import dis
import types

SOURCE_COLUMNS = "columns"
SOURCE_STATIC = "static"
SOURCE_EVERY_COLUMN = "every_column"

# The load instructions that push one local variable.
_LOAD_ONE = ("LOAD_FAST", "LOAD_FAST_CHECK", "LOAD_FAST_AND_CLEAR")


class ReadSetError(Exception):
    """A read set the producer refuses, with the run error's name."""

    def __init__(self, code, message):
        super().__init__("{}: {}".format(code, message))
        self.code = code


class ReadSet:
    """The read set of one function over one input: `names` in input order,
    where they came from (`source`), the fields the sample read (`recorded`,
    in input order; empty without a sample) and, for every_column, why."""

    __slots__ = ("names", "source", "recorded", "note")

    def __init__(self, names, source, recorded, note):
        self.names = names
        self.source = source
        self.recorded = recorded
        self.note = note

    def __repr__(self):
        return "ReadSet({!r}, {!r}, recorded={!r}, note={!r})".format(self.names, self.source, self.recorded, self.note)


def _row_param(f):
    """The name of f's one positional parameter; None when f is not a plain
    function; a ReadSetError when it does not take one row."""
    if not isinstance(f, types.FunctionType):
        return None
    code = f.__code__
    if code.co_argcount != 1 or code.co_kwonlyargcount or code.co_flags & (0x04 | 0x08):
        raise ReadSetError(
            "UDF_ROW_SIGNATURE",
            "{} must take exactly one positional parameter, the row".format(getattr(f, "__qualname__", f)),
        )
    return code.co_varnames[0]


def scan(f):
    """(fields, why): the constant field names f reads from its row, in the
    order first seen, and "" when that is all f does with it; otherwise
    (None, why not)."""
    row = _row_param(f)
    if row is None:
        return None, "{!r} is not a plain Python function, so its bytecode is not scanned".format(f)
    code = f.__code__
    if row in code.co_cellvars:
        return None, "a nested function or lambda captures the row"
    # get_instructions yields no CACHE entries; an EXTENDED_ARG prefix or a
    # NOP is not an operation on the row.
    ins = [i for i in dis.get_instructions(code) if i.opname not in ("EXTENDED_ARG", "NOP")]
    fields = []
    for k, i in enumerate(ins):
        op = i.opname
        if op in ("STORE_FAST", "DELETE_FAST") and i.argval == row:
            return None, "the row parameter is reassigned or deleted"
        if op == "STORE_FAST_STORE_FAST" and row in i.argval:
            return None, "the row parameter is reassigned"
        if op == "STORE_FAST_LOAD_FAST" and i.argval[0] == row:
            return None, "the row parameter is reassigned"
        if op in _LOAD_ONE:
            loads_row = i.argval == row
        elif op == "LOAD_FAST_LOAD_FAST":
            if i.argval[0] == row:
                return None, "the row is used as a value (line {})".format(i.positions.lineno)
            loads_row = i.argval[1] == row
        elif op == "STORE_FAST_LOAD_FAST":
            loads_row = i.argval[1] == row
        else:
            loads_row = False
        if not loads_row:
            continue
        # The row is on top of the stack: what comes next must read one
        # constant field from it. A code object ends with a return, so a
        # load is never its last instruction, nor is the constant after it.
        nxt = ins[k + 1]
        if nxt.opname == "LOAD_ATTR":
            if nxt.arg & 1:
                return None, "a method of the row is called: .{} (line {})".format(nxt.argval, nxt.positions.lineno)
            name = nxt.argval
        elif nxt.opname == "LOAD_CONST" and isinstance(nxt.argval, str) and ins[k + 2].opname == "BINARY_SUBSCR":
            name = nxt.argval
        else:
            return None, "the row is used other than by a constant field name (line {})".format(i.positions.lineno)
        if name not in fields:
            fields.append(name)
    return fields, ""


class _Undetermined(Exception):
    pass


class RecordingRow:
    """The row the sample check passes: it records each field read by name
    and hands back that field's sample value. A whole-row operation
    (iteration, length, membership, conversion) marks the recording
    undetermined, as the design's recording proxy does."""

    __slots__ = ("_values", "_reads", "_whole")

    def __init__(self, values, reads, whole):
        object.__setattr__(self, "_values", values)
        object.__setattr__(self, "_reads", reads)
        object.__setattr__(self, "_whole", whole)

    def _read(self, name):
        reads = object.__getattribute__(self, "_reads")
        if name not in reads:
            reads.append(name)
        values = object.__getattribute__(self, "_values")
        if name not in values:
            raise AttributeError("the input has no column {!r}".format(name))
        return values[name]

    def __getattr__(self, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        return self._read(name)

    def __getitem__(self, key):
        if not isinstance(key, str):
            self._mark("the row is indexed by a {}".format(type(key).__name__))
        return self._read(key)

    def _mark(self, why):
        object.__getattribute__(self, "_whole").append(why)
        raise _Undetermined(why)

    def __iter__(self):
        self._mark("the row is iterated")

    def __len__(self):
        self._mark("the length of the row is taken")

    def __contains__(self, item):
        self._mark("membership is tested on the row")

    def keys(self):
        self._mark("the row's keys are listed")


def record(f, sample):
    """(fields read over `sample`, a list of {column: value}, in first-read
    order; and why it is undetermined, or "")."""
    reads = []
    whole = []
    for values in sample:
        try:
            f(RecordingRow(values, reads, whole))
        except _Undetermined:
            break
    return reads, (whole[0] if whole else "")


def read_set(f, input_columns, columns=None, sample=None):
    """The ReadSet of `f` over an input whose columns are `input_columns`
    (names, in order). `columns`: the user's declaration. `sample`: rows
    ({column: value}) for the cross-check. Raises ReadSetError for a name
    the input lacks, a repeated declared name, a function that does not take
    one row, or a field the sample read outside the read set."""
    order = list(input_columns)
    if columns is not None:
        cols = list(columns)
        if len(set(cols)) != len(cols):
            raise ReadSetError("UDF_ROW_READ_SET_INVALID", "columns=[...] names a field twice: {}".format(cols))
        for c in cols:
            if c not in order:
                raise ReadSetError("UDF_ROW_COLUMN_UNKNOWN", "columns=[...] names {!r}; the input has {}".format(c, order))
        names = [c for c in order if c in cols]
        source = SOURCE_COLUMNS
        note = ""
        _row_param(f)
    else:
        fields, why = scan(f)
        if fields is None:
            names = order
            source = SOURCE_EVERY_COLUMN
            note = why + "; every input column is passed (add columns=[...] to narrow it)"
        else:
            for c in fields:
                if c not in order:
                    raise ReadSetError(
                        "UDF_ROW_COLUMN_UNKNOWN", "the function reads {!r}; the input has {}".format(c, order)
                    )
            names = [c for c in order if c in fields]
            source = SOURCE_STATIC
            note = ""
    recorded = []
    if sample is not None:
        reads, _ = record(f, sample)
        recorded = [c for c in order if c in reads]
        missed = [c for c in reads if c not in names]
        if missed:
            raise ReadSetError(
                "UDF_ROW_READ_SET_MISSED",
                "the sample run read {} outside the read set {} ({}); add it to columns=[...]".format(
                    missed, names, source
                ),
            )
    return ReadSet(names, source, recorded, note)
