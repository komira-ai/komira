# =============================================================================
# src/kci_release_machine/graph.mojo -- a release machine: its
#   stages, in file order, and the steps of each.
# =============================================================================
#
# A STAGE is a named list of STEPS that one `kci run --stage <name>` runs, in
# order. Its name is also the id of the CI job that runs it. `environment` is
# the GitHub environment that job runs in, and defaults to the stage's name
# (kci_workflow_check holds a workflow to both). `after` names the one stage that
# must have finished first; it names an EARLIER stage, so the graph has no
# cycle by construction.
#
# `farm_connected: true` declares that the stage's job joins the private
# network the build farm is on. Such a job holds a network credential, so a
# farm-connected stage may hold no PUBLISH step: the job that holds a farm network
# node must not hold a publishing token.
#
# `trigger` says which CI event runs the stage's job: PUSH (the default: a
# release stage, run on a push or by hand) or PULL_REQUEST (the per-change
# check of a pull request: `kci run --stage <S> --affected-by <base>`, the
# one job of the workflow that runs on `pull_request`, as kci_workflow_check R6
# holds). A PULL_REQUEST stage runs a pull request's code, so it may hold
# BUILD steps only (nothing is published or deployed from it), runs in NO
# GitHub environment (an `environment` field is refused, and none is
# defaulted: an environment's secrets and approvals never reach a pull
# request), runs after no stage and no stage runs after it (its job runs on
# a pull request, where no release job runs). It may be farm-connected.
#
# `break_glass: true` declares that the stage may run off `main`: a manual
# run of a branch (BREAK-GLASS: kci.yml's workflow_dispatch from another ref,
# with a required reason) runs it. A stage without it runs only for a commit
# on main's history, on a run of `main` (kci_cli's start-up ref check, and
# kci_workflow_check R15 on its job's `if:`). The break-glass stages are a PREFIX
# of the release chain: a break_glass stage's `after` is break_glass too, so
# a run off main stops at the first stage without it and never reaches a
# later one. A PULL_REQUEST stage is never break_glass (it is no release
# stage).
#
# `break_glass_environment: "<env>"` names the GitHub environment a
# break_glass stage's job runs in on a BREAK-GLASS run (any run but a push
# to main), in place of its `environment`. It exists so the stage's own
# environment can be locked to main (deployment branches: `main`) while a
# break-glass run goes through an environment of its own, with a required
# reviewer, whose approval GitHub records. Only a break_glass stage has one,
# it is an environment name and it is not the stage's `environment`. A
# break-glass run of a stage that publishes by OIDC trusted publishing
# without one is refused by kci_publish (the channel's trusted publisher
# accepts the stage's main environment only).
#
# A STEP has a name (unique in its stage), a kind and the inputs of that
# kind:
#
#   kind      inputs                                    what it does
#   BUILD     platform, artifacts                    kci_build: one build per
#                                                       declared artifact
#   PUBLISH   platform, artifacts, and ONE destination: kci_publish: the release
#             channels + channel, or cells + cell       set to one channel, or
#                                                       (not run yet) one cell
#   DEPLOY    cells, cell, resources, definitions,   parsed; this kci does
#             DEPLOY_PROBE validations                  not run it yet
#
# A stage may hold steps of different kinds. The kind words are
# kci_api's (verbs.mojo), and so is the name grammar (selection.mojo).
#
# CELLS. A step that writes into a cell (a DEPLOY step, or a PUBLISH step
# with `cells` and `cell`) names a cells file (`cells`, format `kci.cells`)
# and one cell of it (`cell`); the cell names its cloud. A platform stays
# OS + CPU only; it never names a cloud. Every rule of such a step is
# deploy.mojo's (`validate_cell_steps`, which `parse_machine_file` runs after
# `validate_release_machine`); this file only lets the kind and the fields
# through. Whether the cell is in the file is `require_cells_declared`'s, run
# by whoever reads the cells file (this package opens no file).
#
# VALIDATIONS. A step may carry `validation { ... }` blocks. A validation
# name is unique in its stage (the grammar of a step name). The kind says
# which step it belongs to: CONDA_INSTALL_SMOKE and CONDA_INSTALL_ENV check
# what a PUBLISH step published; DEPLOY_PROBE checks the cell a DEPLOY step
# deployed into (any other pairing is refused here). Every rule of a
# DEPLOY_PROBE past its name and kind is probe.mojo's (run by deploy.mojo's
# `validate_cell_steps`); a CONDA_* validation that writes a probe's field
# (`args`, `target`, `timeout_seconds`, `expect`) is refused here. The two
# CONDA kinds (kci_api): CONDA_INSTALL_SMOKE installs the
# published packages inside a container and runs a program against them;
# CONDA_INSTALL_ENV installs them on the machine that runs kci, with no
# container (a pinned pixi, a scratch directory, a cleared environment), and
# runs each installed library's README examples against them:
#
#   image             CONDA_INSTALL_SMOKE only, required: the container
#                     image, pinned by digest:
#                     `<reference>@sha256:<64 lowercase hex>` (a tag alone is
#                     refused: it names whatever the registry serves today).
#                     Refused on CONDA_INSTALL_ENV, which runs no container
#   install           repeated, at least one: a package to install from the
#                     step's channel at this release's version and build (kci
#                     checks it is a member of the release set when it runs;
#                     this package reads no other file)
#   compiler_channel  the channel `mojo-compiler` is pinned to; an https:// URL
#   extra_channel     repeated: a channel that may supply only packages
#                     outside the release set; an https:// URL or the bare
#                     `conda-forge`
#   program           CONDA_INSTALL_SMOKE only, required: the program to
#                     run, a relative path to a .mojo file under `release/`
#                     (no `..` segment). Refused on CONDA_INSTALL_ENV: what it
#                     runs is each installed library's README
#                     (share/doc/<name>/README.md), whose bytes the release
#                     pins
#   smoke             CONDA_INSTALL_ENV only, optional: what runs against
#                     the install. `README` (the one word, and the default
#                     when omitted): each installed library's README examples.
#                     Any other word is refused (a closed vocabulary: a typo
#                     cannot become a validation that runs nothing). Refused
#                     on CONDA_INSTALL_SMOKE, which runs its `program`
#   wait_for_index_seconds
#                     how long to wait for the channel's index to LIST the
#                     release's files: 0 waits not at all; unset is
#                     `VALIDATION_WAIT_DEFAULT_SECONDS`; at most
#                     `VALIDATION_WAIT_MAX_SECONDS`
#
# SELECTION. `resolve_selection` turns `kci run --only ...` into the steps
# and validations to run (file order, whatever the order on the command line)
# and the run's scope. `step:<name>` selects that step WITHOUT its
# validations; `validation:<name>` selects that validation and no step (it
# checks what an earlier run published). Only a FULL run (no `--only`) runs
# every step and every validation. So a stage can be split over several CI
# jobs, one per part, and the parts never overlap. A selector that matches
# nothing in the stage is refused, listing the stage's step and validation
# names: a selective run that runs nothing is never a pass. Any `--only`
# makes the run SELECTIVE, even one that selects every step.
#
# `validate_release_machine` holds every rule the parser cannot see field by
# field; a parsed graph is always a valid one. Paths are kept as written: a
# relative one is relative to the directory kci is started in.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from kci_api import (
    SCOPE_FULL,
    SCOPE_SELECTIVE,
    STEP_KIND_BUILD,
    STEP_KIND_DEPLOY,
    STEP_KIND_PUBLISH,
    STEP_NAME_MAX_BYTES,
    Selector,
    is_step_name,
    require_release_platform,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    VALIDATION_KIND_DEPLOY_PROBE,
    require_validation_kind,
)

