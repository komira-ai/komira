"""komira._ops cannot turn a node into SQL text, and neither can komira.pl,
the polars-shaped skin built on it.

Four checks, each with a case that shows it fails when the thing it looks for
is present (the last two also read komira.pl: its modules, classes and an
expression have no name with "sql" in it, and no string constant of its
sources, other than a docstring, holds an upper-case SQL keyword):

- the text of every node, support type and plan node is the dataclass repr;
- no name on any class or module of komira._ops contains "sql";
- no module of the komira package has "sql" in its name;
- no string constant in the source of komira._ops, other than a docstring,
  holds an upper-case SQL keyword.

    test_ops_no_sql.py
"""

import ast
import importlib
import inspect
import os
import pkgutil
import re

import komira
from komira import _ops
from komira._ops import _dtype
from komira._ops import (
    EXPR_NODES,
    PLAN_NODES,
    Agg,
    Aggregate,
    Alias,
    Arith,
    BoolOp,
    Cast,
    ColRef,
    Compare,
    Distinct,
    Extract,
    Field,
    Filter,
    Frame,
    Join,
    Limit,
    Lit,
    MapBatches,
    MathFn,
    MathFn2,
    Project,
    Regexp,
    Scan,
    Sort,
    SortKey,
    StringFn,
    StringFnN,
    StringOp,
    StructField,
    Substring,
    TopN,
    UdfCall,
    Unnest,
    UdfSpec,
    Unary,
    Union,
    When,
    WindowExpr,
    Write,
    WriteTarget,
)

SQL_KEYWORDS = re.compile(r"\b(SELECT|FROM|WHERE|GROUP BY|ORDER BY|CASE WHEN|LIMIT|JOIN)\b")


# ---------------------------------------------------------------------------
# The checks themselves, each a function so a case can be given to it
# ---------------------------------------------------------------------------


def text_problems(obj):
    """What is wrong with the text of `obj`, empty when str is the dataclass repr."""
    problems = []
    name = type(obj).__qualname__
    if str(obj) != repr(obj):
        problems.append(f"{name}: str differs from repr")
    if not repr(obj).startswith(name + "("):
        problems.append(f"{name}: repr does not start with {name}(")
    if SQL_KEYWORDS.search(repr(obj)):
        problems.append(f"{name}: repr holds an SQL keyword")
    return problems


def sql_names(obj):
    """The attribute names of `obj` (public and private) that contain "sql"."""
    return sorted(n for n in dir(obj) if "sql" in n.lower())


def sql_module_names(names):
    """The module names in `names` that contain "sql"."""
    return [n for n in names if "sql" in n.lower()]


def sql_strings(source):
    """The string constants of `source`, docstrings left out, that match SQL_KEYWORDS."""
    tree = ast.parse(source)
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            first = node.body[0] if node.body else None
            if (
                isinstance(first, ast.Expr)
                and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)
            ):
                docstrings.add(id(first.value))
    found = []
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and id(node) not in docstrings
            and SQL_KEYWORDS.search(node.value)
        ):
            found.append(node.value)
    return found


# ---------------------------------------------------------------------------
# One instance of everything
# ---------------------------------------------------------------------------

A = ColRef("a")
B = ColRef("b")
P = Compare("gt", A, Lit(1))
LEFT = Scan("left.parquet", "parquet", (Field("a", "int64"), Field("b", "string")))
SCALAR = UdfSpec("m.g", "scalar", "package", "m:g", (), "int64", "immutable", "propagate", "values")
FRAME = UdfSpec(
    "m.f", "map_batches_frame", "package", "m:f", (), (("x", "int64"),), "stable", "propagate", "values", ("a",)
)
RIGHT = Scan("right.parquet", "parquet", (Field("c", "int64"),))

EXPR_INSTANCES = [
    A,
    Lit(1),
    P,
    Arith("add", A, B),
    BoolOp("and", P, P),
    Unary("negate", A),
    Cast(A, "int64"),
    When(((P, A),), B),
    StringOp("contains", A, "x"),
    Regexp("like", A, "x"),
    StringFn("upper", A),
    StringFnN("concat", (A, B)),
    Substring(A, 1),
    MathFn("sqrt", A),
    MathFn2("pow", A, B),
    Extract("year", A),
    StructField(A, "f"),
    Alias(A, "n"),
    UdfCall(SCALAR, (A,)),
]

