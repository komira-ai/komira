"""Every public name of the package has an entry in the changelog.

The public names are those of `komira` and `komira.pl`: each module's
`__all__` (a name starting with `_` is not one), and for each public class
every attribute `vars(cls)` defines that does not start with `_`. A name has
an entry when its last part (`aggregate` of `komira.DataFrame.aggregate`) is
an identifier inside a backticked code span of `python/CHANGELOG.md` or of a
file of `python/changelog.d/`, which together are what the changelog says
(python/CHANGELOG.md, how a release assembles them).

- every public name has an entry; the failure lists the names without one,
  sorted, and nothing else;
- the names found include the names the package is known to define, so an
  empty or wrong enumeration cannot pass for "nothing is missing";
- on a synthetic changelog that leaves one name out the finding is exactly
  that name, with the message the failure gives; a name left out among others
  is listed with them in order; a name only in prose, a name that is only part
  of a longer identifier, and a name in a code span of another file are each
  told apart from a name in a code span of the changelog itself or of a
  fragment, whatever the span's length and wherever it breaks across lines;
- the inputs are read from the tree the rule passes: CHANGELOG.md and every
  file of `changelog.d/`.

    test_changelog_names.py <dir>

`<dir>` holds `CHANGELOG.md` and `changelog.d/` (python/BUCK, `:changelog`,
the sub-target `sources`).
"""

import os
import re
import sys
import tempfile

import komira
import komira.pl

MODULES = (komira, komira.pl)

# A code span: a run of backticks, the text up to the next run of exactly as
# many, as Markdown reads it (fenced blocks are such spans of three).
SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", re.DOTALL)
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def public_names(modules):
    """The qualified public names of `modules`, as `module.Name` and
    `module.Class.attribute`, each with the part the changelog must name."""
    found = {}
    for module in modules:
        for name in module.__all__:
            if name.startswith("_"):
                continue
            found[f"{module.__name__}.{name}"] = name
            member = getattr(module, name)
            if isinstance(member, type):
                for attribute in vars(member):
                    if not attribute.startswith("_"):
                        found[f"{module.__name__}.{name}.{attribute}"] = attribute
    return found


def identifiers_in_code_spans(text):
    """The identifiers inside the code spans of `text`."""
    found = set()
    for span in SPAN.finditer(text):
        found.update(IDENTIFIER.findall(span.group(2)))
    return found


def missing_names(names, text):
    """The qualified names of `names` ({qualified: last part}) whose last part
    is no identifier inside a code span of `text`, sorted."""
    named = identifiers_in_code_spans(text)
    return sorted(qualified for qualified, part in names.items() if part not in named)


def message(missing):
    """The failure for the names without an entry."""
    return (
        "{} public name(s) have no entry in python/CHANGELOG.md or python/changelog.d/: each needs to be an "
        "identifier inside a backticked code span of an entry (add it to the fragment of the change that "
        "made it public): {}".format(len(missing), ", ".join(missing))
    )


def changelog_text(tree):
    """CHANGELOG.md and every file of changelog.d/ of `tree`, as one text."""
    parts = []
    with open(os.path.join(tree, "CHANGELOG.md"), encoding="utf-8") as f:
        parts.append(f.read())
    fragments = os.path.join(tree, "changelog.d")
    if os.path.isdir(fragments):
        for name in sorted(os.listdir(fragments)):
            with open(os.path.join(fragments, name), encoding="utf-8") as f:
                parts.append(f.read())
    return "\n\n".join(parts)


NAMES = public_names(MODULES)


def test_every_public_name_has_an_entry(tree):
    missing = missing_names(NAMES, changelog_text(tree))
    assert not missing, message(missing)


def test_the_names_found_include_the_known_ones():
    for name in [
        "komira.Session",
        "komira.KomiraError",
        "komira.read_parquet",
        "komira.DataFrame.groupby",
        "komira.DataFrame.aggregate",
        "komira.Series.isin",
        "komira.GroupBy.agg",
        "komira.Result.to_arrow",
        "komira.pl.LazyFrame.collect",
        "komira.pl.Expr.alias",
        "komira.pl.ExprStringNameSpace.contains",
        "komira.pl.col",
    ]:
        assert name in NAMES, f"the enumeration of public names does not find {name}"
    assert "komira.__version__" not in NAMES
    assert all(not part.startswith("_") for part in NAMES.values())


