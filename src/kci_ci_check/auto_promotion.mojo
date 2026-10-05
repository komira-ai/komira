# =============================================================================
# src/kci_ci_check/auto_promotion.mojo -- rules R13 to R19 (and R4's
#   permission allow-list): continuous auto-promotion, where a push to main
#   IS the release (build -> gamma -> validate -> prod), held to the machine
#   file.
# =============================================================================
#
#   R13 MAIN-ONLY STAGES. The machine file's `break_glass` stage field says
#       which stages a manual (BREAK-GLASS) run may run (a PREFIX of the
#       chain; kci_release_machine refuses anything else). The job of every
#       PUSH stage WITHOUT `break_glass`, and every part job of one, carries
#       BOTH top-level conjuncts `github.event_name == 'push'` and
#       `github.ref == 'refs/heads/main'` in its job-level `if:` (exactly
#       those terms, spaces around `==` aside; read by pull_request.mojo's
#       `top_level_terms`, so a grouping, negation, call or `||` reads as
#       missing): a manual run of main never reaches it, only a push does.
#       `github.ref_name == 'main'` is not it (a TAG named main matches). A
#       break_glass stage's job carries neither: the workflow and the
#       machine file would disagree about which stages a manual run
#       reaches. ⚠ GitHub compares strings IGNORING CASE, so the `ref`
#       conjunct also passes for a branch `MAIN`: it is defence in depth.
#       The LOCKS are GitHub's: the `prod` environment's deployment
#       branches (`main`), a repository ruleset refusing branches and tags
#       that are main in another case (docs/ci.md), and R19's byte-exact
#       shell step.
#   R14 ONE RELEASE AT A TIME. The workflow-level `concurrency:` is a
#       mapping of exactly `group` and `cancel-in-progress`, each the
#       canonical text below byte for byte: a pull request's runs in a
#       group per pull request (a newer push cancels the older check); a
#       PUSH to main in `kci-release-main`, never cancelled in progress (a
#       newer push replaces only the PENDING one); a manual DRY run in a
#       group of its own run (`kci-plan-<run id>`: it writes nothing, so it
#       never waits for or replaces anything); any other run (a manual run,
#       of main too) in a group per ref (`kci-ref-<ref name>`), so no
#       manual run, whatever revision it names, can replace a pending
#       release. No job has a `concurrency:` of its own (a job-level
#       group's pending replacement could drop a prod job).
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
#   R19 THE REVISION IS THIS RUN'S, checked by the workflow itself. Every
#       job of a PUSH stage, and every part job of one, starts with exactly
#       two steps: `actions/checkout` (pinned, R8) with `ref: ${{
#       env.REVISION }}`, then the step `the revision this run releases`, whose
#       `run:` is the canonical script below byte for byte and which has no
#       other key (no `if:`, `continue-on-error:`, `shell:` or `env:`): on a
#       push REVISION is GITHUB_SHA, on any other run a full commit id on
#       GITHUB_SHA's history. A job of a stage WITHOUT `break_glass` has a
#       third, `only a push to main reaches this job`, the same way: the
#       event is `push` and GITHUB_REF is `refs/heads/main`, byte for byte.
#       So a run of main, whose workflow file is main's own, refuses a
#       `revision` input naming an unmerged commit BEFORE anything built
#       from that revision runs (the farm-connect action, ./buck2, kci):
#       those are the revision's own code and could leave any in-kci check
#       out. No release job has `continue-on-error:` or `defaults:`, nor has
#       the workflow `defaults:` (a default `shell` would run the script
#       elsewhere).
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
"""R13: a conjunct of a main-only stage's job."""

comptime PUSH_EVENT_TERM: String = "github.event_name == 'push'"
"""R13: the other conjunct of a main-only stage's job."""

comptime CONCURRENCY_GROUP: String = (
    "kci-${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number)"
    " || github.event_name == 'push' && github.ref == 'refs/heads/main' && 'release-main'"
    " || inputs.dry_run && format('plan-{0}', github.run_id) || format('ref-{0}', github.ref_name) }}"
)
"""R14: the workflow-level concurrency group, byte for byte."""

comptime CONCURRENCY_CANCEL: String = "${{ github.event_name == 'pull_request' }}"
"""R14: `cancel-in-progress`, byte for byte: only a pull request's check is
cancelled in progress."""

