# =============================================================================
# src/kci_workflow_check/pull_request_events.mojo -- rule R6 (rules.mojo's
#   header): the events that run pr.yml, the pull request's check, and what
#   its job's `if:` and its `kci run --affected-by` evaluate to under each.
# =============================================================================
#
# pr.yml runs on two events, and on nothing else:
#
#   pull_request  a pull request to main: GITHUB_SHA is the pull request's
#                 merge commit, `github.event.pull_request.base.sha` its base;
#   merge_group   a merge-queue candidate (activity `checks_requested`):
#                 GITHUB_SHA is the merge group's commit,
#                 `github.event.merge_group.base_sha` the base branch's
#                 commit it was cut from. The event carries no
#                 `pull_request` object, and the queue builds its branch in
#                 this repository: there is no fork to keep out.
#
# A job-level `if:` and a `--affected-by` value are EVALUATED per event, by
# a reader of a closed grammar (anything outside it reads as nothing, so
# the rule refuses it):
#
#   base       <path> | github.event_name == '<event>' && <path> || <path>
#              a <path> is one of the two base commits above. GitHub's
#              `a && b || c` is b when a holds and b is not empty, else c;
#              a base commit is never empty under its own event, so the
#              form selects by event (`base_for_event`).
#   condition  <same-repository> | github.event_name == '<event>' || <condition>
#              <same-repository> is `github.event.pull_request.head.repo.
#              full_name == github.repository`: true for a pull request from
#              a branch of this repository, false for a fork's and false on
#              an event with no pull request (null is no repository name),
#              which skips the job (`condition_for_event`).
#
# Tokens are names ([A-Za-z0-9_.-]), single-quoted literals of [a-z_],
# `==`, `&&` and `||`, with whitespace between them; any other byte reads as
# nothing.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from .workflow_reader import NODE_LIST, NODE_MAP, NODE_SCALAR, WorkflowDoc

comptime PULL_REQUEST_EVENT: String = "pull_request"
"""The pull request's event; a release job's condition keeps it out (R6)."""

comptime MERGE_GROUP_EVENT: String = "merge_group"
"""The merge queue's event: pr.yml's second trigger (R6)."""

comptime MERGE_GROUP_ACTIVITY: String = "checks_requested"
"""The one activity type of `merge_group`, and the one pr.yml lists."""

comptime PULL_REQUEST_BASE_EXPRESSION: String = "github.event.pull_request.base.sha"
"""What a PULL_REQUEST stage's `kci run --affected-by` reads on a
`pull_request` run (R6): the pull request's base commit, a full commit id."""

comptime MERGE_GROUP_BASE_EXPRESSION: String = "github.event.merge_group.base_sha"
"""What a PULL_REQUEST stage's `kci run --affected-by` reads on a
`merge_group` run (R6): the base branch's commit the merge group was cut
from, a full commit id."""

comptime SAME_REPOSITORY_CONDITION: String = "github.event.pull_request.head.repo.full_name == github.repository"
"""The same-repository term of a PULL_REQUEST stage's job-level `if:` (R6):
a fork's pull request runs nothing, and an event without a pull request
skips the job."""

comptime MERGE_GROUP_CONDITION: String = "github.event_name == 'merge_group' || github.event.pull_request.head.repo.full_name == github.repository"
"""The job-level `if:` of a PULL_REQUEST stage's job when pr.yml has the
`merge_group` trigger (R6): a merge group runs the job, a pull request only
from a branch of this repository."""

comptime BASE_EXPRESSION: String = "github.event_name == 'merge_group' && github.event.merge_group.base_sha || github.event.pull_request.base.sha"
"""The `--affected-by` of a PULL_REQUEST stage's `kci run` when pr.yml has
the `merge_group` trigger (R6), inside `${{ }}`."""

comptime RUNS: String = "runs"
"""`condition_for_event`: the job runs on every run of the event."""

comptime SAME_REPOSITORY: String = "same repository"
"""`condition_for_event`: the job runs for a pull request from a branch of
this repository only."""

comptime SKIPPED: String = "skipped"
"""`condition_for_event`: the job never runs on the event."""


