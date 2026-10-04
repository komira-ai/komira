# =============================================================================
# src/kci_stage_graph/graph.mojo -- the stage graph of a release machine: its
#   stages, in file order, and the steps of each.
# =============================================================================
#
# A STAGE is a named list of STEPS that one `kci run --stage <name>` runs, in
# order. Its name is also the id of the CI job that runs it. `environment` is
# the GitHub environment that job runs in, and defaults to the stage's name
# (kci_ci_check holds a workflow to both). `after` names the one stage that
# must have finished first; it names an EARLIER stage, so the graph has no
# cycle by construction.
#
# `farm_connected: true` declares that the stage's job joins the private
# network the build farm is on. Such a job holds a network credential, so a
# farm-connected stage may hold no PUBLISH step: the job that holds a tailnet
# node must not hold a publishing token.
#
# A STEP has a name (unique in its stage), a kind and the inputs of that
# kind:
#
#   kind      inputs                                    what it does
#   BUILD     platform, declarations                    kci_build: one build per
#                                                       declared artifact
#   PUBLISH   platform, declarations, channels, channel kci_publish: the release
#                                                       set to one channel
#   DEPLOY    (none yet)                                reserved: refused as
#                                                       "needs a newer kci"
#
# A stage may hold steps of different kinds. The kind words are
# kci_contract's (verbs.mojo), and so is the name grammar (selection.mojo).
#
# DEPLOY, reserved. When its body lands, a DEPLOY step names a CELL (one
# deploy target: an account or project in one region), and the cell names
# its CLOUD (the deploy-target adapter that turns resources into calls). A
# platform stays OS + CPU only; it never names a cloud. No field for either
# exists yet.
#
# VALIDATIONS. A PUBLISH step may carry `validation { ... }` blocks that check
# what it published. A validation name is unique in its stage (the grammar of
# a step name). The one kind is CONDA_INSTALL_SMOKE (kci_contract):
#
#   install        the package to install from the step's channel, at this
#                  release's version and build (kci checks it is a declared
#                  artifact when it runs; this package reads no other file)
#   extra_channel  repeated: a channel that may supply only packages outside
#                  the release set; an https:// URL or the bare `conda-forge`
#   program        the smoke program, a relative path to a .mojo file in the
#                  repository (no `..` segment)
#   tool           the installer; `pixi`, the default, is the only one
#
# SELECTION. `resolve_selection` turns `kci run --only ...` into the steps
# and validations to run (file order, whatever the order on the command line)
# and the run's scope. `step:<name>` selects that step and its validations;
# `validation:<name>` selects that validation and no step (it checks what an
# earlier run published). A selector that matches nothing in the stage is
# refused, listing the stage's step and validation names: a selective run that
# runs nothing is never a pass. Any `--only` makes the run SELECTIVE, even one
# that selects every step.
#
# `validate_stage_graph` holds every rule the parser cannot see field by
# field; a parsed graph is always a valid one. Paths are kept as written: a
# relative one is relative to the directory kci is started in.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from kci_contract import (
    SCOPE_FULL,
    SCOPE_SELECTIVE,
    STEP_KIND_BUILD,
    STEP_KIND_DEPLOY,
    STEP_KIND_PUBLISH,
    STEP_NAME_MAX_BYTES,
    Selector,
    is_step_name,
    require_release_platform,
    require_validation_kind,
)

comptime VALIDATION_TOOL_PIXI: String = "pixi"
"""The one installer a CONDA_INSTALL_SMOKE validation runs, and the default."""

comptime EXTRA_CHANNEL_CONDA_FORGE: String = "conda-forge"
"""The one bare channel name an `extra_channel` may be."""

comptime NAME_MAX_BYTES: Int = STEP_NAME_MAX_BYTES
"""Longest stage or step name: a stage name is also a CI job id and a
GitHub environment name (kci_contract states the number)."""


