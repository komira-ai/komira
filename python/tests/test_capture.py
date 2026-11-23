"""Capture of a user function (komira._capture): the `@udf` decorator and its
refusals, the types, the read set (columns=, annotations and the bytecode
scan), the code form (package or bundle), the deterministic bundle, and the
code objects written under a code root. Pure Python: no library and no
protobuf. The fixture functions live in real modules under fixtures/udfs,
because capture reads a function's source file.

    test_capture.py
"""

import ast
import contextlib
import hashlib
import importlib
import io
import os
import shutil
import sys
import tempfile
import types
import zipfile
import zipimport

import komira._capture as capture
from komira import KomiraError
from komira._capture import udf
from komira._errors import UnsupportedOperation
from komira._ops import ColRef, Lit
from komira._ops._expr import UdfCall, UdfSpec

from fixtures.udfs import future, rows, scalars

CARRIED = (
    "bool, int8, int16, int32, int64, float32, float64, string, large_string, binary, large_binary, "
    "date32[day], timestamp[s|ms|us|ns] with an optional tz, decimal128(p, s), list<item: T>, "
    "large_list<item: T> and struct<name: T, ...>, where a list item or struct field is not a list, "
    "a struct, a decimal or a zoned timestamp"
)
# A list item or struct field a column cannot hold as a child, as return_dtype=
# and schema= word the refusal, and as a return hint does.
NESTS = (
    "UDF_RETURN_TYPE_UNMAPPABLE: {what} {value!r} nests {child} in a list or struct, "
    "which a komira column cannot hold; the carried types are {carried}"
)
NESTED_HINT = (
    "UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{shown}` of `{name}()` nests {child} in a list or struct, "
    "which a komira column cannot hold; the carried types are {carried}"
)
# What the refusal of an unmappable return hint says the hints are.
HINTS_NOTE = (
    "the hints int, float, bool, str, bytes, datetime.date, datetime.datetime, list[T], "
    "and a TypedDict or dataclass of them map to carried types"
)
# A decimal.Decimal return hint has no precision or scale.
DECIMAL_HINT = (
    "UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{shown}` of `{name}()` is a decimal.Decimal, "
    "which carries no precision or scale. Pass return_dtype=\"decimal128(p, s)\" to udf"
)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def spec_refuses(u, message, cls=UnsupportedOperation):
    refuses(u.spec, cls, message)


