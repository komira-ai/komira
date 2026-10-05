# =============================================================================
# src/kci_ci_check/rules.mojo -- a CI workflow held to a machine file's stage
#   graph: the workflow consistency check.
# =============================================================================
#
# The workflow consistency check is library code, not a command. Two places
# use it: the welded test that holds this repository's kci.yml to
# release/machine.textproto, and `kci run` at start-up, which checks the
# workflow it runs under and refuses to run on a mismatch
# (`check_running_workflow`).
#
# The machine file owns the release machine; the workflow is written by hand and
# must agree with it. `check_workflow` returns every disagreement (empty =
# they agree); it never stops at the first, so one run names them all:
#
#   R1  every stage has a job whose id is the stage's name, and every other
#       job runs a PART of a stage (a `kci run --stage <S> --only ...`, see
#       R9); a job that is neither is a disagreement. [Amended, PENDING A
#       RULING: before, the job ids were exactly the stage names.]
#   R2  each job runs in its stage's GitHub environment, the stage's
#       `environment` (by default its name): `environment: <env>`, or
#       `environment: {name: <env>}` as a block
#   R3  each job's `needs` is exactly the jobs that run its stage's `after`
#       (none for none): the job named after that stage, and, when that
#       stage is split (R9), each of its part jobs too, so a later stage waits
#       for the earlier stage's validations. [Amended with R9, PENDING A
#       RULING.]
#   R4  `id-token: write` is in a job's own `permissions` exactly when its
#       stage needs an identity token: it publishes to a channel whose
#       credential is OIDC trusted publishing (`id_token_stages`), or it is
#       farm-connected (the farm connection exchanges the job's identity
#       token for a network credential). Never in the workflow-level
#       `permissions`, which reach every job. No other job carries it.
#       A `permissions:` written as a scalar, at either level, is a plain
#       `read-all`: `write-all` grants `id-token: write` with no map entry
#       naming it, so any other scalar is a disagreement (and counts as
#       holding the token). The token is read by allow-list: an `id-token`
#       entry withholds it only as a plain `read` or `none`; any other value
#       (quoted, a block scalar, a mapping, empty) counts as holding it.
#       Keys are read exactly: a `permissions` or `id-token` key written in
#       another case, or two permissions keys that differ only in case, is
#       a disagreement (an `id-token` key in another case counts as holding
#       the token). `id-token` is the only permission these rules read.
#   R5  each job's steps invoke `kci run` exactly once; a job named after a
#       stage passes `--stage` its own id written literally (a `--stage`
#       naming another stage, or one that is a variable, is a
#       disagreement), and a part job (R9) the literal name of the stage it
#       runs a part of
#   R6  a pull request's code runs only in the job of the machine file's
#       PULL_REQUEST stage, in the same workflow as the release stages.
#       [Amended: before, no trigger could be `pull_request`.] The rule
#       itself is in pull_request.mojo:
#         * `pull_request_target` is never a trigger (it runs a pull
#           request's code with the base repository's secrets);
#         * `pull_request` is a trigger exactly when the machine file
#           declares a PULL_REQUEST stage (the typed `trigger` field,
#           kci_release_machine), and R1 asks a job for that stage too;
#         * when it is, every job but the PULL_REQUEST stage's is
#           RELEASE-ONLY: a PUSH stage's job, and a part job of one, carries
#           a job-level `if:` that is a TOP-LEVEL conjunction (bare or
#           inside one outer `${{ }}`; outside single-quoted literals only
#           names, numbers and `&&` `==` `!=` `<` `<=` `>` `>=`, so no
#           grouping, negation, call, index or `||`; no other `${{` or `}}`,
#           a literal included) with a term that is exactly
#           `github.event_name != 'pull_request'`, `github.event_name ==
#           'push'` or `github.event_name == 'workflow_dispatch'` (a
#           single-quoted [a-z_]+ literal, nothing after it; GitHub compares
#           strings case-insensitively, so another case is not read). No
#           release job, environment, publishing token or release tailnet
#           node is reached from a pull request;
#         * the PULL_REQUEST stage's job carries the job-level condition
#           `if: github.event.pull_request.head.repo.full_name ==
#           github.repository` (bare or inside `${{ }}`, nothing else): a
#           pull request from a fork runs nothing (its code reaches the farm
#           only when a maintainer pushes it to a branch of this
#           repository), and a push or a manual run skips the job;
#         * that job runs the whole stage in one job (no part job), in no
#           environment (R2); its `permissions` hold `contents: read` and
#           `id-token: write` only (R4 allows the identity token only when
#           the stage is farm-connected: the farm connection exchanges it;
#           a PULL_REQUEST stage never publishes); its one `kci run` (R5)
#           carries `--affected-by ${{ github.event.pull_request.base.sha
#           }}`, written so (the base commit of the pull request; quotes and
#           the spacing inside `${{ }}` aside); every `actions/checkout`
#           step of the job has `with: fetch-depth: 0`, and there is one
#           (kci reads the change from git and refuses a shallow clone).
#           What it runs is a BUILD step: the machine file refuses any other
#           kind in such a stage, so nothing is published or deployed from a
#           pull request;
#         * a PUSH stage's `kci run` never carries `--affected-by`.
#   R7  `workflow_dispatch` takes an input `revision` (the commit a manual
#       run releases)
#   R8  every `uses:` is pinned to a full 40-hex commit id, except the one
#       local action `./.github/actions/farm-connect` (a local action is part
#       of the checked-out commit; the `uses:` inside it are pinned by its
#       own gate)
#   R9  no `kci run` carries `--only`, so a release job runs its whole stage
#       (a FULL run), UNLESS the stage is SPLIT over several jobs. [Amended,
#       PENDING A RULING.] A stage is split when some job other than the one
#       named after it runs `kci run --stage <S> --only ...` (a PART job).
#       Then:
#         * every `--only` value is a literal `step:<name>` or
#           `validation:<name>` that matches something in S;
#         * a part job runs validations only: the steps are run by the job
#           named after the stage (which holds the environment and, when the
#           stage needs one, the identity token: R2, R4);
#         * together the stage's jobs run EVERY step and EVERY validation of
#           S EXACTLY ONCE (`--only step:<s>` runs no validation, and a job
#           without `--only` runs all of S), so the split runs what one FULL
#           run would, and each job's result says SELECTIVE;
#         * a part job runs in NO environment (R2), never holds `id-token:
#           write` nor uses the farm-connect action (R4, R11), and `needs`
#           the job named after the stage, and besides it only the stage's
#           `after` (R3).
#   R10 each `kci run` reads the machine file being checked: a `--machine`
#       must name that file, and a `kci run` without one reads the default
#       (kci_api's DEFAULT_MACHINE_FILE), which must then be that file.
#       Paths are compared as written, after dropping a leading `./`
#   R11 a job has a step `uses: ./.github/actions/farm-connect` exactly when
#       its stage is farm-connected (the machine file's typed field, never a
#       job name)
#   R12 every `kci run` passes `--summary-file` (the job summary carries the
#       run's outcome and the NEW NAMES an approver reads before approving a
#       later stage)
#
# How `kci run` is found (R5): each `run:` block is split into shell words
# (a line ending in `\` continues; quotes around a word are dropped); an
# invocation is a word in COMMAND position (the first word of a line, or
# right after `;` `&&` `||` `|` `then` `do` `else` `exec` `!`, or after a
# word ending in `;`) whose last `/`-separated part is `kci`, followed by
# the word `run`. So `echo "... kci run ..."` is not one. Its arguments run
# to the end of the line or the next `;` `&&` `||` `|`; `--stage`,
# `--machine`, `--only`, `--summary-file` and `--affected-by` take the next
# word, or `=<v>`. A GitHub expression `${{ ... }}` is one word, whatever
# spaces it holds.
#
# A workflow the restricted reader cannot read raises (`cannot tell:`,
# workflow_reader.mojo): the caller reports INDETERMINATE, never a pass.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from kci_api import DEFAULT_MACHINE_FILE, Selector, parse_selector
from kci_release_channel import Channel, find_channel, parse_channels_file
from kci_release_machine import Selection, Stage, ReleaseMachine, joined_names, resolve_selection

