# =============================================================================
# src/kci_release_machine/deploy.mojo -- the rules of a step that writes into
#   a cell: a DEPLOY step, or a PUBLISH step with `cells` and `cell`.
# =============================================================================
#
#   step {
#     name: "deploy"
#     kind: DEPLOY
#     cells: "release/cells.textproto"
#     cell: "staging"
#     resources: "deploy/app.json"
#     definitions: "deploy/defs/queue_worker.json"
#     validation { name: "probe" kind: DEPLOY_PROBE ... }   (probe.mojo)
#   }
#
# A DEPLOY step:
#   cells, cell     required: the cells file (format `kci.cells`) and the one
#                   cell of it the step deploys into
#   resources       required: a relative path, no `..` segment (a proto3-JSON
#                   ResourceList; this package does not read it)
#   definitions     repeated, optional: each a relative path, no `..` segment
#                   (a proto3-JSON CompositeDefinition)
#   platform, artifacts, channels, channel
#                   refused: a platform is an OS plus a CPU and never names a
#                   cloud, and a DEPLOY's images come from the release set
#   validation      repeated, optional: DEPLOY_PROBE only (graph.mojo refuses
#                   any other kind on a DEPLOY step, and a DEPLOY_PROBE on
#                   any other step); its fields are probe.mojo's
#
# A PUBLISH step names exactly ONE destination: `channels` and `channel`, or
# `cells` and `cell`. Any field of one beside any field of the other is
# refused. `resources` and `definitions` belong to a DEPLOY step; a BUILD
# step has no `cells`, `cell`, `resources` or `definitions`.
#
# Over the whole machine (`validate_cell_steps`), a step that writes into a
# cell is refused:
#   * in a machine with no `name` (the scope `(machine, cell)` has no machine);
#   * in a `break_glass` stage (only a push to main may write into a cell,
#     one run at a time);
# and a DEPLOY step is refused:
#   * in a `farm_connected` stage (the job holding a farm network credential
#     must not also hold a cell's deploy identity; a PUBLISH there is already
#     graph.mojo's refusal);
#   * in a stage that another stage names in `after`, when it carries no
#     DEPLOY_PROBE validation: its set hash would be handed on with nothing
#     having checked the cell (kci hands a set hash on unconditionally when
#     a run selects no validation). The refusal says PROMOTED_DEPLOY_REFUSAL;
#   * when an earlier DEPLOY step, in any stage, names the same cell: the
#     scope is `(machine, cell)`, so a second step would see the first one's
#     objects as leftovers.
# A DEPLOY step in a PULL_REQUEST stage is graph.mojo's refusal (a pull
# request's check holds BUILD steps only).
#
# Whether a step's cell is in its cells file needs that file:
# `require_cells_declared` takes one cells file's path and the names it
# declares, and refuses a step naming that file and a cell it does not
# declare. This package opens no file; the caller reads the cells file.
#
# Every refusal starts `<source>: line N:`. Pure functions over owned values;
# no pointer, no file I/O.
# =============================================================================

from kci_api import STEP_KIND_DEPLOY

from .graph import ReleaseMachine, Stage, StageStep, joined_names
from .probe import check_probe, has_probe

comptime PROMOTED_DEPLOY_REFUSAL: String = (
    "a promoted DEPLOY needs a DEPLOY_PROBE validation, so the set hash it hands on is one a probe checked"
)
"""The refusal of a DEPLOY step in a stage another stage runs after (file
header)."""


def _at(source: String, line: Int) -> String:
    return source + String(": line ") + String(line) + String(": ")


def _where(stage: Stage, step: StageStep) -> String:
    return String("step '") + step.name + String("' of stage '") + stage.name + String("'")


def is_relative_data_path(path: String) -> Bool:
    """Not empty, not absolute, and no `..` segment."""
    if path.byte_length() == 0 or path.startswith(String("/")):
        return False
    var segments = path.split(String("/"))
    for i in range(len(segments)):
        if String(segments[i]) == String(".."):
            return False
    return True


