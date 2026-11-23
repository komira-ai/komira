"""komira._plan builds plans as nodes and never reaches SQL text.

The encoder turns node trees into plan messages; a frame is never rendered to
SQL text and re-parsed. Three checks over the source of every module of
komira._plan, each with a case that shows it fails when the thing it looks for
is present:

- the modules import only the encoder's own parts, the node tree, the errors,
  the generated plan modules and the standard library pieces they use, so they
  cannot reach libkomira (komira._native) or any SQL entry;
- no name the code uses (a variable, an attribute, an imported name) contains
  "sql";
- no string constant, other than a docstring, contains "sql" or an upper-case
  SQL keyword.

    test_plan_no_sql.py
"""

import ast
import os
import re
import sys

from komira import _plan

# What komira._plan may import: itself, the node tree, the errors, the
# generated plan modules, and these standard-library modules.
ALLOWED = ("komira._plan", "komira._ops", "komira._errors", "komira.plan.v1")
ALLOWED_STDLIB = {"__future__", "collections.abc", "datetime", "decimal"}

KEYWORDS = re.compile(r"\b(SELECT|FROM|WHERE|GROUP BY|ORDER BY|CASE WHEN|LIMIT|JOIN|UNION|OVER)\b")


def plan_sources():
    """(file name, source) of every module of komira._plan."""
    directory = os.path.dirname(_plan.__file__)
    out = []
    for name in sorted(os.listdir(directory)):
        if name.endswith(".py"):
            with open(os.path.join(directory, name), encoding="utf-8") as f:
                out.append((name, f.read()))
    return out


def imported(tree):
    """The absolute module names a module imports, relative imports resolved
    inside komira._plan."""
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            out.extend(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                parts = ["komira", "_plan"][: 3 - node.level]
                out.append(".".join(parts + ([node.module] if node.module else [])))
            else:
                out.append(node.module)
    return out


def import_problems(source):
    """The imports of `source` outside what the encoder may import."""
    bad = []
    for name in imported(ast.parse(source)):
        if name in ALLOWED_STDLIB:
            continue
        if any(name == a or name.startswith(a + ".") for a in ALLOWED):
            continue
        bad.append(name)
    return bad


def sql_names(source):
    """Every name `source` binds, reads or imports that contains "sql"."""
    found = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Name):
            names = [node.id]
        elif isinstance(node, ast.Attribute):
            names = [node.attr]
        elif isinstance(node, (ast.FunctionDef, ast.ClassDef, ast.AsyncFunctionDef)):
            names = [node.name]
        elif isinstance(node, ast.arg):
            names = [node.arg]
        elif isinstance(node, ast.alias):
            names = [node.name, node.asname or ""]
        elif isinstance(node, ast.keyword):
            names = [node.arg or ""]
        else:
            continue
        found.extend(n for n in names if "sql" in n.lower())
    return found


def sql_strings(source):
    """The string constants of `source`, docstrings left out, that contain
    "sql" or an upper-case SQL keyword."""
    tree = ast.parse(source)
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            first = node.body[0] if node.body else None
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str):
                docstrings.add(id(first.value))
    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings:
            if "sql" in node.value.lower() or KEYWORDS.search(node.value):
                found.append(node.value)
    return found


def test_the_search_reads_every_module_of_the_encoder():
    names = [n for n, _ in plan_sources()]
    for module in ("__init__.py", "_agg.py", "_expr.py", "_field.py", "_rel.py", "_scalar.py", "_source.py", "_udf.py", "_window.py", "_wire.py"):
        assert module in names, (module, names)


def test_the_encoder_imports_nothing_that_reaches_libkomira_or_sql():
    for name, source in plan_sources():
        assert import_problems(source) == [], (name, import_problems(source))


def test_the_import_check_catches_libkomira_a_sql_module_and_a_session():
    assert import_problems("from komira._native import Library") == ["komira._native"]
    assert import_problems("import sqlglot") == ["sqlglot"]
    assert import_problems("from komira import _session") == ["komira"]
    assert import_problems("from .. import _native") == ["komira"]
    assert import_problems("from ..._x import y") == ["_x"]
    assert import_problems("import ctypes") == ["ctypes"]
    assert import_problems("from ._wire import pb\nfrom komira._ops._expr import ColRef") == []


def test_no_name_in_the_encoder_contains_sql():
    for name, source in plan_sources():
        assert sql_names(source) == [], (name, sql_names(source))


def test_the_name_check_catches_a_call_a_definition_and_an_import():
    assert sql_names("lib.komira_sql_stream(ctx, text)") == ["komira_sql_stream"]
    assert sql_names("def to_sql(plan):\n    return plan") == ["to_sql"]
    assert sql_names("def render(sql_text):\n    return sql_text") == ["sql_text", "sql_text"]
    assert sql_names("from komira._ops import ToSql") == ["ToSql"]
    assert sql_names("f(dialect=1, SQL=2)") == ["SQL"]
    assert sql_names("encode(plan, sources)") == []


def test_no_string_in_the_encoder_holds_sql():
    for name, source in plan_sources():
        assert sql_strings(source) == [], (name, sql_strings(source))


def test_the_string_check_catches_sql_text_and_a_sql_entry_name():
    assert sql_strings('q = "SELECT a FROM t"') == ["SELECT a FROM t"]
    assert sql_strings('q = f"SELECT {a}"') == ["SELECT "]
    assert sql_strings('getattr(lib, "komira_sql_stream")') == ["komira_sql_stream"]
    for word in ("WHERE", "GROUP BY", "ORDER BY", "CASE WHEN", "LIMIT", "JOIN", "UNION", "OVER"):
        assert sql_strings(f'x = "a {word} b"') == [f"a {word} b"], word


def test_the_string_check_leaves_docstrings_and_lower_case_words_alone():
    source = '"""The SQL binder\'s SELECT list."""\n\ndef f():\n    """FROM here."""\n    return "a limit, a join, an order"\n'
    assert sql_strings(source) == []


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("plan_no_sql: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
