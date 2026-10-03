# =============================================================================
# src/kci_stage_graph/graph.mojo -- the stage graph of a release machine: its
#   stages, in file order, and the steps of each.
# =============================================================================
#
# A STAGE is a named list of STEPS that one `kci run --stage <name>` runs, in
# order. Its name is also the CI job that runs it and the CI environment that
# job runs in (kci_ci_check holds a workflow to that). `after` names the one
# stage that must have finished first; it names an EARLIER stage, so the
# graph has no cycle by construction.
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
# kci_contract's (verbs.mojo).
#
# `validate_stage_graph` holds every rule the parser cannot see field by
# field; a parsed graph is always a valid one. Paths are kept as written: a
# relative one is relative to the directory kci is started in.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from kci_contract import ACTION_BUILD, ACTION_DEPLOY, ACTION_PUBLISH, require_release_platform

comptime NAME_MAX_BYTES: Int = 63
"""Longest stage or step name: a stage name is also a CI job id and a CI
environment name."""


struct StageStep(Copyable, Movable):
    """One step of a stage (file header). Unused inputs are "".

    Layout: owned Strings and an Int. No pointer field."""

    var name: String
    var kind: String
    var platform: String
    var declarations: String
    var channels: String
    var channel: String
    var line: Int

    def __init__(out self, line: Int):
        self.name = String("")
        self.kind = String("")
        self.platform = String("")
        self.declarations = String("")
        self.channels = String("")
        self.channel = String("")
        self.line = line

    def is_build(self) -> Bool:
        return self.kind == ACTION_BUILD

    def is_publish(self) -> Bool:
        return self.kind == ACTION_PUBLISH


struct Stage(Copyable, Movable):
    """One stage: a name, the stage it runs after ("" for none), and its
    steps in file order.

    Layout: owned values only. No pointer field."""

    var name: String
    var after: String
    var steps: List[StageStep]
    var line: Int

    def __init__(out self, line: Int):
        self.name = String("")
        self.after = String("")
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
    """`[a-z][a-z0-9-]*`, at most `NAME_MAX_BYTES` bytes, not ending in `-`."""
    var b = name.as_bytes()
    if len(b) == 0 or len(b) > NAME_MAX_BYTES:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var lower = c >= 97 and c <= 122
        if i == 0:
            if not lower:
                return False
            continue
        if not (lower or (c >= 48 and c <= 57) or c == 45):
            return False
    return Int(b[len(b) - 1]) != 45


def _at(source: String, line: Int) -> String:
    return source + String(": line ") + String(line) + String(": ")


def _check_step(source: String, stage: Stage, step: StageStep) raises:
    var where = String("step '") + step.name + String("' of stage '") + stage.name + String("'")
    if not is_stage_or_step_name(step.name):
        raise Error(
            _at(source, step.line) + String("a step of stage '") + stage.name
            + String("' has name '") + step.name
            + String("'; a step name is [a-z][a-z0-9-]*, at most ") + String(NAME_MAX_BYTES)
            + String(" bytes, not ending in '-'")
        )
    if step.kind == ACTION_DEPLOY:
        raise Error(
            _at(source, step.line) + where
            + String(" is a DEPLOY step: that kind needs a newer kci (this kci runs BUILD and PUBLISH steps)")
        )
    if step.kind != ACTION_BUILD and step.kind != ACTION_PUBLISH:
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
    if step.kind == ACTION_BUILD:
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
                + String(" bytes, not ending in '-' (it is also a CI job id and a CI environment name)")
            )
        for j in range(i):
            if g.stages[j].name == s.name:
                raise Error(
                    _at(source, s.line) + String("stage '") + s.name
                    + String("' is declared twice (first on line ") + String(g.stages[j].line) + String(")")
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
