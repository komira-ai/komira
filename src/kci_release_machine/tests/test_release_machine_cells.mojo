# =============================================================================
# src/kci_release_machine/tests/test_release_machine_cells.mojo
#   The machine's name, a DEPLOY step and a PUBLISH step into a cell read
#   back through the parser, and every refusal of deploy.mojo (and of the
#   machine name in parse.mojo), each asserted by its message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_release_machine import (
    PROMOTED_DEPLOY_REFUSAL,
    cells_files_named,
    is_relative_data_path,
    parse_machine_file,
    require_cells_declared,
)


comptime _SRC: String = "machine file"
comptime _CELLS: String = "release/cells.textproto"

comptime _BUILD_STEP: String = (
    "step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"release/artifacts.textproto\" }\n"
)


def _deploy(name: String, cell: String, extra: String = String("")) -> String:
    return (
        String("step { name: \"") + name + String("\" kind: DEPLOY cells: \"") + String(_CELLS)
        + String("\" cell: \"") + cell + String("\" resources: \"deploy/app.json\"") + extra + String(" }\n")
    )


def _push(extra: String) -> String:
    """A PUBLISH step with its platform and artifacts; `extra` holds its
    destination."""
    return (
        String("step { name: \"push\" kind: PUBLISH platform: \"linux-x86_64\"")
        + String(" artifacts: \"release/artifacts.textproto\"") + extra + String(" }\n")
    )


def _into_cell() -> String:
    return _push(String(" cells: \"") + String(_CELLS) + String("\" cell: \"staging\""))


def _named(body: String) -> String:
    return String("schema_version: 1\nname: \"shop\"\n") + body


def _stage(name: String, fields: String, steps: String) -> String:
    return String("stage {\n name: \"") + name + String("\"\n") + fields + steps + String("}\n")


def _refusal(text: String) -> String:
    try:
        _ = parse_machine_file(text, String(_SRC))
    except e:
        return String(e)
    return String("")


def _assert_refused(text: String, needle: String) raises:
    var got = _refusal(text)
    if got.find(needle) < 0:
        raise Error(String("expected a refusal containing '") + needle + String("', got: '") + got + String("'"))


def _shop() -> String:
    """build, then staging (a PUBLISH into a cell and a DEPLOY into it). No
    stage runs after staging."""
    return _named(
        _stage(String("build"), String(""), String(_BUILD_STEP))
        + _stage(
            String("staging"),
            String(" after: \"build\"\n"),
            _into_cell()
            + _deploy(
                String("deploy"),
                String("staging"),
                String(" definitions: \"deploy/defs/a.json\" definitions: \"deploy/defs/b.json\""),
            ),
        )
    )


# ---- reads back ----------------------------------------------------------------


def test_a_machine_with_deploy_and_a_publish_into_a_cell_reads_back() raises:
    var g = parse_machine_file(_shop(), String(_SRC))
    assert_equal(g.name, String("shop"))
    assert_equal(g.name_line, 2)
    var s = g.stage(String("staging"))
    assert_equal(len(s.steps), 2)
    ref push = s.steps[0]
    assert_true(push.is_publish())
    assert_true(push.writes_cell())
    assert_equal(push.cells, String(_CELLS))
    assert_equal(push.cell, String("staging"))
    assert_equal(push.channels, String(""))
    assert_equal(push.channel, String(""))
    ref d = s.steps[1]
    assert_true(d.is_deploy())
    assert_true(d.writes_cell())
    assert_equal(d.cells, String(_CELLS))
    assert_equal(d.cell, String("staging"))
    assert_equal(d.resources, String("deploy/app.json"))
    assert_equal(len(d.definitions), 2)
    assert_equal(d.definitions[0], String("deploy/defs/a.json"))
    assert_equal(d.definitions[1], String("deploy/defs/b.json"))
    assert_equal(d.platform, String(""))
    assert_false(g.stage(String("build")).steps[0].writes_cell())
    var files = cells_files_named(g)
    assert_equal(len(files), 1)
    assert_equal(files[0], String(_CELLS))


def test_a_deploy_with_no_definitions_parses() raises:
    var g = parse_machine_file(_named(_stage(String("s"), String(""), _deploy(String("d"), String("c")))), String(_SRC))
    assert_equal(len(g.stages[0].steps[0].definitions), 0)


