# =============================================================================
# src/kci_ci_check/auto_promotion.mojo -- rules R13 to R18 (and R4's
#   permission allow-list): continuous auto-promotion, where a push to main
#   IS the release (build -> gamma -> validate -> prod), held to the machine
#   file.
# =============================================================================
#
#   R13 MAIN-ONLY STAGES. The machine file's `break_glass` stage field says
#       which stages a manual run of another branch may run (a PREFIX of the
#       chain; kci_release_machine refuses anything else). The job of every
#       PUSH stage WITHOUT `break_glass`, and every part job of one, carries
#       the top-level conjunct `github.ref == 'refs/heads/main'` in its
#       job-level `if:` (exactly that term, spaces around `==` aside; read
#       by pull_request.mojo's `top_level_terms`, so a grouping, negation,
#       call or `||` reads as missing). `github.ref_name == 'main'` is not
#       it (a TAG named main matches). A break_glass stage's job never
#       carries it: the workflow and the machine file would disagree about
#       which stages a branch reaches.
#   R14 ONE RELEASE AT A TIME. The workflow-level `concurrency:` is a
#       mapping of exactly `group` and `cancel-in-progress`, each the
#       canonical text below byte for byte: a pull request's runs in a
#       group per pull request (a newer push cancels the older check); a
#       run of main in `kci-release-main`, never cancelled in progress (a
#       newer run replaces only the PENDING one); a break-glass run in a
#       group per branch. No job has a `concurrency:` of its own (a
#       job-level group's pending replacement could drop a prod job).
#   R15 THE PUSH FILTER (took over R6's push clause). `on.push` holds
#       exactly `branches: [main]` (a list of one plain item) and
#       `paths-ignore:`, a BLOCK list of exactly the quoted items 'docs/**'
#       then '**.md'. No `paths`, `branches-ignore` or `tags`, no other or
#       reordered item, no flow list; no path filter under `pull_request`.
#       `documentation_filter_findings` (the welded repository test) holds
#       release_version.sh's `:(exclude)` set to the same documentation:
#       its excludes are `docs`, `*.md` and `.github`, and `.github` stays a
#       trigger on purpose (it changes the release machinery).
#   R16 THE MANUAL RUN'S INPUTS. `workflow_dispatch.inputs` is exactly
#       `revision` (type string), `reason` (type string, `required: true`,
#       no default) and `dry_run` (type boolean, `default: false`). No
#       `run:` script of any job holds a `${{ }}` expression other than the
#       pull request's base commit (`${{ github.event.pull_request.base.sha
#       }}`): an input (the reason above all) or the event payload expanded
#       into a script is script injection, so a value reaches a script only
#       through an `env:` value.
#   R17 THE SAME SET, BY HASH. Every job of a PUSH stage with an `after`
#       that runs a PUBLISH step or a validation (a part job always) passes
#       its one `kci run` `--release-set-hash "$RELEASE_SET_HASH"`, and its
#       job-level `env:` sets RELEASE_SET_HASH to exactly `${{
#       needs.<J>.outputs.<O> }}`, where, for the stage's `after` stage A:
#       when A has validations, J is the job that runs them (A's part job,
#       or A's own job when A is not split) and O is `validated_set_hash`;
#       otherwise J is A's job and O is `set_hash`. So prod publishes the set
#       validate installed, never build's or gamma's word for it, and no
#       literal stands in for it. Job J declares the output O.
#   R18 THE PROD LINE. Every job of a PUSH stage, and every part job of one,
#       ends with a step named `the prod line` whose `if:` is `always()`: one
#       plain line in the job summary says what happens to prod.
#   R4  (amended) a `permissions:` mapping, of the workflow or of a release
#       job, grants `contents: read` and R4's `id-token` only: no other
#       permission (no `actions: read`, no write) reaches a release job. The
#       PULL_REQUEST stage's job is R6's.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from kci_release_machine import ReleaseMachine, Stage