struct StageValidation(Copyable, Movable):
    """One validation of a step (file header). `tool` is `pixi` unless the
    file says otherwise; `line` is the line its block opens on.

    Layout: owned Strings, a List of Strings and an Int. No pointer field."""

    var name: String
    var kind: String
    var install: String
    var extra_channels: List[String]
    var program: String
    var tool: String
    var line: Int

    def __init__(out self, line: Int):
        self.name = String("")
        self.kind = String("")
        self.install = String("")
        self.extra_channels = List[String]()
        self.program = String("")
        self.tool = String(VALIDATION_TOOL_PIXI)
        self.line = line


struct StageStep(Copyable, Movable):
    """One step of a stage (file header). Unused inputs are "";
    `validations` is in file order.

    Layout: owned Strings, a List of owned values and an Int. No pointer
    field."""

    var name: String
    var kind: String
    var platform: String
    var declarations: String
    var channels: String
    var channel: String
    var validations: List[StageValidation]
    var line: Int

    def __init__(out self, line: Int):
        self.name = String("")
        self.kind = String("")
        self.platform = String("")
        self.declarations = String("")
        self.channels = String("")
        self.channel = String("")
        self.validations = List[StageValidation]()
        self.line = line

    def is_build(self) -> Bool:
        return self.kind == STEP_KIND_BUILD

    def is_publish(self) -> Bool:
        return self.kind == STEP_KIND_PUBLISH


struct Stage(Copyable, Movable):
    """One stage: a name, its GitHub environment (the parser sets it to the
    name when the file does not), the stage it runs after ("" for none),
    whether it is farm-connected, and its steps in file order.

    Layout: owned values only. No pointer field."""

    var name: String
    var environment: String
    var after: String
    var farm_connected: Bool
    var steps: List[StageStep]
    var line: Int

    def __init__(out self, line: Int):
        self.name = String("")
        self.environment = String("")
        self.after = String("")
        self.farm_connected = False
        self.steps = List[StageStep]()
        self.line = line

    def has_kind(self, kind: String) -> Bool:
        for i in range(len(self.steps)):
            if self.steps[i].kind == kind:
                return True
        return False

    def step_kinds(self) -> List[String]:
        """The kind of each step, in order."""
        var out = List[String]()
        for i in range(len(self.steps)):
            out.append(self.steps[i].kind.copy())
        return out^

    def step_names(self) -> List[String]:
        var out = List[String]()
        for i in range(len(self.steps)):
            out.append(self.steps[i].name.copy())
        return out^

    def validation_names(self) -> List[String]:
        """Every validation of every step, in file order."""
        var out = List[String]()
        for i in range(len(self.steps)):
            for k in range(len(self.steps[i].validations)):
                out.append(self.steps[i].validations[k].name.copy())
        return out^


struct StageGraph(Copyable, Movable):
    """Every stage of a machine file, in file order.

    Layout: owned values only. No pointer field."""

    var schema_version: Int
    var stages: List[Stage]

    def __init__(out self, schema_version: Int):
        self.schema_version = schema_version
        self.stages = List[Stage]()

    def stage_names(self) -> List[String]:
        var out = List[String]()
        for i in range(len(self.stages)):
            out.append(self.stages[i].name.copy())
        return out^

    def has_stage(self, name: String) -> Bool:
        for i in range(len(self.stages)):
            if self.stages[i].name == name:
                return True
        return False

    def stage(self, name: String) raises -> Stage:
        """The stage named `name`; refuses an unknown name, listing every
        stage the file holds."""
        for i in range(len(self.stages)):
            if self.stages[i].name == name:
                return self.stages[i].copy()
        raise Error(
            String("the machine file has no stage '") + name + String("'; its stages: ")
            + joined_names(self.stage_names())
        )


def joined_names(names: List[String]) -> String:
    var s = String("")
    for i in range(len(names)):
        if i > 0:
            s += String(", ")
        s += names[i]
    return s^


def is_stage_or_step_name(name: String) -> Bool:
    """`[a-z][a-z0-9-]*`, at most `NAME_MAX_BYTES` bytes, not ending in `-`
    (kci_contract's `is_step_name`)."""
    return is_step_name(name)


