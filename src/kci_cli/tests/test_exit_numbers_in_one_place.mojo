# =============================================================================
# src/kci_cli/tests/test_exit_numbers_in_one_place.mojo -- kci's exit numbers
#   are kci_api's alone: no kci_cli source and not bin/kci's main may
#   spell `comptime EXIT_`, `return <digit>` or `exit(<digit>`. Every exit
#   number comes from kci_api's table, so a renumbering is one place.
# =============================================================================
#
# The sources are staged as test data (BUCK): a new source file must be
# added there too.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal


def _offences(name: String) raises -> List[String]:
    var out = List[String]()
    var lines = Path(name).read_text().split(String("\n"))
    for i in range(len(lines)):
        var l = String(String(lines[i]).strip())
        if l.startswith(String("#")):
            continue
        var bad = l.find(String("comptime EXIT_")) >= 0
        for d in range(10):
            if l.find(String("return ") + String(d)) >= 0 or l.find(String("exit(") + String(d)) >= 0:
                bad = True
        if bad:
            out.append(name + String(":") + String(i + 1) + String(": ") + l)
    return out^


def test_no_exit_number_outside_kci_api() raises:
    var all = List[String]()
    for f in [
        "kci_cli_args.mojo",
        "kci_cli_deploy_step.mojo",
        "kci_cli_dispatch.mojo",
        "kci_cli_library_verbs.mojo",
        "kci_cli_recorder.mojo",
        "kci_cli_seam.mojo",
        "kci_cli_start_checks.mojo",
        "kci_cli_summary.mojo",
        "bin_kci_main.mojo",
    ]:
        all.extend(_offences(String(f)))
    if len(all) > 0:
        raise Error(String("an exit number spelled outside kci_api: ") + all[0])
    assert_equal(len(all), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
