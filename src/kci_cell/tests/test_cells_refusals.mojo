# =============================================================================
# src/kci_cell/tests/test_cells_refusals.mojo
#   Every refusal of `parse_cells_file`, one case per message.
# =============================================================================
#
# Each case builds a small synthetic cells file that is valid except for one
# thing and asserts the WHOLE message, so the `cells file: line N:` prefix
# and the line it names are pinned as well as the words. A control case
# shows the unbroken fixture parses, so each refusal is caused by its one
# change. Line numbers: `schema_version: 1` is line 1, so a cell built by
# `_cell` opens on line 2 and its body starts on line 3.
# =============================================================================

from std.testing import TestSuite, assert_equal

from kci_cell import parse_cells_file

comptime _NAME = "  name: \"staging\"\n"
comptime _CLOUD = "  cloud: \"gcp\"\n"
comptime _PROJECT = "  setting { key: \"project\" value: \"example-staging\" }\n"
comptime _LEVEL = "  bootstrap_level: 1\n"


def _cell(body: String) -> String:
    return String("cell {\n") + body + String("}\n")


def _ok_cell() -> String:
    """Lines 2..7 when it is the first cell."""
    return _cell(String(_NAME) + String(_CLOUD) + String(_PROJECT) + String(_LEVEL))


def _file(cells: String) -> String:
    return String("schema_version: 1\n") + cells


def _refusal(text: String) -> String:
    try:
        _ = parse_cells_file(text)
    except e:
        return String(e)
    return String("<no refusal>")


def test_control_the_fixture_parses() raises:
    var cells = parse_cells_file(_file(_ok_cell()))
    assert_equal(len(cells), 1)


# ── an unknown field, at each level ─────────────────────────────────────────


def test_unknown_top_level_field() raises:
    assert_equal(
        _refusal(_file(String("zone: \"a\"\n") + _ok_cell())),
        String("cells file: line 2: unknown top-level field 'zone' (expected schema_version, cell)"),
    )


def test_unknown_cell_field() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String("  region: \"x\"\n") + String(_CLOUD) + String(_LEVEL)))),
        String(
            "cells file: line 4: unknown field 'region' in cell 'staging'"
            " (expected name, cloud, setting, bootstrap_level)"
        ),
    )


def test_unknown_setting_field() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  setting { key: \"a\" val: \"x\" }\n") + String(_LEVEL)))),
        String("cells file: line 5: unknown field 'val' in a setting of cell 'staging' (expected key, value)"),
    )


# ── a scalar set twice ──────────────────────────────────────────────────────


def test_name_set_twice() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  name: \"other\"\n") + String(_LEVEL)))),
        String("cells file: line 5: field 'name' is set twice in cell 'staging'"),
    )


def test_cloud_set_twice() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String(_CLOUD) + String(_LEVEL)))),
        String("cells file: line 5: field 'cloud' is set twice in cell 'staging'"),
    )


def test_bootstrap_level_set_twice() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String(_LEVEL) + String(_LEVEL)))),
        String("cells file: line 6: field 'bootstrap_level' is set twice in cell 'staging'"),
    )


def test_setting_key_set_twice_in_one_setting() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  setting { key: \"a\" key: \"b\" }\n") + String(_LEVEL)))),
        String("cells file: line 5: field 'key' is set twice in a setting of cell 'staging'"),
    )


def test_setting_value_set_twice() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  setting { key: \"a\" value: \"1\" value: \"2\" }\n") + String(_LEVEL)))),
        String("cells file: line 5: field 'value' is set twice in a setting of cell 'staging'"),
    )


# ── a scalar whose value is a brace or a colon ──────────────────────────────
# `_scalar_token` takes only a string, word or number after the `:`. Each
# case would parse on (taking the brace or colon as the value) if that kind
# check were gone, and would then fail later with another message or not
# at all.