@contextlib.contextmanager
def project(files, tops, path_dirs=("",)):
    """A temporary directory holding `files` ({path: text}), with each of
    `path_dirs` (relative to it) on sys.path; the modules named `tops` are
    forgotten on exit. Yields the directory."""
    root = tempfile.mkdtemp()
    added = []
    try:
        for rel, text in files.items():
            path = os.path.join(root, *rel.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        for rel in path_dirs:
            entry = os.path.join(root, rel) if rel else root
            sys.path.insert(0, entry)
            added.append(entry)
        importlib.invalidate_caches()
        yield root
    finally:
        for entry in added:
            sys.path.remove(entry)
        for name in list(sys.modules):
            if name.split(".")[0] in tops:
                del sys.modules[name]
        importlib.invalidate_caches()
        shutil.rmtree(root, ignore_errors=True)


def source_of(module):
    with open(module.__file__, "rb") as f:
        return f.read()


def bundle_digest(u):
    return hashlib.sha256(u.bundle_bytes()).digest()


# ---- the decorator ------------------------------------------------------------


def test_decorator_forms():
    assert isinstance(scalars.double, capture.Udf)
    assert isinstance(scalars.narrow, capture.Udf)
    assert scalars.double.spec().kind == "scalar"
    assert scalars.narrow.spec().return_type == "int32"
    direct = udf(scalars.plain)
    assert isinstance(direct, capture.Udf) and direct.spec().return_type == "int64"
    by_keyword = udf(fn=scalars.plain, return_dtype="float64")
    assert by_keyword.spec().return_type == "float64"
    factory = udf(return_dtype="int32")
    assert callable(factory) and not isinstance(factory, capture.Udf)
    assert factory(scalars.plain).spec().return_type == "int32"
    assert repr(scalars.double) == "<Udf scalar 'double'>"


def test_a_udf_runs_the_function_unchanged():
    assert scalars.double(4) == 8
    assert scalars.double(x=3) == 6
    assert scalars.halve(5.0) == 2.5
    assert scalars.double.__wrapped__(4) == 8
    assert scalars.double.__name__ == "double"
    assert scalars.double.__qualname__ == "double"
    assert scalars.double.__module__ == "fixtures.udfs.scalars"
    assert scalars.double.__doc__ == "Twice x."
    row = types.SimpleNamespace(a=1, b=2)
    assert rows.attribute(row) == 3
    assert rows.subscript({"a": 5, "b": 7}) == 35


def test_the_decorator_refuses_wrong_arguments():
    refuses(lambda: udf(kind="x"), ValueError, "kind must be one of map_batches_column, map_batches_frame, row, scalar, not 'x'")
    refuses(lambda: udf(kind=3), TypeError, "kind must be a str, not int")
    refuses(lambda: udf(stability="hard"), ValueError, "stability must be one of immutable, stable, volatile, not 'hard'")
    refuses(lambda: udf(null_mode="x"), ValueError, "null_mode must be one of manual, propagate, not 'x'")
    refuses(
        lambda: udf(kind="row", null_mode="propagate"),
        ValueError,
        "a row function takes null_mode='manual': under 'propagate' a null in a field read on some branches would drop rows",
    )
    refuses(
        lambda: udf(kind="map_batches_frame", return_dtype="int64"),
        ValueError,
        "return_dtype= is for a column function; a map_batches_frame function takes schema=",
    )
    refuses(lambda: udf(schema={"a": "int64"}), ValueError, "schema= is for a map_batches_frame function; a scalar function takes return_dtype=")
    refuses(
        lambda: udf(kind="row", schema={"a": "int64"}),
        ValueError,
        "schema= is for a map_batches_frame function; a row function takes return_dtype=",
    )
    refuses(
        lambda: udf(columns=["a"]),
        UnsupportedOperation,
        "UDF_READ_SET_INVALID: columns= is for a row or map_batches_frame function; a scalar function reads its argument expressions",
    )
    refuses(
        lambda: udf(kind="map_batches_column", columns=["a"]),
        UnsupportedOperation,
        "UDF_READ_SET_INVALID: columns= is for a row or map_batches_frame function; "
        "a map_batches_column function reads its argument expressions",
    )
    refuses(lambda: udf(5), TypeError, "udf() decorates a function, not int")
    refuses(lambda: udf(scalars.double), TypeError, "udf() was given a Udf; decorate the function once")
    refuses(lambda: udf(kind="x")(scalars.plain), ValueError, "kind must be one of map_batches_column, map_batches_frame, row, scalar, not 'x'")


# Every carried type as a user may spell it, and the spelling the spec keeps.
CARRIED_DTYPES = [
    ("bool", "bool"), ("int8", "int8"), ("int16", "int16"), ("int32", "int32"), ("int64", "int64"),
    ("float32", "float32"), ("float64", "float64"), ("float", "float32"), ("double", "float64"),
    ("string", "string"), ("utf8", "string"),
    ("large_string", "large_string"), ("large_utf8", "large_string"), ("binary", "binary"),
    ("large_binary", "large_binary"), ("date32", "date32[day]"), ("date32[day]", "date32[day]"),
    ("timestamp[s]", "timestamp[s]"), ("timestamp[ms]", "timestamp[ms]"), ("timestamp[us]", "timestamp[us]"),
    ("timestamp[ns]", "timestamp[ns]"), ("timestamp[us,tz=UTC]", "timestamp[us, tz=UTC]"),
    ("timestamp[ns, tz=Europe/Paris]", "timestamp[ns, tz=Europe/Paris]"),
    ("decimal128(10,2)", "decimal128(10, 2)"), ("decimal128(38, 0)", "decimal128(38, 0)"),
    ("list<int64>", "list<item: int64>"), ("list<item: utf8>", "list<item: string>"),
    ("large_list<timestamp[ns]>", "large_list<item: timestamp[ns]>"),
    ("list<double>", "list<item: float64>"), ("struct<a: float, b: double>", "struct<a: float32, b: float64>"),
    ("struct<a:int64,b:utf8>", "struct<a: int64, b: string>"), ("struct<a: date32>", "struct<a: date32[day]>"),
]


def test_dtypes_outside_the_carried_types_are_refused_by_name():
    for dtype in ("float16", "uint8", "map<string, int64>"):
        refuses(
            lambda: udf(return_dtype=dtype),
            UnsupportedOperation,
            f"UDF_RETURN_TYPE_UNMAPPABLE: return_dtype= {dtype!r} is not a type komira/python carries; the carried types are {CARRIED}",
        )
        refuses(
            lambda: udf(kind="map_batches_frame", schema={"a": dtype}),
            UnsupportedOperation,
            f"UDF_RETURN_TYPE_UNMAPPABLE: schema= column 'a' {dtype!r} is not a type komira/python carries; the carried types are {CARRIED}",
        )
    refuses(lambda: udf(return_dtype=5), TypeError, "return_dtype= must be a dtype name (str), not int")


def test_a_list_item_or_struct_field_that_is_not_flat_is_refused_by_name():
    for dtype, child in (
        ("list<item: decimal128(5, 2)>", "decimal128(5, 2)"),
        ("list<list<int64>>", "list<item: int64>"),
        ("struct<a: timestamp[us, tz=UTC]>", "timestamp[us, tz=UTC]"),
        ("struct<a: int64, b: list<item: string>>", "list<item: string>"),
    ):
        refuses(
            lambda: udf(return_dtype=dtype),
            UnsupportedOperation,
            NESTS.format(what="return_dtype=", value=dtype, child=child, carried=CARRIED),
        )
        refuses(
            lambda: udf(kind="map_batches_frame", schema={"a": dtype}),
            UnsupportedOperation,
            NESTS.format(what="schema= column 'a'", value=dtype, child=child, carried=CARRIED),
        )


def test_return_dtype_accepts_each_carried_type_and_stores_its_canonical_spelling():
    for given, canonical in CARRIED_DTYPES:
        assert udf(scalars.plain, return_dtype=given).spec().return_type == canonical, given
        assert udf(return_dtype=given)(scalars.plain).spec().return_type == canonical, given
        batch = udf(scalars.plain, kind="map_batches_column", return_dtype=given)
        assert batch.spec().return_type == canonical, given


def test_schema_accepts_each_carried_type_and_stores_its_canonical_spelling():
    frame = dict(kind="map_batches_frame", columns=["a"])
    for given, canonical in CARRIED_DTYPES:
        as_dict = udf(scalars.plain, schema={"c": given}, **frame)
        assert as_dict.spec().return_type == (("c", canonical),), given
        as_pairs = udf(scalars.plain, schema=[("c", given), ("d", "int64")], **frame)
        assert as_pairs.spec().return_type == (("c", canonical), ("d", "int64")), given


def test_schema_forms_and_refusals():
    frame = "map_batches_frame"
    refuses(lambda: udf(kind=frame, schema=5), TypeError, "schema= must be a dict or a list of (name, dtype) pairs, not int")
    refuses(lambda: udf(kind=frame, schema="ab"), TypeError, "schema= must be a dict or a list of (name, dtype) pairs, not str")
    refuses(lambda: udf(kind=frame, schema=[("a",)]), TypeError, "schema= holds (name, dtype) pairs")
    refuses(lambda: udf(kind=frame, schema={1: "int64"}), TypeError, "schema= column names must be str, not int")
    refuses(lambda: udf(kind=frame, schema={"": "int64"}), ValueError, "schema= holds an empty column name")
    refuses(lambda: udf(kind=frame, schema={}), ValueError, "schema= names at least one column")
    refuses(
        lambda: udf(kind=frame, schema=[("a", "int64"), ("a", "int32")]),
        ValueError,
        "schema= names the column 'a' more than once",
    )
    assert rows.frame_columns.spec().return_type == (("total", "int64"), ("mean", "float64"))
    assert rows.frame_pairs.spec().return_type == (("total", "int64"),)


def test_columns_refusals():
    refuses(lambda: udf(kind="row", columns="ab"), TypeError, "columns= must be a list or tuple of column names, not str")
    refuses(lambda: udf(kind="row", columns=[1]), TypeError, "columns= holds only str names, not int")
    refuses(lambda: udf(kind="row", columns=[""]), UnsupportedOperation, "UDF_READ_SET_INVALID: columns= holds an empty column name")
    refuses(
        lambda: udf(kind="row", columns=["a", "b", "a"]),
        UnsupportedOperation,
        "UDF_READ_SET_INVALID: columns= names 'a' more than once",
    )


# ---- the spec of each kind ------------------------------------------------------


def expected(u, **fields):
    """The spec a fixture is expected to have, its code taken from the capture."""
    spec = u.spec()
    base = dict(
        name=u.__qualname__,
        kind="scalar",
        form="bundle",
        entry=f"{u.__module__}:{u.__qualname__}",
        code=(("bundle", bundle_digest(u)),),
        return_type="int64",
        stability="stable",
        null_mode="propagate",
        batch_format="values",
        read_set=None,
    )
    base.update(fields)
    assert spec == UdfSpec(**base), (spec, base)
    return spec


def test_spec_of_a_scalar():
    expected(scalars.double)
    expected(scalars.halve, return_type="float64")
    expected(scalars.maybe)
    expected(scalars.maybe_pipe, return_type="float64")
    expected(scalars.narrow, return_type="int32")
    expected(scalars.declared, return_type="float64", stability="immutable", null_mode="manual")


def test_spec_of_a_map_batches_column():
    expected(scalars.batch, kind="map_batches_column", stability="volatile", batch_format="arrow")
    expected(scalars.batch_hinted, kind="map_batches_column", return_type="float64", batch_format="arrow")


def test_spec_of_a_row():
    expected(rows.attribute, kind="row", null_mode="manual", read_set=("a", "b"))


def test_spec_of_a_map_batches_frame():
    schema = (("total", "int64"), ("mean", "float64"))
    expected(rows.frame_columns, kind="map_batches_frame", null_mode="manual", batch_format="arrow", return_type=schema, read_set=("x", "y"))
    expected(
        rows.frame_pairs,
        kind="map_batches_frame",
        null_mode="propagate",
        stability="volatile",
        batch_format="arrow",
        return_type=(("total", "int64"),),
        read_set=("a",),
    )


def test_string_hints_are_resolved():
    expected(future.scalar)
    expected(future.optional, return_type="float64")
    expected(future.piped)
    expected(future.typed_row, kind="row", null_mode="manual", read_set=("a", "b"))
    expected(future.dataclass_row, kind="row", null_mode="manual", return_type="float64", read_set=("x", "y"))
    expected(future.scanned, kind="row", null_mode="manual", read_set=("p", "q"))


def test_spec_is_captured_lazily_and_once():
    source = "from komira._capture import udf\n\n\n@udf\ndef f(x: int) -> int:\n    return x\n"
    with project({"capt_lazy.py": source}, ["capt_lazy"]) as root:
        module = importlib.import_module("capt_lazy")
        path = os.path.join(root, "capt_lazy.py")
        os.unlink(path)
        message = "UDF_CAPTURE_UNSUPPORTED: `f` is defined in module `capt_lazy`, which has no .py source file. " \
            "A UDF is a function defined at the top level of a .py module: move it to a module and import it"
        spec_refuses(module.f, message)
        with open(path, "w", encoding="utf-8") as f:
            f.write(source)
        first = module.f.spec()
        assert module.f.spec() is first
        objects = module.f.code_objects()
        os.unlink(path)
        assert module.f.spec() is first
        assert module.f.code_objects() == objects
        assert module.f(3) == 3


# ---- types ------------------------------------------------------------------------


def test_missing_return_types_are_refused():
    spec_refuses(
        scalars.no_hint,
        "UDF_RETURN_TYPE_MISSING: `no_hint()` has no return type. Annotate it (`def no_hint(...) -> int`) "
        f"or pass return_dtype= to udf (`@udf(return_dtype=\"int64\")`); a lambda takes return_dtype=. The carried types are {CARRIED}",
    )
    spec_refuses(
        rows.frame_no_schema,
        "UDF_RETURN_TYPE_MISSING: `frame_no_schema()` has no output schema. Pass schema= to udf "
        "(`@udf(kind=\"map_batches_frame\", schema={\"total\": \"int64\"})`); a frame function's type hints "
        f"do not give one. The carried types are {CARRIED}",
    )


def unmappable(name, shown):
    return (
        f"UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{shown}` of `{name}()` names no type komira/python carries. "
        f"Pass return_dtype= to udf; the carried types are {CARRIED} ({HINTS_NOTE})"
    )


HINTS_HEADER = """\
import dataclasses
import datetime
import decimal
import typing
from typing import NotRequired, Optional, TypedDict

from komira._capture import udf


class Pair(TypedDict):
    a: int
    b: Optional[str]


@dataclasses.dataclass
class Point:
    x: int
    y: Optional[float]
    when: datetime.datetime


WithList = TypedDict("WithList", {"a": int, "b": list[int]})
OptTotal = TypedDict("OptTotal", {"a": int, "b": str}, total=False)
OptNotRequired = TypedDict("OptNotRequired", {"a": int, "b": NotRequired[str], "c": NotRequired[int]})
EmptyDict = TypedDict("EmptyDict", {})


@dataclasses.dataclass
class EmptyData:
    pass


@dataclasses.dataclass
class Priced:
    name: str
    price: decimal.Decimal
"""

# (function name, return hint as written, the dtype the spec gets)
HINT_DTYPES = [
    ("h_int", "int", "int64"), ("h_float", "float", "float64"), ("h_opt_int", "Optional[int]", "int64"),
    ("h_str", "str", "large_string"), ("h_bytes", "bytes", "large_binary"), ("h_bool", "bool", "bool"),
    ("h_date", "datetime.date", "date32[day]"), ("h_datetime", "datetime.datetime", "timestamp[us]"),
    ("h_list_int", "list[int]", "large_list<item: int64>"),
    ("h_list_str_or_none", "list[str | None]", "large_list<item: large_string>"),
    ("h_typing_list", "typing.List[float]", "large_list<item: float64>"),
    ("h_list_datetime", "list[datetime.datetime]", "large_list<item: timestamp[us]>"),
    ("h_typed_dict", "Pair", "struct<a: int64, b: large_string>"),
    ("h_dataclass", "Point", "struct<x: int64, y: float64, when: timestamp[us]>"),
    ("h_opt_str", "Optional[str]", "large_string"), ("h_opt_pipe_date", "datetime.date | None", "date32[day]"),
    ("h_opt_list", "Optional[list[int]]", "large_list<item: int64>"),
    ("h_opt_item", "list[Optional[int]]", "large_list<item: int64>"),
    ("h_opt_both", "Optional[list[Optional[str]]]", "large_list<item: large_string>"),
    ("h_opt_list_opt_int", "Optional[list[Optional[int]]]", "large_list<item: int64>"),
    ("h_opt_typed_dict", "Optional[Pair]", "struct<a: int64, b: large_string>"),
    ("h_opt_dataclass", "Point | None", "struct<x: int64, y: float64, when: timestamp[us]>"),
]

# (function name, return hint as written, the hint as a refusal shows it)
UNMAPPABLE_HINTS = [
    ("u_dict", "dict[str, int]", "dict[str, int]"), ("u_set", "set[int]", "set[int]"), ("u_object", "object", "object"),
    ("u_empty_dict", "EmptyDict", "<class 'capt_hints.EmptyDict'>"),
    ("u_empty_dataclass", "EmptyData", "<class 'capt_hints.EmptyData'>"),
    ("u_list_empty_dataclass", "list[EmptyData]", "list[capt_hints.EmptyData]"),
]

# (function name, return hint as written, the hint as a refusal shows it, the child it nests)
NESTED_HINTS = [
    ("n_list_list", "list[list[int]]", "list[list[int]]", "large_list<item: int64>"),
    ("n_opt_list_list", "Optional[list[list[int]]]", "list[list[int]] | None", "large_list<item: int64>"),
    ("n_list_dataclass", "list[Point]", "list[capt_hints.Point]", "struct<x: int64, y: float64, when: timestamp[us]>"),
    ("n_list_with_list", "list[WithList]", "list[capt_hints.WithList]", "large_list<item: int64>"),
    ("n_dataclass_decimal", "Priced", "<class 'capt_hints.Priced'>", "decimal.Decimal"),
]

# (function name, return hint as written, the hint as a refusal shows it, the TypedDict, its optional keys)
OPTIONAL_KEY_HINTS = [
    ("o_total", "OptTotal", "<class 'capt_hints.OptTotal'>", "OptTotal", ["a", "b"]),
    ("o_not_required", "OptNotRequired", "<class 'capt_hints.OptNotRequired'>", "OptNotRequired", ["b", "c"]),
    ("o_list_total", "list[OptNotRequired]", "list[capt_hints.OptNotRequired]", "OptNotRequired", ["b", "c"]),
]
OPTIONAL_KEYS = (
    "UDF_RETURN_TYPE_UNMAPPABLE: the return hint `{shown}` of `{name}()` holds the TypedDict `{cls}` with the "
    "optional keys {keys!r}, which a struct column cannot hold: every field of a struct is required. "
    "Declare every key required, or pass return_dtype= to udf"
)

DECIMAL_HINTS = [
    ("d_decimal", "decimal.Decimal", "<class 'decimal.Decimal'>"),
    ("d_opt_decimal", "Optional[decimal.Decimal]", "<class 'decimal.Decimal'> | None"),
]


def hints_module():
    body = HINTS_HEADER
    for name, hint, *_ in HINT_DTYPES + UNMAPPABLE_HINTS + NESTED_HINTS + DECIMAL_HINTS + OPTIONAL_KEY_HINTS:
        body += f"\n@udf\ndef {name}(x) -> {hint}:\n    return x\n\n"
    return body


def test_return_hints_map_to_their_dtypes():
    with project({"capt_hints.py": hints_module()}, ["capt_hints"]):
        module = importlib.import_module("capt_hints")
        for name, hint, dtype in HINT_DTYPES:
            assert getattr(module, name).spec().return_type == dtype, hint


def test_unmappable_return_hints_are_refused_by_name():
    for u, shown in (
        (scalars.hint_union, "int | float"),
        (scalars.hint_optional_union, "int | float | None"),
        (scalars.hint_any, "typing.Any"),
        (scalars.hint_none, "None"),
    ):
        spec_refuses(u, unmappable(u.__name__, shown))
    with project({"capt_hints.py": hints_module()}, ["capt_hints"]):
        module = importlib.import_module("capt_hints")
        for name, _, shown in UNMAPPABLE_HINTS:
            spec_refuses(getattr(module, name), unmappable(name, shown))


def test_a_decimal_return_hint_is_refused_by_name():
    with project({"capt_hints.py": hints_module()}, ["capt_hints"]):
        module = importlib.import_module("capt_hints")
        for name, _, shown in DECIMAL_HINTS:
            spec_refuses(getattr(module, name), DECIMAL_HINT.format(shown=shown, name=name))


def test_a_return_hint_with_a_child_a_column_cannot_hold_is_refused_by_name():
    with project({"capt_hints.py": hints_module()}, ["capt_hints"]):
        module = importlib.import_module("capt_hints")
        for name, _, shown, child in NESTED_HINTS:
            spec_refuses(getattr(module, name), NESTED_HINT.format(shown=shown, name=name, child=child, carried=CARRIED))


def test_a_typed_dict_return_hint_with_optional_keys_is_refused_by_name():
    with project({"capt_hints.py": hints_module()}, ["capt_hints"]):
        module = importlib.import_module("capt_hints")
        for name, _, shown, cls, keys in OPTIONAL_KEY_HINTS:
            spec_refuses(getattr(module, name), OPTIONAL_KEYS.format(shown=shown, name=name, cls=cls, keys=keys))


def test_typed_dict_keys_are_judged_by_their_qualifiers_when_annotations_are_strings():
    """Under `from __future__ import annotations` the class itself cannot see
    `NotRequired` or `Required`: a NotRequired key is still optional, and a
    Required key of a total=False class is still required."""
    spec_refuses(future.partial, OPTIONAL_KEYS.format(
        shown="<class 'fixtures.udfs.future.Partial'>", name="partial", cls="Partial", keys=["b"]))
    assert future.all_required.spec().return_type == "struct<a: int64, b: large_string>"


def test_unresolvable_hints_are_refused():
    spec_refuses(
        scalars.hint_unresolvable,
        "UDF_CAPTURE_UNSUPPORTED: the type hints of `hint_unresolvable()` cannot be resolved: "
        "NameError: name 'NoSuchName' is not defined",
    )


def test_return_dtype_wins_over_a_hint():
    """return_dtype= is used when the function has no hint, and in place of a
    hint of another type."""
    assert scalars.narrow.spec().return_type == "int32"
    assert scalars.declared_over_str.spec().return_type == "int64"


# ---- the read set -------------------------------------------------------------------


def read_set(u):
    return u.spec().read_set


def test_read_set_from_columns():
    assert read_set(rows.declared_columns) == ("a", "b")
    assert read_set(rows.frame_columns) == ("x", "y")


def test_empty_read_sets_are_sets():
    assert read_set(rows.declared_empty) == ()
    assert read_set(rows.typed_nothing) == ()
    assert read_set(rows.dataclass_empty) == ()
    assert read_set(rows.frame_empty) == ()
    assert read_set(rows.reads_nothing) == ()
    assert rows.reads_nothing.expr() == UdfCall(rows.reads_nothing.spec(), ())


def test_read_set_ascends_by_utf8_bytes():
    assert read_set(rows.declared_non_ascii) == ("a", "z", "é")
    assert read_set(rows.non_ascii) == ("a", "z", "é", "日本", "😀")
    assert [n.encode("utf-8") for n in read_set(rows.non_ascii)] == sorted(n.encode("utf-8") for n in read_set(rows.non_ascii))


def test_read_set_from_a_typed_dict():
    assert read_set(rows.typed) == ("a", "b")
    assert read_set(rows.typed_wider) == ("a", "b", "c")
    assert read_set(rows.frame_typed) == ("a", "b")


def test_read_set_from_a_dataclass():
    assert read_set(rows.dataclass_row) == ("x", "y")
    assert read_set(rows.frame_dataclass) == ("x", "y")


def test_columns_and_an_annotation_must_name_one_set():
    assert read_set(rows.typed_and_columns) == ("a", "b")
    spec_refuses(
        rows.typed_disagrees,
        "UDF_READ_SET_INVALID: columns= and the annotation of `r` in `typed_disagrees()` name different sets: "
        "columns= has ['a', 'c'], Pair has ['a', 'b']; give one of them, or make them equal",
    )
    spec_refuses(
        rows.dataclass_disagrees,
        "UDF_READ_SET_INVALID: columns= and the annotation of `r` in `dataclass_disagrees()` name different sets: "
        "columns= has ['y'], Point has ['x', 'y']; give one of them, or make them equal",
    )
    spec_refuses(
        rows.frame_disagrees,
        "UDF_READ_SET_INVALID: columns= and the annotation of `df` in `frame_disagrees()` name different sets: "
        "columns= has ['a', 'q'], Pair has ['a', 'b']; give one of them, or make them equal",
    )


def test_a_row_type_on_a_function_that_reads_argument_expressions_is_refused():
    spec_refuses(
        rows.scalar_with_row_type,
        "UDF_READ_SET_INVALID: `scalar_with_row_type()` is a scalar function and reads its argument expressions, "
        "but its parameter `x` is annotated with the row type `Point`; only a row or map_batches_frame function "
        "reads a set of columns",
    )


def test_a_frame_without_columns_or_annotation_is_refused():
    spec_refuses(
        rows.frame_unbounded,
        "UDF_READ_SET_REQUIRED: the map_batches_frame function `frame_unbounded()` has no read set. "
        "Pass columns=[...] to udf, naming every column it reads, or annotate its first parameter "
        "with a TypedDict or dataclass of those columns",
    )


def test_an_annotation_that_is_not_a_row_type_declares_nothing():
    assert read_set(rows.annotated_other) == ("a",)


def test_scan_of_bounded_reads():
    assert read_set(rows.attribute) == ("a", "b")
    assert read_set(rows.subscript) == ("a", "b")
    assert read_set(rows.repeated) == ("a",)
    assert read_set(rows.through_field) == ("a", "b", "text")
    assert read_set(rows.many_locals) == ("first", "fourth", "second", "third")


def test_scan_counts_every_branch():
    assert read_set(rows.branches) == ("flag", "taken", "untaken")
    assert read_set(rows.only_untaken) == ("kind", "late")


def test_scan_handles_extended_arguments():
    names = [f"c{i}" for i in range(300)]
    body = "def wide(r):\n    return " + " + ".join(f"r.c{i}" for i in range(300)) + "\n"
    with project({"capt_wide.py": "from komira._capture import udf\n\n" + "@udf(kind='row', return_dtype='int64')\n" + body}, ["capt_wide"]):
        module = importlib.import_module("capt_wide")
        assert module.wide.spec().read_set == tuple(sorted(names, key=lambda n: n.encode("utf-8")))


WHOLE = 'the row `r` is used as a whole, not as r.field or r["field"]'
ASSIGNED = "the row `r` is assigned, deleted or kept under another name"
NESTED = "the row `r` is used by a nested function"
COMPREHENSION = "it contains a comprehension or generator expression, which may read the row"
SERIES = "is also an attribute of a pandas Series, so it may not name a column"


def required(name, problem):
    return (
        f"UDF_READ_SET_REQUIRED: cannot tell which columns the row function `{name}()` reads: {problem}. "
        "Pass columns=[...] to udf, naming every column it reads"
    )


def test_scan_refuses_every_unbounded_use_of_the_row():
    for u, problem in (
        (rows.passed_on, WHOLE),
        (rows.passed_with_other, WHOLE),
        (rows.iterated_loop, WHOLE),
        (rows.unpacked, WHOLE),
        (rows.variable_key, WHOLE),
        (rows.computed_getattr, WHOLE),
        (rows.stored, WHOLE),
        (rows.stored_after_store, WHOLE),
        (rows.membership, WHOLE),
        (rows.item_assignment, WHOLE),
        (rows.attribute_assignment, WHOLE),
        (rows.item_deletion, WHOLE),
        (rows.sliced, WHOLE),
        (rows.integer_key, WHOLE),
        (rows.merged_branches, WHOLE),
        (rows.returns_row, WHOLE),
        (rows.reassigned, ASSIGNED),
        (rows.deleted, ASSIGNED),
        (rows.in_lambda, NESTED),
        (rows.in_nested_def, NESTED),
        (rows.iterated, COMPREHENSION),
        (rows.in_comprehension, COMPREHENSION),
        (rows.in_generator, COMPREHENSION),
        (rows.series_name, f"`r.name` {SERIES}"),
        (rows.series_index, f"`r.index` {SERIES}"),
        (rows.series_values, f"`r.values` {SERIES}"),
        (rows.series_get, "`r.get(...)` calls a method on the row"),
        (rows.method_call, "`r.compute(...)` calls a method on the row"),
        (rows.dunder, "`r.__class__` is a special attribute, not a column"),
        (rows.reads_locals, "it calls locals(), which can read the row by any name"),
        (rows.reads_vars, "it calls vars(), which can read the row by any name"),
        (rows.reads_frame, "it calls _getframe(), whose frame holds the row"),
        (rows.reads_current_frame, "it calls currentframe(), whose frame holds the row"),
        (rows.no_parameter, "it takes no parameter to receive the row"),
    ):
        spec_refuses(u, required(u.__name__, problem))


def test_declared_columns_bound_an_otherwise_unbounded_row():
    assert read_set(rows.declared_columns) == ("a", "b")
    assert rows.declared_columns(types.SimpleNamespace()) == 1


def test_a_row_call_passes_its_read_set():
    assert rows.attribute.expr() == UdfCall(rows.attribute.spec(), (ColRef("a"), ColRef("b")))
    assert rows.non_ascii.expr().args == tuple(ColRef(n) for n in ("a", "z", "é", "日本", "😀"))
    refuses(
        lambda: rows.attribute.expr(ColRef("a")),
        ValueError,
        "the row function `attribute()` takes no arguments: it is passed the columns of its read set",
    )


# ---- expressions ----------------------------------------------------------------------


def test_a_column_call_takes_expressions_and_literals():
    call = scalars.double.expr(ColRef("x"))
    assert call == UdfCall(scalars.double.spec(), (ColRef("x"),))
    assert scalars.double.expr(3).args == (Lit(3),)
    assert scalars.batch.expr(ColRef("v"), 2.5).args == (ColRef("v"), Lit(2.5))
    refuses(scalars.double.expr, ValueError, "UdfCall of double takes at least one argument")


def test_a_frame_function_has_no_expression():
    refuses(
        rows.frame_columns.expr,
        UnsupportedOperation,
        "`frame_columns()` is a map_batches_frame function and has no expression form; "
        "apply it to a plan with komira._ops.map_batches(plan, udf_spec)",
    )


# ---- where the code lives ----------------------------------------------------------------


REFUSAL_TAIL = ". A UDF is a function defined at the top level of a .py module: move it to a module and import it"


def test_functions_that_cannot_be_captured_are_refused():
    spec_refuses(scalars.as_lambda, "UDF_CAPTURE_UNSUPPORTED: `<lambda>` is a lambda" + REFUSAL_TAIL)
    spec_refuses(udf(scalars.lam, return_dtype="int64"), "UDF_CAPTURE_UNSUPPORTED: `<lambda>` is a lambda" + REFUSAL_TAIL)
    spec_refuses(
        udf(scalars.NESTED),
        "UDF_CAPTURE_UNSUPPORTED: `make_nested.<locals>.inner` is nested inside another function" + REFUSAL_TAIL,
    )
    spec_refuses(udf(scalars.METHOD), "UDF_CAPTURE_UNSUPPORTED: `Holder.method` is defined inside a class" + REFUSAL_TAIL)
    spec_refuses(
        scalars.REPLACED,
        "UDF_CAPTURE_UNSUPPORTED: `replaced` is not what `fixtures.udfs.scalars.replaced` names" + REFUSAL_TAIL,
    )
    spec_refuses(
        udf(scalars.INSTANCE),
        "UDF_CAPTURE_UNSUPPORTED: `Callable_` is a Callable_, not a plain function" + REFUSAL_TAIL,
    )
    spec_refuses(
        udf(len),
        "UDF_CAPTURE_UNSUPPORTED: `len` is a builtin_function_or_method, not a plain function" + REFUSAL_TAIL,
    )


def test_a_function_of_main_is_refused():
    def f(x: int) -> int:
        return x

    f.__qualname__ = "f"
    f.__module__ = "__main__"
    spec_refuses(udf(f), "UDF_CAPTURE_UNSUPPORTED: `f` is defined in __main__" + REFUSAL_TAIL)


def test_a_function_without_a_source_file_is_refused():
    module = types.ModuleType("capt_nofile")
    sys.modules["capt_nofile"] = module
    try:
        exec("def f(x: int) -> int:\n    return x\n", module.__dict__)
        spec_refuses(
            udf(module.f),
            "UDF_CAPTURE_UNSUPPORTED: `f` is defined in module `capt_nofile`, which has no .py source file" + REFUSAL_TAIL,
        )
    finally:
        del sys.modules["capt_nofile"]

    def g(x: int) -> int:
        return x

    g.__qualname__ = "g"
    g.__module__ = "capt_not_imported"
    spec_refuses(
        udf(g),
        "UDF_CAPTURE_UNSUPPORTED: `g` is defined in module `capt_not_imported`, which has no .py source file" + REFUSAL_TAIL,
    )


# ---- the bundle ------------------------------------------------------------------------------


def open_zip(data):
    return zipfile.ZipFile(io.BytesIO(data))


def test_a_project_module_is_a_bundle_with_its_parents():
    u = scalars.double
    spec = u.spec()
    assert spec.form == "bundle" and spec.entry == "fixtures.udfs.scalars:double"
    data = u.bundle_bytes()
    assert spec.code == (("bundle", hashlib.sha256(data).digest()),)
    z = open_zip(data)
    assert z.namelist() == ["fixtures/", "fixtures/udfs/__init__.py", "fixtures/udfs/scalars.py"]
    assert z.read("fixtures/udfs/scalars.py") == source_of(scalars)
    assert z.read("fixtures/udfs/__init__.py") == source_of(sys.modules["fixtures.udfs"])
    assert z.read("fixtures/") == b""
    assert u.code_objects() == {hashlib.sha256(data).digest(): data}


def test_the_bundle_is_stored_with_fixed_metadata():
    z = open_zip(scalars.double.bundle_bytes())
    for info in z.infolist():
        assert info.compress_type == zipfile.ZIP_STORED
        assert info.date_time == (2026, 9, 1, 0, 0, 0)
        assert info.create_system == 3
        assert info.compress_size == info.file_size
        if info.filename.endswith("/"):
            assert info.external_attr == (0o40755 << 16) | 0x10
        else:
            assert info.external_attr == 0o100644 << 16
    assert z.namelist() == sorted(z.namelist(), key=lambda n: n.encode("utf-8"))


def test_the_bundle_is_the_same_bytes_every_time():
    first = udf(scalars.plain).bundle_bytes()
    second = udf(scalars.plain).bundle_bytes()
    assert first == second
    assert scalars.double.bundle_bytes() == scalars.halve.bundle_bytes()
    assert scalars.double.spec().code == scalars.halve.spec().code
    assert scalars.double.spec().code != rows.attribute.spec().code


def test_a_source_change_changes_the_digest():
    source = "def f(x: int) -> int:\n    return x\n"
    with project({"capt_change.py": source}, ["capt_change"]) as root:
        module = importlib.import_module("capt_change")
        before = udf(module.f).spec()
        with open(os.path.join(root, "capt_change.py"), "w", encoding="utf-8") as f:
            f.write(source + "# edited\n")
        after = udf(module.f).spec()
        assert before.code != after.code
        assert before.code[0][1] == hashlib.sha256(
            make_expected_zip({"capt_change.py": source.encode("utf-8")})
        ).digest()
        assert after.code[0][1] == hashlib.sha256(
            make_expected_zip({"capt_change.py": (source + "# edited\n").encode("utf-8")})
        ).digest()


def make_expected_zip(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2026, 9, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            z.writestr(info, files[name])
    return buf.getvalue()


def test_a_top_level_module_bundles_alone():
    source = "def f(x: int) -> int:\n    return x\n"
    with project({"capt_top.py": source}, ["capt_top"]):
        module = importlib.import_module("capt_top")
        u = udf(module.f)
        assert open_zip(u.bundle_bytes()).namelist() == ["capt_top.py"]
        assert u.spec().entry == "capt_top:f"


def test_a_package_init_function_bundles_as_init():
    files = {"capt_pkg/__init__.py": "def f(x: int) -> int:\n    return x\n"}
    with project(files, ["capt_pkg"]):
        module = importlib.import_module("capt_pkg")
        u = udf(module.f)
        assert open_zip(u.bundle_bytes()).namelist() == ["capt_pkg/__init__.py"]
        assert u.spec().entry == "capt_pkg:f"


def test_namespace_parents_are_directory_entries_and_the_zip_imports():
    files = {
        "capt_ns/inner/__init__.py": "",
        "capt_ns/inner/leaf.py": "def f(x: int) -> int:\n    return x\n",
    }
    with project(files, ["capt_ns"]) as root:
        module = importlib.import_module("capt_ns.inner.leaf")
        u = udf(module.f)
        data = u.bundle_bytes()
        assert open_zip(data).namelist() == ["capt_ns/", "capt_ns/inner/__init__.py", "capt_ns/inner/leaf.py"]
        archive = os.path.join(root, "bundle.zip")
        with open(archive, "wb") as f:
            f.write(data)
        assert zipimport.zipimporter(archive).find_spec("capt_ns").submodule_search_locations
        inner = zipimport.zipimporter(archive + "/capt_ns/inner")
        assert inner.get_source("leaf") == files["capt_ns/inner/leaf.py"]


# ---- package or bundle ------------------------------------------------------------------------


def dist_files(name, module_text):
    return {
        f"{name}.py": module_text,
        f"{name}-1.0.dist-info/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: 1.0\n",
        f"{name}-1.0.dist-info/top_level.txt": f"{name}\n",
    }


def test_a_module_of_an_installed_distribution_is_a_package():
    text = "def f(x: int) -> int:\n    return x\n"
    files = {f"site-packages/{k}": v for k, v in dist_files("capt_installed", text).items()}
    with project(files, ["capt_installed"], path_dirs=("site-packages",)):
        module = importlib.import_module("capt_installed")
        u = udf(module.f)
        spec = u.spec()
        assert spec.form == "package" and spec.code == () and spec.entry == "capt_installed:f"
        assert u.code_objects() == {}
        assert u.bundle_bytes() is None


def test_a_module_in_site_packages_without_a_distribution_is_a_bundle():
    files = {"site-packages/capt_orphan.py": "def f(x: int) -> int:\n    return x\n"}
    with project(files, ["capt_orphan"], path_dirs=("site-packages",)):
        module = importlib.import_module("capt_orphan")
        assert udf(module.f).spec().form == "bundle"


def test_a_module_of_a_distribution_outside_site_packages_is_a_bundle():
    text = "def f(x: int) -> int:\n    return x\n"
    files = {f"src/{k}": v for k, v in dist_files("capt_editable", text).items()}
    with project(files, ["capt_editable"], path_dirs=("src",)):
        module = importlib.import_module("capt_editable")
        assert udf(module.f).spec().form == "bundle"


# ---- the code root --------------------------------------------------------------------------------


def test_write_code_writes_the_bundle_by_digest():
    u = scalars.double
    with tempfile.TemporaryDirectory() as scratch:
        code_root = os.path.join(scratch, "nested", "code")
        capture.write_code(code_root, u)
        digest = u.spec().code[0][1]
        path = os.path.join(code_root, digest.hex())
        assert os.listdir(code_root) == [digest.hex()]
        with open(path, "rb") as f:
            assert f.read() == u.bundle_bytes()
        before = os.stat(path)
        capture.write_code(code_root, u)
        capture.write_code(code_root, scalars.halve)
        after = os.stat(path)
        assert os.listdir(code_root) == [digest.hex()]
        assert (before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns)


def test_write_code_refuses_a_file_with_other_bytes():
    u = scalars.double
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, u.spec().code[0][1].hex())
        with open(path, "wb") as f:
            f.write(b"other")
        refuses(lambda: capture.write_code(scratch, u), KomiraError, f"the code object {path} already exists with other bytes")
        with open(path, "rb") as f:
            assert f.read() == b"other"
        assert os.listdir(scratch) == [os.path.basename(path)]


def test_write_code_writes_nothing_for_a_package():
    text = "def f(x: int) -> int:\n    return x\n"
    files = {f"site-packages/{k}": v for k, v in dist_files("capt_installed_two", text).items()}
    with project(files, ["capt_installed_two"], path_dirs=("site-packages",)):
        module = importlib.import_module("capt_installed_two")
        with tempfile.TemporaryDirectory() as scratch:
            code_root = os.path.join(scratch, "code")
            capture.write_code(code_root, udf(module.f))
            assert os.listdir(code_root) == []


def test_write_code_propagates_a_failed_write():
    with tempfile.TemporaryDirectory() as scratch:
        blocker = os.path.join(scratch, "file")
        with open(blocker, "wb") as f:
            f.write(b"x")
        e = raised(lambda: capture.write_code(os.path.join(blocker, "code"), scalars.double))
        assert isinstance(e, OSError)


def test_write_code_removes_its_temporary_file_when_the_move_fails():
    def failing(source, target):
        raise OSError("replace failed")

    real = os.replace
    os.replace = failing
    try:
        with tempfile.TemporaryDirectory() as scratch:
            e = raised(lambda: capture.write_code(scratch, scalars.double))
            assert type(e) is OSError and e.args == ("replace failed",), repr(e)
            assert os.listdir(scratch) == []
    finally:
        os.replace = real


# ---- no ctypes -----------------------------------------------------------------------------------------


def test_the_capture_package_does_not_use_ctypes():
    package = os.path.dirname(capture.__file__)
    sources = sorted(n for n in os.listdir(package) if n.endswith(".py"))
    assert "_decorator.py" in sources and "_code.py" in sources
    for name in sources:
        with open(os.path.join(package, name), encoding="utf-8") as f:
            tree = ast.parse(f.read(), name)
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                assert not any(a.name.split(".")[0] == "ctypes" for a in node.names), name
            elif isinstance(node, ast.ImportFrom):
                assert (node.module or "").split(".")[0] != "ctypes", name
            elif isinstance(node, ast.Constant) and isinstance(node.value, str):
                assert node.value.split(".")[0] != "ctypes", name


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("capture: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
