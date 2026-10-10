# =============================================================================
# src/kci_cell/tests/test_cells_parse.mojo
#   A golden cells file parses to exactly its cells, and the lookups read
#   them back.
# =============================================================================
#
# The golden case renders every parsed field (name, cloud, each setting in
# file order, bootstrap level, the line of the cell's `{`) into one string and
# compares it whole, so a dropped, reordered or mis-assigned field fails it.
# The other cases pin what the grammar accepts beyond the golden file (a `:`
# before a `{`, bare scalars, `schema_version` anywhere at the top level) and
# that a lookup never falls back.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import FORMAT_CELLS, format_row
from kci_cell import (
    BOOTSTRAP_LEVEL_V1,
    Cell,
    CellSetting,
    cell_names,
    find_cell,
    parse_cells_file,
)

comptime _GOLDEN = """schema_version: 1
# Two synthetic cells.
cell {
  name: "staging"
  cloud: "gcp"
  setting { key: "project" value: "example-staging" }
  setting { key: "region" value: "europe-west1" }
  bootstrap_level: 1
}
cell: {
  bootstrap_level: 1
  setting: { value: "" key: "note" }
  cloud: fake
  name: prod-eu-1
}
"""

comptime _GOLDEN_RENDERED = (
    "staging@3 cloud=gcp level=1 [project=example-staging, region=europe-west1]\n"
    "prod-eu-1@10 cloud=fake level=1 [note=]\n"
)


def _render(cells: List[Cell]) -> String:
    var out = String("")
    for i in range(len(cells)):
        ref c = cells[i]
        out += c.name + String("@") + String(c.line) + String(" cloud=") + c.cloud
        out += String(" level=") + String(c.bootstrap_level) + String(" [")
        for k in range(len(c.settings)):
            if k > 0:
                out += String(", ")
            out += c.settings[k].key + String("=") + c.settings[k].value
        out += String("]\n")
    return out^


def test_golden_parse() raises:
    var cells = parse_cells_file(String(_GOLDEN))
    assert_equal(_render(cells), String(_GOLDEN_RENDERED))


comptime _PREFIX_RELATED = """schema_version: 1
cell {
  name: "prod"
  cloud: "gcp"
  setting { key: "project" value: "example-prod" }
  setting { key: "project-id" value: "example-123" }
  setting { key: "proj" value: "example-short" }
  bootstrap_level: 1
}
cell { name: "prod-eu-1" cloud: "fake" bootstrap_level: 1 }
cell { name: "prod-eu" cloud: "fake" bootstrap_level: 1 }
"""

comptime _PREFIX_RELATED_RENDERED = (
    "prod@2 cloud=gcp level=1 [project=example-prod, project-id=example-123, proj=example-short]\n"
    "prod-eu-1@10 cloud=fake level=1 []\n"
    "prod-eu@11 cloud=fake level=1 []\n"
)


def test_prefix_related_names_and_keys_are_distinct() raises:
    # cell names and setting keys compare whole, never by prefix: each name
    # and key here is a prefix of a later one (`prod` / `prod-eu-1`,
    # `project` / `project-id`) and then of an earlier one (`prod-eu`,
    # `proj`), and every cell and setting parses
    var cells = parse_cells_file(String(_PREFIX_RELATED))
    assert_equal(_render(cells), String(_PREFIX_RELATED_RENDERED))
    assert_equal(cells[0].setting(String("project")), String("example-prod"))
    assert_equal(cells[0].setting(String("project-id")), String("example-123"))
    assert_equal(find_cell(cells, String("prod-eu")).line, 11)


def test_lookups_read_the_cells_back() raises:
    var cells = parse_cells_file(String(_GOLDEN))
    var names = cell_names(cells)
    assert_equal(len(names), 2)
    assert_equal(names[0], String("staging"))
    assert_equal(names[1], String("prod-eu-1"))
    var staging = find_cell(cells, String("staging"))
    assert_equal(staging.cloud, String("gcp"))
    assert_equal(staging.bootstrap_level, BOOTSTRAP_LEVEL_V1)
    assert_true(staging.has_setting(String("region")))
    assert_equal(staging.setting(String("project")), String("example-staging"))
    assert_false(staging.has_setting(String("zone")))


def test_a_missing_setting_is_never_defaulted() raises:
    var staging = find_cell(parse_cells_file(String(_GOLDEN)), String("staging"))
    var msg = String("<no refusal>")
    try:
        _ = staging.setting(String("zone"))
    except e:
        msg = String(e)
    assert_equal(msg, String("cell 'staging' declares no setting 'zone'"))


def test_an_unknown_cell_never_falls_back() raises:
    var cells = parse_cells_file(String(_GOLDEN))
    var msg = String("<no refusal>")
    try:
        _ = find_cell(cells, String("dev"))
    except e:
        msg = String(e)
    assert_equal(msg, String("unknown cell 'dev' (declared: staging, prod-eu-1)"))


def test_schema_version_anywhere_at_the_top_level() raises:
    var cells = parse_cells_file(
        String("cell { name: \"a\" cloud: \"fake\" bootstrap_level: 1 }\nschema_version: 1\n")
    )
    assert_equal(len(cells), 1)
    assert_equal(len(cells[0].settings), 0)


def test_a_cell_built_in_code() raises:
    var settings = List[CellSetting]()
    settings.append(CellSetting(String("project"), String("example-staging")))
    var cells = List[Cell]()
    cells.append(Cell(String("staging"), String("gcp"), settings^, BOOTSTRAP_LEVEL_V1))
    assert_equal(find_cell(cells, String("staging")).line, 0)


def test_the_format_row() raises:
    assert_equal(String(FORMAT_CELLS), String("kci.cells"))
    assert_equal(format_row(String(FORMAT_CELLS)).current_major, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