from .pull_request import check_pull_request_job, check_release_only
from .workflow_reader import NODE_LIST, NODE_MAP, NODE_SCALAR, WorkflowDoc, read_workflow

comptime FARM_CONNECT_ACTION: String = "./.github/actions/farm-connect"
"""The one local action a workflow may use (R8), and the step a
farm-connected stage's job must have (R11)."""

struct ChannelsFile(Copyable, Movable):
    """A channels file's path, as a machine-file step names it, and its
    text. Layout: owned Strings. No pointer field."""

    var path: String
    var text: String

    def __init__(out self, var path: String, var text: String):
        self.path = path^
        self.text = text^


def _channels_text(files: List[ChannelsFile], path: String) raises -> String:
    for i in range(len(files)):
        if files[i].path == path:
            return files[i].text.copy()
    raise Error(String("the channels file '") + path + String("' was not given"))


def channels_paths(g: ReleaseMachine) -> List[String]:
    """Every distinct channels path a PUBLISH step names, in file order: what
    `id_token_stages` needs read."""
    var out = List[String]()
    for i in range(len(g.stages)):
        for k in range(len(g.stages[i].steps)):
            ref s = g.stages[i].steps[k]
            if not s.is_publish():
                continue
            var seen = False
            for j in range(len(out)):
                if out[j] == s.channels:
                    seen = True
            if not seen:
                out.append(s.channels.copy())
    return out^


def _channel_is_oidc(ch: Channel) -> Bool:
    for i in range(len(ch.repositories)):
        ref r = ch.repositories[i]
        if r.credential and r.credential.value().is_oidc_trusted_publishing():
            return True
    return False


