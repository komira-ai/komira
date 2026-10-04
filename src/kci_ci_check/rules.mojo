# =============================================================================
# src/kci_ci_check/rules.mojo -- a CI workflow held to a machine file's stage
#   graph (`kci ci check`).
# =============================================================================
#
# The machine file owns the stage graph; the workflow is written by hand and
# must agree with it. `check_workflow` returns every disagreement (empty =
# they agree); it never stops at the first, so one run names them all:
#
#   R1  the workflow's job ids are exactly the machine file's stage names
#       (a job no stage names, a stage no job runs)
#   R2  each job runs in the GitHub environment named like its id
#       (`environment: <id>`, or `environment: {name: <id>}` as a block)
#   R3  each job's `needs` is exactly its stage's `after` (none for none)
#   R4  `id-token: write` is in a job's own `permissions` exactly when its
#       stage needs an identity token (it publishes to a channel whose
#       credential is OIDC trusted publishing: `id_token_stages`); and never
#       in the workflow-level `permissions`, which reach every job
#   R5  each job's steps invoke `kci run` exactly once, with `--stage` its
#       own id written literally (a `--stage` naming another stage, or one
#       that is a variable, is a disagreement)
#   R6  no trigger is `pull_request` or `pull_request_target`: a release
#       workflow never runs a pull request's code
#   R7  `workflow_dispatch` takes an input `revision` (the commit a manual
#       run releases)
#   R8  every `uses:` is pinned to a full 40-hex commit id
#   R9  no `kci run` carries `--only`: a release job runs its whole stage,
#       so its result is a FULL run, never a selective one
#   R10 each `kci run` reads the machine file being checked: a `--machine`
#       must name that file, and a `kci run` without one reads the default
#       (kci_contract's DEFAULT_MACHINE_FILE), which must then be that file.
#       Paths are compared as written, after dropping a leading `./`
#
# How `kci run` is found (R5): each `run:` block is split into shell words
# (a line ending in `\` continues; quotes around a word are dropped); an
# invocation is a word in COMMAND position (the first word of a line, or
# right after `;` `&&` `||` `|` `then` `do` `else` `exec` `!`, or after a
# word ending in `;`) whose last `/`-separated part is `kci`, followed by
# the word `run`. So `echo "... kci run ..."` is not one. Its arguments run
# to the end of the line or the next `;` `&&` `||` `|`; `--stage`,
# `--machine` and `--only` take the next word, or `=<v>`.
#
# A workflow the restricted reader cannot read raises (`cannot tell:`,
# workflow_reader.mojo): the caller reports INDETERMINATE, never a pass.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from kci_contract import DEFAULT_MACHINE_FILE
from kci_release_channel import ChannelDeclaration, find_channel, parse_channels_file
from kci_stage_graph import Stage, StageGraph, joined_names

from .workflow_reader import NODE_LIST, NODE_MAP, NODE_SCALAR, WorkflowDoc, read_workflow


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


def channels_paths(g: StageGraph) -> List[String]:
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


def _channel_is_oidc(ch: ChannelDeclaration) -> Bool:
    for i in range(len(ch.repositories)):
        ref r = ch.repositories[i]
        if r.credential and r.credential.value().is_oidc_trusted_publishing():
            return True
    return False