def _refuse_field(source: String, stage: Stage, step: StageStep, field: String, why: String) raises:
    raise Error(
        _at(source, step.line) + _where(stage, step) + String(" is a ") + step.kind + String(" step and has ")
        + field + String(": ") + why
    )


def _check_deploy_fields(source: String, stage: Stage, step: StageStep) raises:
    """The fields of a DEPLOY step (file header)."""
    var why_platform = String("a platform is an OS plus a CPU and never names a cloud (the cell names it)")
    var why_images = String("a DEPLOY step's images come from the release set")
    var why_channel = String("channels and channel belong to a PUBLISH step")
    if step.platform.byte_length() > 0:
        _refuse_field(source, stage, step, String("platform '") + step.platform + String("'"), why_platform)
    if step.artifacts.byte_length() > 0:
        _refuse_field(source, stage, step, String("artifacts '") + step.artifacts + String("'"), why_images)
    if step.channels.byte_length() > 0:
        _refuse_field(source, stage, step, String("channels '") + step.channels + String("'"), why_channel)
    if step.channel.byte_length() > 0:
        _refuse_field(source, stage, step, String("channel '") + step.channel + String("'"), why_channel)
    var where = _at(source, step.line) + _where(stage, step)
    if step.cells.byte_length() == 0:
        raise Error(where + String(" has no cells (the cells file)"))
    if step.cell.byte_length() == 0:
        raise Error(where + String(" has no cell (the cell to deploy into)"))
    if step.resources.byte_length() == 0:
        raise Error(where + String(" has no resources (the resource list file)"))
    if not is_relative_data_path(step.resources):
        raise Error(
            where + String(" has resources '") + step.resources
            + String("'; a resource list is a relative path with no '..' segment")
        )
    for i in range(len(step.definitions)):
        ref d = step.definitions[i]
        if not is_relative_data_path(d):
            raise Error(
                where + String(" has definitions '") + d
                + String("'; a definitions file is a relative path with no '..' segment")
            )


def _check_publish_destination(source: String, stage: Stage, step: StageStep) raises:
    """A PUBLISH step names exactly one destination (file header)."""
    var where = _at(source, step.line) + _where(stage, step)
    var names_channel = step.channels.byte_length() > 0 or step.channel.byte_length() > 0
    if names_channel and step.names_cell():
        raise Error(
            where + String(" names a channel (channels '") + step.channels + String("', channel '") + step.channel
            + String("') and a cell (cells '") + step.cells + String("', cell '") + step.cell
            + String("'): a PUBLISH step names exactly one destination")
        )
    if step.names_cell():
        if step.cells.byte_length() == 0:
            raise Error(where + String(" has cell '") + step.cell + String("' and no cells (the cells file)"))
        if step.cell.byte_length() == 0:
            raise Error(where + String(" has cells '") + step.cells + String("' and no cell (the cell to publish into)"))


def _check_kind_fields(source: String, stage: Stage, step: StageStep) raises:
    """The cell fields on a step of each kind."""
    if step.is_deploy():
        _check_deploy_fields(source, stage, step)
        return
    var why_deploy = String("resources and definitions belong to a DEPLOY step")
    if step.resources.byte_length() > 0:
        _refuse_field(source, stage, step, String("resources '") + step.resources + String("'"), why_deploy)
    if len(step.definitions) > 0:
        _refuse_field(source, stage, step, String("definitions '") + step.definitions[0] + String("'"), why_deploy)
    if step.is_publish():
        _check_publish_destination(source, stage, step)
    elif step.names_cell():
        _refuse_field(
            source, stage, step, String("cells '") + step.cells + String("' or cell '") + step.cell + String("'"),
            String("cells and cell belong to a PUBLISH or DEPLOY step"),
        )