def _at(source: String, line: Int) -> String:
    return source + String(": line ") + String(line) + String(": ")


def _is_relative_mojo_path(path: String) -> Bool:
    """A relative path to a `.mojo` file: not absolute, no empty, `.` or
    `..` segment, and a file name longer than `.mojo`."""
    if not path.endswith(String(".mojo")) or path.startswith(String("/")):
        return False
    var segments = path.split(String("/"))
    for i in range(len(segments)):
        var seg = String(segments[i])
        if seg.byte_length() == 0 or seg == String(".") or seg == String(".."):
            return False
    return String(segments[len(segments) - 1]) != String(".mojo")


def _is_extra_channel(channel: String) -> Bool:
    """An https:// URL with a host, or the bare `conda-forge`."""
    if channel == EXTRA_CHANNEL_CONDA_FORGE:
        return True
    var prefix = String("https://")
    if not channel.startswith(prefix):
        return False
    var rest = String(channel[byte = prefix.byte_length() :])
    if rest.byte_length() == 0 or rest.startswith(String("/")):
        return False
    return (
        rest.find(String(" ")) < 0
        and rest.find(String("?")) < 0
        and rest.find(String("#")) < 0
        and rest.find(String("@")) < 0
    )


def _check_validation(source: String, stage: Stage, step: StageStep, v: StageValidation) raises:
    var of_step = String(" of step '") + step.name + String("' of stage '") + stage.name + String("'")
    if v.name.byte_length() == 0:
        raise Error(_at(source, v.line) + String("a validation") + of_step + String(" has no name"))
    if not is_step_name(v.name):
        raise Error(
            _at(source, v.line) + String("a validation") + of_step + String(" has name '") + v.name
            + String("'; a validation name is [a-z][a-z0-9-]*, at most ") + String(NAME_MAX_BYTES)
            + String(" bytes, not ending in '-'")
        )
    var where = String("validation '") + v.name + String("'") + of_step
    if step.kind != STEP_KIND_PUBLISH:
        raise Error(
            _at(source, v.line) + where
            + String(": a validation belongs to a PUBLISH step (it checks what the step published)")
        )
    if v.kind.byte_length() == 0:
        raise Error(_at(source, v.line) + where + String(" has no kind (CONDA_INSTALL_SMOKE)"))
    try:
        require_validation_kind(v.kind)
    except e:
        raise Error(_at(source, v.line) + where + String(": ") + String(e))
    if v.install.byte_length() == 0:
        raise Error(_at(source, v.line) + where + String(" has no install (the package to install)"))
    if v.program.byte_length() == 0:
        raise Error(_at(source, v.line) + where + String(" has no program (the smoke program to run)"))
    if not _is_relative_mojo_path(v.program):
        raise Error(
            _at(source, v.line) + where + String(" has program '") + v.program
            + String("'; a program is a relative path to a .mojo file inside the repository")
        )
    if v.tool != VALIDATION_TOOL_PIXI:
        raise Error(
            _at(source, v.line) + where + String(" has tool '") + v.tool
            + String("'; this kci installs with pixi")
        )
    for i in range(len(v.extra_channels)):
        ref ch = v.extra_channels[i]
        if not _is_extra_channel(ch):
            raise Error(
                _at(source, v.line) + where + String(" has extra_channel '") + ch
                + String("'; an extra channel is an https:// URL or conda-forge")
            )
        for j in range(i):
            if v.extra_channels[j] == ch:
                raise Error(_at(source, v.line) + where + String(" names extra_channel '") + ch + String("' twice"))


