# =============================================================================
# src/kci_ci_check/pull_request.mojo -- rule R6 (rules.mojo's header): what
#   runs on a pull request, in the one workflow that also runs the release.
# =============================================================================
#
# One workflow runs every stage of the machine file. When the machine file
# declares a PULL_REQUEST stage, the workflow has a `pull_request` trigger,
# and the job of that stage is the only job that runs on a pull request:
#
#   * the PULL_REQUEST stage's job carries the job-level condition
#     `github.event.pull_request.head.repo.full_name == github.repository`
#     (`check_pull_request_job`). A pull request from a fork then runs
#     nothing, and a push or a manual run (no pull request) skips the job;
#   * every other job is RELEASE-ONLY (`check_release_only`): its job-level
#     `if:` is a conjunction one of whose terms keeps a pull request out
#     (`excludes_pull_request`).
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from .workflow_reader import NODE_MAP, NODE_SCALAR, WorkflowDoc

comptime PULL_REQUEST_BASE_EXPRESSION: String = "github.event.pull_request.base.sha"
"""What a PULL_REQUEST stage's `kci run --affected-by` passes, inside
`${{ }}` (R6): the pull request's base commit, a full commit id."""

comptime SAME_REPOSITORY_CONDITION: String = "github.event.pull_request.head.repo.full_name == github.repository"
"""The job-level `if:` of a PULL_REQUEST stage's job (R6): a fork's pull
request runs nothing, and an event without a pull request skips the job."""

comptime CHECKOUT_ACTION: String = "actions/checkout@"
"""The checkout action's `uses:` prefix; under R6 each such step of a
PULL_REQUEST stage's job fetches the full history."""

comptime PULL_REQUEST_EVENT: String = "pull_request"
"""The event name a release job's condition keeps out (R6)."""


def _at(doc: WorkflowDoc, node: Int) -> String:
    if node < 0:
        return String("")
    return String("line ") + String(doc.line(node)) + String(": ")


def is_expression(text: String, expression: String) -> Bool:
    """`text` is `${{ <expression> }}`, the spacing inside the braces
    aside."""
    var t = String(text.strip())
    if not t.startswith(String("${{")) or not t.endswith(String("}}")) or t.byte_length() < 5:
        return False
    var inner = String(String(t[byte = 3 : t.byte_length() - 2]).strip())
    return inner == expression


def _unwrapped(text: String) -> String:
    """A job condition without its optional `${{ }}`."""
    var t = String(text.strip())
    if t.startswith(String("${{")) and t.endswith(String("}}")) and t.byte_length() >= 5:
        return String(String(t[byte = 3 : t.byte_length() - 2]).strip())
    return t^


comptime EVENT_NAME: String = "github.event_name"
"""The left-hand side of a release job's event term (R6)."""


