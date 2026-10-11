# =============================================================================
# src/kci_validate/tests/test_readme_tool.mojo
#   The README examples tool kci runs for an installed README
#   (readme_installed.mojo): where kci looks for it (beside its own
#   executable), each way it is refused by name (no path, a missing file, a
#   file that does not run), and the tool's own refusals passed on in its
#   words; a report the tool fails to map is refused naming the report, and
#   fails the program's row (check_readme_program) though the program
#   passed. The real tool, the target bin/kci/BUCK ships, is this test's data.
# =============================================================================

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import ResultValidationCheck

from komira_runtime_paths import data_path, executable_path, test_tmpdir

from kci_validate import (
    README_TOOL_NAME,
    ReadmeProgram,
    check_readme_program,
    map_report_file,
    readme_program_of,
    shipped_readme_tool,
)

comptime README: String = "# x\n\n```mojo\nprint(1)\n```\n"


def _refusal(text: String, tool: String, scratch: String) -> String:
    try:
        _ = readme_program_of(text, String("x"), String("src/x/README.md"), tool, scratch)
    except e:
        return String(e)
    return String("")


def test_kci_looks_beside_its_executable() raises:
    var exe = executable_path()
    var dir = String(exe[byte = 0 : exe.rfind(String("/"))])
    assert_equal(shipped_readme_tool(), dir + String("/") + String(README_TOOL_NAME))
    assert_equal(String(README_TOOL_NAME), String("readme_examples"))


def test_a_missing_tool_is_refused_by_name() raises:
    var tmp = test_tmpdir()
    var tool = tmp + String("/kci/readme_examples")
    var why = _refusal(String(README), tool, tmp + String("/missing"))
    assert_equal(
        why,
        String("the README examples tool ") + tool + String(" is missing: kci ships it beside its executable")
        + String(" (//tools/build/readme_examples:tool, in //bin/kci:kci[runnable] and in kci's bundle);")
        + String(" copy kci's whole directory, not the executable alone"),
    )
    # the report map refuses the same way, before writing anything
    var mapped = String("")
    try:
        map_report_file(tool, tmp + String("/report"), String("x"), String("src/x/README.md"), tmp + String("/out"), tmp + String("/m"))
    except e:
        mapped = String(e)
    assert_true(mapped.startswith(String("the README examples tool ") + tool + String(" is missing")), mapped)


def test_no_tool_path_is_refused() raises:
    var why = _refusal(String(README), String(""), test_tmpdir() + String("/none"))
    assert_true(why.startswith(String("kci was given no README examples tool: kci ships `readme_examples`")), why)


def test_a_tool_that_does_not_run_is_refused() raises:
    var tmp = test_tmpdir()
    var tool = tmp + String("/not_a_program")
    var f = open(tool, "w")
    f.write_bytes(String("not a program\n").as_bytes())
    f.close()
    var why = _refusal(String(README), tool, tmp + String("/norun"))
    assert_true(why.startswith(String("the README examples tool ") + tool + String(" could not be run: ")), why)


def test_the_tools_refusals_are_passed_on_in_its_words() raises:
    var tool = data_path(String("readme_examples"))
    var tmp = test_tmpdir()
    var why = _refusal(String("x\n\n```Mojo\nprint(1)\n```\n\nSee [a](a.md).\n"), tool, tmp + String("/refused"))
    assert_equal(
        why,
        String("src/x/README.md:3: `Mojo` is not `mojo`: write ```mojo for an example that runs, or ```text for a sketch\n")
        + String("src/x/README.md:7: a.md: a relative link in a README that ships in its package; the installed copy")
        + String(" has no such file. Link an absolute URL, or an #anchor of this README"),
    )
    # and a README the tool accepts is programs
    var p = readme_program_of(String(README), String("x"), String("src/x/README.md"), tool, tmp + String("/ok"))
    assert_equal(p.examples, 1)
    assert_equal(p.file, String("readme_x.mojo"))
    assert_equal(p.modules[0].name, String("readme_x_3.mojo"))


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write_bytes(text.as_bytes())
    f.close()


def test_a_failed_map_is_refused_naming_the_report() raises:
    # The tool runs, but cannot read the report: exit 2, and kci says which
    # report and passes on the tool's words.
    var tool = data_path(String("readme_examples"))
    var tmp = test_tmpdir()
    var report = tmp + String("/no_such_report")
    var why = String("")
    try:
        map_report_file(tool, report, String("x"), String("src/x/README.md"), tmp + String("/mapped"), tmp + String("/fm"))
    except e:
        why = String(e)
    assert_true(why.startswith(String("the README examples tool ") + tool + String(" failed on ") + report + String(" (")), why)
    assert_true(why.find(String("readme-examples: cannot read ") + report) > 0, why)


def _passed_run(out_dir: String, stderr_too: Bool) raises -> ReadmeProgram:
    """A run of `readme_x.mojo` that passed, as the ENV validation leaves it
    in `out_dir`: the exit status and the raw stdout, and the raw stderr
    only when `stderr_too`."""
    makedirs(out_dir, exist_ok=True)
    _write(out_dir + String("/readme_x.exit"), String("0\n"))
    _write(out_dir + String("/readme_x.stdout"), String("readme_x validation: 1 of 1 checks passed\n"))
    if stderr_too:
        _write(out_dir + String("/readme_x.stderr"), String(""))
    var p = ReadmeProgram()
    p.display = String("src/x/README.md")
    p.installed = String(".pixi/envs/default/share/doc/x/README.md")
    p.package = String("x")
    p.file = String("readme_x.mojo")
    return p^


def test_a_report_the_tool_cannot_map_fails_the_program_row() raises:
    # The program passed, but its stderr report is missing, so the tool
    # cannot map it: the row fails, naming why, and the raw report is kept.
    var tool = data_path(String("readme_examples"))
    var tmp = test_tmpdir()
    var out_dir = tmp + String("/unmapped")
    var p = _passed_run(out_dir, False)
    var checks = List[ResultValidationCheck]()
    check_readme_program(tool, p, out_dir, String("readme_x"), tmp + String("/um"), True, checks)
    assert_equal(len(checks), 1)
    assert_false(checks[0].ok, checks[0].got)
    assert_true(
        checks[0].got.startswith(
            String("program: mojo run of an import of readme_x ran 1 checks, all passed")
            + String(" (its report names program lines, not README lines: the README examples tool ") + tool
            + String(" failed on ") + out_dir + String("/readme_x.stderr (")
        ),
        checks[0].got,
    )
    assert_equal(open(out_dir + String("/readme_x.err"), "r").read(), String(""))
    # the same run with both reports present passes: the row failed for the map alone
    var both = tmp + String("/mapped_both")
    var q = _passed_run(both, True)
    var ok = List[ResultValidationCheck]()
    check_readme_program(tool, q, both, String("readme_x"), tmp + String("/mb"), True, ok)
    assert_equal(len(ok), 1)
    assert_true(ok[0].ok, ok[0].got)
    assert_equal(open(both + String("/readme_x.out"), "r").read(), String("readme_x validation: 1 of 1 checks passed\n"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