def _check_step(source: String, stage: Stage, step: StageStep) raises:
    var where = String("step '") + step.name + String("' of stage '") + stage.name + String("'")
    if not is_stage_or_step_name(step.name):
        raise Error(
            _at(source, step.line) + String("a step of stage '") + stage.name
            + String("' has name '") + step.name
            + String("'; a step name is [a-z][a-z0-9-]*, at most ") + String(NAME_MAX_BYTES)
            + String(" bytes, not ending in '-'")
        )
    if step.kind == STEP_KIND_DEPLOY:
        raise Error(
            _at(source, step.line) + where
            + String(" is a DEPLOY step: that kind needs a newer kci (this kci runs BUILD and PUBLISH steps)")
        )
    if step.kind != STEP_KIND_BUILD and step.kind != STEP_KIND_PUBLISH:
        if step.kind.byte_length() == 0:
            raise Error(_at(source, step.line) + where + String(" has no kind (BUILD or PUBLISH)"))
        raise Error(
            _at(source, step.line) + where + String(" has kind '") + step.kind
            + String("'; a step is BUILD or PUBLISH")
        )
    if step.platform.byte_length() == 0:
        raise Error(_at(source, step.line) + where + String(" has no platform"))
    try:
        require_release_platform(step.platform)
    except e:
        raise Error(_at(source, step.line) + where + String(": ") + String(e))
    if step.declarations.byte_length() == 0:
        raise Error(_at(source, step.line) + where + String(" has no declarations (the artifact declarations file)"))
    if step.kind == STEP_KIND_BUILD:
        if step.channels.byte_length() > 0 or step.channel.byte_length() > 0:
            raise Error(
                _at(source, step.line) + where
                + String(" is a BUILD step: channels and channel belong to a PUBLISH step")
            )
        return
    if step.channels.byte_length() == 0:
        raise Error(_at(source, step.line) + where + String(" has no channels (the channels file)"))
    if step.channel.byte_length() == 0:
        raise Error(_at(source, step.line) + where + String(" has no channel (the channel to publish to)"))


def _check_step_validations(source: String, stage: Stage, step: StageStep) raises:
    for i in range(len(step.validations)):
        _check_validation(source, stage, step, step.validations[i])


def validate_stage_graph(g: StageGraph, source: String) raises:
    """Every rule of the file header that the parser does not see field by
    field. Raises on the first, naming the line."""
    if len(g.stages) == 0:
        raise Error(source + String(" declares no stage"))
    for i in range(len(g.stages)):
        ref s = g.stages[i]
        if not is_stage_or_step_name(s.name):
            if s.name.byte_length() == 0:
                raise Error(_at(source, s.line) + String("a stage has no name"))
            raise Error(
                _at(source, s.line) + String("stage name '") + s.name
                + String("' is not [a-z][a-z0-9-]*, at most ") + String(NAME_MAX_BYTES)
                + String(" bytes, not ending in '-' (it is also a CI job id and a GitHub environment name)")
            )
        for j in range(i):
            if g.stages[j].name == s.name:
                raise Error(
                    _at(source, s.line) + String("stage '") + s.name
                    + String("' is declared twice (first on line ") + String(g.stages[j].line) + String(")")
                )
        if not is_stage_or_step_name(s.environment):
            raise Error(
                _at(source, s.line) + String("stage '") + s.name + String("' has environment '") + s.environment
                + String("'; an environment name is [a-z][a-z0-9-]*, at most ") + String(NAME_MAX_BYTES)
                + String(" bytes, not ending in '-'")
            )
        if s.after.byte_length() > 0:
            if s.after == s.name:
                raise Error(_at(source, s.line) + String("stage '") + s.name + String("' runs after itself"))
            var earlier = False
            for j in range(i):
                if g.stages[j].name == s.after:
                    earlier = True
            if not earlier:
                raise Error(
                    _at(source, s.line) + String("stage '") + s.name + String("' runs after '") + s.after
                    + String("', which is not a stage declared above it")
                )
        if len(s.steps) == 0:
            raise Error(_at(source, s.line) + String("stage '") + s.name + String("' has no step"))
        for k in range(len(s.steps)):
            _check_step(source, s, s.steps[k])
            for m in range(k):
                if s.steps[m].name == s.steps[k].name:
                    raise Error(
                        _at(source, s.steps[k].line) + String("stage '") + s.name + String("' has two steps named '")
                        + s.steps[k].name + String("' (first on line ") + String(s.steps[m].line) + String(")")
                    )
            if s.farm_connected and s.steps[k].kind == STEP_KIND_PUBLISH:
                raise Error(
                    _at(source, s.line) + String("stage '") + s.name + String("' is farm-connected and has PUBLISH step '")
                    + s.steps[k].name + String("': a farm-connected stage may not publish (the job that holds a")
                    + String(" tailnet node must not hold a publishing token)")
                )
            _check_step_validations(source, s, s.steps[k])
        _check_validation_names_unique(source, s)