def _is_promoted(g: ReleaseMachine, stage: Stage) -> Bool:
    for i in range(len(g.stages)):
        if g.stages[i].after == stage.name:
            return True
    return False


def _check_writes_cell(source: String, g: ReleaseMachine, i: Int, k: Int) raises:
    """The machine-wide rules of step k of stage i, which writes into a cell
    (file header)."""
    ref stage = g.stages[i]
    ref step = stage.steps[k]
    var where = _at(source, step.line) + _where(stage, step) + String(" writes into cell '") + step.cell
    where += String("'")
    if g.name.byte_length() == 0:
        raise Error(
            where + String(" and the machine file has no name: the scope a cell's objects are stamped with is")
            + String(" (machine, cell)")
        )
    if stage.break_glass:
        raise Error(
            where + String(" in a break_glass stage: only a push to main writes into a cell, one run at a time,")
            + String(" so a manual run off main never reaches such a step")
        )
    if not step.is_deploy():
        return
    if stage.farm_connected:
        raise Error(
            where + String(" in a farm-connected stage: the job that holds a farm network credential must not")
            + String(" also hold a cell's deploy identity")
        )
    if _is_promoted(g, stage) and not has_probe(step):
        raise Error(
            where + String(" in a stage another stage runs after, with no DEPLOY_PROBE: ")
            + String(PROMOTED_DEPLOY_REFUSAL)
        )
    for a in range(i + 1):
        ref earlier = g.stages[a]
        var last = k if a == i else len(earlier.steps)
        for b in range(last):
            ref other = earlier.steps[b]
            if other.kind == STEP_KIND_DEPLOY and other.cell == step.cell:
                raise Error(
                    where + String(", as DEPLOY ") + _where(earlier, other) + String(" (line ") + String(other.line)
                    + String(") does: one DEPLOY step per cell, since the scope is (machine, cell)")
                )


def validate_cell_steps(g: ReleaseMachine, source: String) raises:
    """Every rule of the file header, over a machine graph.mojo's
    `validate_release_machine` already accepted. Raises on the first,
    naming the line."""
    for i in range(len(g.stages)):
        ref stage = g.stages[i]
        for k in range(len(stage.steps)):
            _check_kind_fields(source, stage, stage.steps[k])
            if stage.steps[k].is_deploy():
                # graph.mojo let only DEPLOY_PROBE validations through on a DEPLOY step
                for m in range(len(stage.steps[k].validations)):
                    check_probe(source, stage, stage.steps[k], stage.steps[k].validations[m])
            if stage.steps[k].writes_cell():
                _check_writes_cell(source, g, i, k)


def require_cells_declared(g: ReleaseMachine, cells_file: String, declared: List[String], source: String) raises:
    """Refuses a step whose `cells` is `cells_file` and whose `cell` is not
    in `declared` (the cell names that file declares, in its order). Steps
    naming another cells file are not looked at."""
    for i in range(len(g.stages)):
        ref stage = g.stages[i]
        for k in range(len(stage.steps)):
            ref step = stage.steps[k]
            if not step.writes_cell() or step.cells != cells_file:
                continue
            var found = False
            for n in range(len(declared)):
                if declared[n] == step.cell:
                    found = True
            if not found:
                raise Error(
                    _at(source, step.line) + _where(stage, step) + String(" names cell '") + step.cell
                    + String("', which cells file '") + cells_file + String("' does not declare (declared: ")
                    + joined_names(declared) + String(")")
                )


def cells_files_named(g: ReleaseMachine) -> List[String]:
    """Every distinct `cells` path a step names, in file order: the files a
    caller reads and hands to `require_cells_declared`."""
    var out = List[String]()
    for i in range(len(g.stages)):
        for k in range(len(g.stages[i].steps)):
            ref step = g.stages[i].steps[k]
            if not step.writes_cell():
                continue
            var seen = False
            for n in range(len(out)):
                if out[n] == step.cells:
                    seen = True
            if not seen:
                out.append(step.cells.copy())
    return out^