def id_token_stages(g: ReleaseMachine, files: List[ChannelsFile]) raises -> List[String]:
    """The stages that need a CI identity token: those with a PUBLISH step
    whose channel publishes by OIDC trusted publishing. Raises when a
    channels file is not given or is refused, or names no such channel."""
    var out = List[String]()
    for i in range(len(g.stages)):
        ref st = g.stages[i]
        var needs = False
        for k in range(len(st.steps)):
            ref s = st.steps[k]
            if not s.is_publish():
                continue
            var channels = parse_channels_file(_channels_text(files, s.channels))
            var ch = find_channel(channels, s.channel)
            if _channel_is_oidc(ch):
                needs = True
        if needs:
            out.append(st.name.copy())
    return out^


# ---- shell words ---------------------------------------------------------------


def _words(script: String) -> List[List[String]]:
    """`script` as logical lines of words (file header, R5)."""
    var out = List[List[String]]()
    var parts = script.split(String("\n"))
    var current = String("")
    for i in range(len(parts)):
        var line = String(String(parts[i]).strip())
        if line.endswith(String("\\")):
            current += String(line[byte = 0 : line.byte_length() - 1]) + String(" ")
            continue
        current += line
        var words = List[String]()
        var toks = current.split(String(" "))
        var t = 0
        while t < len(toks):
            var w = String(toks[t])
            t += 1
            if w.byte_length() == 0:
                continue
            # `${{ ... }}` is one word, whatever spaces it holds
            var expr_at = w.find(String("${{"))
            if expr_at >= 0 and w.find(String("}}"), expr_at) < 0:
                while t < len(toks):
                    var more = String(toks[t])
                    t += 1
                    w += String(" ") + more
                    if more.find(String("}}")) >= 0:
                        break
            if w.byte_length() >= 2 and (
                (w.startswith(String("\"")) and w.endswith(String("\"")))
                or (w.startswith(String("'")) and w.endswith(String("'")))
            ):
                var unquoted = String(w[byte = 1 : w.byte_length() - 1])
                w = unquoted^
            words.append(w^)
        out.append(words^)
        current = String("")
    return out^


def _is_kci(word: String) -> Bool:
    var at = word.rfind(String("/"))
    var base = word.copy()
    if at >= 0:
        base = String(word[byte = at + 1 :])
    return base == String("kci")


struct KciRunCall(Copyable, Movable):
    """One `kci run` found in a job: the `--stage` value ("" when absent),
    the `--machine` value (`has_machine` False when absent), whether it
    carries any `--only` and each `--only` value as written (unquoted), and
    whether it passes `--summary-file`, and the `--affected-by` value
    (`has_affected_by` False when absent).
    Layout: owned Strings, a List of Strings and Bools. No pointer field."""

    var stage: String
    var machine: String
    var has_machine: Bool
    var has_only: Bool
    var only: List[String]
    var has_summary_file: Bool
    var affected_by: String
    var has_affected_by: Bool

    def __init__(out self, var stage: String):
        self.stage = stage^
        self.machine = String("")
        self.has_machine = False
        self.has_only = False
        self.only = List[String]()
        self.has_summary_file = False
        self.affected_by = String("")
        self.has_affected_by = False


def _command_position(w: List[String], j: Int) -> Bool:
    if j == 0:
        return True
    var p = w[j - 1]
    if p.endswith(String(";")):
        return True
    for sep in [";", "&&", "||", "|", "then", "do", "else", "exec", "!"]:
        if p == String(sep):
            return True
    return False


def kci_run_calls(script: String) -> List[KciRunCall]:
    """Every `kci run` invocation in a `run:` script (file header, R5)."""
    var out = List[KciRunCall]()
    var lines = _words(script)
    for i in range(len(lines)):
        ref w = lines[i]
        for j in range(len(w)):
            if not _is_kci(w[j]) or j + 1 >= len(w) or w[j + 1] != String("run"):
                continue
            if not _command_position(w, j):
                continue
            var args = _call_args(w, j + 2)
            var call = KciRunCall(String(""))
            var seen_stage = False
            var k = 0
            while k < len(args):
                var a = args[k].copy()
                var value = String("")
                var has_value = False
                var flag = a.copy()
                var eq = a.find(String("="))
                if a.startswith(String("--")) and eq > 0:
                    flag = String(a[byte=0:eq])
                    value = String(a[byte = eq + 1 :])
                    has_value = True
                elif k + 1 < len(args):
                    value = args[k + 1].copy()
                    has_value = True
                if flag == String("--stage") and has_value:
                    if not seen_stage:
                        call.stage = value.copy()
                        seen_stage = True
                elif flag == String("--machine") and has_value:
                    call.machine = value.copy()
                    call.has_machine = True
                elif flag == String("--only"):
                    call.has_only = True
                    if has_value:
                        call.only.append(value.copy())
                elif flag == String("--summary-file") and has_value:
                    call.has_summary_file = True
                elif flag == String("--affected-by"):
                    call.has_affected_by = True
                    if has_value:
                        call.affected_by = value.copy()
                k += 1
            out.append(call^)
    return out^