from .kci_run_calls import KciRunCall, kci_run_calls
from .pull_request import PULL_REQUEST_BASE_EXPRESSION, RELEASE_BRANCH, is_expression, top_level_terms
from .workflow_reader import NODE_LIST, NODE_MAP, NODE_SCALAR, WorkflowDoc

comptime MAIN_REF_TERM: String = "github.ref == 'refs/heads/main'"
"""R13: the conjunct of a main-only stage's job."""

comptime CONCURRENCY_GROUP: String = (
    "kci-${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number)"
    " || github.ref == 'refs/heads/main' && 'release-main' || format('breakglass-{0}', github.ref_name) }}"
)
"""R14: the workflow-level concurrency group, byte for byte."""

comptime CONCURRENCY_CANCEL: String = "${{ github.event_name == 'pull_request' }}"
"""R14: `cancel-in-progress`, byte for byte: only a pull request's check is
cancelled in progress."""

comptime PROD_LINE_STEP: String = "the prod line"
"""R18: the name of every release job's last step."""

comptime SET_HASH_ENV: String = "RELEASE_SET_HASH"
"""R17: the job-level env variable `--release-set-hash` reads."""

comptime SET_HASH_OUTPUT: String = "set_hash"
comptime VALIDATED_SET_HASH_OUTPUT: String = "validated_set_hash"


def _at(doc: WorkflowDoc, node: Int) -> String:
    if node < 0:
        return String("")
    return String("line ") + String(doc.line(node)) + String(": ")


def _is_main_term(term: String) -> Bool:
    """Exactly `github.ref == 'refs/heads/main'`, spaces around `==`
    aside."""
    var t = String(term.strip())
    var head = String("github.ref")
    if not t.startswith(head):
        return False
    var rest = String(String(t[byte = head.byte_length() :]).lstrip(String(" ")))
    if not rest.startswith(String("==")):
        return False
    var lit = String(String(rest[byte=2:]).lstrip(String(" ")))
    return lit == String("'refs/heads/") + String(RELEASE_BRANCH) + String("'")


def check_main_only(doc: WorkflowDoc, job_id: String, job: Int, st: Stage, mut findings: List[String]):
    """R13 for a job that runs PUSH stage `st` or a part of it."""
    var terms = List[String]()
    var read = top_level_terms(doc, doc.child(job, String("if")), terms)
    var has_main = False
    if read:
        for i in range(len(terms)):
            if _is_main_term(terms[i]):
                has_main = True
    var where = _at(doc, job) + String("job '") + job_id + String("': R13: stage '") + st.name + String("'")
    if not st.break_glass and not has_main:
        findings.append(
            where + String(" runs only on main (the machine file gives it no `break_glass`), so the job's `if:` is")
            + String(" a top-level conjunction with the term `") + String(MAIN_REF_TERM)
            + String("` (not `github.ref_name`, which a tag named main matches)")
        )
    elif st.break_glass and has_main:
        findings.append(
            where + String(" is break_glass in the machine file (a manual run of a branch runs it), and the job's")
            + String(" `if:` holds `") + String(MAIN_REF_TERM) + String("`: the workflow and the machine file disagree")
        )


def check_concurrency(doc: WorkflowDoc, mut findings: List[String]):
    """R14: the workflow-level `concurrency:` mapping, and no job's own."""
    var c = doc.child(0, String("concurrency"))
    var why = String("")
    if c < 0:
        why = String("there is none")
    elif doc.kind(c) != NODE_MAP:
        why = String("it is not a mapping of `group` and `cancel-in-progress`")
    else:
        var keys = doc.keys(c)
        var group = doc.child(c, String("group"))
        var cancel = doc.child(c, String("cancel-in-progress"))
        if len(keys) != 2 or group < 0 or cancel < 0:
            why = String("its keys are not exactly `group` and `cancel-in-progress`")
        elif doc.kind(group) != NODE_SCALAR or doc.is_block(group) or doc.text(group) != String(CONCURRENCY_GROUP):
            why = String("its `group` is not the canonical one")
        elif doc.kind(cancel) != NODE_SCALAR or doc.is_block(cancel) or doc.text(cancel) != String(CONCURRENCY_CANCEL):
            why = String("its `cancel-in-progress` is not the canonical one")
    if why.byte_length() > 0:
        findings.append(
            _at(doc, c) + String("R14: the workflow-level `concurrency:` is exactly `group: ") + String(CONCURRENCY_GROUP)
            + String("` and `cancel-in-progress: ") + String(CONCURRENCY_CANCEL)
            + String("` (one release of main at a time, never cancelled in progress, the newest pending run")
            + String(" wins); ") + why
        )
    var jobs = doc.child(0, String("jobs"))
    var ids = doc.keys(jobs)
    var nodes = doc.items(jobs)
    for i in range(len(ids)):
        var jc = doc.child(nodes[i], String("concurrency"))
        if jc >= 0:
            findings.append(
                _at(doc, jc) + String("job '") + ids[i] + String("': R14: a job has no `concurrency:` of its own")
                + String(" (its pending replacement could drop a release job); the workflow's group holds the run")
            )