def test_a_machine_that_writes_no_cell_needs_no_name() raises:
    var text = (
        String("schema_version: 1\n") + _stage(String("build"), String(""), String(_BUILD_STEP))
        + _stage(String("prod"), String(" after: \"build\"\n"), _push(String(" channels: \"c\" channel: \"prod\"")))
    )
    var g = parse_machine_file(text, String(_SRC))
    assert_equal(g.name, String(""))
    assert_equal(g.name_line, 0)
    assert_equal(len(cells_files_named(g)), 0)


# ---- the machine name ------------------------------------------------------------


def test_the_machine_name_grammar() raises:
    var body = _stage(String("b"), String(""), String(_BUILD_STEP))
    var max_name = String("")
    for _ in range(63):
        max_name += String("a")
    var g = parse_machine_file(String("schema_version: 1\nname: \"") + max_name + String("\"\n") + body, String(_SRC))
    assert_equal(g.name, max_name)
    for bad in ["Shop", "shop-", "1shop", "sh_op", ""]:
        _assert_refused(
            String("schema_version: 1\nname: \"") + String(bad) + String("\"\n") + body,
            String("machine file: line 2: the machine's name '") + String(bad)
            + String("' is not [a-z][a-z0-9-]*, at most 63 bytes, not ending in '-'"),
        )
    _assert_refused(
        String("schema_version: 1\nname: \"") + max_name + String("a\"\n") + body,
        String("the machine's name '") + max_name + String("a' is not [a-z][a-z0-9-]*"),
    )


def test_the_machine_name_set_twice_or_after_a_stage() raises:
    var body = _stage(String("b"), String(""), String(_BUILD_STEP))
    _assert_refused(
        String("schema_version: 1\nname: \"shop\"\nname: \"shop\"\n") + body,
        String("machine file: line 3: the machine's name is set twice (first on line 2)"),
    )
    _assert_refused(
        String("schema_version: 1\n") + body + String("name: \"shop\"\n"),
        String("the machine's name comes after a stage; it is written before the first stage"),
    )


def test_a_cell_step_needs_the_machine_name() raises:
    var unnamed = String("schema_version: 1\n")
    _assert_refused(
        unnamed + _stage(String("s"), String(""), _deploy(String("d"), String("staging"))),
        String("step 'd' of stage 's' writes into cell 'staging' and the machine file has no name"),
    )
    _assert_refused(
        unnamed + _stage(String("s"), String(""), _into_cell()),
        String("step 'push' of stage 's' writes into cell 'staging' and the machine file has no name"),
    )


# ---- refusals in the machine file -------------------------------------------------


def test_deploy_in_a_pull_request_stage() raises:
    _assert_refused(
        _named(_stage(String("pr"), String(" trigger: PULL_REQUEST\n"), _deploy(String("d"), String("staging")))),
        String("stage 'pr' is a PULL_REQUEST stage and has DEPLOY step 'd'"),
    )


def test_deploy_in_a_farm_connected_stage() raises:
    _assert_refused(
        _named(_stage(String("s"), String(" farm_connected: true\n"), _deploy(String("d"), String("staging")))),
        String("step 'd' of stage 's' writes into cell 'staging' in a farm-connected stage"),
    )
    # a PUBLISH into a cell there is graph.mojo's PUBLISH rule
    _assert_refused(
        _named(_stage(String("s"), String(" farm_connected: true\n"), _into_cell())),
        String("stage 's' is farm-connected and has PUBLISH step 'push'"),
    )


def test_a_cell_step_in_a_break_glass_stage() raises:
    _assert_refused(
        _named(_stage(String("s"), String(" break_glass: true\n"), _deploy(String("d"), String("staging")))),
        String("step 'd' of stage 's' writes into cell 'staging' in a break_glass stage"),
    )
    _assert_refused(
        _named(_stage(String("s"), String(" break_glass: true\n"), _into_cell())),
        String("step 'push' of stage 's' writes into cell 'staging' in a break_glass stage"),
    )