def _check_validation_names_unique(source: String, s: Stage) raises:
    var names = List[String]()
    var lines = List[Int]()
    for k in range(len(s.steps)):
        for i in range(len(s.steps[k].validations)):
            ref v = s.steps[k].validations[i]
            for j in range(len(names)):
                if names[j] == v.name:
                    raise Error(
                        _at(source, v.line) + String("stage '") + s.name + String("' has two validations named '")
                        + v.name + String("' (first on line ") + String(lines[j]) + String(")")
                    )
            names.append(v.name.copy())
            lines.append(v.line)


# ---- selection -----------------------------------------------------------------


struct Selection(Copyable, Movable):
    """What one `kci run` runs of a stage (file header, SELECTION).

    `steps[i]` says whether the stage's step i runs; the steps run in file
    order. `validations` names every validation that runs, in file order:
    each validation of a selected step, and each one selected on its own.
    `only` is every selector, canonical, in the order given. `scope` is FULL
    or SELECTIVE.

    Layout: owned values only. No pointer field."""

    var steps: List[Bool]
    var validations: List[String]
    var only: List[String]
    var scope: String

    def __init__(out self):
        self.steps = List[Bool]()
        self.validations = List[String]()
        self.only = List[String]()
        self.scope = String(SCOPE_FULL)

    def selected_count(self) -> Int:
        var n = 0
        for i in range(len(self.steps)):
            if self.steps[i]:
                n += 1
        return n


def _names_of(stage: Stage) -> String:
    var steps = joined_names(stage.step_names())
    var validations = stage.validation_names()
    var vtext = String("(none)")
    if len(validations) > 0:
        vtext = joined_names(validations)
    return String("its steps: ") + steps + String("; its validations: ") + vtext


def resolve_selection(stage: Stage, selectors: List[Selector]) raises -> Selection:
    """The steps and validations of `stage` that `selectors` select (file
    header). No selector selects every step and every validation, FULL.
    Refuses a selector that matches nothing in the stage, naming the stage's
    step and validation names."""
    var sel = Selection()
    var all = len(selectors) == 0
    for i in range(len(stage.steps)):
        sel.steps.append(all)
    var picked = List[String]()
    if not all:
        sel.scope = String(SCOPE_SELECTIVE)
    for i in range(len(selectors)):
        ref s = selectors[i]
        sel.only.append(s.canonical())
        var found = False
        if s.is_validation():
            for k in range(len(stage.steps)):
                for m in range(len(stage.steps[k].validations)):
                    if stage.steps[k].validations[m].name == s.name:
                        picked.append(s.name.copy())
                        found = True
            if not found:
                raise Error(
                    String("--only '") + s.canonical() + String("' matches no validation of stage '") + stage.name
                    + String("'; ") + _names_of(stage)
                )
            continue
        for k in range(len(stage.steps)):
            if stage.steps[k].name == s.name:
                sel.steps[k] = True
                found = True
        if not found:
            raise Error(
                String("--only '") + s.canonical() + String("' matches no step of stage '") + stage.name
                + String("'; ") + _names_of(stage)
            )
    # every validation that runs, once each, in file order
    for k in range(len(stage.steps)):
        for m in range(len(stage.steps[k].validations)):
            ref name = stage.steps[k].validations[m].name
            var runs = sel.steps[k]
            for j in range(len(picked)):
                if picked[j] == name:
                    runs = True
            if runs:
                sel.validations.append(name.copy())
    return sel^