comptime PROD_LINE_STEP: String = "the prod line"
"""R18: the name of every release job's last step."""

comptime SET_HASH_ENV: String = "RELEASE_SET_HASH"
"""R17: the job-level env variable `--release-set-hash` reads."""

comptime REVISION_STEP: String = "the revision this run releases"
"""R19: the second step of every release job."""

comptime REVISION_STEP_RUN: String = (
    "case \"$REVISION\" in\n"
    "  *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n"
    "esac\n"
    "[ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n"
    "if [ \"$GITHUB_EVENT_NAME\" = push ]; then\n"
    "  [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n"
    "    { echo \"refused: a push releases the commit it pushed ($GITHUB_SHA), not $REVISION\"; exit 1; }\n"
    "else\n"
    "  git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n"
    "    { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n"
    "fi\n"
)
"""R19: that step's `run:`, byte for byte."""

comptime MAIN_ONLY_STEP: String = "only a push to main reaches this job"
"""R19: the third step of a main-only stage's job."""

comptime MAIN_ONLY_STEP_RUN: String = (
    "[ \"$GITHUB_EVENT_NAME\" = push ] && [ \"$GITHUB_REF\" = refs/heads/main ] ||\n"
    "  { echo \"refused: only a push to refs/heads/main reaches this job; this run is a $GITHUB_EVENT_NAME of $GITHUB_REF\"; exit 1; }\n"
)
"""R19: that step's `run:`, byte for byte."""

comptime CHECKOUT_REF: String = "${{ env.REVISION }}"
"""R19: the first step's `with.ref`."""

comptime SET_HASH_OUTPUT: String = "set_hash"
comptime VALIDATED_SET_HASH_OUTPUT: String = "validated_set_hash"


def _at(doc: WorkflowDoc, node: Int) -> String:
    if node < 0:
        return String("")
    return String("line ") + String(doc.line(node)) + String(": ")


def _is_term(term: String, head: String, literal: String) -> Bool:
    """Exactly `<head> == '<literal>'`, spaces around `==` aside."""
    var t = String(term.strip())
    if not t.startswith(head):
        return False
    var rest = String(String(t[byte = head.byte_length() :]).lstrip(String(" ")))
    if not rest.startswith(String("==")):
        return False
    var lit = String(String(rest[byte=2:]).lstrip(String(" ")))
    return lit == String("'") + literal + String("'")


def _is_main_term(term: String) -> Bool:
    """Exactly `github.ref == 'refs/heads/main'`, spaces around `==`
    aside."""
    return _is_term(term, String("github.ref"), String("refs/heads/") + String(RELEASE_BRANCH))


def _is_push_term(term: String) -> Bool:
    """Exactly `github.event_name == 'push'`, spaces around `==` aside."""
    return _is_term(term, String("github.event_name"), String("push"))


def break_glass_environment_expression(environment: String, break_glass_environment: String) -> String:
    """R2 for a stage with a `break_glass_environment`: its job's
    `environment:`, byte for byte. A push runs in the stage's environment
    (locked to main by its deployment branches); every other run in the
    break-glass one (a required reviewer)."""
    return (
        String("${{ github.event_name == 'push' && '") + environment + String("' || '") + break_glass_environment
        + String("' }}")
    )


def check_main_only(doc: WorkflowDoc, job_id: String, job: Int, st: Stage, mut findings: List[String]):
    """R13 for a job that runs PUSH stage `st` or a part of it."""
    var terms = List[String]()
    var read = top_level_terms(doc, doc.child(job, String("if")), terms)
    var has_main = False
    var has_push = False
    if read:
        for i in range(len(terms)):
            if _is_main_term(terms[i]):
                has_main = True
            if _is_push_term(terms[i]):
                has_push = True
    var where = _at(doc, job) + String("job '") + job_id + String("': R13: stage '") + st.name + String("'")
    if not st.break_glass and not (has_main and has_push):
        findings.append(
            where + String(" runs only on a push to main (the machine file gives it no `break_glass`), so the job's")
            + String(" `if:` is a top-level conjunction with the terms `") + String(PUSH_EVENT_TERM) + String("` and `")
            + String(MAIN_REF_TERM) + String("` (not `github.ref_name`, which a tag named main matches; a manual run")
            + String(" of main is not a push)")
        )
    elif st.break_glass and (has_main or has_push):
        var held = String(MAIN_REF_TERM) if has_main else String(PUSH_EVENT_TERM)
        findings.append(
            where + String(" is break_glass in the machine file (a manual run runs it), and the job's")
            + String(" `if:` holds `") + held + String("`: the workflow and the machine file disagree")
        )