def _event_literal(text: String) -> String:
    """The literal of `text` when `text` is exactly one single-quoted
    literal of [a-z_]+ and nothing after it; "" otherwise. GitHub compares
    strings case-insensitively, so a literal in another case is not read; a
    GitHub literal is single-quoted, so a double-quoted one is not read."""
    var b = text.as_bytes()
    var n = len(b)
    if n < 3 or b[0] != UInt8(ord("'")) or b[n - 1] != UInt8(ord("'")):
        return String("")
    for i in range(1, n - 1):
        var c = b[i]
        if not ((c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or c == UInt8(ord("_"))):
            return String("")
    return String(text[byte = 1 : n - 1])


def _keeps_pull_request_out(term: String) -> Bool:
    """Exactly `github.event_name != 'pull_request'`, or exactly
    `github.event_name == 'push'` / `== 'workflow_dispatch'` (spaces around
    the operator aside). Any other term is not read as keeping a pull
    request out."""
    var t = String(term.strip())
    var head = String(EVENT_NAME)
    if not t.startswith(head):
        return False
    var rest = String(String(t[byte = head.byte_length() :]).lstrip(String(" ")))
    var op = String(rest[byte=0:2]) if rest.byte_length() >= 2 else String("")
    if op != String("!=") and op != String("=="):
        return False
    var lit = _event_literal(String(String(rest[byte=2:]).lstrip(String(" "))))
    if op == String("!="):
        return lit == String(PULL_REQUEST_EVENT)
    return lit == String("push") or lit == String("workflow_dispatch")


def excludes_pull_request(condition: String) -> Bool:
    """A job condition that a pull request never satisfies (R6): bare or
    inside `${{ }}`, terms joined by `&&` only (no `||`), and one term is
    exactly `github.event_name != 'pull_request'`, `github.event_name ==
    'push'` or `github.event_name == 'workflow_dispatch'`. Anything else is
    not read as release-only."""
    var c = _unwrapped(condition)
    if c.find(String("||")) >= 0:
        return False
    var terms = c.split(String("&&"))
    for i in range(len(terms)):
        if _keeps_pull_request_out(String(terms[i])):
            return True
    return False


def check_release_only(doc: WorkflowDoc, job_id: String, job: Int, stage: String, mut findings: List[String]):
    """R6 for a job that runs a PUSH stage (or a part of one) in a workflow
    triggered by `pull_request`: its job-level `if:` keeps a pull request
    out."""
    var cond = doc.child(job, String("if"))
    if cond >= 0 and doc.kind(cond) == NODE_SCALAR and excludes_pull_request(doc.text(cond)):
        return
    findings.append(
        _at(doc, job) + String("job '") + job_id + String("': R6: runs stage '") + stage
        + String("', a release stage, and the workflow is triggered by pull_request, so the job's `if:` keeps a")
        + String(" pull request out (a term `github.event_name != 'pull_request'`, joined by `&&`): only the")
        + String(" PULL_REQUEST stage's job runs a pull request's code")
    )


def check_pull_request_job(
    doc: WorkflowDoc,
    job_id: String,
    job: Int,
    affected_by: List[String],
    has_affected_by: List[Bool],
    mut findings: List[String],
):
    """R6 for the job of a PULL_REQUEST stage (rules.mojo's header): the
    base commit (each `kci run`'s `--affected-by`, given as two parallel
    lists), the full history, the fork condition and the permissions."""
    var where = _at(doc, job) + String("job '") + job_id + String("': R6: stage '") + job_id + String("' is a PULL_REQUEST stage")
    var want = String("${{ ") + String(PULL_REQUEST_BASE_EXPRESSION) + String(" }}")
    for i in range(len(affected_by)):
        if not has_affected_by[i]:
            findings.append(
                where + String(", so its `kci run` carries --affected-by ") + want
                + String(" (the per-change check of the pull request)")
            )
        elif not is_expression(affected_by[i], String(PULL_REQUEST_BASE_EXPRESSION)):
            findings.append(
                where + String(": `--affected-by ") + affected_by[i] + String("`; it passes ") + want
                + String(", written so")
            )
    var checkouts = 0
    var steps = doc.items(doc.child(job, String("steps")))
    for i in range(len(steps)):
        var u = doc.child(steps[i], String("uses"))
        if u < 0 or doc.kind(u) != NODE_SCALAR or not doc.text(u).startswith(String(CHECKOUT_ACTION)):
            continue
        checkouts += 1
        var depth = doc.child(doc.child(steps[i], String("with")), String("fetch-depth"))
        if depth < 0 or doc.kind(depth) != NODE_SCALAR or doc.text(depth) != String("0"):
            findings.append(
                _at(doc, u) + String("job '") + job_id + String("': R6: its checkout has no `with: fetch-depth: 0`;")
                + String(" kci reads the change from git and refuses a shallow clone")
            )
    if checkouts == 0:
        findings.append(
            where + String(", so the job checks out the full history (`uses: ") + String(CHECKOUT_ACTION)
            + String("<sha>` with `fetch-depth: 0`); it has no checkout step")
        )
    # the fork condition: every PULL_REQUEST stage's job, farm-connected or not
    var cond = doc.child(job, String("if"))
    var ok = False
    if cond >= 0 and doc.kind(cond) == NODE_SCALAR:
        var text = doc.text(cond)
        ok = String(text.strip()) == String(SAME_REPOSITORY_CONDITION) or is_expression(
            text, String(SAME_REPOSITORY_CONDITION)
        )
    if not ok:
        findings.append(
            where + String(", so the job carries `if: ") + String(SAME_REPOSITORY_CONDITION)
            + String("`: a pull request from a fork runs nothing, and an event without a pull request skips the job")
        )
    # permissions: `contents: read`, and `id-token: write` (R4) only for the farm connection
    var perms = doc.child(job, String("permissions"))
    if perms >= 0 and doc.kind(perms) != NODE_MAP:
        findings.append(
            where + String(", so its `permissions` is a mapping of `contents: read` and, only when the stage is")
            + String(" farm-connected, `id-token: write`; it is `") + doc.text(perms) + String("`")
        )
    elif perms >= 0:
        var keys = doc.keys(perms)
        for i in range(len(keys)):
            var v = doc.child(perms, keys[i])
            var value = doc.text(v) if doc.kind(v) == NODE_SCALAR else String("(not a scalar)")
            if keys[i] == String("contents") and value == String("read"):
                continue
            if keys[i] == String("id-token"):
                continue  # R4 holds it to the farm connection
            findings.append(
                where + String(", so its permissions hold only `contents: read` and, for the farm connection,")
                + String(" `id-token: write`; it grants `") + keys[i] + String(": ") + value + String("`")
            )