def id_token_stages(g: StageGraph, files: List[ChannelsFile]) raises -> List[String]:
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
            var decls = parse_channels_file(_channels_text(files, s.channels))
            var ch = find_channel(decls, s.channel)
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
        for t in range(len(toks)):
            var w = String(toks[t])
            if w.byte_length() == 0:
                continue
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
    the `--machine` value (`has_machine` False when absent), and whether it
    carries any `--only`.
    Layout: owned Strings and Bools. No pointer field."""

    var stage: String
    var machine: String
    var has_machine: Bool
    var has_only: Bool

    def __init__(out self, var stage: String):
        self.stage = stage^
        self.machine = String("")
        self.has_machine = False
        self.has_only = False


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


def _id_token_write(doc: WorkflowDoc, perms: Int) -> Bool:
    var v = doc.child(perms, String("id-token"))
    return v >= 0 and doc.kind(v) == NODE_SCALAR and doc.text(v) == String("write")


def _check_job(
    doc: WorkflowDoc,
    job_id: String,
    job: Int,
    st: Stage,
    needs_token: Bool,
    machine_path: String,
    mut findings: List[String],
):
    var where = _at(doc, job) + String("job '") + job_id + String("'")
    # R2
    var env = doc.child(job, String("environment"))
    var env_name = String("")
    if env >= 0 and doc.kind(env) == NODE_SCALAR:
        env_name = doc.text(env)
    elif env >= 0 and doc.kind(env) == NODE_MAP:
        var n = doc.child(env, String("name"))
        if n >= 0 and doc.kind(n) == NODE_SCALAR:
            env_name = doc.text(n)
    if env_name != job_id:
        if env_name.byte_length() == 0:
            findings.append(where + String(": R2: runs in no environment; it must run in `environment: ") + job_id + String("`"))
        else:
            findings.append(
                where + String(": R2: runs in environment '") + env_name + String("'; it must run in '")
                + job_id + String("' (the stage's name)")
            )
    # R3
    var needs = doc.scalar_or_list(doc.child(job, String("needs")))
    var want_after = st.after.copy()
    var needs_ok = (len(needs) == 0 and want_after.byte_length() == 0) or (len(needs) == 1 and needs[0] == want_after)
    if not needs_ok:
        var said = joined_names(needs)
        if said.byte_length() == 0:
            said = String("nothing")
        var want = want_after.copy()
        if want.byte_length() == 0:
            want = String("nothing")
        findings.append(
            where + String(": R3: needs ") + said + String("; the stage runs after ") + want
        )
    # R4
    var has_token = _id_token_write(doc, doc.child(job, String("permissions")))
    if needs_token and not has_token:
        findings.append(
            where + String(": R4: stage '") + job_id
            + String("' publishes by OIDC trusted publishing, so the job needs `id-token: write` in its own permissions")
        )
    if has_token and not needs_token:
        findings.append(
            where + String(": R4: has `id-token: write`, but stage '") + job_id
            + String("' publishes to no OIDC channel; remove it")
        )
    # R5
    var calls = List[KciRunCall]()
    var steps = doc.items(doc.child(job, String("steps")))
    for i in range(len(steps)):
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
    # R9, R10
    for i in range(len(calls)):
        ref call = calls[i]
        if call.has_only:
            findings.append(
                where + String(": R9: `kci run` carries --only; a release job runs its whole stage")
                + String(" (a FULL run), never a selection")
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


def check_workflow_doc(
    doc: WorkflowDoc, g: StageGraph, token_stages: List[String], machine_path: String
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
    for i in range(len(triggers)):
        if triggers[i] == String("pull_request") or triggers[i] == String("pull_request_target"):
            findings.append(
                _at(doc, on) + String("R6: trigger '") + triggers[i]
                + String("': a release workflow never runs a pull request's code")
            )
    var inputs = doc.child(doc.child(on, String("workflow_dispatch")), String("inputs"))
    if doc.child(inputs, String("revision")) < 0:
        findings.append(_at(doc, on) + String("R7: workflow_dispatch takes no input `revision` (the commit a manual run releases)"))
    # R4, workflow level
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
    for i in range(len(job_ids)):
        if not g.has_stage(job_ids[i]):
            findings.append(
                _at(doc, job_nodes[i]) + String("R1: job '") + job_ids[i]
                + String("' is no stage of the machine file (stages: ") + joined_names(g.stage_names()) + String(")")
            )
    for i in range(len(g.stages)):
        ref st = g.stages[i]
        var found = -1
        for j in range(len(job_ids)):
            if job_ids[j] == st.name:
                found = j
        if found < 0:
            findings.append(String("R1: stage '") + st.name + String("' has no job of the same id"))
            continue
        _check_job(doc, job_ids[found], job_nodes[found], st, _member(token_stages, st.name), machine_path, findings)
    # R8
    _collect_uses(doc, root, findings)
    return findings^


def check_workflow(
    workflow_text: String, g: StageGraph, token_stages: List[String], machine_path: String
) raises -> List[String]:
    """`check_workflow_doc` over a workflow's text. Raises `cannot tell:` when
    the restricted reader cannot read it."""
    var doc = read_workflow(workflow_text)
    return check_workflow_doc(doc, g, token_stages, machine_path)