PLAN_INSTANCES = [
    LEFT,
    Filter(LEFT, P),
    Project(LEFT, (("a", A),)),
    Aggregate(LEFT, ("a",), (("n", Agg("count")),)),
    Sort(LEFT, (SortKey("a"),)),
    Limit(LEFT, 1),
    TopN(LEFT, (SortKey("a"),), 1),
    Distinct(LEFT),
    Join(LEFT, RIGHT, "inner", ("a",), ("c",)),
    Union((LEFT, LEFT)),
    Write(LEFT, WriteTarget("out.parquet", "parquet")),
    MapBatches(LEFT, FRAME),
    Unnest(LEFT, "a", True),
]

SUPPORT_INSTANCES = [
    Field("a", "int64"),
    SortKey("a"),
    Agg("sum", (A,)),
    Frame("rows", "unbounded_preceding", "current_row"),
    WindowExpr("sum", arg="a"),
    WriteTarget("out.parquet", "parquet"),
    SCALAR,
    _dtype.parse("struct<a: int64, b: timestamp[us]>"),
]


def ops_modules():
    """komira._ops and each of its submodules, imported."""
    mods = [_ops]
    for info in pkgutil.iter_modules(_ops.__path__):
        mods.append(importlib.import_module(f"komira._ops.{info.name}"))
    return mods


def ops_classes():
    """Every class defined in a module of komira._ops."""
    classes = {}
    for mod in ops_modules():
        for _, member in inspect.getmembers(mod, inspect.isclass):
            if member.__module__.startswith("komira._ops"):
                classes[member] = None
    return list(classes)


def ops_sources():
    """(file name, source text) of every .py file in komira/_ops."""
    folder = os.path.dirname(_ops.__file__)
    out = []
    for name in sorted(os.listdir(folder)):
        if name.endswith(".py"):
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                out.append((name, f.read()))
    return out


# ---------------------------------------------------------------------------
# Check 1: the text of a node is the dataclass repr
# ---------------------------------------------------------------------------


def test_instances_cover_every_expression_plan_and_support_class():
    expr = {type(x) for x in EXPR_INSTANCES}
    assert expr == set(EXPR_NODES), (expr ^ set(EXPR_NODES))
    plan = {type(x) for x in PLAN_INSTANCES}
    assert plan == set(PLAN_NODES), (plan ^ set(PLAN_NODES))
    covered = expr | plan | {type(x) for x in SUPPORT_INSTANCES}
    # Every dataclass the package defines has an instance above.
    defined = {c for c in ops_classes() if hasattr(c, "__dataclass_fields__")}
    assert covered == defined, sorted(c.__name__ for c in covered ^ defined)


def test_every_expression_node_text_is_the_dataclass_repr():
    for node in EXPR_INSTANCES:
        assert text_problems(node) == [], text_problems(node)


def test_every_plan_node_text_is_the_dataclass_repr():
    for node in PLAN_INSTANCES:
        assert text_problems(node) == [], text_problems(node)


def test_every_support_type_text_is_the_dataclass_repr():
    for node in SUPPORT_INSTANCES:
        assert text_problems(node) == [], text_problems(node)


def test_repr_of_a_nested_plan_names_its_nodes_and_holds_no_keyword():
    plan = _ops.limit(_ops.filter_(_ops.sort(LEFT, [SortKey("a")]), P), 3)
    text = repr(plan)
    assert str(plan) == text
    for name in ("Limit(", "Sort(", "Filter(", "Scan(", "Compare("):
        assert name in text, (name, text)
    assert SQL_KEYWORDS.search(text) is None, text


def test_text_check_reports_a_str_that_renders_sql():
    class Renders:
        def __str__(self):
            return "SELECT a FROM t"

        def __repr__(self):
            return type(self).__qualname__ + "()"

    name = Renders.__qualname__
    assert text_problems(Renders()) == [f"{name}: str differs from repr"]


