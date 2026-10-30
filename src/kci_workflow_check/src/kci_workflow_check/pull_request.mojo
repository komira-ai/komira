# =============================================================================
# src/kci_workflow_check/pull_request.mojo -- rule R6 (rules.mojo's header): what
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
#     `if:` is a TOP-LEVEL conjunction (no grouping, negation, call, `||` or
#     partial `${{ }}`) one of whose terms keeps a pull request out
#     (`excludes_pull_request`). `github.event_name != 'pull_request'`
#     keeps out a pull request only because the triggers are an allow-list
#     (rules.mojo, R6: push, workflow_dispatch and pull_request): any other
#     event that runs a pull request's code is refused as a trigger;
#   * the PULL_REQUEST stage's job runs on `runs-on: ubuntu-24.04`, that
#     plain scalar exactly (`check_pull_request_job`): a GitHub-hosted runner,
#     never a self-hosted label, a label list, a runner group or an
#     expression;
#   * the PULL_REQUEST stage's job has its own `permissions:` mapping
#     (`check_pull_request_job`), and no stored secret reaches it
#     (`check_no_secret`, over the job and the workflow-level `env:`);
#   * a push runs the release jobs only on `main` (auto_promotion.mojo's
#     `check_push_filter`, R17, which took over this clause):
#     `github.event_name != 'pull_request'` holds for a push to a pull
#     request's head branch;
#   * both conditions are read by `condition_expression`: an `if:` holding
#     `${{` is exactly `${{ <expression> }}` (nothing before `${{` or after
#     `}}`, not even whitespace inside quotes) and no block scalar holds it.
#     GitHub reads any other `if:` holding `${{` as a format string, which
#     is always true.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from .workflow_reader import NODE_LIST, NODE_MAP, NODE_SCALAR, WorkflowDoc

comptime CHANGE_BASE_VARIABLE: String = "change_base"
"""The shell variable a PULL_REQUEST stage's `kci run --affected-by` passes
(R6), as `"$change_base"`: the merge commit's first parent, set by
`CHANGE_BASE_LINE` earlier in the same `run:` script."""

comptime CHANGE_BASE_LINE: String = (
    "if ! git rev-parse --verify --quiet HEAD^2 > /dev/null || ! change_base=$(git rev-parse --verify HEAD^1);"
    " then echo \"::error::the change base is the merge commit's first parent, and HEAD is not a merge commit\"; exit 1; fi"
)
"""The line, alone and exactly so, that sets `change_base` (R6). A pull
request's check builds the merge commit GitHub made (`github.sha`, which kci
holds HEAD to); its first parent is exactly the base branch the change is
merged into, so `git diff <it>...HEAD` is the pull request's change and
nothing else. HEAD with no second parent is not a merge commit, and the step
stops."""

comptime EVENT_BASE_EXPRESSION: String = "github.event.pull_request.base.sha"
"""The pull request event's base commit: the base branch when the event
fired, which is not the first parent of the merge commit once the base
branch has moved. As `--affected-by` it widens the check to every change
merged to the base branch since then (R6 refuses it by name)."""

comptime SAME_REPOSITORY_CONDITION: String = "github.event.pull_request.head.repo.full_name == github.repository"
"""The job-level `if:` of a PULL_REQUEST stage's job (R6): a fork's pull
request runs nothing, and an event without a pull request skips the job."""

comptime CHECKOUT_ACTION: String = "actions/checkout@"
"""The checkout action's `uses:` prefix; under R6 each such step of a
PULL_REQUEST stage's job fetches the full history."""

comptime PULL_REQUEST_RUNNER: String = "ubuntu-24.04"
"""The one `runs-on` of a PULL_REQUEST stage's job (R6), as a plain scalar:
a GitHub-hosted runner. A self-hosted label, a label list, a runner group or
an expression could put a pull request's code on a machine that keeps state
between jobs."""

comptime PULL_REQUEST_EVENT: String = "pull_request"
"""The event name a release job's condition keeps out (R6)."""

comptime RELEASE_BRANCH: String = "main"
"""The one branch a `push` trigger names (R17, which took over R6's push
clause)."""

comptime GITHUB_TOKEN_SECRET: String = "secrets.GITHUB_TOKEN"
"""The one name of the `secrets` context a pull request's job may hold
(R6): the job's own token, bounded by its `permissions:`."""


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