def _push_filter_ok(doc: WorkflowDoc, push: Int) -> Bool:
    if push < 0 or doc.kind(push) != NODE_MAP or len(doc.keys(push)) != 2:
        return False
    var branches = doc.child(push, String("branches"))
    if branches < 0 or doc.kind(branches) != NODE_LIST:
        return False
    var b = doc.items(branches)
    if len(b) != 1 or not doc.is_plain(b[0], String(RELEASE_BRANCH)):
        return False
    var ignore = doc.child(push, String("paths-ignore"))
    if ignore < 0 or doc.kind(ignore) != NODE_LIST:
        return False
    var items = doc.items(ignore)
    var want = documentation_paths()
    if len(items) != len(want):
        return False
    for i in range(len(items)):
        # quoted: a flow list's items are always plain
        if doc.kind(items[i]) != NODE_SCALAR or doc.nodes[items[i]].plain or doc.text(items[i]) != want[i]:
            return False
    return True


def documentation_paths() -> List[String]:
    """R15: the push trigger's `paths-ignore`, in order."""
    var out = List[String]()
    out.append(String("docs/**"))
    out.append(String("**.md"))
    return out^


def check_push_filter(doc: WorkflowDoc, on: Int, mut findings: List[String]):
    """R15 (file header)."""
    var push = doc.child(on, String("push"))
    var has_push = push >= 0
    if not has_push and on >= 0 and doc.kind(on) != NODE_MAP:
        # `on: push` or `on: [push, ...]`: a push with no filter at all
        var events = doc.scalar_or_list(on)
        for i in range(len(events)):
            if events[i] == String("push"):
                has_push = True
    if has_push and not _push_filter_ok(doc, push):
        findings.append(
            _at(doc, push) + String("R15: the push trigger is exactly `branches: [") + String(RELEASE_BRANCH)
            + String("]` and a block list `paths-ignore:` of '") + String("', '").join(documentation_paths())
            + String("' in that order: another branch filter, `branches-ignore`, `tags`, `paths` or another")
            + String(" documentation list releases on a push it should not, or skips one it should")
        )
    var pr = doc.child(on, String("pull_request"))
    for key in [String("paths"), String("paths-ignore")]:
        var p = doc.child(pr, key)
        if p >= 0:
            findings.append(
                _at(doc, p) + String("R15: `pull_request` has `") + key
                + String("`: the pull request's check runs on every change it can reach (kci decides what it builds)")
            )


def _plain_child(doc: WorkflowDoc, node: Int, key: String, want: String) -> Bool:
    return doc.is_plain(doc.child(node, key), want)