def pull_request_stage_events() -> List[String]:
    """The events pr.yml may be triggered by, and the only ones `kci run`
    runs a PULL_REQUEST stage on under GitHub Actions: `pull_request` and
    `merge_group`."""
    var e = List[String]()
    e.append(String(PULL_REQUEST_EVENT))
    e.append(String(MERGE_GROUP_EVENT))
    return e^


def is_pull_request_stage_event(name: String) -> Bool:
    """`name` is one of `pull_request_stage_events`, written exactly."""
    var events = pull_request_stage_events()
    for i in range(len(events)):
        if events[i] == name:
            return True
    return False


def base_context(event: String) -> String:
    """The base commit `kci run --affected-by` reads on a run of `event`
    (file header); "" for any other event."""
    if event == String(PULL_REQUEST_EVENT):
        return String(PULL_REQUEST_BASE_EXPRESSION)
    if event == String(MERGE_GROUP_EVENT):
        return String(MERGE_GROUP_BASE_EXPRESSION)
    return String("")


def _is_name_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("."))
        or c == UInt8(ord("-"))
    )


def _tokens(expression: String, mut out: List[String]) -> Bool:
    """The tokens of `expression` (file header); False when a byte is
    outside them (and `out` unspecified). A literal keeps its quotes."""
    var b = expression.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        if c == UInt8(ord(" ")) or c == UInt8(ord("\t")) or c == UInt8(ord("\n")):
            i += 1
            continue
        if _is_name_byte(c):
            var start = i
            while i < n and _is_name_byte(b[i]):
                i += 1
            out.append(String(expression[byte = start : i]))
            continue
        if c == UInt8(ord("'")):
            var start = i
            i += 1
            while i < n and b[i] != UInt8(ord("'")):
                var l = b[i]
                if not ((l >= UInt8(ord("a")) and l <= UInt8(ord("z"))) or l == UInt8(ord("_"))):
                    return False
                i += 1
            if i >= n or i == start + 1:
                return False
            i += 1
            out.append(String(expression[byte = start : i]))
            continue
        var next = b[i + 1] if i + 1 < n else UInt8(0)
        if (c == UInt8(ord("=")) or c == UInt8(ord("&")) or c == UInt8(ord("|"))) and next == c:
            out.append(String(expression[byte = i : i + 2]))
            i += 2
            continue
        return False
    return True


def _is_base_path(token: String) -> Bool:
    return token == String(PULL_REQUEST_BASE_EXPRESSION) or token == String(MERGE_GROUP_BASE_EXPRESSION)


def _is_event_test(t: List[String], at: Int) -> Bool:
    """`t[at:at+3]` is `github.event_name == '<literal>'`."""
    return (
        at + 2 < len(t)
        and t[at] == String("github.event_name")
        and t[at + 1] == String("==")
        and t[at + 2].startswith(String("'"))
    )


def _literal(token: String) -> String:
    return String(token[byte = 1 : token.byte_length() - 1])


def base_for_event(expression: String, event: String) -> String:
    """The base commit GitHub passes for `expression` (inside `${{ }}`) on a
    run of `event`: one of the two base paths, by the file header's base
    grammar; "" when `expression` is outside it."""
    var t = List[String]()
    if not _tokens(expression, t):
        return String("")
    if len(t) == 1 and _is_base_path(t[0]):
        return t[0].copy()
    if (
        len(t) == 7
        and _is_event_test(t, 0)
        and t[3] == String("&&")
        and _is_base_path(t[4])
        and t[5] == String("||")
        and _is_base_path(t[6])
    ):
        return t[4].copy() if _literal(t[2]) == event else t[6].copy()
    return String("")


def is_base_expression(text: String) -> Bool:
    """`text` is exactly `${{ <expression> }}` (spacing inside the braces
    aside) and `<expression>` is in the base grammar (file header): what
    R18 lets a `run:` script hold."""
    var s = String(text.strip())
    if not s.startswith(String("${{")) or not s.endswith(String("}}")) or s.byte_length() < 5:
        return False
    var inner = String(s[byte = 3 : s.byte_length() - 2])
    return base_for_event(inner, String(PULL_REQUEST_EVENT)).byte_length() > 0


