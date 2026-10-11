# =============================================================================
# src/kci_validate/tests/test_readme_tool.mojo
#   The README examples tool kci runs for an installed README
#   (readme_installed.mojo): where kci looks for it (beside its own
#   executable), each way it is refused by name (no path, a missing file, a
#   file that does not run), and the tool's own refusals passed on in its
#   words. The real tool, the target bin/kci/BUCK ships, is this test's data.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_runtime_paths import data_path, executable_path, test_tmpdir

from kci_validate import README_TOOL_NAME, map_report_file, readme_program_of, shipped_readme_tool

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
