# =============================================================================
# src/kci_api/selection.mojo -- the `--only` selector grammar, the step
#   name grammar, and the two scope words of a run.
# =============================================================================
#
#   --only step:<name>         run step <name> of the stage (and, once the
#                              format has validations, its validations)
#   --only validation:<name>   run validation <name> only, and no step
#
# `--only` is repeatable and POSITIVE: it names what to run, never what to
# skip, so a step added to the machine file later is not run by an old
# selective command. A name is a step name: `[a-z][a-z0-9-]*`, at most
# `STEP_NAME_MAX_BYTES` bytes, not ending in `-` (the machine file's grammar
# for stage and step names; kci_release_machine uses this one).
#
# Refused here, before anything is read (a usage error, `KCI-E-SELECTOR`,
# exit 2): an unknown prefix, a malformed name, and the same selector twice.
# Resolving a selector against a stage, and refusing one that matches
# nothing (`KCI-E-SELECTOR-NO-MATCH`, exit 3), is kci_release_machine's job: this
# file is pure grammar.
#
# SCOPE. A run is FULL when no `--only` is given and SELECTIVE whenever one
# is, even if the selectors cover every step: the verdict keys on what the
# operator asked for, not on what was left out. A selective run is never
# reported as a full one (result.mojo refuses to render that).
#
# Pure functions over owned values; no pointer.
# =============================================================================

comptime SELECTOR_STEP: String = "step"
comptime SELECTOR_VALIDATION: String = "validation"

comptime SCOPE_FULL: String = "FULL"
comptime SCOPE_SELECTIVE: String = "SELECTIVE"

comptime STEP_NAME_MAX_BYTES: Int = 63
"""Longest stage or step name: a stage name is also a CI job id and a
GitHub environment name."""


def is_step_name(name: String) -> Bool:
    """`[a-z][a-z0-9-]*`, at most `STEP_NAME_MAX_BYTES` bytes, not ending in
    `-`: a stage, step or validation name."""
    var b = name.as_bytes()
    if len(b) == 0 or len(b) > STEP_NAME_MAX_BYTES:
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


struct Selector(Copyable, Movable):
    """One `--only` selector: a kind (`step` or `validation`) and a name.

    Layout: owned Strings. No pointer field."""

    var kind: String
    var name: String

    def __init__(out self, var kind: String, var name: String):
        self.kind = kind^
        self.name = name^

    def is_step(self) -> Bool:
        return self.kind == SELECTOR_STEP

    def is_validation(self) -> Bool:
        return self.kind == SELECTOR_VALIDATION

    def canonical(self) -> String:
        """`<kind>:<name>`: the spelling the result document records."""
        return self.kind + String(":") + self.name


def parse_selector(text: String) raises -> Selector:
    """Parse one `--only` value (`step:<name>` or `validation:<name>`);
    refuses anything else, naming what was given."""
    var at = text.find(String(":"))
    if at < 0:
        raise Error(
            String("--only '") + text
            + String("' is not step:<name> or validation:<name>")
        )
    var kind = String(text[byte=0:at])
    var name = String(text[byte = at + 1 :])
    if kind != SELECTOR_STEP and kind != SELECTOR_VALIDATION:
        raise Error(
            String("--only '") + text + String("': '") + kind
            + String("' is not a selector kind (step or validation)")
        )
    if not is_step_name(name):
        raise Error(
            String("--only '") + text + String("': name '") + name
            + String("' is not [a-z][a-z0-9-]*, at most ") + String(STEP_NAME_MAX_BYTES)
            + String(" bytes, not ending in '-'")
        )
    return Selector(kind^, name^)


def parse_selectors(texts: List[String]) raises -> List[Selector]:
    """Parse every `--only` value in the order given; refuses a malformed
    one and the same selector twice."""
    var out = List[Selector]()
    for i in range(len(texts)):
        var s = parse_selector(texts[i])
        for j in range(len(out)):
            if out[j].canonical() == s.canonical():
                raise Error(String("--only '") + s.canonical() + String("' is given twice"))
        out.append(s^)
    return out^


def scope_of(only: List[String]) -> String:
    """FULL when `only` is empty, SELECTIVE otherwise (file header)."""
    if len(only) == 0:
        return String(SCOPE_FULL)
    return String(SCOPE_SELECTIVE)


def require_scope(word: String) raises:
    if word != SCOPE_FULL and word != SCOPE_SELECTIVE:
        raise Error(String("scope '") + word + String("' is not FULL or SELECTIVE"))


def run_evidence_line(scope: String, stage: String, only: List[String], outcome: String) raises -> String:
    """The one final stderr line of `kci run`. Prefix-safe: a grep for
    `kci: FULL run` never matches a selective run.

      kci: FULL run of stage S: <OUTCOME>
      kci: SELECTIVE run of stage S (step:a step:b): <OUTCOME> -- not a full run
    """
    require_scope(scope)
    if scope == SCOPE_FULL:
        if len(only) > 0:
            raise Error(String("a FULL run has no --only"))
        return String("kci: FULL run of stage ") + stage + String(": ") + outcome
    if len(only) == 0:
        raise Error(String("a SELECTIVE run names its --only"))
    var sel = String("")
    for i in range(len(only)):
        if i > 0:
            sel += String(" ")
        sel += only[i]
    return (
        String("kci: SELECTIVE run of stage ") + stage + String(" (") + sel + String("): ")
        + outcome + String(" -- not a full run")
    )