def _step_is(doc: WorkflowDoc, step: Int, name: String, run: String) -> Bool:
    """`step` has exactly the keys `name` (plain or quoted `name`) and `run`
    (a block scalar, `run` byte for byte)."""
    if step < 0 or doc.kind(step) != NODE_MAP or len(doc.keys(step)) != 2:
        return False
    var n = doc.child(step, String("name"))
    var r = doc.child(step, String("run"))
    return (
        n >= 0 and doc.kind(n) == NODE_SCALAR and not doc.is_block(n) and doc.text(n) == name
        and r >= 0 and doc.is_block(r) and doc.text(r) == run
    )


def _is_revision_checkout(doc: WorkflowDoc, step: Int) -> Bool:
    if step < 0 or doc.kind(step) != NODE_MAP:
        return False
    var u = doc.child(step, String("uses"))
    if u < 0 or doc.kind(u) != NODE_SCALAR or not doc.text(u).startswith(String("actions/checkout@")):
        return False
    if doc.child(step, String("if")) >= 0 or doc.child(step, String("continue-on-error")) >= 0:
        return False
    var wref = doc.child(doc.child(step, String("with")), String("ref"))
    return wref >= 0 and doc.kind(wref) == NODE_SCALAR and not doc.is_block(wref) and doc.text(wref) == String(CHECKOUT_REF)


def check_revision_steps(doc: WorkflowDoc, job_id: String, job: Int, st: Stage, mut findings: List[String]):
    """R19 for a job that runs PUSH stage `st` or a part of it."""
    var steps = doc.items(doc.child(job, String("steps")))
    var where = _at(doc, job) + String("job '") + job_id + String("': R19: ")
    if len(steps) < 1 or not _is_revision_checkout(doc, steps[0]):
        findings.append(
            where + String("its first step is `actions/checkout` with `ref: ") + String(CHECKOUT_REF)
            + String("` (no `if:`, no `continue-on-error:`)")
        )
    if len(steps) < 2 or not _step_is(doc, steps[1], String(REVISION_STEP), String(REVISION_STEP_RUN)):
        findings.append(
            where + String("its second step is `name: ") + String(REVISION_STEP) + String("` with the canonical `run:`")
            + String(" (auto_promotion.mojo REVISION_STEP_RUN, byte for byte) and no other key: the workflow refuses a")
            + String(" revision that is not this run's before anything built from it runs")
        )
    if not st.break_glass and (
        len(steps) < 3 or not _step_is(doc, steps[2], String(MAIN_ONLY_STEP), String(MAIN_ONLY_STEP_RUN))
    ):
        findings.append(
            where + String("stage '") + st.name + String("' runs only on a push to main, so its third step is `name: ")
            + String(MAIN_ONLY_STEP) + String("` with the canonical `run:` (MAIN_ONLY_STEP_RUN, byte for byte) and no")
            + String(" other key: GITHUB_REF compared byte for byte, which no `if:` can do")
        )
    for key in [String("continue-on-error"), String("defaults")]:
        var k = doc.child(job, key)
        if k >= 0:
            findings.append(
                _at(doc, k) + String("job '") + job_id + String("': R19: a release job has no `") + key
                + String(":` (it could run the revision check elsewhere, or carry on past it)")
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
    """R13 to R19 and R4's allow-list over every job (file header).
    `part_stage[i]` is the stage job `ids[i]` runs a part of ("" for none);
    a job named after a stage runs that stage."""
    var root = 0
    var on = doc.child(root, String("on"))
    check_concurrency(doc, findings)
    check_dispatch_inputs(doc, on, findings)
    check_no_expression_in_run(doc, findings)
    check_permission_grants(doc, root, String("workflow: "), findings)
    var defaults = doc.child(root, String("defaults"))
    if defaults >= 0:
        findings.append(
            _at(doc, defaults) + String("workflow: R19: the workflow has no `defaults:` (a default `shell` would run")
            + String(" the revision check, and every script, elsewhere)")
        )
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
        check_revision_steps(doc, ids[i], nodes[i], st, findings)
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
