"""The suite and the test families of python/tests (BUCK).

A test of the Python package is one of three things:

- a file of a family directory (`plan/`, `run/`, `duckdb/`, `pl/`, `pl_oracle/`,
  BUCK says what each one runs with): BUCK finds it with a glob, so adding the
  test is adding the file;
- the `src` of a stanza of BUCK, for a test whose inputs no family has;
- a file the wheel's install tests of //python run (`export_file`), which is no
  test of this package.

Every `py_test` and `python_binding_test` of the package is registered through
`register` when BUCK declares it, by the name it is declared under, and
`:all` (BUCK's last target) depends on every registered name, so the check set
(ci/roots/) holds the one root `:all` for this package and a new test
changes no row.

A name declared twice, and a `test_*.py` that no target runs, fail the load of
BUCK. The logic is in the pure functions below (`claim`, `unclaimed_findings`);
families_cases.bzl holds their cases, which tools/build/ci/cases.bxl runs.
"""

def test_target_name(path, suffix = ""):
    """The name of the target that runs the test file `path` (`plan/test_frame.py`,
    `_py311` -> `frame_test_py311`): the file stem without `test_`, `_test`, then
    the suffix of the minor or protobuf edge it runs on."""
    base = path.split("/")[-1]
    stem = base[len("test_"):-len(".py")] if base.startswith("test_") and base.endswith(".py") else base
    return stem + "_test" + suffix

def claim(registry, name, src):
    """The text that says target `name` (running `src`) is declared twice when
    `registry` ({name: src}) holds it already, naming both files, or ""."""
    if name not in registry:
        return ""
    return "python/tests: target {} is declared twice, for {} and for {}: two test files of one name (the file stem without test_) cannot both run; rename one".format(
        name,
        registry[name],
        src,
    )

def register(rule, registry):
    """`rule` (`py_test`, `python_binding_test`) as BUCK declares tests with it:
    each call is recorded in `registry` ({name: src}) before the rule runs, and
    a name declared twice fails the load (see `claim`)."""

    def declare(**kwargs):
        name = kwargs["name"]
        text = claim(registry, name, kwargs.get("src", ""))
        if text:
            fail(text)
        registry[name] = kwargs.get("src", "")
        rule(**kwargs)

    return declare

def unclaimed_findings(test_files, claimed, exported, family_dirs):
    """The failure text for the files of `test_files` (every `test_*.py` under
    python/tests, as paths from the package) that run as no test, or "".

    A file runs when it is the `src` of a registered target (`claimed`, which
    holds every file of a family directory the globs found) or when
    `exported` names it (an `export_file` the wheel's install tests use). Any
    other file, in a family directory too deep for the glob, in `fixtures/` or
    in the package's own directory with no stanza, would be a test nobody
    runs."""
    left = sorted([f for f in test_files if f not in claimed and f not in exported])
    if not left:
        return ""
    return "python/tests: {} test file(s) are the src of no test target: {}. Move each into a family directory ({}), directly under it (a subdirectory is not read), or give it a stanza in python/tests/BUCK".format(
        len(left),
        ", ".join(left),
        ", ".join([d + "/" for d in family_dirs]),
    )

def require_all_run(test_files, claimed, exported, family_dirs):
    """Fails the load of BUCK with `unclaimed_findings` when it is not empty."""
    text = unclaimed_findings(test_files, claimed, exported, family_dirs)
    if text:
        fail(text)