def check_dispatch_inputs(doc: WorkflowDoc, on: Int, mut findings: List[String]):
    """R16: the inputs of `workflow_dispatch` (file header)."""
    var inputs = doc.child(doc.child(on, String("workflow_dispatch")), String("inputs"))
    var where = _at(doc, inputs) + String("R16: workflow_dispatch's inputs")
    var keys = doc.keys(inputs)
    for i in range(len(keys)):
        if keys[i] != String("revision") and keys[i] != String("reason") and keys[i] != String("dry_run"):
            findings.append(where + String(" are exactly revision, reason and dry_run; it has '") + keys[i] + String("'"))
    var revision = doc.child(inputs, String("revision"))
    if revision >= 0 and not _plain_child(doc, revision, String("type"), String("string")):
        findings.append(where + String(": `revision` is `type: string`"))
    var reason = doc.child(inputs, String("reason"))
    if reason < 0:
        findings.append(where + String(" have no `reason`: every manual run says why, and a break-glass run needs it"))
    else:
        if not _plain_child(doc, reason, String("type"), String("string")):
            findings.append(where + String(": `reason` is `type: string`"))
        if not _plain_child(doc, reason, String("required"), String("true")):
            findings.append(where + String(": `reason` is `required: true` (every manual run says why)"))
        if doc.child(reason, String("default")) >= 0:
            findings.append(where + String(": `reason` has no `default` (a default would say why for the person who did not)"))
    var dry = doc.child(inputs, String("dry_run"))
    if dry < 0:
        findings.append(where + String(" have no `dry_run`"))
    else:
        if not _plain_child(doc, dry, String("type"), String("boolean")):
            findings.append(where + String(": `dry_run` is `type: boolean`"))
        if not _plain_child(doc, dry, String("default"), String("false")):
            findings.append(
                where + String(": `dry_run` is `default: false` (a manual run is a real run unless asked to be a dry one)")
            )


def check_no_expression_in_run(doc: WorkflowDoc, mut findings: List[String]):
    """R16: no `run:` script holds a `${{ }}` other than the pull request's
    base commit (file header)."""
    var jobs = doc.child(0, String("jobs"))
    var ids = doc.keys(jobs)
    var nodes = doc.items(jobs)
    for j in range(len(ids)):
        var steps = doc.items(doc.child(nodes[j], String("steps")))
        for i in range(len(steps)):
            var r = doc.child(steps[i], String("run"))
            if r < 0 or doc.kind(r) != NODE_SCALAR:
                continue
            var text = doc.text(r)
            var at = text.find(String("${{"))
            while at >= 0:
                var end = text.find(String("}}"), at)
                var expr = String(text[byte=at:]) if end < 0 else String(text[byte = at : end + 2])
                if end < 0 or not is_expression(expr, String(PULL_REQUEST_BASE_EXPRESSION)):
                    findings.append(
                        _at(doc, r) + String("job '") + ids[j] + String("': R16: a `run:` script holds `") + expr
                        + String("`: an expression expanded into a script is script injection (a manual run's reason")
                        + String(" above all); pass the value through the job's or the step's `env:`")
                    )
                if end < 0:
                    break
                at = text.find(String("${{"), end)


def _job_index(ids: List[String], id: String) -> Int:
    for i in range(len(ids)):
        if ids[i] == id:
            return i
    return -1


def _has_validations(st: Stage) -> Bool:
    for i in range(len(st.steps)):
        if len(st.steps[i].validations) > 0:
            return True
    return False


def _set_hash_source(
    g: ReleaseMachine, st: Stage, ids: List[String], part_stage: List[String], mut job: String, mut output: String
) -> Bool:
    """R17: the job and output a job of `st` takes its set hash from; False
    when `st` has no `after`."""
    if st.after.byte_length() == 0:
        return False
    var a: Stage
    try:
        a = g.stage(st.after)
    except:
        return False
    if _has_validations(a):
        output = String(VALIDATED_SET_HASH_OUTPUT)
        job = a.name.copy()
        for i in range(len(ids)):
            if part_stage[i] == a.name:
                job = ids[i].copy()
                break
        return True
    output = String(SET_HASH_OUTPUT)
    job = a.name.copy()
    return True