def _condition_from(t: List[String], at: Int, event: String) -> String:
    var rest = len(t) - at
    if (
        rest == 3
        and t[at] == String("github.event.pull_request.head.repo.full_name")
        and t[at + 1] == String("==")
        and t[at + 2] == String("github.repository")
    ):
        return String(SAME_REPOSITORY) if event == String(PULL_REQUEST_EVENT) else String(SKIPPED)
    if rest > 4 and _is_event_test(t, at) and t[at + 3] == String("||"):
        if _literal(t[at + 2]) == event:
            return String(RUNS)
        return _condition_from(t, at + 4, event)
    return String("")


def condition_for_event(expression: String, event: String) -> String:
    """What a job-level `if:` whose expression is `expression` does on a run
    of `event`, by the file header's condition grammar: `RUNS`,
    `SAME_REPOSITORY` or `SKIPPED`; "" when `expression` is outside it."""
    var t = List[String]()
    if not _tokens(expression, t):
        return String("")
    return _condition_from(t, 0, event)


def _at(doc: WorkflowDoc, node: Int) -> String:
    if node < 0:
        return String("")
    return String("line ") + String(doc.line(node)) + String(": ")


def _merge_group_value_ok(doc: WorkflowDoc, node: Int) -> Bool:
    """`merge_group:` with no value, or exactly `types: [checks_requested]`."""
    if node < 0:
        return False
    if doc.kind(node) == NODE_SCALAR:
        return doc.text(node).byte_length() == 0
    if doc.kind(node) != NODE_MAP:
        return False
    var keys = doc.keys(node)
    if len(keys) != 1 or keys[0] != String("types"):
        return False
    var types = doc.child(node, String("types"))
    if doc.kind(types) != NODE_LIST:
        return False
    var items = doc.scalar_or_list(types)
    return len(items) == 1 and items[0] == String(MERGE_GROUP_ACTIVITY)


def check_pull_request_triggers(doc: WorkflowDoc, on: Int, triggers: List[String], mut findings: List[String]):
    """R6 for pr.yml's `on:` (whose keys or items are `triggers`): exactly
    `pull_request` and, optionally, `merge_group` (no value, or `types:
    [checks_requested]`); any other event is refused."""
    if len(triggers) == 0:
        findings.append(String("R6: the workflow has no `on:` triggers"))
    var has_pull_request = False
    for i in range(len(triggers)):
        if triggers[i] == String(PULL_REQUEST_EVENT):
            has_pull_request = True
        elif triggers[i] == String(MERGE_GROUP_EVENT):
            if doc.kind(on) == NODE_MAP and not _merge_group_value_ok(doc, doc.child(on, triggers[i])):
                findings.append(
                    _at(doc, on) + String("R6: trigger 'merge_group' takes no value or exactly `types: [")
                    + String(MERGE_GROUP_ACTIVITY) + String("]`, its one activity type")
                )
        elif triggers[i] == String("pull_request_target"):
            findings.append(
                _at(doc, on) + String("R6: trigger 'pull_request_target': it runs a pull request's code with the")
                + String(" base repository's secrets, and no workflow has it")
            )
        else:
            findings.append(
                _at(doc, on) + String("R6: trigger '") + triggers[i]
                + String("': pr.yml is triggered by `pull_request` and `merge_group` alone (a push, a manual run,")
                + String(" a schedule or a workflow_run is no pull request's check)")
            )
    if not has_pull_request:
        findings.append(_at(doc, on) + String("R6: pr.yml has no `pull_request` trigger"))


def triggered_events(doc: WorkflowDoc) -> List[String]:
    """The events of `pull_request_stage_events` that `doc`'s `on:` names,
    in that order: the events a PULL_REQUEST stage's job is evaluated for
    (`condition_for_event`, `base_for_event`)."""
    var out = List[String]()
    var on = doc.child(0, String("on"))
    if on < 0:
        return out^
    var named = doc.keys(on) if doc.kind(on) == NODE_MAP else doc.scalar_or_list(on)
    var events = pull_request_stage_events()
    for i in range(len(events)):
        for k in range(len(named)):
            if named[k] == events[i]:
                out.append(events[i].copy())
                break
    return out^
