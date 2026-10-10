"""The planted tree of test 40 (README API coverage), as {path in the tree: file}.

komira_a's __init__.mojo exports ten names: three from one import line,
one under an alias (`farewell as bye`), two from a parenthesised import (a
private name and a comment in the list are skipped, and a repeated import
counts once), one from a backslash-continued import (Box), a module
(`from . import errors`), one imported by the package's own name under an
alias (`from komira_a.errors import NOT_FOUND as MISSING`), and a
`comptime` and a `def` declared there. A name in its docstring, a
commented-out import, an import from another package and a private struct
are not exports. Three exports are structs: Greeter's public methods are
hello (two overloads, one symbol), make and wave (its docstring's `def`,
`__init__`, `_secret`, `write_to`, a struct-level `comptime`, and a struct
of the same name in tests/ are not counted); Square's are area and
perimeter (the unexported Circle's method is not counted, nor is the method
of another Square in extra.mojo, outside the module the import names); Box,
whose header spans three lines, has get.

Its README uses greet, Greeter, Square, Box, MISSING, and the methods
.hello, .perimeter and .get in examples, and bye only in hidden lines.
Not uses: area only imported, inside the token squared_area, as the name
of a README-declared method, and in a ```text fence; .wave only in a
comment (a bare `wave`, a loop variable, is not the method); ANSWER and make only in a string; errors only in a triple-quoted
string; top_level only in prose, which the ledger excepts. komira_b
exports one name, has a `from .star import *` (a note) and no README;
komira_c's README has no ```mojo example; the readme tool refuses
komira_d's README (```mojo skip); komira_gen has no __init__.mojo.
src/tests holds a test-only package (komira_f_e2e, under tests/e2e, with
komira_b's exports), which the census skips: neither it nor `tests` is a row.
expect_packages.tsv, expect_symbols.tsv and expect_report.txt are the
census, exactly: 16 symbols of komira_a, 9 used (56.2%), 1 excepted, 6
undocumented. The files are exported by functional/readme_api_coverage/BUCK,
so negative/readme_api_coverage plants its defects in the same tree.
"""

_DIR = "tests//functional/readme_api_coverage:"

README_API_TREE = {
    "src/komira_a/README.md": _DIR + "a_readme.txt",
    "src/komira_a/__init__.mojo": _DIR + "a_init.txt",
    "src/komira_a/errors.mojo": _DIR + "a_errors.txt",
    "src/komira_a/extra.mojo": _DIR + "a_extra.txt",
    "src/komira_a/greet.mojo": _DIR + "a_greet.txt",
    "src/komira_a/shapes.mojo": _DIR + "a_shapes.txt",
    "src/komira_a/tests/test_greet.mojo": _DIR + "a_test.txt",
    "src/komira_b/__init__.mojo": _DIR + "b_init.txt",
    "src/komira_b/thing.mojo": _DIR + "b_thing.txt",
    "src/komira_c/README.md": _DIR + "c_readme.txt",
    "src/komira_c/__init__.mojo": _DIR + "c_init.txt",
    "src/komira_d/README.md": _DIR + "d_readme.txt",
    "src/komira_d/__init__.mojo": _DIR + "d_init.txt",
    "src/komira_d/dee.mojo": _DIR + "d_dee.txt",
    "src/komira_gen/BUCK": _DIR + "gen_buck.txt",
    "src/tests/e2e/komira_f_e2e/__init__.mojo": _DIR + "b_init.txt",
    "src/tests/e2e/komira_f_e2e/thing.mojo": _DIR + "b_thing.txt",
}

# The ledger that excepts top_level: no finding.
README_API_LEDGER = _DIR + "exceptions.tsv"