def test_text_check_reports_a_repr_that_is_not_the_class_call():
    class Plain:
        pass

    problems = text_problems(Plain())
    name = Plain.__qualname__
    assert problems == [f"{name}: repr does not start with {name}("], problems


def test_text_check_reports_a_repr_that_holds_a_keyword():
    class Kw:
        def __repr__(self):
            return type(self).__qualname__ + "('SELECT 1')"

    name = Kw.__qualname__
    assert text_problems(Kw()) == [f"{name}: repr holds an SQL keyword"]


# ---------------------------------------------------------------------------
# Check 2: no attribute name contains "sql"
# ---------------------------------------------------------------------------


def test_the_search_finds_the_modules_and_classes_it_must_look_at():
    names = {m.__name__ for m in ops_modules()}
    assert names == {
        "komira._ops",
        "komira._ops._build",
        "komira._ops._columns",
        "komira._ops._dtype",
        "komira._ops._expr",
        "komira._ops._rel",
        "komira._ops._vocab",
        "komira._ops._walk",
    }, sorted(names)
    classes = set(ops_classes())
    for cls in list(EXPR_NODES) + list(PLAN_NODES) + [Field, SortKey, Agg, Frame, WindowExpr, WriteTarget]:
        assert cls in classes, cls.__name__


def test_no_module_of_ops_has_an_attribute_with_sql_in_its_name():
    for mod in ops_modules():
        assert sql_names(mod) == [], (mod.__name__, sql_names(mod))


def test_no_class_of_ops_has_an_attribute_with_sql_in_its_name():
    for cls in ops_classes():
        assert sql_names(cls) == [], (cls.__name__, sql_names(cls))


def test_no_instance_of_ops_has_an_attribute_with_sql_in_its_name():
    for obj in EXPR_INSTANCES + PLAN_INSTANCES + SUPPORT_INSTANCES:
        assert sql_names(obj) == [], (type(obj).__name__, sql_names(obj))


def test_no_name_exported_by_ops_has_sql_in_it():
    assert sql_module_names(_ops.__all__) == []


def test_name_check_catches_a_class_with_a_to_sql_method():
    class Node:
        def to_sql(self):
            return "SELECT 1"

    assert sql_names(Node) == ["to_sql"]
    assert sql_names(Node()) == ["to_sql"]


def test_name_check_catches_private_and_mixed_case_names():
    class Node:
        _render_SQL_text = None
        toSql = None

        def __init__(self):
            self.SQLtext = None

    assert sql_names(Node) == ["_render_SQL_text", "toSql"]
    assert sql_names(Node()) == ["SQLtext", "_render_SQL_text", "toSql"]


def test_name_check_catches_a_module_attribute():
    import types

    mod = types.ModuleType("fake")
    mod.lower_to_sql = lambda node: ""
    assert sql_names(mod) == ["lower_to_sql"]


def test_name_check_passes_a_class_without_such_a_name():
    class Node:
        def render(self):
            return "x"

    assert sql_names(Node) == []


# ---------------------------------------------------------------------------
# Check 3: no module of the package has "sql" in its name
# ---------------------------------------------------------------------------


def test_no_module_of_the_komira_package_has_sql_in_its_name():
    names = [
        info.name
        for info in pkgutil.walk_packages(komira.__path__, "komira.", onerror=lambda n: None)
    ]
    # The walk reached into komira._ops, so an empty answer is not vacuous.
    assert "komira._ops" in names and "komira._ops._build" in names, names
    assert "komira._errors" in names, names
    assert sql_module_names(names) == [], sql_module_names(names)


def test_module_name_check_catches_a_sql_module():
    names = ["komira._ops._rel", "komira._ops._to_sql", "komira.SQLgen"]
    assert sql_module_names(names) == ["komira._ops._to_sql", "komira.SQLgen"]
    assert sql_module_names([]) == []


# ---------------------------------------------------------------------------
# Check 4: no SQL keyword in a string constant of the sources
# ---------------------------------------------------------------------------


