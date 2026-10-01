# =============================================================================
# kci_deploy/reporter.mojo -- the REPORTER seam of the deploy library.
# =============================================================================
#
# `deploy_plan` / `deploy_apply` emit structured events (a planned action, an
# applied node, an informational note) through this trait. The reconcile core
# and every conformer are identical across frontends; the reporter is one of
# the two intended forks (the other is the creds provider). A frontend picks its
# conformer once per invocation and the facade is generic over it, so a new
# frontend binds its own reporter with no library change.
#
# Conformers:
#   * StdoutReporter    -- human-readable lines to stdout (the CLI default).
#   * JsonLinesReporter -- one JSON object per event, buffered and written to a
#     local file on `finish`.
#   * CaptureReporter   -- an in-memory line buffer for hermetic tests.
#
# ENCAPSULATION: value-typed surface (`ChangeAction` / `AppliedNode` / `String`
# in, `raises` for an I/O fault). No pointer field, no wildcard origin.
# =============================================================================

from kci_iac import (
    ChangeAction,
    AppliedNode,
    VERB_CREATE,
    VERB_UPDATE,
    VERB_REPLACE,
    VERB_DELETE,
)


def verb_label(verb: Int) -> StaticString:
    """The VERB_* code -> a lowercase label (create / update / replace / delete /
    noop). `ChangeAction` has its own `verb_name`; `AppliedNode` carries a bare
    Int verb."""
    if verb == VERB_CREATE:
        return "create"
    if verb == VERB_UPDATE:
        return "update"
    if verb == VERB_REPLACE:
        return "replace"
    if verb == VERB_DELETE:
        return "delete"
    return "noop"


def _json_escape(s: String) -> String:
    """Minimal JSON string-body escaper (backslash, quote and the common control
    characters), enough for logical ids, physical ids and reasons."""
    var out = s.replace("\\", "\\\\")
    out = out.replace('"', '\\"')
    out = out.replace("\n", "\\n")
    out = out.replace("\t", "\\t")
    out = out.replace("\r", "\\r")
    return out^


trait Reporter(Movable, Deinitable):
    """The frontend-terminated reporting seam the deploy facade emits events
    through. Every method `raises` so a file-backed conformer can surface a write
    fault."""

    def begin(mut self, phase: String, env: String) raises:
        """Open a `phase` ("plan" / "apply") for environment `env`."""
        ...

    def plan_action(mut self, action: ChangeAction) raises:
        """Report one dry-run `ChangeAction`."""
        ...

    def applied_node(mut self, node: AppliedNode) raises:
        """Report one converged `AppliedNode`."""
        ...

    def info(mut self, message: String) raises:
        """Report a freeform informational note."""
        ...

    def finish(mut self, summary: String) raises:
        """Close the phase with a one-line `summary`; a file-backed conformer
        writes here."""
        ...


struct StdoutReporter(Reporter, Copyable, Movable, Deinitable):
    """A `Reporter` that prints human-readable lines to stdout, each phase
    headed by `brand` (the CLI name)."""

    var _brand: String

    def __init__(out self, brand: String = String("kci")):
        self._brand = brand

    def begin(mut self, phase: String, env: String) raises:
        print(
            self._brand
            + String(" ")
            + phase
            + String(" [env: ")
            + env
            + String("]")
        )

    def plan_action(mut self, action: ChangeAction) raises:
        print(
            String("  ")
            + action.verb_name()
            + String("  ")
            + action.logical_id
            + String("   (")
            + action.reason
            + String(")")
        )

    def applied_node(mut self, node: AppliedNode) raises:
        var adopted = String(" [adopted]") if node.already_confirmed else String(
            ""
        )
        print(
            String("  ")
            + verb_label(node.verb)
            + String("  ")
            + node.logical_id
            + String(" -> ")
            + node.physical_id
            + adopted
        )

    def info(mut self, message: String) raises:
        print(String("  ") + message)

    def finish(mut self, summary: String) raises:
        print(summary)


struct JsonLinesReporter(Reporter, Movable, Deinitable):
    """A `Reporter` that renders each event as one JSON object and writes them,
    one per line, to `path` on `finish`."""

    var _path: String
    var _buf: List[String]

    def __init__(out self, path: String):
        self._path = path
        self._buf = List[String]()

    def begin(mut self, phase: String, env: String) raises:
        self._buf.append(
            String('{"event":"begin","phase":"')
            + _json_escape(phase)
            + String('","env":"')
            + _json_escape(env)
            + String('"}')
        )

    def plan_action(mut self, action: ChangeAction) raises:
        self._buf.append(
            String('{"event":"plan_action","verb":"')
            + action.verb_name()
            + String('","logical_id":"')
            + _json_escape(action.logical_id)
            + String('","reason":"')
            + _json_escape(action.reason)
            + String('"}')
        )

    def applied_node(mut self, node: AppliedNode) raises:
        self._buf.append(
            String('{"event":"applied_node","verb":"')
            + verb_label(node.verb)
            + String('","logical_id":"')
            + _json_escape(node.logical_id)
            + String('","physical_id":"')
            + _json_escape(node.physical_id)
            + String('","adopted":')
            + (String("true") if node.already_confirmed else String("false"))
            + String("}")
        )

    def info(mut self, message: String) raises:
        self._buf.append(
            String('{"event":"info","message":"')
            + _json_escape(message)
            + String('"}')
        )

    def finish(mut self, summary: String) raises:
        self._buf.append(
            String('{"event":"finish","summary":"')
            + _json_escape(summary)
            + String('"}')
        )
        var blob = String("")
        for i in range(len(self._buf)):
            blob += self._buf[i] + String("\n")
        with open(self._path, "w") as f:
            f.write(blob)


struct CaptureReporter(Reporter, Movable, Deinitable):
    """A `Reporter` that appends a compact `event:field:field:...` line per
    event to an owned buffer, for substring assertions in hermetic tests."""

    var _lines: List[String]

    def __init__(out self):
        self._lines = List[String]()

    def begin(mut self, phase: String, env: String) raises:
        self._lines.append(
            String("begin:") + phase + String(":") + env
        )

    def plan_action(mut self, action: ChangeAction) raises:
        self._lines.append(
            String("plan_action:")
            + action.verb_name()
            + String(":")
            + action.logical_id
            + String(":")
            + action.reason
        )

    def applied_node(mut self, node: AppliedNode) raises:
        self._lines.append(
            String("applied_node:")
            + verb_label(node.verb)
            + String(":")
            + node.logical_id
            + String(":")
            + node.physical_id
            + String(":")
            + (String("adopted") if node.already_confirmed else String("fresh"))
        )

    def info(mut self, message: String) raises:
        self._lines.append(String("info:") + message)

    def finish(mut self, summary: String) raises:
        self._lines.append(String("finish:") + summary)

    def line_count(self) -> Int:
        """How many event lines were captured."""
        return len(self._lines)

    def line_at(self, i: Int) -> String:
        """The captured line at index `i`."""
        return self._lines[i]

    def contains(self, needle: String) -> Bool:
        """True iff any captured line contains `needle`."""
        for i in range(len(self._lines)):
            if self._lines[i].find(needle) >= 0:
                return True
        return False
