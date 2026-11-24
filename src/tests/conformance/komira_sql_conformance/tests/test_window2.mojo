from std.testing import TestSuite, assert_true

from komira_sql_conformance.function_coverage import measure_table
from runtime_paths import read_data


def test_window() raises:
    var lines = measure_table(read_data("sql_fn_table.mojo")).split("\n")
    var out = String("")
    for i in range(390, min(585, len(lines))):
        out += String(lines[i]) + "\n"
    assert_true(False, "WINDOW 2\n<<<<\n" + out + ">>>>")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
