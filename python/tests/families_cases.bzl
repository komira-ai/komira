"""The cases of the suite's checks (families.bzl), which tools/build/ci/cases.bxl runs.

Each case gives a layout of python/tests as lists written out here and holds
the answer of the pure function that BUCK applies to the real one: the name a
test file gets, a name declared twice (two families, a family and a stanza),
and the test files no target runs. The green cases hold that a file of a
family, a stanza's `src` and an exported file are not findings; the others
hold that a file in no family directory, in a subdirectory of one, or in
`fixtures/` fails the load and is named with what to do.
"""

load("//python/tests:families.bzl", "claim", "test_target_name", "unclaimed_findings")

_FAMILIES = ["plan", "run", "duckdb", "pl", "pl_oracle"]

def _expect(out, what, got, want):
    if got != want:
        out.append("python tests: {}: got {}, wanted {}".format(what, repr(got), repr(want)))

def _says(out, what, text, parts):
    for part in parts:
        if part not in text:
            out.append("python tests: {}: '{}' does not say '{}'".format(what, text, part))

def _name_cases(out):
    _expect(out, "a family file's name", test_target_name("plan/test_frame.py"), "frame_test")
    _expect(out, "a stanza file's name", test_target_name("test_plan_expr_goldens.py"), "plan_expr_goldens_test")
    _expect(out, "a minor's suffix", test_target_name("run/test_frame_run.py", "_py311"), "frame_run_test_py311")
    _expect(out, "the protobuf edge's suffix", test_target_name("plan/test_frame_groupby.py", "_protobuf_lower_edge"), "frame_groupby_test_protobuf_lower_edge")
    _expect(out, "the directory is no part of the name", test_target_name("pl/test_pl_verbs.py"), test_target_name("test_pl_verbs.py"))

def _claim_cases(out):
    registry = {"frame_test": "plan/test_frame.py", "frame_test_py311": "plan/test_frame.py"}
    _expect(out, "a new name", claim(registry, "frame_run_test", "run/test_frame_run.py"), "")
    _expect(out, "a new suffix of a known stem", claim(registry, "frame_test_py312", "plan/test_frame.py"), "")
    two_families = claim(registry, "frame_test", "pl/test_frame.py")
    _says(out, "two families, one name", two_families, ["frame_test", "plan/test_frame.py", "pl/test_frame.py"])
    stanza_and_family = claim(registry, "frame_test_py311", "test_frame.py")
    _says(out, "a stanza and a family, one name", stanza_and_family, ["frame_test_py311", "plan/test_frame.py", "test_frame.py"])

def _unclaimed_cases(out):
    stanza = ["test_load.py", "test_session.py"]
    family = ["plan/test_frame.py", "run/test_frame_run.py", "pl_oracle/test_pl_oracle.py"]
    exported = ["test_installed.py", "test_upgrade.py"]
    everything = stanza + family + exported

    def findings(files, claimed = everything, exp = exported):
        return unclaimed_findings(files, [c for c in claimed if c not in exp], exp, _FAMILIES)

    _expect(out, "every file run or exported", findings(everything), "")
    _expect(out, "no test files", findings([]), "")

    left_out = findings(everything + ["test_orphan.py"])
    _says(out, "a file in the package's directory with no stanza", left_out, [
        "1 test file(s)",
        "test_orphan.py",
        "family directory (plan/, run/, duckdb/, pl/, pl_oracle/)",
        "a stanza in python/tests/BUCK",
    ])

    deep = findings(everything + ["plan/sub/test_deep.py"])
    _says(out, "a file one directory below a family's", deep, ["plan/sub/test_deep.py", "a subdirectory is not read"])

    elsewhere = findings(everything + ["other/test_x.py", "fixtures/test_y.py"])
    _says(out, "files in a directory of no family and in fixtures/", elsewhere, ["2 test file(s)", "fixtures/test_y.py, other/test_x.py"])

    # A file a family's glob found is a `src` (it is claimed); the same file with no
    # family directory is not.
    _expect(out, "a family file the glob found", findings(everything + ["duckdb/test_frame_duckdb.py"], claimed = everything + ["duckdb/test_frame_duckdb.py"]), "")

    # An exported file is no finding, a file that is not exported is, and
    # exporting does not hide another file.
    _expect(out, "an exported file", findings(everything + ["test_beside_modular.py"], exp = exported + ["test_beside_modular.py"]), "")
    still = findings(everything + ["test_beside_modular.py", "test_orphan.py"], exp = exported + ["test_beside_modular.py"])
    _says(out, "an export beside an orphan", still, ["1 test file(s)", "test_orphan.py"])
    if "test_beside_modular.py" in still:
        out.append("python tests: an export beside an orphan: the exported file is named in '{}'".format(still))

def python_tests_cases():
    """The failures of the suite's cases, one text each; empty when every case holds."""
    out = []
    _name_cases(out)
    _claim_cases(out)
    _unclaimed_cases(out)
    return out
