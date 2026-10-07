"""The planted packages of test 45 (src_layout), as package paths in the cell.

Under src/: two shipped libraries, one of them named komira_test_* and
listed in SRC_LAYOUT_SHIPPED; a name that holds `e2e` but does not end with
it (komira_e2ex_codec); and under src/tests/ one package of each kind, a
*_loopback among the e2e ones. A path outside src/ is not under the root,
so it is not checked: a tools/ package named *_e2e is no finding.
"""

SRC_LAYOUT_PACKAGES = [
    "src/komira_a",
    "src/komira_e2ex_codec",
    "src/komira_test_shipped",
    "src/tests/conformance/komira_b_conformance",
    "src/tests/e2e/komira_c_e2e",
    "src/tests/e2e/komira_d_loopback",
    "src/tests/helpers/komira_test_harness",
    "tools/komira_tool_e2e",
]

SRC_LAYOUT_SHIPPED = ["komira_test_shipped"]