comptime VALIDATION_PROGRAM_DIR: String = "release/"
"""Where a validation's program lives: the release files' directory."""

comptime VALIDATION_SMOKE_README: String = "README"
"""The one `smoke` word: run each installed library's README examples."""

comptime VALIDATION_WAIT_MAX_SECONDS: Int = 3600
"""The longest `wait_for_index_seconds` a validation may declare."""

comptime VALIDATION_WAIT_DEFAULT_SECONDS: Int = 1800
"""`wait_for_index_seconds` when a validation does not set it. A registry
can take a quarter of an hour to make a new subdir's first index."""

comptime EXTRA_CHANNEL_CONDA_FORGE: String = "conda-forge"
"""The one bare channel name an `extra_channel` may be."""

comptime STAGE_TRIGGER_PUSH: String = "PUSH"
"""A stage run by a release workflow (a push, or by hand): the default."""

comptime STAGE_TRIGGER_PULL_REQUEST: String = "PULL_REQUEST"
"""A stage run by a pull request's per-change check (file header)."""

comptime NAME_MAX_BYTES: Int = STEP_NAME_MAX_BYTES
"""Longest stage or step name: a stage name is also a CI job id and a
GitHub environment name (kci_api states the number)."""


struct StageValidation(Copyable, Movable):
    """One validation of a step (file header). `installs`,
    `extra_channels`, `args` and `expects` are in file order; `written`
    names each field the block wrote, once, in file order (so a rule can
    tell a field left at its default from one written with that value);
    `line` is the line its block opens on.

    Layout: owned Strings, Lists of Strings and Ints. No pointer field."""

    var name: String
    var kind: String
    var image: String
    var installs: List[String]
    var compiler_channel: String
    var extra_channels: List[String]
    var program: String
    var smoke: String
    var wait_for_index_seconds: Int
    var args: List[String]
    var target_resource: String
    var target_output: String
    var timeout_seconds: Int
    var expects: List[String]
    var written: List[String]
    var line: Int

    def __init__(out self, line: Int):
        self.name = String("")
        self.kind = String("")
        self.image = String("")
        self.installs = List[String]()
        self.compiler_channel = String("")
        self.extra_channels = List[String]()
        self.program = String("")
        self.smoke = String("")
        self.wait_for_index_seconds = VALIDATION_WAIT_DEFAULT_SECONDS
        self.args = List[String]()
        self.target_resource = String("")
        self.target_output = String("")
        self.timeout_seconds = 0
        self.expects = List[String]()
        self.written = List[String]()
        self.line = line

    def wrote(self, field: String) -> Bool:
        """Whether the block wrote `field` (a default never counts)."""
        for i in range(len(self.written)):
            if self.written[i] == field:
                return True
        return False