def test_cell_name_value_is_an_open_brace() raises:
    assert_equal(
        _refusal(_file(_cell(String("  name: {\n") + String(_CLOUD) + String(_LEVEL)))),
        String("cells file: line 3: expected a value for 'name' but got '{'"),
    )


def test_cell_cloud_value_is_a_close_brace() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String("  cloud: }\n") + String(_LEVEL)))),
        String("cells file: line 4: expected a value for 'cloud' but got '}'"),
    )


def test_bootstrap_level_value_is_a_colon() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  bootstrap_level: :\n")))),
        String("cells file: line 5: expected a value for 'bootstrap_level' but got ':'"),
    )


def test_setting_value_is_a_close_brace() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  setting { key: \"a\" value: }\n") + String(_LEVEL)))),
        String("cells file: line 5: expected a value for 'value' but got '}'"),
    )


def test_setting_key_value_is_an_open_brace() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  setting { key: { value: \"x\" }\n") + String(_LEVEL)))),
        String("cells file: line 5: expected a value for 'key' but got '{'"),
    )


def test_schema_version_value_is_a_close_brace() raises:
    # the top-level field never reaches `_scalar_token`: kci_api's
    # `authored_schema_version` checks it first, over the whole token list
    assert_equal(
        _refusal(String("schema_version: }\n") + _ok_cell()),
        String(
            "cells file: line 1: schema_version is not a decimal integer"
            " (expected `schema_version: <major>`)"
        ),
    )


# ── a duplicate cell name or setting key ────────────────────────────────────


def test_duplicate_cell_name() raises:
    # the second cell opens on line 8; its name is line 9
    assert_equal(
        _refusal(_file(_ok_cell() + _ok_cell())),
        String("cells file: line 9: cell 'staging' is declared twice (first on line 3)"),
    )


def test_duplicate_setting_key() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String(_PROJECT) + String(_LEVEL) + String(_PROJECT)))),
        String("cells file: line 7: setting 'project' is set twice in cell 'staging' (first on line 5)"),
    )


def _named_cell(name: String) -> String:
    """Six lines, the name on the second, like `_ok_cell`."""
    return _cell(String("  name: \"") + name + String("\"\n") + String(_CLOUD) + String(_PROJECT) + String(_LEVEL))


def test_duplicate_cell_name_not_adjacent() raises:
    # staging (lines 2..7), prod (8..13), staging again (14..19, name on 15):
    # the repeat is checked against EVERY earlier cell, not only the last one
    assert_equal(
        _refusal(_file(_named_cell(String("staging")) + _named_cell(String("prod")) + _named_cell(String("staging")))),
        String("cells file: line 15: cell 'staging' is declared twice (first on line 3)"),
    )


def test_duplicate_setting_key_not_adjacent() raises:
    # project (line 5), region (6), project again (7): checked against every
    # earlier setting of the cell, and the first one's line is named
    assert_equal(
        _refusal(_file(_cell(
            String(_NAME) + String(_CLOUD) + String(_PROJECT)
            + String("  setting { key: \"region\" value: \"europe-west1\" }\n")
            + String(_PROJECT) + String(_LEVEL)
        ))),
        String("cells file: line 7: setting 'project' is set twice in cell 'staging' (first on line 5)"),
    )


def test_duplicate_cell_name_with_another_cloud() raises:
    # staging on gcp (lines 2..7), then staging on aws (8..13, name on 9):
    # the name alone conflicts, whatever the rest of the cell says
    var aws_staging = _cell(
        String(_NAME) + String("  cloud: \"aws\"\n")
        + String("  setting { key: \"region\" value: \"eu-west-1\" }\n") + String(_LEVEL)
    )
    assert_equal(
        _refusal(_file(_ok_cell() + aws_staging)),
        String("cells file: line 9: cell 'staging' is declared twice (first on line 3)"),
    )