def _check_set_hash_consumer(
    doc: WorkflowDoc, job_id: String, job: Int, source: String, output: String, mut findings: List[String]
):
    var calls = List[KciRunCall]()
    var steps = doc.items(doc.child(job, String("steps")))
    for i in range(len(steps)):
        var r = doc.child(steps[i], String("run"))
        if r >= 0 and doc.kind(r) == NODE_SCALAR:
            calls.extend(kci_run_calls(doc.text(r)))
    var want = String("needs.") + source + String(".outputs.") + output
    var where = _at(doc, job) + String("job '") + job_id + String("': R17")
    for i in range(len(calls)):
        if not calls[i].has_release_set_hash:
            findings.append(
                where + String(": its `kci run` passes no `--release-set-hash \"$") + String(SET_HASH_ENV)
                + String("\"`: kci holds the release it is given to the set ") + source + String(" handed on")
            )
        elif calls[i].release_set_hash != String("$") + String(SET_HASH_ENV) and calls[i].release_set_hash != (
            String("${") + String(SET_HASH_ENV) + String("}")
        ):
            findings.append(
                where + String(": `--release-set-hash ") + calls[i].release_set_hash + String("`; it passes \"$")
                + String(SET_HASH_ENV) + String("\" (never a literal)")
            )
    var env = doc.child(doc.child(job, String("env")), String(SET_HASH_ENV))
    if env < 0 or doc.kind(env) != NODE_SCALAR or doc.is_block(env) or not is_expression(doc.text(env), want):
        var got = String("none") if env < 0 else String("`") + doc.text(env) + String("`")
        findings.append(
            where + String(": its `env:` sets ") + String(SET_HASH_ENV) + String(" to exactly `${{ ") + want
            + String(" }}`; it has ") + got
        )


def _check_set_hash_output(doc: WorkflowDoc, source: String, output: String, mut findings: List[String]):
    var job = doc.child(doc.child(0, String("jobs")), source)
    if job < 0:
        return  # R1 says so
    var o = doc.child(doc.child(job, String("outputs")), output)
    if o < 0 or doc.kind(o) != NODE_SCALAR or doc.text(o).byte_length() == 0:
        findings.append(
            _at(doc, job) + String("job '") + source + String("': R17: a later job takes the release set's hash from")
            + String(" its output `") + output + String("`, and it declares none")
        )


def check_prod_line(doc: WorkflowDoc, job_id: String, job: Int, mut findings: List[String]):
    """R18 (file header)."""
    var steps = doc.items(doc.child(job, String("steps")))
    var ok = False
    if len(steps) > 0:
        var last = steps[len(steps) - 1]
        var name = doc.child(last, String("name"))
        var cond = doc.child(last, String("if"))
        ok = (
            name >= 0 and doc.kind(name) == NODE_SCALAR and doc.text(name) == String(PROD_LINE_STEP)
            and doc.is_plain(cond, String("always()"))
        )
    if not ok:
        findings.append(
            _at(doc, job) + String("job '") + job_id + String("': R18: its last step is `name: ") + String(PROD_LINE_STEP)
            + String("` with `if: always()`: every release job says in one line what happens to prod")
        )


def check_permission_grants(doc: WorkflowDoc, owner: Int, whose: String, mut findings: List[String]):
    """R4 (amended): a `permissions:` mapping of `owner` grants `contents:
    read` and `id-token` (R4's) only."""
    var perms = doc.child(owner, String("permissions"))
    if perms < 0 or doc.kind(perms) != NODE_MAP:
        return
    var keys = doc.keys(perms)
    for i in range(len(keys)):
        if keys[i].lower() == String("id-token"):
            continue  # R4
        if keys[i] == String("contents") and doc.is_plain(doc.child(perms, keys[i]), String("read")):
            continue
        var v = doc.child(perms, keys[i])
        var value = doc.text(v) if doc.kind(v) == NODE_SCALAR else String("(not a scalar)")
        findings.append(
            _at(doc, perms) + whose + String("R4: permissions grant `") + keys[i] + String(": ") + value
            + String("`; a release job holds `contents: read` and R4's `id-token` only")
        )