struct StageStep(Copyable, Movable):
    """One step of a stage (file header). Unused inputs are "";
    `validations` is in file order.

    Layout: owned Strings, a List of owned values and an Int. No pointer
    field."""

    var name: String
    var kind: String
    var platform: String
    var artifacts: String
    var channels: String
    var channel: String
    var cells: String
    var cell: String
    var resources: String
    var definitions: List[String]
    var validations: List[StageValidation]
    var line: Int

    def __init__(out self, line: Int):
        self.name = String("")
        self.kind = String("")
        self.platform = String("")
        self.artifacts = String("")
        self.channels = String("")
        self.channel = String("")
        self.cells = String("")
        self.cell = String("")
        self.resources = String("")
        self.definitions = List[String]()
        self.validations = List[StageValidation]()
        self.line = line

    def is_build(self) -> Bool:
        return self.kind == STEP_KIND_BUILD

    def is_publish(self) -> Bool:
        return self.kind == STEP_KIND_PUBLISH

    def is_deploy(self) -> Bool:
        return self.kind == STEP_KIND_DEPLOY

    def names_cell(self) -> Bool:
        """Whether the step sets `cells` or `cell`."""
        return self.cells.byte_length() > 0 or self.cell.byte_length() > 0

    def writes_cell(self) -> Bool:
        """A DEPLOY step, or a PUBLISH step into a cell (file header,
        CELLS)."""
        return self.is_deploy() or (self.is_publish() and self.names_cell())


struct Stage(Copyable, Movable):
    """One stage: a name, its GitHub environment (the parser sets it to the
    name when the file does not, except on a PULL_REQUEST stage, which has
    none), the stage it runs after ("" for none), whether it is
    farm-connected, its trigger (PUSH or PULL_REQUEST), whether it may run
    off main (`break_glass`, file header) and its steps in file order.

    Layout: owned values only. No pointer field."""

    var name: String
    var environment: String
    var after: String
    var farm_connected: Bool
    var trigger: String
    var break_glass: Bool
    var break_glass_environment: String
    var steps: List[StageStep]
    var line: Int

    def __init__(out self, line: Int):
        self.name = String("")
        self.environment = String("")
        self.after = String("")
        self.farm_connected = False
        self.trigger = String(STAGE_TRIGGER_PUSH)
        self.break_glass = False
        self.break_glass_environment = String("")
        self.steps = List[StageStep]()
        self.line = line

    def is_pull_request(self) -> Bool:
        """Whether a pull request's per-change check runs this stage."""
        return self.trigger == STAGE_TRIGGER_PULL_REQUEST

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