def test_the_source_scan_reads_every_file_of_the_ops_package():
    names = [name for name, _ in ops_sources()]
    assert names == [
        "__init__.py",
        "_build.py",
        "_columns.py",
        "_dtype.py",
        "_expr.py",
        "_rel.py",
        "_vocab.py",
        "_walk.py",
    ], names
    for name, source in ops_sources():
        assert source.strip(), name


def pl_sources():
    """(file name, source text) of every module of komira.pl."""
    import komira.pl

    directory = os.path.dirname(komira.pl.__file__)
    out = []
    for name in sorted(os.listdir(directory)):
        if name.endswith(".py"):
            with open(os.path.join(directory, name), encoding="utf-8") as f:
                out.append((name, f.read()))
    return out


def test_the_source_scan_reads_every_file_of_komira_pl():
    names = [name for name, _ in pl_sources()]
    assert names == [
        "__init__.py",
        "_dt.py",
        "_expr.py",
        "_frame.py",
        "_group.py",
        "_join.py",
        "_names.py",
        "_schema.py",
        "_scope.py",
        "_sink.py",
        "_types.py",
        "_window.py",
    ], names
    for name, source in pl_sources():
        assert source.strip(), name


def test_no_source_of_komira_pl_holds_a_sql_keyword_in_a_string_constant():
    for name, source in pl_sources():
        assert sql_strings(source) == [], (name, sql_strings(source))


def test_no_name_of_komira_pl_has_sql_in_it():
    import komira.pl as kpl
    from komira.pl import _expr, _frame, _names, _schema, _scope, _types

    for mod in (kpl, _expr, _frame, _names, _schema, _scope, _types):
        assert [n for n in vars(mod) if "sql" in n.lower()] == [], mod.__name__
    for cls in (kpl.LazyFrame, kpl.Expr, kpl.ExprStringNameSpace, _expr.When_, _expr.Then, _scope.Scope):
        assert sql_names(cls) == [], (cls, sql_names(cls))
    assert sql_names(kpl.col("a") + 1) == []
    assert sql_names(kpl.col("a").str) == []


def test_no_source_of_ops_holds_a_sql_keyword_in_a_string_constant():
    for name, source in ops_sources():
        assert sql_strings(source) == [], (name, sql_strings(source))


def test_source_scan_catches_a_keyword_in_a_string_assignment():
    assert sql_strings('x = "SELECT a FROM t"\n') == ["SELECT a FROM t"]


def test_source_scan_catches_each_keyword():
    for word in ("SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "CASE WHEN", "LIMIT", "JOIN"):
        assert sql_strings(f'x = "a {word} b"\n') == [f"a {word} b"], word


def test_source_scan_catches_a_keyword_in_an_f_string_and_a_call_argument():
    assert sql_strings('def f(t):\n    return f"SELECT * FROM {t}"\n') == ["SELECT * FROM ", ]
    assert sql_strings('run("WHERE x")\n') == ["WHERE x"]


def test_source_scan_leaves_docstrings_alone():
    source = (
        '"""SELECT in a module docstring."""\n'
        "class C:\n"
        '    """FROM in a class docstring."""\n'
        "    def f(self):\n"
        '        """JOIN in a function docstring."""\n'
        "        return 1\n"
    )
    assert sql_strings(source) == []


def test_source_scan_reports_a_string_that_follows_a_docstring():
    source = 'def f():\n    """Doc."""\n    return "SELECT 1"\n'
    assert sql_strings(source) == ["SELECT 1"]


def test_source_scan_matches_upper_case_whole_words_only():
    assert sql_strings('x = "select a from t"\n') == []
    assert sql_strings('x = "SELECTED"\n') == []
    assert sql_strings('x = "UNLIMITED"\n') == []
    assert sql_strings('x = "limit"\n') == []


def main():
    tests = [(name, fn) for name, fn in globals().items() if name.startswith("test_") and callable(fn)]
    for _, fn in tests:
        fn()
    print(f"ops_no_sql: {len(tests)} tests passed")


if __name__ == "__main__":
    main()