def test_duplicate_setting_key_with_another_value() raises:
    # project = example-staging (line 5), then project = other (line 6):
    # the key alone conflicts, whatever the value
    assert_equal(
        _refusal(_file(_cell(
            String(_NAME) + String(_CLOUD) + String(_PROJECT)
            + String("  setting { key: \"project\" value: \"other\" }\n")
            + String(_LEVEL)
        ))),
        String("cells file: line 6: setting 'project' is set twice in cell 'staging' (first on line 5)"),
    )


def test_duplicate_cell_name_matching_a_later_earlier_cell() raises:
    # prod (lines 2..7), staging (8..13, name on 9), staging again (14..19,
    # name on 15): the earlier match is NOT the first cell, so a check that
    # compares only with the first cell lets this through
    assert_equal(
        _refusal(_file(_named_cell(String("prod")) + _named_cell(String("staging")) + _named_cell(String("staging")))),
        String("cells file: line 15: cell 'staging' is declared twice (first on line 9)"),
    )


def test_duplicate_setting_key_matching_a_later_earlier_setting() raises:
    # region (line 5), project (6), project again (7): the earlier match is
    # NOT the cell's first setting
    assert_equal(
        _refusal(_file(_cell(
            String(_NAME) + String(_CLOUD)
            + String("  setting { key: \"region\" value: \"europe-west1\" }\n")
            + String(_PROJECT) + String(_PROJECT) + String(_LEVEL)
        ))),
        String("cells file: line 7: setting 'project' is set twice in cell 'staging' (first on line 6)"),
    )


def test_duplicate_multi_line_setting_names_the_key_line() raises:
    # project (line 5), then a setting written over lines 6..9 whose `{` is
    # on line 6 and whose `key` is on line 7: the refusal names the key line
    assert_equal(
        _refusal(_file(_cell(
            String(_NAME) + String(_CLOUD) + String(_PROJECT)
            + String("  setting {\n    key: \"project\"\n    value: \"other\"\n  }\n")
            + String(_LEVEL)
        ))),
        String("cells file: line 7: setting 'project' is set twice in cell 'staging' (first on line 5)"),
    )


def test_duplicate_of_a_multi_line_setting_names_its_key_line_first() raises:
    # a setting over lines 5..8 (`{` on 5, `key` on 6), then project on line
    # 9: "first on line" names the earlier setting's key line, not its `{`
    assert_equal(
        _refusal(_file(_cell(
            String(_NAME) + String(_CLOUD)
            + String("  setting {\n    key: \"project\"\n    value: \"other\"\n  }\n")
            + String(_PROJECT) + String(_LEVEL)
        ))),
        String("cells file: line 9: setting 'project' is set twice in cell 'staging' (first on line 6)"),
    )


def test_setting_keys_differing_by_case_are_two_keys() raises:
    # kci does not interpret settings: `Project` and `project` are distinct
    var cells = parse_cells_file(_file(_cell(
        String(_NAME) + String(_CLOUD) + String(_PROJECT)
        + String("  setting { key: \"Project\" value: \"other\" }\n")
        + String(_LEVEL)
    )))
    assert_equal(len(cells[0].settings), 2)
    assert_equal(cells[0].setting(String("project")), String("example-staging"))
    assert_equal(cells[0].setting(String("Project")), String("other"))


def test_setting_with_an_empty_key() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  setting { key: \"\" value: \"x\" }\n") + String(_LEVEL)))),
        String("cells file: line 5: a setting of cell 'staging' has no key"),
    )


def test_setting_with_no_key() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  setting { value: \"x\" }\n") + String(_LEVEL)))),
        String("cells file: line 5: a setting of cell 'staging' has no key"),
    )


# ── an empty cloud ──────────────────────────────────────────────────────────


def test_empty_cloud() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String("  cloud: \"\"\n") + String(_LEVEL)))),
        String("cells file: line 4: cell 'staging' has an empty cloud (a cloud id such as \"gcp\" is required)"),
    )


def test_whitespace_cloud() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String("  cloud: \" \"\n") + String(_LEVEL)))),
        String("cells file: line 4: cell 'staging' has an empty cloud (a cloud id such as \"gcp\" is required)"),
    )