struct ReleaseMachine(Copyable, Movable):
    """Every stage of a machine file, in file order, and the machine's
    `name` ("" when the file has none; `name_line` is 0 then).

    Layout: owned values only. No pointer field."""

    var schema_version: Int
    var name: String
    var name_line: Int
    var stages: List[Stage]

    def __init__(out self, schema_version: Int):
        self.schema_version = schema_version
        self.name = String("")
        self.name_line = 0
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
    (kci_api's `is_step_name`)."""
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


def _is_lower_hex(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
            return False
    return True


def is_digest_pinned_image(image: String) -> Bool:
    """`<reference>@sha256:<64 lowercase hex>`, the reference non-empty and
    nothing in it a shell or a registry would read twice (no space, quote or
    second `@`)."""
    var at = image.find(String("@sha256:"))
    if at <= 0 or image.find(String("@")) != at or image.rfind(String("@")) != at:
        return False
    var digest = String(image[byte = at + 8 :])
    if digest.byte_length() != 64 or not _is_lower_hex(digest):
        return False
    var b = image.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c <= 32 or c == 34 or c == 39 or c == 92 or c >= 127:
            return False
    return True


def _is_https_url(channel: String) -> Bool:
    """An https:// URL with a host and no space, query, fragment or `@`."""
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
        and rest.find(String("'")) < 0
        and rest.find(String('"')) < 0
    )


def _is_extra_channel(channel: String) -> Bool:
    """An https:// URL with a host, or the bare `conda-forge`."""
    if channel == EXTRA_CHANNEL_CONDA_FORGE:
        return True
    return _is_https_url(channel)


def _is_package_name(name: String) -> Bool:
    """A conda package name: `[a-z0-9_.-]+`, starting with a letter or a
    digit."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var alnum = (c >= 97 and c <= 122) or (c >= 48 and c <= 57)
        if i == 0 and not alnum:
            return False
        if not (alnum or c == 95 or c == 46 or c == 45):
            return False
    return True


def probe_only_fields() -> List[String]:
    """The validation fields only a DEPLOY_PROBE may write (file header)."""
    var out = List[String]()
    out.append(String("args"))
    out.append(String("target"))
    out.append(String("timeout_seconds"))
    out.append(String("expect"))
    return out^


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
    if v.kind.byte_length() == 0:
        raise Error(
            _at(source, v.line) + where
            + String(" has no kind (CONDA_INSTALL_SMOKE, CONDA_INSTALL_ENV or DEPLOY_PROBE)")
        )
    try:
        require_validation_kind(v.kind)
    except e:
        raise Error(_at(source, v.line) + where + String(": ") + String(e))
    if v.kind == VALIDATION_KIND_DEPLOY_PROBE:
        if step.kind != STEP_KIND_DEPLOY:
            raise Error(
                _at(source, v.line) + where + String(": a DEPLOY_PROBE validation belongs to a DEPLOY step")
                + String(" (it checks the cell the step deployed into)")
            )
        return  # every other rule of a probe is probe.mojo's (file header, VALIDATIONS)
    if step.kind != STEP_KIND_PUBLISH:
        raise Error(
            _at(source, v.line) + where + String(": a ") + v.kind
            + String(" validation belongs to a PUBLISH step (it checks what the step published)")
        )
    var probe_only = probe_only_fields()
    for i in range(len(probe_only)):
        if v.wrote(probe_only[i]):
            raise Error(
                _at(source, v.line) + where + String(" is a ") + v.kind + String(" validation and has ")
                + probe_only[i] + String(": it belongs to a DEPLOY_PROBE validation")
            )
    var on_this_machine = v.kind == VALIDATION_KIND_CONDA_INSTALL_ENV
    if on_this_machine:
        if v.image.byte_length() > 0:
            raise Error(
                _at(source, v.line) + where + String(" has image '") + v.image
                + String("'; a CONDA_INSTALL_ENV validation runs on this machine with no container")
                + String(" (an image belongs to CONDA_INSTALL_SMOKE)")
            )
        if v.program.byte_length() > 0:
            raise Error(
                _at(source, v.line) + where + String(" has program '") + v.program
                + String("'; a CONDA_INSTALL_ENV validation runs each installed library's README")
                + String(" (share/doc/<name>/README.md), so it names no program")
            )
        if v.smoke.byte_length() > 0 and v.smoke != VALIDATION_SMOKE_README:
            raise Error(
                _at(source, v.line) + where + String(" has smoke '") + v.smoke
                + String("'; the one word is ") + String(VALIDATION_SMOKE_README)
                + String(" (each installed library's README examples, the default)")
            )
    else:
        if v.smoke.byte_length() > 0:
            raise Error(
                _at(source, v.line) + where + String(" has smoke '") + v.smoke
                + String("'; a CONDA_INSTALL_SMOKE validation runs its program (smoke belongs to CONDA_INSTALL_ENV)")
            )
        if v.image.byte_length() == 0:
            raise Error(_at(source, v.line) + where + String(" has no image (the container image, pinned by digest)"))
        if not is_digest_pinned_image(v.image):
            raise Error(
                _at(source, v.line) + where + String(" has image '") + v.image
                + String("'; an image is pinned by digest, <reference>@sha256:<64 lowercase hex>")
            )
    if len(v.installs) == 0:
        raise Error(_at(source, v.line) + where + String(" has no install (a package to install)"))
    for i in range(len(v.installs)):
        ref name = v.installs[i]
        if not _is_package_name(name):
            raise Error(
                _at(source, v.line) + where + String(" has install '") + name
                + String("'; a package name is [a-z0-9_.-]+, starting with a letter or a digit")
            )
        for j in range(i):
            if v.installs[j] == name:
                raise Error(_at(source, v.line) + where + String(" names install '") + name + String("' twice"))
    if v.compiler_channel.byte_length() == 0:
        raise Error(
            _at(source, v.line) + where + String(" has no compiler_channel (the channel mojo-compiler comes from)")
        )
    if not _is_https_url(v.compiler_channel):
        raise Error(
            _at(source, v.line) + where + String(" has compiler_channel '") + v.compiler_channel
            + String("'; a compiler channel is an https:// URL")
        )
    if not on_this_machine and v.program.byte_length() == 0:
        raise Error(_at(source, v.line) + where + String(" has no program (the program to run)"))
    if not on_this_machine and (
        not _is_relative_mojo_path(v.program) or not v.program.startswith(String(VALIDATION_PROGRAM_DIR))
    ):
        raise Error(
            _at(source, v.line) + where + String(" has program '") + v.program
            + String("'; a program is a relative path to a .mojo file under ") + String(VALIDATION_PROGRAM_DIR)
        )
    if v.wait_for_index_seconds < 0 or v.wait_for_index_seconds > VALIDATION_WAIT_MAX_SECONDS:
        raise Error(
            _at(source, v.line) + where + String(" has wait_for_index_seconds ") + String(v.wait_for_index_seconds)
            + String("; it is 0 to ") + String(VALIDATION_WAIT_MAX_SECONDS)
        )
    for i in range(len(v.extra_channels)):
        ref ch = v.extra_channels[i]
        if not _is_extra_channel(ch):
            raise Error(
                _at(source, v.line) + where + String(" has extra_channel '") + ch
                + String("'; an extra channel is an https:// URL or conda-forge")
            )
        if ch == v.compiler_channel:
            raise Error(
                _at(source, v.line) + where + String(" names '") + ch
                + String("' as compiler_channel and as extra_channel")
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
        return  # every rule of a DEPLOY step is deploy.mojo's (file header, CELLS)
    if step.kind != STEP_KIND_BUILD and step.kind != STEP_KIND_PUBLISH:
        if step.kind.byte_length() == 0:
            raise Error(_at(source, step.line) + where + String(" has no kind (BUILD, PUBLISH or DEPLOY)"))
        raise Error(
            _at(source, step.line) + where + String(" has kind '") + step.kind
            + String("'; a step is BUILD, PUBLISH or DEPLOY")
        )
    if step.platform.byte_length() == 0:
        raise Error(_at(source, step.line) + where + String(" has no platform"))
    try:
        require_release_platform(step.platform)
    except e:
        raise Error(_at(source, step.line) + where + String(": ") + String(e))
    if step.artifacts.byte_length() == 0:
        raise Error(_at(source, step.line) + where + String(" has no artifacts (the artifacts file)"))
    if step.kind == STEP_KIND_BUILD:
        if step.channels.byte_length() > 0 or step.channel.byte_length() > 0:
            raise Error(
                _at(source, step.line) + where
                + String(" is a BUILD step: channels and channel belong to a PUBLISH step")
            )
        return
    if step.names_cell():
        return  # a PUBLISH into a cell: its destination is deploy.mojo's
    if step.channels.byte_length() == 0:
        raise Error(_at(source, step.line) + where + String(" has no channels (the channels file)"))
    if step.channel.byte_length() == 0:
        raise Error(_at(source, step.line) + where + String(" has no channel (the channel to publish to)"))


def _check_step_validations(source: String, stage: Stage, step: StageStep) raises:
    for i in range(len(step.validations)):
        _check_validation(source, stage, step, step.validations[i])


def validate_release_machine(g: ReleaseMachine, source: String) raises:
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
        if s.trigger != STAGE_TRIGGER_PUSH and s.trigger != STAGE_TRIGGER_PULL_REQUEST:
            raise Error(
                _at(source, s.line) + String("stage '") + s.name + String("' has trigger '") + s.trigger
                + String("'; a trigger is PUSH or PULL_REQUEST")
            )
        if s.is_pull_request():
            _check_pull_request_stage(source, g, i)
        elif not is_stage_or_step_name(s.environment):
            raise Error(
                _at(source, s.line) + String("stage '") + s.name + String("' has environment '") + s.environment
                + String("'; an environment name is [a-z][a-z0-9-]*, at most ") + String(NAME_MAX_BYTES)
                + String(" bytes, not ending in '-'")
            )
        if s.break_glass_environment.byte_length() > 0:
            _check_break_glass_environment(source, s)
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
            if s.break_glass and not g.stage(s.after).break_glass:
                raise Error(
                    _at(source, s.line) + String("stage '") + s.name + String("' is break_glass and runs after '")
                    + s.after + String("', which is not: the break-glass stages are a prefix of the chain, so a")
                    + String(" run off main stops at the first stage that runs only on main")
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
                    + String(" farm network node must not hold a publishing token)")
                )
            _check_step_validations(source, s, s.steps[k])
        _check_validation_names_unique(source, s)


def _check_break_glass_environment(source: String, s: Stage) raises:
    """`break_glass_environment` (file header): only on a break_glass
    stage, an environment name, not the stage's `environment`."""
    var where = _at(source, s.line) + String("stage '") + s.name + String("' has break_glass_environment '")
    where += s.break_glass_environment + String("'")
    if not s.break_glass:
        raise Error(where + String(" and is not break_glass: only a stage a break-glass run reaches has one"))
    if not is_stage_or_step_name(s.break_glass_environment):
        raise Error(
            where + String("; an environment name is [a-z][a-z0-9-]*, at most ") + String(NAME_MAX_BYTES)
            + String(" bytes, not ending in '-'")
        )
    if s.break_glass_environment == s.environment:
        raise Error(
            where + String(", the stage's own environment: a break-glass run goes through an environment of its")
            + String(" own, so the stage's environment can be locked to main")
        )


def _check_pull_request_stage(source: String, g: ReleaseMachine, i: Int) raises:
    """The rules of a PULL_REQUEST stage (file header): no environment, no
    `after` either way, BUILD steps only."""
    ref s = g.stages[i]
    var where = String("stage '") + s.name + String("' is a PULL_REQUEST stage")
    if s.break_glass:
        raise Error(
            _at(source, s.line) + where + String(" and is break_glass: break-glass is a manual release run off")
            + String(" main, and a pull request's check is no release stage")
        )
    if s.environment.byte_length() > 0:
        raise Error(
            _at(source, s.line) + where + String(" and has environment '") + s.environment
            + String("': its job runs a pull request's code in NO environment, so no environment secret")
            + String(" or approval reaches it")
        )
    if s.after.byte_length() > 0:
        raise Error(
            _at(source, s.line) + where + String(" and runs after '") + s.after
            + String("': its job runs on a pull request, where no release stage runs")
        )
    for j in range(len(g.stages)):
        if g.stages[j].after == s.name:
            raise Error(
                _at(source, g.stages[j].line) + String("stage '") + g.stages[j].name + String("' runs after '")
                + s.name + String("', a PULL_REQUEST stage: no stage runs after a pull request's check")
            )
    for k in range(len(s.steps)):
        if s.steps[k].kind != STEP_KIND_BUILD:
            raise Error(
                _at(source, s.steps[k].line) + where + String(" and has ") + s.steps[k].kind + String(" step '")
                + s.steps[k].name + String("': a pull request's check builds and never publishes or deploys,")
                + String(" so its steps are BUILD steps")
            )


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
    every one in a FULL run, and each one selected on its own in a SELECTIVE
    run (a step selector does not bring its step's validations).
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
    # every validation that runs, once each, in file order: all of them in a
    # FULL run; in a selective one, only those named (a step selector never
    # brings its step's validations)
    for k in range(len(stage.steps)):
        for m in range(len(stage.steps[k].validations)):
            ref name = stage.steps[k].validations[m].name
            var runs = all
            for j in range(len(picked)):
                if picked[j] == name:
                    runs = True
            if runs:
                sel.validations.append(name.copy())
    return sel^