def test_a_deploy_missing_cells_cell_or_resources() raises:
    var no_cell = String("step { name: \"d\" kind: DEPLOY cells: \"c\" resources: \"r.json\" }\n")
    _assert_refused(_named(_stage(String("s"), String(""), no_cell)), String("step 'd' of stage 's' has no cell"))
    var no_cells = String("step { name: \"d\" kind: DEPLOY cell: \"x\" resources: \"r.json\" }\n")
    _assert_refused(_named(_stage(String("s"), String(""), no_cells)), String("step 'd' of stage 's' has no cells"))
    var no_resources = String("step { name: \"d\" kind: DEPLOY cells: \"c\" cell: \"x\" }\n")
    _assert_refused(
        _named(_stage(String("s"), String(""), no_resources)), String("step 'd' of stage 's' has no resources")
    )


def test_a_cell_not_in_its_cells_file() raises:
    var g = parse_machine_file(_shop(), String(_SRC))
    var declared = List[String]()
    declared.append(String("prod"))
    declared.append(String("dev"))
    var got = String("")
    try:
        require_cells_declared(g, String(_CELLS), declared, String(_SRC))
    except e:
        got = String(e)
    # the PUBLISH into the cell comes first in the stage
    assert_equal(
        got,
        String("machine file: line 10: step 'push' of stage 'staging' names cell 'staging', which cells file '")
        + String(_CELLS) + String("' does not declare (declared: prod, dev)"),
    )
    # the DEPLOY step alone
    var only_deploy = parse_machine_file(
        _named(_stage(String("s"), String(""), _deploy(String("d"), String("staging")))), String(_SRC)
    )
    got = String("")
    try:
        require_cells_declared(only_deploy, String(_CELLS), declared, String(_SRC))
    except e:
        got = String(e)
    assert_true(got.find(String("step 'd' of stage 's' names cell 'staging', which cells file")) >= 0)
    # declared: accepted; another cells file is not looked at
    declared.append(String("staging"))
    require_cells_declared(g, String(_CELLS), declared, String(_SRC))
    require_cells_declared(g, String("other/cells.textproto"), List[String](), String(_SRC))


def test_a_resources_or_definitions_path() raises:
    for bad in ["/abs/app.json", "../app.json", "deploy/../app.json", "deploy/.."]:
        var step = String("step { name: \"d\" kind: DEPLOY cells: \"c\" cell: \"x\" resources: \"") + String(bad)
        step += String("\" }\n")
        _assert_refused(
            _named(_stage(String("s"), String(""), step)),
            String("has resources '") + String(bad) + String("'; a resource list is a relative path with no '..'"),
        )
        _assert_refused(
            _named(
                _stage(
                    String("s"), String(""),
                    _deploy(String("d"), String("x"), String(" definitions: \"") + String(bad) + String("\"")),
                )
            ),
            String("has definitions '") + String(bad) + String("'; a definitions file is a relative path"),
        )
    assert_true(is_relative_data_path(String("deploy/app..json")))
    assert_false(is_relative_data_path(String("")))


def test_a_deploy_refuses_platform_artifacts_channels_channel() raises:
    _assert_refused(
        _named(_stage(String("s"), String(""), _deploy(String("d"), String("x"), String(" platform: \"linux-x86_64\"")))),
        String("machine file: line 5: step 'd' of stage 's' is a DEPLOY step and has platform 'linux-x86_64': a")
        + String(" platform is an OS plus a CPU and never names a cloud"),
    )
    _assert_refused(
        _named(_stage(String("s"), String(""), _deploy(String("d"), String("x"), String(" artifacts: \"a\"")))),
        String("is a DEPLOY step and has artifacts 'a': a DEPLOY step's images come from the release set"),
    )
    _assert_refused(
        _named(_stage(String("s"), String(""), _deploy(String("d"), String("x"), String(" channels: \"c\"")))),
        String("is a DEPLOY step and has channels 'c': channels and channel belong to a PUBLISH step"),
    )
    _assert_refused(
        _named(_stage(String("s"), String(""), _deploy(String("d"), String("x"), String(" channel: \"prod\"")))),
        String("is a DEPLOY step and has channel 'prod': channels and channel belong to a PUBLISH step"),
    )