def test_one_name_left_out_is_the_whole_finding():
    # a name whose last part no other name has, so that leaving its span out leaves exactly it out
    parts = list(NAMES.values())
    left_out = next(q for q, p in NAMES.items() if parts.count(p) == 1)
    spans = " ".join("`{}`".format(p) for q, p in NAMES.items() if q != left_out)
    assert missing_names(NAMES, spans) == [left_out]
    assert message(missing_names(NAMES, spans)) == (
        "1 public name(s) have no entry in python/CHANGELOG.md or python/changelog.d/: each needs to be an "
        "identifier inside a backticked code span of an entry (add it to the fragment of the change that "
        "made it public): " + left_out
    )
    assert missing_names(NAMES, " ".join("`{}`".format(p) for p in parts)) == []


def test_names_left_out_are_listed_sorted_with_the_message():
    names = {"komira.Zed": "Zed", "komira.Alpha": "Alpha", "komira.Mid": "Mid", "komira.Mid.run": "run"}
    assert missing_names(names, "`Mid`") == ["komira.Alpha", "komira.Mid.run", "komira.Zed"]
    assert message(missing_names(names, "`Mid`")) == (
        "3 public name(s) have no entry in python/CHANGELOG.md or python/changelog.d/: each needs to be an "
        "identifier inside a backticked code span of an entry (add it to the fragment of the change that "
        "made it public): komira.Alpha, komira.Mid.run, komira.Zed"
    )
    assert missing_names(names, "`Alpha` `Mid` `run` `Zed`") == []
    assert missing_names({}, "") == []


def test_a_name_in_prose_or_inside_a_longer_identifier_is_not_an_entry():
    names = {"komira.pl.Expr.alias": "alias"}
    assert missing_names(names, "alias is described in prose, and also (alias) in parentheses") == ["komira.pl.Expr.alias"]
    assert missing_names(names, "`aliases` and `realias` and `alias2` and `my_alias`") == ["komira.pl.Expr.alias"]
    assert missing_names(names, "an unclosed `alias span") == ["komira.pl.Expr.alias"]
    assert missing_names(names, "`kpl.col('x').alias('y')`") == []
    assert missing_names(names, "`.alias(name)`") == []


def test_a_code_span_may_be_long_or_break_across_lines():
    names = {"komira.DataFrame.groupby": "groupby", "komira.Series.dtype": "dtype"}
    assert missing_names(names, "- `df.groupby(by, *, sort=True,\n  dropna=True)` and `s.dtype`") == []
    assert missing_names(names, "``a `groupby` with a backtick`` and ```\ndtype\n```") == []
    assert missing_names(names, "`groupby` ``dtype`") == ["komira.Series.dtype"]


def test_the_inputs_are_the_changelog_and_every_fragment_of_the_tree():
    with tempfile.TemporaryDirectory() as tree:
        with open(os.path.join(tree, "CHANGELOG.md"), "w", encoding="utf-8") as f:
            f.write("# Changelog\n\n## 0.1.1\n\n- **A.** `kept`\n")
        assert identifiers_in_code_spans(changelog_text(tree)) == {"kept"}
        os.mkdir(os.path.join(tree, "changelog.d"))
        for name, text in [("b.md", "- **B.** `second`\n"), ("a.md", "- **A.** `first`\n")]:
            with open(os.path.join(tree, "changelog.d", name), "w", encoding="utf-8") as f:
                f.write(text)
        assert identifiers_in_code_spans(changelog_text(tree)) == {"kept", "first", "second"}
        names = {"komira.One": "first", "komira.Two": "second", "komira.Three": "third"}
        assert missing_names(names, changelog_text(tree)) == ["komira.Three"]


def main(args):
    tree = os.path.abspath(args[0])
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f(tree) if f.__code__.co_argcount else f()
    print("changelog_names: {} tests passed, {} public names have an entry".format(len(tests), len(NAMES)))


if __name__ == "__main__":
    main(sys.argv[1:])