def _call_args(w: List[String], start: Int) -> List[String]:
    """The words of one invocation from `start`: up to the end of the line,
    a separator word, or a word ending in `;` (kept, without the `;`)."""
    var out = List[String]()
    var k = start
    while k < len(w):
        var word = w[k].copy()
        if word == String(";") or word == String("&&") or word == String("||") or word == String("|"):
            break
        var last = word.endswith(String(";"))
        while word.endswith(String(";")):
            var trimmed = String(word[byte = 0 : word.byte_length() - 1])
            word = trimmed^
        if word.byte_length() > 0:
            out.append(word^)
        if last:
            break
        k += 1
    return out^


def _path(p: String) -> String:
    var s = p.copy()
    while s.startswith(String("./")):
        var rest = String(s[byte=2:])
        s = rest^
    return s^


# ---- the rules -------------------------------------------------------------------


def _at(doc: WorkflowDoc, node: Int) -> String:
    if node < 0:
        return String("")
    return String("line ") + String(doc.line(node)) + String(": ")


def _is_full_sha(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) != 40:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
            return False
    return True


def _collect_uses(doc: WorkflowDoc, node: Int, mut findings: List[String]):
    if node < 0:
        return
    ref n = doc.nodes[node]
    if n.kind == NODE_MAP:
        for k in range(len(n.keys)):
            var c = n.children[k]
            if n.keys[k] == String("uses") and doc.kind(c) == NODE_SCALAR:
                var v = doc.text(c)
                var at = v.rfind(String("@"))
                var pinned = at > 0 and not v.startswith(String("./")) and _is_full_sha(String(v[byte = at + 1 :]))
                if v == FARM_CONNECT_ACTION:
                    pinned = True
                if not pinned:
                    findings.append(
                        _at(doc, c) + String("R8: `uses: ") + v
                        + String("` is not pinned to a full 40-hex commit id")
                    )
            else:
                _collect_uses(doc, c, findings)
    elif n.kind == NODE_LIST:
        for k in range(len(n.children)):
            _collect_uses(doc, n.children[k], findings)