def test_tab_cr_lf_cloud() raises:
    # every whitespace byte counts as blank, not only a space
    for ws in [String("\\t"), String("\\r"), String("\\n"), String(" \\t\\r\\n")]:
        assert_equal(
            _refusal(_file(_cell(String(_NAME) + String("  cloud: \"") + ws + String("\"\n") + String(_LEVEL)))),
            String("cells file: line 4: cell 'staging' has an empty cloud (a cloud id such as \"gcp\" is required)"),
        )


def test_missing_cloud() raises:
    # no `cloud` field: the line is the cell's `{`
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_LEVEL)))),
        String("cells file: line 2: cell 'staging' has an empty cloud (a cloud id such as \"gcp\" is required)"),
    )


# ── a name outside the step-name grammar ────────────────────────────────────


def _bad_name(name: String) -> String:
    return _refusal(_file(_cell(String("  name: \"") + name + String("\"\n") + String(_CLOUD) + String(_LEVEL))))


def _grammar(label: String, name: String, line: Int) -> String:
    return (
        String("cells file: line ") + String(line) + String(": ") + label
        + String(" has name '") + name
        + String("'; a cell name is [a-z][a-z0-9-]*, at most 63 bytes, not ending in '-'")
    )


def test_name_with_an_upper_case_letter() raises:
    assert_equal(_bad_name(String("Staging")), _grammar(String("cell 'Staging'"), String("Staging"), 3))


def test_name_starting_with_a_digit() raises:
    assert_equal(_bad_name(String("2a")), _grammar(String("cell '2a'"), String("2a"), 3))


def test_name_ending_in_a_dash() raises:
    assert_equal(_bad_name(String("staging-")), _grammar(String("cell 'staging-'"), String("staging-"), 3))