def test_a_publish_names_one_destination() raises:
    var both = String(" channels: \"c\" channel: \"prod\" cells: \"") + String(_CELLS) + String("\" cell: \"staging\"")
    _assert_refused(
        _named(_stage(String("s"), String(""), _push(both))),
        String("step 'push' of stage 's' names a channel (channels 'c', channel 'prod') and a cell (cells '")
        + String(_CELLS) + String("', cell 'staging'): a PUBLISH step names exactly one destination"),
    )
    _assert_refused(
        _named(_stage(String("s"), String(""), _push(String(" channel: \"prod\" cell: \"staging\"")))),
        String("names a channel (channels '', channel 'prod') and a cell (cells '', cell 'staging')"),
    )
    _assert_refused(
        _named(_stage(String("s"), String(""), _push(String(" channels: \"c\" cells: \"cells\"")))),
        String("names a channel (channels 'c', channel '') and a cell (cells 'cells', cell '')"),
    )
    _assert_refused(
        _named(_stage(String("s"), String(""), _push(String(" cell: \"staging\"")))),
        String("step 'push' of stage 's' has cell 'staging' and no cells"),
    )
    _assert_refused(
        _named(_stage(String("s"), String(""), _push(String(" cells: \"cells\"")))),
        String("step 'push' of stage 's' has cells 'cells' and no cell"),
    )


def test_cell_fields_on_other_kinds() raises:
    _assert_refused(
        _named(_stage(String("s"), String(""), _push(String(" channels: \"c\" channel: \"p\" resources: \"r.json\"")))),
        String("is a PUBLISH step and has resources 'r.json': resources and definitions belong to a DEPLOY step"),
    )
    var build = String("step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"a\" cell: \"x\" }\n")
    _assert_refused(
        _named(_stage(String("s"), String(""), build)),
        String("is a BUILD step and has cells '' or cell 'x': cells and cell belong to a PUBLISH or DEPLOY step"),
    )
    var build_defs = String("step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"a\"")
    build_defs += String(" definitions: \"d.json\" }\n")
    _assert_refused(
        _named(_stage(String("s"), String(""), build_defs)),
        String("is a BUILD step and has definitions 'd.json': resources and definitions belong to a DEPLOY step"),
    )


def test_two_deploy_steps_naming_one_cell() raises:
    # in one stage
    _assert_refused(
        _named(_stage(String("s"), String(""), _deploy(String("a"), String("staging")) + _deploy(String("b"), String("staging")))),
        String("step 'b' of stage 's' writes into cell 'staging', as DEPLOY step 'a' of stage 's' (line 5) does:")
        + String(" one DEPLOY step per cell"),
    )
    # in two stages
    _assert_refused(
        _named(
            _stage(String("one"), String(""), _deploy(String("a"), String("staging")))
            + _stage(String("two"), String(""), _deploy(String("b"), String("staging")))
        ),
        String("step 'b' of stage 'two' writes into cell 'staging', as DEPLOY step 'a' of stage 'one'"),
    )
    # two cells: accepted
    var g = parse_machine_file(
        _named(
            _stage(String("one"), String(""), _deploy(String("a"), String("staging")))
            + _stage(String("two"), String(""), _deploy(String("b"), String("prod")))
        ),
        String(_SRC),
    )
    assert_equal(len(g.stages), 2)


def test_a_deploy_in_a_stage_another_runs_after() raises:
    var later = _stage(String("prod"), String(" after: \"staging\"\n"), String(_BUILD_STEP))
    _assert_refused(
        _named(_stage(String("staging"), String(""), _deploy(String("d"), String("staging"))) + later),
        String("step 'd' of stage 'staging' writes into cell 'staging' in a stage another stage runs after: ")
        + String(PROMOTED_DEPLOY_REFUSAL),
    )
    # with a validation block it is refused too: no validation belongs to a DEPLOY step yet
    var validation = String(" validation { name: \"probe\" kind: CONDA_INSTALL_ENV install: \"x\"")
    validation += String(" compiler_channel: \"https://conda.example\" }")
    _assert_refused(
        _named(_stage(String("staging"), String(""), _deploy(String("d"), String("staging"), validation)) + later),
        String("validation 'probe' of step 'd' of stage 'staging': a validation belongs to a PUBLISH step"),
    )
    # a PUBLISH into a cell in a promoted stage is not this rule's
    var g = parse_machine_file(_named(_stage(String("staging"), String(""), _into_cell()) + later), String(_SRC))
    assert_equal(len(g.stages), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