def _expression_of(text: String, mut expression: String) -> Bool:
    """The expression GitHub evaluates for a job-level `if:` whose value is
    `text`, written as a plain or quoted scalar. With no `${{` in `text`,
    GitHub reads the whole text as the expression (whitespace around it
    aside). With one, `text` is exactly `${{ <expression> }}`: nothing
    before `${{` or after `}}`, not even whitespace, and no other `${{` or
    `}}` inside. Anything else is a format string, which GitHub reads as
    always true: False (and `expression` unspecified)."""
    if text.find(String("${{")) < 0:
        expression = String(text.strip())
        return True
    var n = text.byte_length()
    if n < 5 or not text.startswith(String("${{")) or not text.endswith(String("}}")):
        return False
    var inner = String(text[byte = 3 : n - 2])
    if inner.find(String("${{")) >= 0 or inner.find(String("}}")) >= 0:
        return False
    expression = String(inner.strip())
    return True


def condition_expression(doc: WorkflowDoc, node: Int, mut expression: String) -> Bool:
    """The expression a job-level `if:` (node `node`) has GitHub evaluate,
    by `_expression_of`. A block scalar holding `${{` is refused whatever its
    chomping: its value is not exactly `${{ <expression> }}` (`|` and `>`
    keep a final newline) and so can be a format string. False when `node`
    is not a scalar."""
    if node < 0 or doc.kind(node) != NODE_SCALAR:
        return False
    var text = doc.text(node)
    if doc.is_block(node) and text.find(String("${{")) >= 0:
        return False
    return _expression_of(text, expression)


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
    request out. The `!=` form holds only with R6's trigger allow-list
    (push, workflow_dispatch, pull_request): an event such as merge_group
    or pull_request_review also runs a pull request's code and is not
    `pull_request`."""
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


def _is_name_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("_"))
        or c == UInt8(ord("."))
        or c == UInt8(ord("-"))
    )


def _is_space_byte(c: UInt8) -> Bool:
    return c == UInt8(ord(" ")) or c == UInt8(ord("\t")) or c == UInt8(ord("\n")) or c == UInt8(ord("\r"))


def _conjunction_terms(condition: String, mut terms: List[String]) -> Bool:
    """The terms of `condition` when it is a TOP-LEVEL conjunction: bare, or
    exactly ONE `${{ }}` with nothing around it (`_expression_of`); then,
    outside single-quoted literals (`''` escapes a quote), only names and
    numbers ([A-Za-z0-9_.-]), whitespace, and the operators `&&`, `==`,
    `!=`, `<`, `<=`, `>`, `>=`. No `(`, `)`, `!` (a negation), `||`, `[`,
    `]`, `*` or `,`, so no grouping, negation, call, index or object filter
    can hold a term, and every `&&` is at the top level. No other `${{` or `}}` anywhere, a literal included: a
    partial `${{ }}` makes GitHub read the whole `if:` as a format() string,
    which is always truthy. False (and `terms` unspecified) otherwise."""
    var c = String("")
    if not _expression_of(condition, c):
        return False
    if c.find(String("${{")) >= 0 or c.find(String("}}")) >= 0:
        return False
    var b = c.as_bytes()
    var n = len(b)
    var quote = UInt8(ord("'"))
    var start = 0
    var i = 0
    while i < n:
        var ch = b[i]
        if ch == quote:
            i += 1
            while True:
                if i >= n:
                    return False  # an unterminated literal
                if b[i] == quote:
                    if i + 1 < n and b[i + 1] == quote:
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            continue
        if _is_name_byte(ch) or _is_space_byte(ch):
            i += 1
            continue
        var next = b[i + 1] if i + 1 < n else UInt8(0)
        if ch == UInt8(ord("&")) and next == UInt8(ord("&")):
            terms.append(String(c[byte = start : i]))
            i += 2
            start = i
            continue
        if next == UInt8(ord("=")) and (
            ch == UInt8(ord("=")) or ch == UInt8(ord("!")) or ch == UInt8(ord("<")) or ch == UInt8(ord(">"))
        ):
            i += 2
            continue
        if ch == UInt8(ord("<")) or ch == UInt8(ord(">")):
            i += 1
            continue
        return False
    terms.append(String(c[byte = start : n]))
    return True


def top_level_terms(doc: WorkflowDoc, node: Int, mut terms: List[String]) -> Bool:
    """The terms of the job-level `if:` at `node` when it is a top-level
    conjunction (`condition_expression`, then `_conjunction_terms`); False
    otherwise (and `terms` unspecified)."""
    var expression = String("")
    if not condition_expression(doc, node, expression):
        return False
    return _conjunction_terms(expression, terms)


def excludes_pull_request(condition: String) -> Bool:
    """A job condition that a pull request never satisfies (R6): a
    top-level conjunction (`_conjunction_terms`: bare or exactly one
    `${{ }}` with nothing around it, terms joined by `&&` only, no
    grouping, negation, call or `||`), one of whose terms is exactly `github.event_name !=
    'pull_request'`, `github.event_name == 'push'` or `github.event_name ==
    'workflow_dispatch'`. Anything else is not read as release-only."""
    var terms = List[String]()
    if not _conjunction_terms(condition, terms):
        return False
    for i in range(len(terms)):
        if _keeps_pull_request_out(terms[i]):
            return True
    return False


def check_release_only(doc: WorkflowDoc, job_id: String, job: Int, stage: String, mut findings: List[String]):
    """R6 for a job that runs a PUSH stage (or a part of one) in a workflow
    triggered by `pull_request`: its job-level `if:` keeps a pull request
    out."""
    var cond = doc.child(job, String("if"))
    var expression = String("")
    if condition_expression(doc, cond, expression) and excludes_pull_request(expression):
        return
    findings.append(
        _at(doc, job) + String("job '") + job_id + String("': R6: runs stage '") + stage
        + String("', a release stage, and the workflow is triggered by pull_request, so the job's `if:` keeps a")
        + String(" pull request out (a top-level conjunction, `&&` only and no grouping, negation, call or partial `${{ }}`,")
        + String(" bare or exactly one `${{ }}` with nothing around it and no block scalar holding `${{`,")
        + String(" with a term `github.event_name != 'pull_request'`): only the")
        + String(" PULL_REQUEST stage's job runs a pull request's code")
    )


def check_pull_request_job(
    doc: WorkflowDoc,
    job_id: String,
    job: Int,
    stage: String,
    affected_by: List[String],
    has_affected_by: List[Bool],
    scripts: List[String],
    mut findings: List[String],
):
    """R6 for the job of a PULL_REQUEST stage (rules.mojo's header): the
    change base (each `kci run`'s `--affected-by`, and the `run:` script
    holding that `kci run`, given as three parallel lists), the full
    history, the fork condition and the permissions."""
    var where = _at(doc, job) + String("job '") + job_id + String("': R6: stage '") + stage + String("' is a PULL_REQUEST stage")
    var arg = String("$") + String(CHANGE_BASE_VARIABLE)
    var want = String("--affected-by \"") + arg + String("\" after the line `") + String(CHANGE_BASE_LINE) + String("`")
    for i in range(len(affected_by)):
        if not has_affected_by[i]:
            findings.append(
                where + String(", so its `kci run` carries ") + want
                + String(" (the per-change check of the pull request)")
            )
        elif is_expression(affected_by[i], String(EVENT_BASE_EXPRESSION)):
            findings.append(
                where + String(": `--affected-by ") + affected_by[i]
                + String("` is the base branch when the event fired, not the first parent of the merge commit")
                + String(" the job builds: once the base branch moves, every change merged to it since then is")
                + String(" counted as the pull request's own and widens the check; it passes ") + want
            )
        elif affected_by[i] != arg:
            findings.append(
                where + String(": `--affected-by ") + affected_by[i] + String("`; it passes ") + want
                + String(", the merge commit's first parent")
            )
        else:
            _check_change_base(scripts[i], where, want, findings)
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
    var expression = String("")
    var ok = condition_expression(doc, cond, expression) and expression == String(SAME_REPOSITORY_CONDITION)
    if not ok:
        findings.append(
            where + String(", so the job carries `if: ") + String(SAME_REPOSITORY_CONDITION)
            + String("`, bare or as exactly `${{ <it> }}` (nothing around it, no block scalar)")
            + String(": a pull request from a fork runs nothing, and an event without a pull request skips the job")
        )
    # the runner: exactly the plain scalar, nothing else
    if not doc.is_plain(doc.child(job, String("runs-on")), String(PULL_REQUEST_RUNNER)):
        var r = doc.child(job, String("runs-on"))
        var got = String("no `runs-on`") if r < 0 else (
            String("`runs-on: ") + doc.text(r) + String("`") if doc.kind(r) == NODE_SCALAR else String("a `runs-on` that is not a scalar")
        )
        findings.append(
            where + String(", so the job runs on `runs-on: ") + String(PULL_REQUEST_RUNNER)
            + String("`, written as that plain scalar (no label list, runner group, expression or quotes); it has ")
            + got
        )
    # permissions: `contents: read`, and `id-token: write` (R4) only for the farm connection
    var perms = doc.child(job, String("permissions"))
    if perms < 0:
        findings.append(
            where + String(", so the job has its own `permissions:` mapping (`contents: read` and, only when the")
            + String(" stage is farm-connected, `id-token: write`); it has none, so it would get the workflow-level")
            + String(" permissions or the repository's default token")
        )
    elif doc.kind(perms) != NODE_MAP:
        findings.append(
            where + String(", so its `permissions` is a mapping of `contents: read` and, only when the stage is")
            + String(" farm-connected, `id-token: write`; it is `") + doc.text(perms) + String("`")
        )
    elif perms >= 0:
        var keys = doc.keys(perms)
        for i in range(len(keys)):
            var v = doc.child(perms, keys[i])
            var value = doc.text(v) if doc.kind(v) == NODE_SCALAR else String("(not a scalar)")
            if keys[i] == String("contents") and doc.is_plain(v, String("read")):
                continue
            if keys[i] == String("id-token"):
                continue  # R4 holds it to the farm connection
            findings.append(
                where + String(", so its permissions hold only `contents: read` and, for the farm connection,")
                + String(" `id-token: write`; it grants `") + keys[i] + String(": ") + value + String("`")
            )


def _count(text: String, needle: String) -> Int:
    var n = 0
    var at = text.find(needle)
    while at >= 0:
        n += 1
        at = text.find(needle, at + needle.byte_length())
    return n


def _check_change_base(script: String, where: String, want: String, mut findings: List[String]):
    """R6: the `run:` script whose `kci run` passes `--affected-by
    "$change_base"` sets it by `CHANGE_BASE_LINE`, a line of its own before
    the `kci run`, and names `change_base` nowhere else (no second
    assignment, `read`, `export` or `${change_base}`)."""
    var line = String(CHANGE_BASE_LINE)
    var at = -1
    if script.startswith(line + String("\n")):
        at = 0
    else:
        var nl = script.find(String("\n") + line + String("\n"))
        if nl >= 0:
            at = nl + 1
    var use = script.find(String("$") + String(CHANGE_BASE_VARIABLE))
    if at < 0 or use < at:
        findings.append(
            where + String(": its `kci run` passes --affected-by \"$") + String(CHANGE_BASE_VARIABLE)
            + String("\" and the script does not set it before, so it passes ") + want
        )
    elif _count(script, String(CHANGE_BASE_VARIABLE)) != 2:
        findings.append(
            where + String(": the script names `") + String(CHANGE_BASE_VARIABLE) + String("` ")
            + String(_count(script, String(CHANGE_BASE_VARIABLE)))
            + String(" times; exactly twice, where it is set and as --affected-by, so nothing else changes it")
        )


# ---- what reaches a pull request's job, and the push branch ---------------------


def _is_secret_name_byte(c: UInt8) -> Bool:
    """[A-Za-z0-9_]"""
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("_"))
    )


def _lower_byte(c: UInt8) -> UInt8:
    if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
        return c + 32
    return c


def _names_a_secret(text: String) -> Bool:
    """`text` names the `secrets` context: the word `secrets` in any case,
    not inside a longer name ([A-Za-z0-9_]), anywhere in `text` (a
    `${{ }}`, a bare `if:`, a shell word alike), other than exactly
    `secrets.GITHUB_TOKEN` followed by no name byte. Read wide on purpose:
    `secrets.X`, `SECRETS.X`, `secrets['X']` and `toJSON(secrets)` all
    name it."""
    var b = text.as_bytes()
    var n = len(b)
    var word_text = String("secrets")
    var token_text = String(GITHUB_TOKEN_SECRET)
    var word = word_text.as_bytes()
    var token = token_text.as_bytes()
    for i in range(n - len(word) + 1):
        var hit = True
        for k in range(len(word)):
            if _lower_byte(b[i + k]) != word[k]:
                hit = False
                break
        if not hit:
            continue
        if i > 0 and _is_secret_name_byte(b[i - 1]):
            continue
        var end = i + len(word)
        if end < n and _is_secret_name_byte(b[end]):
            continue
        var is_token = i + len(token) <= n
        if is_token:
            for k in range(len(token)):
                if b[i + k] != token[k]:
                    is_token = False
                    break
        if is_token and i + len(token) < n and _is_secret_name_byte(b[i + len(token)]):
            is_token = False
        if not is_token:
            return True
    return False


def check_no_secret(doc: WorkflowDoc, node: Int, key: String, whose: String, mut findings: List[String]):
    """R6: no scalar under `node` (the value of `key`) names the `secrets`
    context, and no key under it is `secrets` in any case."""
    if node < 0:
        return
    var kind = doc.kind(node)
    if kind == NODE_SCALAR:
        if _names_a_secret(doc.text(node)):
            findings.append(
                _at(doc, node) + whose + String("R6: the value of `") + key
                + String("` names the `secrets` context; no stored secret reaches a pull request's code")
                + String(" (only `") + String(GITHUB_TOKEN_SECRET) + String("`, written so, is the job's own token)")
            )
        return
    var keys = doc.keys(node)
    var items = doc.items(node)
    for i in range(len(items)):
        var at_key = key.copy()
        if kind == NODE_MAP:
            at_key = keys[i].copy()
            if keys[i].lower() == String("secrets"):
                findings.append(
                    _at(doc, items[i]) + whose + String("R6: key `") + keys[i]
                    + String("` passes stored secrets; no stored secret reaches a pull request's code")
                )
                continue
        check_no_secret(doc, items[i], at_key, whose, findings)