def _a_times(n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += String("a")
    return out^


def test_name_too_long() raises:
    var long = _a_times(64)
    assert_equal(_bad_name(long), _grammar(String("cell '") + long + String("'"), long, 3))


def test_name_63_bytes_parses() raises:
    var edge = _a_times(63)
    assert_equal(_bad_name(edge), String("<no refusal>"))


def test_missing_name() raises:
    assert_equal(
        _refusal(_file(_cell(String(_CLOUD) + String(_LEVEL)))),
        _grammar(String("cell #1"), String(""), 2),
    )


def test_missing_name_labels_the_cell_by_its_place_in_the_file() raises:
    # two named cells (lines 2..13), then one with no name opening on line
    # 14: an unnamed cell is labelled by its position among ALL cells
    assert_equal(
        _refusal(_file(
            _named_cell(String("staging")) + _named_cell(String("prod"))
            + _cell(String(_CLOUD) + String(_LEVEL))
        )),
        _grammar(String("cell #3"), String(""), 14),
    )


def test_unnamed_second_cell_refused_before_its_name_check() raises:
    # the second cell (opening on line 8) has no name yet when its unknown
    # field on line 9 is refused: the label is its ordinal, #2
    assert_equal(
        _refusal(_file(_ok_cell() + _cell(String("  region: \"x\"\n") + String(_CLOUD) + String(_LEVEL)))),
        String(
            "cells file: line 9: unknown field 'region' in cell #2"
            " (expected name, cloud, setting, bootstrap_level)"
        ),
    )


# ── a bootstrap_level other than 1 ──────────────────────────────────────────


def _level(value: String) -> String:
    return _refusal(_file(_cell(String(_NAME) + String(_CLOUD) + String("  bootstrap_level: ") + value + String("\n"))))


def _level_refusal(line: Int, got: String) -> String:
    return (
        String("cells file: line ") + String(line)
        + String(": cell 'staging' has bootstrap_level ") + got
        + String("; this kci accepts only the integer 1")
    )


def test_bootstrap_level_two() raises:
    assert_equal(_level(String("2")), _level_refusal(5, String("'2'")))


def test_bootstrap_level_zero() raises:
    assert_equal(_level(String("0")), _level_refusal(5, String("'0'")))


def test_bootstrap_level_quoted() raises:
    assert_equal(_level(String("\"1\"")), _level_refusal(5, String("'1'")))


def test_bootstrap_level_not_canonical() raises:
    assert_equal(_level(String("01")), _level_refusal(5, String("'01'")))


def test_bootstrap_level_missing() raises:
    assert_equal(
        _refusal(_file(_cell(String(_NAME) + String(_CLOUD)))),
        _level_refusal(2, String("none")),
    )


# ── a file with no cell ─────────────────────────────────────────────────────


def test_no_cell() raises:
    assert_equal(
        _refusal(String("schema_version: 1\n# nothing declared\n")),
        String("cells file: line 1: the file declares no cell (expected at least one `cell { ... }`)"),
    )


def test_no_cell_names_the_last_token_line() raises:
    # the only token sits on line 3, after a comment and a blank line: the
    # refusal names the file's last token, not a fixed line 1
    assert_equal(
        _refusal(String("# a cells file\n\nschema_version: 1\n")),
        String("cells file: line 3: the file declares no cell (expected at least one `cell { ... }`)"),
    )


# ── schema_version: missing, or of another major ────────────────────────────


def test_schema_version_missing() raises:
    assert_equal(
        _refusal(_ok_cell()),
        String(
            "cells file: line 1: no schema_version; add `schema_version: 1`"
            " (this kci reads kci.cells up to major 1)"
        ),
    )


def test_schema_version_too_new() raises:
    # the field is on line 7, after the cell: the refusal names its line
    assert_equal(
        _refusal(_ok_cell() + String("schema_version: 2\n")),
        String(
            "cells file: line 7: schema_version 2 needs a newer kci"
            " (this kci reads kci.cells up to major 1)"
        ),
    )


def test_schema_version_missing_at_top_level_but_nested() raises:
    # a `schema_version` inside a cell is not the file's: the refusal is
    # "missing" on line 1, never the nested field's line 3
    assert_equal(
        _refusal(_cell(String(_NAME) + String("  schema_version: 1\n") + String(_CLOUD) + String(_LEVEL))),
        String(
            "cells file: line 1: no schema_version; add `schema_version: 1`"
            " (this kci reads kci.cells up to major 1)"
        ),
    )


def test_schema_version_word_as_a_value_is_not_the_field() raises:
    # line 1 holds `schema_version` as a VALUE; the field is on line 2
    assert_equal(
        _refusal(String("zone: schema_version\nschema_version: 2\n") + _ok_cell()),
        String(
            "cells file: line 2: schema_version 2 needs a newer kci"
            " (this kci reads kci.cells up to major 1)"
        ),
    )


def test_schema_version_too_old() raises:
    assert_equal(
        _refusal(String("schema_version: 0\n") + _ok_cell()),
        String("cells file: line 1: schema_version 0 is no longer read (this kci reads kci.cells major 1)"),
    )


def test_schema_version_set_twice() raises:
    assert_equal(
        _refusal(_file(_ok_cell() + String("schema_version: 1\n"))),
        String("cells file: line 8: field 'schema_version' is set twice (first on line 1)"),
    )


# ── a block never closed, and the lexer's own refusal ───────────────────────


def test_cell_not_closed() raises:
    assert_equal(
        _refusal(_file(String("cell {\n") + String(_NAME) + String(_CLOUD))),
        String("cells file: line 2: cell 'staging' is not closed (expected '}')"),
    )


def test_setting_not_closed() raises:
    assert_equal(
        _refusal(_file(String("cell {\n") + String(_NAME) + String("  setting { key: \"a\"\n"))),
        String("cells file: line 4: a setting of cell 'staging' is not closed (expected '}')"),
    )


def test_lexer_refusal_is_lined() raises:
    assert_equal(
        _refusal(_file(String("cell {\n  name: \"staging\n}\n"))),
        String("cells file: line 3: unterminated string"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