def check_auto_promotion(
    doc: WorkflowDoc, g: ReleaseMachine, ids: List[String], nodes: List[Int], part_stage: List[String], mut findings: List[String]
):
    """R13 to R18 and R4's allow-list over every job (file header).
    `part_stage[i]` is the stage job `ids[i]` runs a part of ("" for none);
    a job named after a stage runs that stage."""
    var root = 0
    var on = doc.child(root, String("on"))
    check_concurrency(doc, findings)
    check_dispatch_inputs(doc, on, findings)
    check_no_expression_in_run(doc, findings)
    check_permission_grants(doc, root, String("workflow: "), findings)
    var sources = List[String]()
    var outputs = List[String]()
    for i in range(len(ids)):
        var stage_name = part_stage[i].copy()
        var part = stage_name.byte_length() > 0
        if not part:
            if not g.has_stage(ids[i]):
                continue  # R1 says so
            stage_name = ids[i].copy()
        var st: Stage
        try:
            st = g.stage(stage_name)
        except:
            continue
        if st.is_pull_request():
            continue  # R6
        var whose = String("job '") + ids[i] + String("': ")
        check_permission_grants(doc, nodes[i], whose, findings)
        check_main_only(doc, ids[i], nodes[i], st, findings)
        check_prod_line(doc, ids[i], nodes[i], findings)
        var needs_hash = part or st.has_kind(String("PUBLISH"))
        var source = String("")
        var output = String("")
        if needs_hash and _set_hash_source(g, st, ids, part_stage, source, output):
            _check_set_hash_consumer(doc, ids[i], nodes[i], source, output, findings)
            var seen = False
            for k in range(len(sources)):
                if sources[k] == source and outputs[k] == output:
                    seen = True
            if not seen:
                sources.append(source.copy())
                outputs.append(output.copy())
    for k in range(len(sources)):
        _check_set_hash_output(doc, sources[k], outputs[k], findings)


def _excludes_of(release_version_text: String) -> List[String]:
    """Every `:(exclude)<path>` pathspec in release_version.sh, in order."""
    var out = List[String]()
    var marker = String(":(exclude)")
    var at = release_version_text.find(marker)
    while at >= 0:
        var start = at + marker.byte_length()
        var b = release_version_text.as_bytes()
        var end = start
        while end < len(b) and Int(b[end]) != 39 and Int(b[end]) != 34 and Int(b[end]) != 32 and Int(b[end]) != 10:
            end += 1
        out.append(String(release_version_text[byte = start:end]))
        at = release_version_text.find(marker, end)
    return out^


def documentation_filter_findings(release_version_text: String, doc: WorkflowDoc) -> List[String]:
    """R15's cross-check (file header): release_version.sh's excludes, as
    trigger paths (`docs` -> 'docs/**', `*.md` -> '**.md'; `.github` must
    be among them and stays a trigger), are exactly the push trigger's
    `paths-ignore`, in order."""
    var findings = List[String]()
    var excludes = _excludes_of(release_version_text)
    var mapped = List[String]()
    var has_github = False
    for i in range(len(excludes)):
        if excludes[i] == String(".github"):
            has_github = True
        elif excludes[i] == String("docs"):
            mapped.append(String("docs/**"))
        elif excludes[i] == String("*.md"):
            mapped.append(String("**.md"))
        else:
            findings.append(
                String("R15: release_version.sh does not count '") + excludes[i]
                + String("', and the push trigger's paths-ignore has no entry for it: documentation means one thing")
                + String(" to the trigger and to the build number")
            )
    if not has_github:
        findings.append(String("R15: release_version.sh no longer excludes '.github' (expected docs, *.md, .github)"))
    var on = doc.child(0, String("on"))
    var ignore = doc.child(doc.child(on, String("push")), String("paths-ignore"))
    var items = doc.items(ignore)
    var got = List[String]()
    for i in range(len(items)):
        got.append(doc.text(items[i]))
    var same = len(got) == len(mapped)
    if same:
        for i in range(len(got)):
            if got[i] != mapped[i]:
                same = False
    if not same:
        findings.append(
            String("R15: the push trigger's paths-ignore (") + String(", ").join(got)
            + String(") is not release_version.sh's documentation (") + String(", ").join(mapped) + String(")")
        )
    return findings^