def _member(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _triggers(doc: WorkflowDoc, on: Int) -> List[String]:
    if on < 0:
        return List[String]()
    if doc.kind(on) == NODE_MAP:
        return doc.keys(on)
    return doc.scalar_or_list(on)


def _in_another_case(key: String, name: String) -> Bool:
    """`key` is `name` ignoring case, but not exactly `name`."""
    return key != name and key.lower() == name.lower()


def _id_token_write(doc: WorkflowDoc, perms: Int) -> Bool:
    """`perms` grants `id-token: write`, read by allow-list: a scalar
    `permissions:` other than a plain `read-all`, an `id-token` key in
    another case (`Id-Token`), or an `id-token` entry other than a plain
    `read` or `none` (a quoted or block scalar, a mapping, an empty value:
    anything else counts as the grant)."""
    if perms >= 0 and doc.kind(perms) == NODE_SCALAR:
        return not doc.is_plain(perms, String("read-all"))
    var keys = doc.keys(perms)
    for k in range(len(keys)):
        if _in_another_case(keys[k], String("id-token")):
            return True
    var v = doc.child(perms, String("id-token"))
    if v < 0:
        return False
    return not (doc.is_plain(v, String("read")) or doc.is_plain(v, String("none")))


def _check_permissions_form(doc: WorkflowDoc, owner: Int, whose: String, mut findings: List[String]):
    """R4, the form of the `permissions:` of `owner` (the workflow or a
    job): no key of `owner` is `permissions` in another case; a
    `permissions:` that is a scalar is a plain `read-all` (any other scalar,
    `write-all` above all, a quoted or block scalar, grants permissions no
    map names); a permissions map has no `id-token` key in another case and
    no two keys that differ only in case."""
    var owner_keys = doc.keys(owner)
    for k in range(len(owner_keys)):
        if _in_another_case(owner_keys[k], String("permissions")):
            findings.append(
                _at(doc, doc.child(owner, owner_keys[k])) + whose + String("R4: key '") + owner_keys[k]
                + String("' is `permissions` in another case; write it `permissions`")
            )
    var perms = doc.child(owner, String("permissions"))
    if perms >= 0 and doc.kind(perms) == NODE_MAP:
        var keys = doc.keys(perms)
        for k in range(len(keys)):
            if _in_another_case(keys[k], String("id-token")):
                findings.append(
                    _at(doc, perms) + whose + String("R4: permissions key '") + keys[k]
                    + String("' is `id-token` in another case (it counts as holding the token); write it `id-token`")
                )
            for j in range(k + 1, len(keys)):
                if keys[k].lower() == keys[j].lower():
                    findings.append(
                        _at(doc, perms) + whose + String("R4: permissions keys '") + keys[k] + String("' and '")
                        + keys[j] + String("' differ only in case")
                    )
    if perms < 0 or doc.kind(perms) != NODE_SCALAR or doc.is_plain(perms, String("read-all")):
        return
    findings.append(
        _at(doc, perms) + whose + String("R4: `permissions: ") + doc.text(perms)
        + String("` grants permissions no map names (`write-all` grants `id-token: write`);")
        + String(" use an explicit permissions map, or `read-all` or `{}`")
    )


def _job_calls(doc: WorkflowDoc, job: Int) -> List[KciRunCall]:
    """Every `kci run` in the `run:` steps of `job`."""
    var calls = List[KciRunCall]()
    var steps = doc.items(doc.child(job, String("steps")))
    for i in range(len(steps)):
        var r = doc.child(steps[i], String("run"))
        if r >= 0 and doc.kind(r) == NODE_SCALAR:
            var got = kci_run_calls(doc.text(r))
            for k in range(len(got)):
                calls.append(got[k].copy())
    return calls^


def _farm_connect_steps(doc: WorkflowDoc, job: Int) -> Int:
    var n = 0
    var steps = doc.items(doc.child(job, String("steps")))
    for i in range(len(steps)):
        var u = doc.child(steps[i], String("uses"))
        if u >= 0 and doc.kind(u) == NODE_SCALAR and doc.text(u) == FARM_CONNECT_ACTION:
            n += 1
    return n


def _check_calls_common(
    doc: WorkflowDoc, job_id: String, job: Int, calls: List[KciRunCall], machine_path: String, mut findings: List[String]
):
    """R10 and R12, for every job."""
    var where = _at(doc, job) + String("job '") + job_id + String("'")
    for i in range(len(calls)):
        ref call = calls[i]
        if not call.has_summary_file:
            findings.append(
                where + String(": R12: `kci run` passes no --summary-file; the job summary carries the outcome")
                + String(" and the NEW NAMES an approver reads")
            )
        if call.has_machine:
            if _path(call.machine) != _path(machine_path):
                findings.append(
                    where + String(": R10: `kci run --machine ") + call.machine
                    + String("` reads another machine file than the one checked (") + machine_path + String(")")
                )
        elif _path(String(DEFAULT_MACHINE_FILE)) != _path(machine_path):
            findings.append(
                where + String(": R10: `kci run` gives no --machine, so it reads the default ")
                + String(DEFAULT_MACHINE_FILE) + String(", not the machine file checked (") + machine_path
                + String(")")
            )


def _check_job(
    doc: WorkflowDoc,
    job_id: String,
    job: Int,
    st: Stage,
    publishes_by_oidc: Bool,
    machine_path: String,
    split: Bool,
    after_jobs: List[String],
    pr_trigger: Bool,
    mut findings: List[String],
):
    var where = _at(doc, job) + String("job '") + job_id + String("'")
    var needs_token = publishes_by_oidc or st.farm_connected
    # R2
    var env = doc.child(job, String("environment"))
    var env_name = String("")
    if env >= 0 and doc.kind(env) == NODE_SCALAR:
        env_name = doc.text(env)
    elif env >= 0 and doc.kind(env) == NODE_MAP:
        var n = doc.child(env, String("name"))
        if n >= 0 and doc.kind(n) == NODE_SCALAR:
            env_name = doc.text(n)
    if st.is_pull_request():
        if env >= 0:
            findings.append(
                where + String(": R2: stage '") + job_id + String("' is a PULL_REQUEST stage, so its job runs in no")
                + String(" environment: no environment secret or approval reaches a pull request's code")
            )
    elif env_name != st.environment:
        if env_name.byte_length() == 0:
            findings.append(
                where + String(": R2: runs in no environment; it must run in `environment: ") + st.environment
                + String("`")
            )
        else:
            findings.append(
                where + String(": R2: runs in environment '") + env_name + String("'; it must run in '")
                + st.environment + String("' (the stage's environment)")
            )
    # R3
    var needs = doc.scalar_or_list(doc.child(job, String("needs")))
    var needs_ok = len(needs) == len(after_jobs)
    for i in range(len(after_jobs)):
        if not _member(needs, after_jobs[i]):
            needs_ok = False
    if not needs_ok:
        var said = joined_names(needs)
        if said.byte_length() == 0:
            said = String("nothing")
        var want = st.after.copy()
        if want.byte_length() == 0:
            want = String("nothing")
        var jobs_text = String("")
        if len(after_jobs) > 1:
            jobs_text = String(" (run by jobs ") + joined_names(after_jobs) + String(")")
        findings.append(
            where + String(": R3: needs ") + said + String("; the stage runs after ") + want + jobs_text
        )
    # R4
    var has_token = _id_token_write(doc, doc.child(job, String("permissions")))
    if needs_token and not has_token:
        var why = String("' publishes by OIDC trusted publishing")
        if not publishes_by_oidc:
            why = String("' is farm-connected")
        findings.append(
            where + String(": R4: stage '") + job_id + why
            + String(", so the job needs `id-token: write` in its own permissions")
        )
    if has_token and not needs_token:
        findings.append(
            where + String(": R4: has `id-token: write`, but stage '") + job_id
            + String("' publishes to no OIDC channel and is not farm-connected; remove it")
        )
    # R5, R11
    var calls = List[KciRunCall]()
    var steps = doc.items(doc.child(job, String("steps")))
    var farm_connect_steps = 0
    for i in range(len(steps)):
        var u = doc.child(steps[i], String("uses"))
        if u >= 0 and doc.kind(u) == NODE_SCALAR and doc.text(u) == FARM_CONNECT_ACTION:
            farm_connect_steps += 1
        var r = doc.child(steps[i], String("run"))
        if r >= 0 and doc.kind(r) == NODE_SCALAR:
            var got = kci_run_calls(doc.text(r))
            for k in range(len(got)):
                calls.append(got[k].copy())
    if len(calls) != 1:
        findings.append(
            where + String(": R5: invokes `kci run` ") + String(len(calls))
            + String(" times; it must invoke it exactly once, as `kci run --stage ") + job_id + String("`")
        )
    for i in range(len(calls)):
        if calls[i].stage != job_id:
            var s = calls[i].stage.copy()
            if s.byte_length() == 0:
                s = String("(none)")
            findings.append(
                where + String(": R5: `kci run --stage ") + s + String("` in job '") + job_id
                + String("'; each job runs its own stage, written literally")
            )
    if st.farm_connected and farm_connect_steps == 0:
        findings.append(
            where + String(": R11: stage '") + job_id + String("' is farm-connected, so the job needs a step `uses: ")
            + String(FARM_CONNECT_ACTION) + String("`")
        )
    if not st.farm_connected and farm_connect_steps > 0:
        findings.append(
            where + String(": R11: uses ") + String(FARM_CONNECT_ACTION) + String(", but stage '") + job_id
            + String("' is not farm-connected (the machine file's `farm_connected`); remove it")
        )
    # R6: what a PULL_REQUEST stage's job runs, and that a PUSH stage's does not
    if st.is_pull_request():
        var values = List[String]()
        var given = List[Bool]()
        for i in range(len(calls)):
            values.append(calls[i].affected_by.copy())
            given.append(calls[i].has_affected_by)
        check_pull_request_job(doc, job_id, job, values, given, findings)
    else:
        if pr_trigger:
            check_release_only(doc, job_id, job, st.name, findings)
        for i in range(len(calls)):
            if calls[i].has_affected_by:
                findings.append(
                    where + String(": R6: `kci run` carries --affected-by, but stage '") + job_id
                    + String("' is a PUSH stage; --affected-by belongs to a PULL_REQUEST stage's job")
                )
    # R9 (a split stage is checked as a whole, `_check_split`), R10, R12
    for i in range(len(calls)):
        if calls[i].has_only and not split:
            findings.append(
                where + String(": R9: `kci run` carries --only; a release job runs its whole stage")
                + String(" (a FULL run), never a selection, unless the stage is split over jobs that")
                + String(" together run all of it")
            )
    _check_calls_common(doc, job_id, job, calls, machine_path, findings)


def _check_part_job(
    doc: WorkflowDoc,
    job_id: String,
    job: Int,
    st: Stage,
    g: ReleaseMachine,
    machine_path: String,
    pr_trigger: Bool,
    mut findings: List[String],
):
    """R2, R3, R4, R11 for a job that runs a part of stage `st` (file
    header, R9); then R10 and R12."""
    var where = _at(doc, job) + String("job '") + job_id + String("'")
    var what = String(": runs only validations of stage '") + st.name + String("', so it ")
    # R2
    if doc.child(job, String("environment")) >= 0:
        findings.append(
            where + String(": R2") + what
            + String("runs in no environment: it needs no approval and must hold no environment secret")
        )
    # R4
    if _id_token_write(doc, doc.child(job, String("permissions"))):
        findings.append(where + String(": R4") + what + String("must not hold `id-token: write`"))
    # R11
    if _farm_connect_steps(doc, job) > 0:
        findings.append(where + String(": R11") + what + String("must not use ") + String(FARM_CONNECT_ACTION))
    # R3: the job named after the stage, and besides it only the stage's `after`
    var needs = doc.scalar_or_list(doc.child(job, String("needs")))
    var said = joined_names(needs)
    if said.byte_length() == 0:
        said = String("nothing")
    if not _member(needs, st.name):
        findings.append(
            where + String(": R3: needs ") + said + String("; a job that runs validations of stage '") + st.name
            + String("' needs '") + st.name + String("' (the job that runs its steps)")
        )
    for i in range(len(needs)):
        if needs[i] != st.name and needs[i] != st.after:
            var also = String("nothing else")
            if st.after.byte_length() > 0:
                also = String("'") + st.after + String("'")
            findings.append(
                where + String(": R3: needs ") + said + String("; besides '") + st.name + String("' it may need only ")
                + also
            )
            break
    # R6: a part of a release stage is release-only too
    if pr_trigger:
        check_release_only(doc, job_id, job, st.name, findings)
    var calls = _job_calls(doc, job)
    _check_calls_common(doc, job_id, job, calls, machine_path, findings)


def _job_selection(
    doc: WorkflowDoc, job_id: String, job: Int, st: Stage, mut findings: List[String]
) -> Optional[Selection]:
    """What `job_id` runs of `st`: its one `kci run`'s `--only` values
    resolved against the stage (no `--only`: all of it). None, with a
    finding, when a value is not a literal selector or matches nothing."""
    var calls = _job_calls(doc, job)
    if len(calls) != 1:
        return None  # R5 says so
    var where = _at(doc, job) + String("R9: job '") + job_id + String("'")
    var selectors = List[Selector]()
    for i in range(len(calls[0].only)):
        ref text = calls[0].only[i]
        try:
            selectors.append(parse_selector(text))
        except:
            findings.append(
                where + String(": `--only ") + text
                + String("` is not a literal step:<name> or validation:<name>")
            )
            return None
    if calls[0].has_only and len(calls[0].only) == 0:
        findings.append(where + String(": `--only` has no value"))
        return None
    try:
        return resolve_selection(st, selectors)
    except e:
        findings.append(where + String(": ") + String(e))
        return None


def _check_split(
    doc: WorkflowDoc,
    st: Stage,
    main_id: String,
    main_job: Int,
    job_ids: List[String],
    job_nodes: List[Int],
    parts: List[Int],
    mut findings: List[String],
):
    """R9 for a split stage (file header): every step and every validation
    run by exactly one of its jobs; steps only by the job named after it."""
    var ids = List[String]()
    var sels = List[Selection]()
    var m = _job_selection(doc, main_id, main_job, st, findings)
    if not m:
        return
    ids.append(main_id.copy())
    sels.append(m.take())
    for k in range(len(parts)):
        var p = _job_selection(doc, job_ids[parts[k]], job_nodes[parts[k]], st, findings)
        if not p:
            return
        var sel = p.take()
        for s in range(len(st.steps)):
            if sel.steps[s]:
                findings.append(
                    _at(doc, job_nodes[parts[k]]) + String("R9: job '") + job_ids[parts[k]] + String("' runs step '")
                    + st.steps[s].name + String("' of stage '") + st.name
                    + String("'; only the job named after the stage runs its steps")
                )
        ids.append(job_ids[parts[k]].copy())
        sels.append(sel^)
    var over = String("job ") if len(ids) == 1 else String("jobs ")
    over += joined_names(ids)
    for s in range(len(st.steps)):
        var by = List[String]()
        for j in range(len(sels)):
            if sels[j].steps[s]:
                by.append(ids[j].copy())
        _one_runner(st, over, String("step"), st.steps[s].name, by, findings)
        for v in range(len(st.steps[s].validations)):
            ref name = st.steps[s].validations[v].name
            var vby = List[String]()
            for j in range(len(sels)):
                if _member(sels[j].validations, name):
                    vby.append(ids[j].copy())
            _one_runner(st, over, String("validation"), name, vby, findings)


def _one_runner(st: Stage, over: String, kind: String, name: String, by: List[String], mut findings: List[String]):
    if len(by) == 0:
        findings.append(
            String("R9: stage '") + st.name + String("' is split over ") + over + String(", and none of them runs ")
            + kind + String(" '") + name + String("'")
        )
    elif len(by) > 1:
        findings.append(
            String("R9: stage '") + st.name + String("': ") + kind + String(" '") + name + String("' is run by ")
            + String(len(by)) + String(" jobs (") + joined_names(by) + String(")")
        )


def _stage_index(g: ReleaseMachine, name: String) -> Int:
    for i in range(len(g.stages)):
        if g.stages[i].name == name:
            return i
    return -1


def check_workflow_doc(
    doc: WorkflowDoc, g: ReleaseMachine, token_stages: List[String], machine_path: String
) -> List[String]:
    """Every disagreement between `doc` and `g` (file header); empty when
    they agree. `machine_path` is the machine file `g` was read from, as the
    caller named it (R10)."""
    var findings = List[String]()
    var root = 0
    # R6, R7
    var on = doc.child(root, String("on"))
    var triggers = _triggers(doc, on)
    if len(triggers) == 0:
        findings.append(String("R6: the workflow has no `on:` triggers"))
    var pr_trigger = _member(triggers, String("pull_request"))
    var pr_stages = List[String]()
    for i in range(len(g.stages)):
        if g.stages[i].is_pull_request():
            pr_stages.append(g.stages[i].name.copy())
    for i in range(len(triggers)):
        if triggers[i] == String("pull_request_target"):
            findings.append(
                _at(doc, on) + String("R6: trigger 'pull_request_target': it runs a pull request's code with the")
                + String(" base repository's secrets, and no workflow has it")
            )
        elif triggers[i] == String("pull_request") and len(pr_stages) == 0:
            findings.append(
                _at(doc, on) + String("R6: trigger 'pull_request': the machine file declares no PULL_REQUEST stage,")
                + String(" and a release stage never runs a pull request's code")
            )
    if len(pr_stages) > 0 and not pr_trigger:
        findings.append(
            _at(doc, on) + String("R6: the machine file declares the PULL_REQUEST stage '") + pr_stages[0]
            + String("', so the workflow has a `pull_request` trigger (its job is the pull request's check)")
        )
    var inputs = doc.child(doc.child(on, String("workflow_dispatch")), String("inputs"))
    if doc.child(inputs, String("revision")) < 0:
        findings.append(_at(doc, on) + String("R7: workflow_dispatch takes no input `revision` (the commit a manual run releases)"))
    # R4, workflow level, and the form of every `permissions:`
    _check_permissions_form(doc, root, String("workflow: "), findings)
    var all_jobs = doc.child(root, String("jobs"))
    var all_ids = doc.keys(all_jobs)
    var all_nodes = doc.items(all_jobs)
    for i in range(len(all_ids)):
        _check_permissions_form(doc, all_nodes[i], String("job '") + all_ids[i] + String("': "), findings)
    if _id_token_write(doc, doc.child(root, String("permissions"))):
        findings.append(
            _at(doc, doc.child(root, String("permissions")))
            + String("R4: `id-token: write` at the workflow level reaches every job; grant it on the publishing job only")
        )
    # R1 and the per-job rules
    var jobs = doc.child(root, String("jobs"))
    var job_ids = doc.keys(jobs)
    var job_nodes = doc.items(jobs)
    if jobs < 0 or doc.kind(jobs) != NODE_MAP:
        findings.append(String("R1: the workflow has no `jobs:` mapping"))
    # a job no stage names may run a PART of one (R9)
    var part_stage = List[String]()
    for i in range(len(job_ids)):
        part_stage.append(String(""))
        if g.has_stage(job_ids[i]):
            continue
        var calls = _job_calls(doc, job_nodes[i])
        if len(calls) == 1 and calls[0].has_only and g.has_stage(calls[0].stage):
            var of = _stage_index(g, calls[0].stage)
            if g.stages[of].is_pull_request():
                findings.append(
                    _at(doc, job_nodes[i]) + String("R6: job '") + job_ids[i] + String("' runs a part of stage '")
                    + calls[0].stage + String("', a PULL_REQUEST stage, which runs whole in the job of its name")
                )
            else:
                part_stage[i] = calls[0].stage.copy()
            continue
        findings.append(
            _at(doc, job_nodes[i]) + String("R1: job '") + job_ids[i]
            + String("' is no stage of the machine file (stages: ") + joined_names(g.stage_names())
            + String(") and runs no part of one (`kci run --stage <stage> --only ...`)")
        )
    for i in range(len(g.stages)):
        ref st = g.stages[i]
        var found = -1
        for j in range(len(job_ids)):
            if job_ids[j] == st.name:
                found = j
        var parts = List[Int]()
        for j in range(len(job_ids)):
            if part_stage[j] == st.name:
                parts.append(j)
        if found < 0:
            findings.append(String("R1: stage '") + st.name + String("' has no job of the same id"))
            continue
        var main_calls = _job_calls(doc, job_nodes[found])
        var split = len(parts) > 0
        for k in range(len(main_calls)):
            if main_calls[k].has_only:
                split = True
        var after_jobs = List[String]()
        if st.after.byte_length() > 0:
            after_jobs.append(st.after.copy())
            for j in range(len(job_ids)):
                if part_stage[j] == st.after:
                    after_jobs.append(job_ids[j].copy())
        _check_job(
            doc, job_ids[found], job_nodes[found], st, _member(token_stages, st.name), machine_path, len(parts) > 0,
            after_jobs, pr_trigger, findings,
        )
        for k in range(len(parts)):
            _check_part_job(doc, job_ids[parts[k]], job_nodes[parts[k]], st, g, machine_path, pr_trigger, findings)
        if split:
            _check_split(doc, st, job_ids[found], job_nodes[found], job_ids, job_nodes, parts, findings)
    # R8
    _collect_uses(doc, root, findings)
    return findings^


def check_workflow(
    workflow_text: String, g: ReleaseMachine, token_stages: List[String], machine_path: String
) raises -> List[String]:
    """`check_workflow_doc` over a workflow's text. Raises `cannot tell:` when
    the restricted reader cannot read it."""
    var doc = read_workflow(workflow_text)
    return check_workflow_doc(doc, g, token_stages, machine_path)


def check_running_workflow(
    g: ReleaseMachine, channels_files: List[ChannelsFile], workflow_text: String, machine_path: String
) raises -> List[String]:
    """The check `kci run` makes at start-up on the workflow it runs under:
    every disagreement between `workflow_text` and `g` (empty = they agree).
    It is `check_workflow` with the identity-token stages read from the
    channels files the graph names; the separate name pins the call site.
    Raises when a channels file is not given or is refused, and `cannot
    tell:` when the workflow cannot be read: the caller reports either as
    CANNOT_TELL, never a pass."""
    var token_stages = id_token_stages(g, channels_files)
    return check_workflow(workflow_text, g, token_stages, machine_path)
