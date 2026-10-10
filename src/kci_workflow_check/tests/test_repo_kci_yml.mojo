# =============================================================================
# src/kci_workflow_check/tests/test_repo_kci_yml.mojo -- the repository's own
#   two workflows, .github/workflows/kci.yml (the release) and pr.yml (the pull
#   request's check), each held to the machine file, release/machine.textproto,
#   by the same check `kci run` makes at start-up (`check_running_workflow`,
#   with `pull_request_file` for pr.yml): it finds nothing. A drift between the
#   two (a renamed job or environment, a stage the workflow does not run, a
#   `pull_request` trigger in kci.yml, a job in pr.yml that is not the pull
#   request's check, a pr job a fork reaches, an unpinned
#   action, a split of a stage that does not
#   run all of it exactly once, a `kci run` without --summary-file or reading
#   another machine file, farm-connect on the wrong job) fails this test, and with it `./buck2 build //...` on every pull
#   request. The workflow's KCI_MACHINE (used only to skip a revision without a
#   machine file) must be kci's default machine file, because no `kci` line of
#   the workflow passes --machine. The workflow names no removed input or verb
#   (`ci check`, a claim, an expected set hash) and no channel but the machine
#   file's. The validate job's `kci run` is the one each validation target
#   (`./buck2 run //release/validations:<name>`) runs, but for paths and what
#   a caller supplies; no other job handles pixi. Continuous auto-promotion: build and gamma are
#   break_glass, prod is not; a break-glass publish to gamma goes through the
#   environment gamma-breakglass, which the gamma channel trusts as its
#   second publisher, and prod has none; the push trigger's documentation
#   filter is the documentation release_version.sh does not count (R17).
# =============================================================================
#
# The files are staged as test data (BUCK): `kci.yml` (the root BUCK exports
# it), `machine.textproto` and `channels.textproto` (release/BUCK),
# release_version.sh (tools/build/package/BUCK), `pixi_pin.txt`, the
# platform table's linux-x86_64 pixi pin
# (//tools/build/toolchains:pixi_pin_linux_x86_64), and `validations.txt`,
# the validation targets' record (//release/validations:names, one line per
# target: `<name> <stage> <kci> <argv...>`, paths and the platform's pixi
# sha256 as `<placeholders>`). gamma's validations run each installed
# library's README, so they name no program.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_workflow_check import (
    FARM_CONNECT_ACTION,
    NODE_SCALAR,
    KciRunCall,
    ChannelsFile,
    channels_paths,
    check_running_workflow,
    check_workflow,
    documentation_filter_findings,
    id_token_stages,
    kci_run_calls,
    read_workflow,
)
from kci_api import DEFAULT_MACHINE_FILE
from kci_release_channel import (
    break_glass_push_identity_environment,
    find_channel,
    parse_channels_file,
    push_identity_environment,
)
from kci_release_machine import ReleaseMachine, parse_machine_file


def _graph() raises -> ReleaseMachine:
    return parse_machine_file(Path(String("machine.textproto")).read_text(), String("release/machine.textproto"))


def _channels() raises -> List[ChannelsFile]:
    var files = List[ChannelsFile]()
    files.append(ChannelsFile(String("release/channels.textproto"), Path(String("channels.textproto")).read_text()))
    return files^


def _joined(findings: List[String]) -> String:
    var all = String("")
    for i in range(len(findings)):
        all += String("\n  ") + findings[i]
    return all^


def _pixi_pin_findings(text: String, pin: String) raises -> List[String]:
    """What keeps the workflow `text` from installing with the pixi `pin`.

    The validate job downloads the pin's URL itself and keeps the bytes only
    at the pin's sha256, and its one `kci run` passes them and that sha256.
    Both values are the platform table's (the record //tools/build/toolchains
    writes from it), so neither the job nor any other job chooses which pixi
    runs: no other job handles pixi, and the build job's tar carries kci, the
    release and its result file only. An empty or absent value is a finding
    here, at build time, not a refusal of `kci run`.
    """
    var out = List[String]()
    var doc = read_workflow(text)
    var jobs = doc.child(0, String("jobs"))
    var validate = doc.child(jobs, String("validate"))
    if validate < 0:
        out.append(String("kci.yml has no job validate"))
        return out^
    var venv = doc.child(validate, String("env"))
    var vals = List[String]()
    for name in [String("PIXI_URL"), String("PIXI_SHA256")]:
        var n = doc.child(venv, name) if venv >= 0 else -1
        if n < 0 or doc.kind(n) != NODE_SCALAR:
            out.append(String("the validate job sets no env ") + name)
            vals.append(String(""))
        else:
            vals.append(doc.text(n))
    var got = String("url ") + vals[0] + String("\nsha256 ") + vals[1] + String("\n")
    if got != pin:
        out.append(String("the validate job's PIXI_URL/PIXI_SHA256 are not the pin: ") + got + String("!= ") + pin)
    var vrun = String("")
    var vall = String("")
    var vsteps = doc.items(doc.child(validate, String("steps")))
    for i in range(len(vsteps)):
        var r = doc.child(vsteps[i], String("run"))
        if r >= 0 and doc.kind(r) == NODE_SCALAR:
            vall += doc.text(r) + String("\n")
            if len(kci_run_calls(doc.text(r))) > 0:
                vrun = doc.text(r)
    if vall.find(String("curl -fsSL --retry 3 -o \"$RUNNER_TEMP/pixi/pixi\" \"$PIXI_URL\"")) < 0:
        out.append(String("the validate job does not download $PIXI_URL"))
    if vall.find(String("printf '%s  %s\\n' \"$PIXI_SHA256\" \"$RUNNER_TEMP/pixi/pixi\" | sha256sum -c -")) < 0:
        out.append(String("the validate job does not check the download against $PIXI_SHA256"))
    if vrun.find(String("--pixi \"$RUNNER_TEMP/pixi/pixi\"")) < 0:
        out.append(String("the validate job passes no --pixi"))
    if vrun.find(String("--pixi-sha256 \"$PIXI_SHA256\"")) < 0:
        out.append(String("the validate job passes no --pixi-sha256"))
    var others = String("")
    for job in [String("build"), String("gamma"), String("prod")]:
        var jsteps = doc.items(doc.child(doc.child(jobs, job), String("steps")))
        for i in range(len(jsteps)):
            var r = doc.child(jsteps[i], String("run"))
            if r >= 0 and doc.kind(r) == NODE_SCALAR:
                others += doc.text(r) + String("\n")
    if others.find(String("pixi")) >= 0:
        out.append(String("a job other than validate handles pixi"))
    if others.find(String("-cf \"$RUNNER_TEMP/kci-release.tar\" kci release kci-result-build.json\n")) < 0:
        out.append(String("the build job's tar is not kci, the release and its result file only"))
    return out^


def test_the_release_machine() raises:
    var g = _graph()
    var names = g.stage_names()
    assert_equal(len(names), 4)
    assert_equal(names[0], String("build"))
    assert_equal(names[1], String("gamma"))
    assert_equal(names[2], String("prod"))
    assert_equal(names[3], String("pr"))
    # the pull request's check: no environment, farm-connected, one BUILD
    # step over the release's artifacts file, after nothing
    var pr = g.stage(String("pr"))
    assert_true(pr.is_pull_request())
    assert_equal(pr.environment, String(""))
    assert_true(pr.farm_connected)
    assert_equal(pr.after, String(""))
    assert_equal(len(pr.steps), 1)
    assert_true(pr.steps[0].is_build())
    assert_equal(pr.steps[0].platform, String("linux-x86_64"))
    assert_equal(pr.steps[0].artifacts, String("release/artifacts.textproto"))
    # continuous auto-promotion: a branch's manual run reaches build and
    # gamma (break-glass), never prod; the pr stage is no release stage
    assert_true(g.stage(String("build")).break_glass)
    assert_true(g.stage(String("gamma")).break_glass)
    assert_false(g.stage(String("prod")).break_glass)
    assert_false(pr.break_glass)
    var b = g.stage(String("build"))
    assert_equal(b.environment, String("build"))
    assert_true(b.farm_connected)
    assert_equal(len(b.steps), 1)
    assert_true(b.steps[0].is_build())
    assert_equal(b.steps[0].platform, String("linux-x86_64"))
    assert_equal(b.steps[0].artifacts, String("release/artifacts.textproto"))
    var channels = parse_channels_file(Path(String("channels.textproto")).read_text())
    var after = String("build")
    for name in [String("gamma"), String("prod")]:
        var p = g.stage(name)
        assert_equal(p.after, after)
        assert_equal(p.environment, name)
        assert_false(p.farm_connected)
        assert_equal(len(p.steps), 1)
        assert_true(p.steps[0].is_publish())
        assert_equal(p.steps[0].artifacts, String("release/artifacts.textproto"))
        assert_equal(p.steps[0].channels, String("release/channels.textproto"))
        assert_equal(p.steps[0].channel, name)
        # gamma's step carries the two ENV validations, each installing ONE
        # name: the library alone, and the metapackage alone (kci expands it
        # to every member); prod's none
        if name == String("gamma"):
            assert_equal(len(p.steps[0].validations), 2)
            var want_names = List[String]()
            want_names.append(String("install-komira-encoding"))
            want_names.append(String("install-set"))
            var want_installs = List[String]()
            want_installs.append(String("komira_encoding"))
            want_installs.append(String("komira_all"))
            for k in range(2):
                ref v = p.steps[0].validations[k]
                assert_equal(v.name, want_names[k])
                assert_equal(v.kind, String("CONDA_INSTALL_ENV"))
                assert_equal(len(v.installs), 1)
                assert_equal(v.installs[0], want_installs[k])
                assert_equal(v.compiler_channel, String("https://conda.modular.com/max"))
                assert_equal(len(v.extra_channels), 1)
                assert_equal(v.extra_channels[0], String("conda-forge"))
                assert_equal(v.smoke, String("README"))
                assert_equal(v.program, String(""))
                assert_equal(v.image, String(""))
                assert_equal(v.wait_for_index_seconds, 1800)
        else:
            assert_equal(len(p.steps[0].validations), 0)
        # The stage's environment IS the one the channel's trusted publisher
        # names: kci refuses a trusted publish from any other.
        var ch = find_channel(channels, p.steps[0].channel)
        assert_equal(push_identity_environment(ch.repositories[0]), p.environment)
        # a break-glass publish: its own environment, the channel's second
        # trusted publisher; prod has neither
        assert_equal(break_glass_push_identity_environment(ch.repositories[0]), p.break_glass_environment)
        if name == String("gamma"):
            assert_equal(p.break_glass_environment, String("gamma-breakglass"))
        else:
            assert_equal(p.break_glass_environment, String(""))
        after = name.copy()
    var paths = channels_paths(g)
    assert_equal(len(paths), 1)
    assert_equal(paths[0], String("release/channels.textproto"))


def test_kci_yml_agrees_with_the_machine_file() raises:
    var g = _graph()
    var tokens = id_token_stages(g, _channels())
    assert_equal(len(tokens), 2)
    assert_equal(tokens[0], String("gamma"))
    assert_equal(tokens[1], String("prod"))
    # the machine file checked is kci's default: every `kci run` reads it (R10);
    # the same entry point `kci run` calls at start-up
    var findings = check_running_workflow(g, _channels(), Path(String("kci.yml")).read_text(), String(DEFAULT_MACHINE_FILE))
    if len(findings) > 0:
        var all = String("")
        for i in range(len(findings)):
            all += String("\n  ") + findings[i]
        raise Error(String(".github/workflows/kci.yml disagrees with release/machine.textproto:") + all)


def test_pr_yml_agrees_with_the_machine_file() raises:
    # the pull request's check: the PULL_REQUEST stage alone, the same entry point
    # `kci run --stage pr` calls (pull_request_file)
    var findings = check_running_workflow(
        _graph(), _channels(), Path(String("pr.yml")).read_text(), String(DEFAULT_MACHINE_FILE), True
    )
    if len(findings) > 0:
        raise Error(String(".github/workflows/pr.yml disagrees with release/machine.textproto:") + _joined(findings))
    var doc = read_workflow(Path(String("pr.yml")).read_text())
    # the check is `pr / check`: workflow `pr`, the one job `check`
    assert_equal(doc.text(doc.child(0, String("name"))), String("pr"))
    var jobs = doc.child(0, String("jobs"))
    var ids = doc.keys(jobs)
    assert_equal(len(ids), 1)
    assert_equal(ids[0], String("check"))
    # nothing but the pull_request trigger
    var triggers = doc.keys(doc.child(0, String("on")))
    assert_equal(len(triggers), 1)
    assert_equal(triggers[0], String("pull_request"))
    # one `kci run --stage pr --affected-by`, one farm connection, no environment
    var steps = doc.items(doc.child(doc.items(jobs)[0], String("steps")))
    var runs = 0
    var farm = 0
    for i in range(len(steps)):
        var u = doc.child(steps[i], String("uses"))
        if u >= 0 and doc.kind(u) == NODE_SCALAR and doc.text(u) == FARM_CONNECT_ACTION:
            farm += 1
        var r = doc.child(steps[i], String("run"))
        if r >= 0 and doc.kind(r) == NODE_SCALAR:
            var calls = kci_run_calls(doc.text(r))
            for k in range(len(calls)):
                runs += 1
                assert_equal(calls[k].stage, String("pr"))
                assert_true(calls[k].has_affected_by)
                assert_true(calls[k].has_summary_file)
    assert_equal(runs, 1)
    assert_equal(farm, 1)
    assert_true(doc.child(doc.items(jobs)[0], String("environment")) < 0)
    # the build budget: the FIRST step takes the job's deadline, 5 of its
    # 120 minutes before GitHub would cancel it, and the one `kci run` gets
    # the seconds left of it as --build-budget-s (kci_build THE BUDGET)
    assert_equal(doc.text(doc.child(doc.items(jobs)[0], String("timeout-minutes"))), String("120"))
    var first = doc.child(steps[0], String("run"))
    assert_true(first >= 0, String("pr.yml's first step runs nothing"))
    assert_equal(
        doc.text(first), String('echo "$(( $(date +%s) + 115 * 60 ))" > "$RUNNER_TEMP/job_deadline_s"\n')
    )
    var budgeted = 0
    for i in range(len(steps)):
        var r = doc.child(steps[i], String("run"))
        if r >= 0 and doc.kind(r) == NODE_SCALAR and len(kci_run_calls(doc.text(r))) > 0:
            var t = doc.text(r)
            # a missing deadline file stops the step before the arithmetic
            # (which would read it as 0: a huge negative budget)
            assert_true(
                t.startswith(
                    String('[ -s "$RUNNER_TEMP/job_deadline_s" ] || { echo "::error::no job deadline in ')
                    + String("\\$RUNNER_TEMP/job_deadline_s: the job's first step did not write it\"; exit 1; }\n")
                    + String('budget_s=$(( $(cat "$RUNNER_TEMP/job_deadline_s") - $(date +%s) ))\n')
                ),
                t,
            )
            assert_true(t.find(String(' --build-budget-s "$budget_s" ')) >= 0, t)
            budgeted += 1
    assert_equal(budgeted, 1)


def test_each_real_workflow_is_refused_when_read_as_the_other() raises:
    var g = _graph()
    var tokens = id_token_stages(g, _channels())
    var kci_as_pr = check_workflow(Path(String("kci.yml")).read_text(), g, tokens, String(DEFAULT_MACHINE_FILE), True)
    assert_true(len(kci_as_pr) > 0, String("kci.yml read as the pull request's workflow is not refused"))
    var pr_as_release = check_workflow(Path(String("pr.yml")).read_text(), g, tokens, String(DEFAULT_MACHINE_FILE), False)
    assert_true(len(pr_as_release) > 0, String("pr.yml read as the release workflow is not refused"))
    # the real kci.yml has no pull_request trigger
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var triggers = doc.keys(doc.child(0, String("on")))
    for i in range(len(triggers)):
        assert_true(triggers[i] != String("pull_request"), String("kci.yml has a pull_request trigger"))


def test_kci_yml_splits_only_gamma_and_reads_the_default_machine_file() raises:
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var env = doc.child(0, String("env"))
    var m = doc.child(env, String("KCI_MACHINE"))
    assert_true(m >= 0 and doc.kind(m) == NODE_SCALAR, String("kci.yml sets no env KCI_MACHINE"))
    assert_equal(doc.text(m), String(DEFAULT_MACHINE_FILE))
    # every `kci run` of every job: no --machine (the default, R10), a
    # --summary-file (R12); --only only where gamma is split (R9): its step
    # in the job gamma, its validation in the job validate
    var jobs = doc.child(0, String("jobs"))
    var nodes = doc.items(jobs)
    var runs = 0
    var farm = 0
    var ids = doc.keys(jobs)
    var only_seen = List[String]()
    for j in range(len(nodes)):
        var steps = doc.items(doc.child(nodes[j], String("steps")))
        for i in range(len(steps)):
            var u = doc.child(steps[i], String("uses"))
            if u >= 0 and doc.kind(u) == NODE_SCALAR and doc.text(u) == FARM_CONNECT_ACTION:
                farm += 1
            var r = doc.child(steps[i], String("run"))
            if r < 0 or doc.kind(r) != NODE_SCALAR:
                continue
            var calls = kci_run_calls(doc.text(r))
            for k in range(len(calls)):
                runs += 1
                for o in range(len(calls[k].only)):
                    only_seen.append(ids[j] + String(" ") + calls[k].stage + String(" ") + calls[k].only[o])
                assert_true(not calls[k].has_machine, String("a kci run in kci.yml passes --machine"))
                assert_true(calls[k].has_summary_file, String("a kci run in kci.yml passes no --summary-file"))
    assert_equal(runs, 4)
    assert_equal(len(only_seen), 3)
    assert_equal(only_seen[0], String("gamma gamma step:publish"))
    assert_equal(only_seen[1], String("validate gamma validation:install-komira-encoding"))
    assert_equal(only_seen[2], String("validate gamma validation:install-set"))
    # the build job, and only it, joins the tailnet (pr.yml's check is the other)
    assert_equal(farm, 1)
    # the validate job: no environment, no identity token, after the publish
    var validate = doc.child(jobs, String("validate"))
    assert_true(validate >= 0, String("kci.yml has no job validate"))
    assert_true(doc.child(validate, String("environment")) < 0, String("the validate job runs in an environment"))
    var perms = doc.child(validate, String("permissions"))
    assert_true(doc.child(perms, String("id-token")) < 0, String("the validate job holds id-token"))
    var needs = doc.scalar_or_list(doc.child(validate, String("needs")))
    assert_equal(len(needs), 2)
    assert_equal(needs[1], String("gamma"))
    # the validate job installs with the platform table's linux-x86_64 pixi
    # pin, and no other job handles pixi (_pixi_pin_findings)
    var pixi = _pixi_pin_findings(Path(String("kci.yml")).read_text(), Path(String("pixi_pin.txt")).read_text())
    assert_equal(len(pixi), 0, _joined(pixi))
    # prod waits for the validation
    var prod_needs = doc.scalar_or_list(doc.child(doc.child(jobs, String("prod")), String("needs")))
    assert_equal(len(prod_needs), 2)
    assert_equal(prod_needs[1], String("validate"))


def test_the_documentation_filter_is_release_version_shs() raises:
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var f = documentation_filter_findings(Path(String("release_version.sh")).read_text(), doc)
    if len(f) > 0:
        raise Error(String("\n").join(f))
    # a documentation exclusion the trigger does not share is red
    var more = Path(String("release_version.sh")).read_text().replace(
        String("':(exclude).github'"), String("':(exclude).github' ':(exclude)README'")
    )
    var red = documentation_filter_findings(more, doc)
    assert_equal(len(red), 1, String("\n").join(red))
    assert_true(red[0].find(String("does not count 'README'")) >= 0, red[0])


def test_kci_yml_hands_the_set_hash_on() raises:
    # build hands its set hash to gamma and validate; validate hands what it
    # validated to prod (R19), read from each job's own kci result
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var jobs = doc.child(0, String("jobs"))
    var b = doc.child(doc.child(doc.child(jobs, String("build")), String("outputs")), String("set_hash"))
    assert_equal(doc.text(b), String("${{ steps.set_hash.outputs.set_hash }}"))
    var v = doc.child(doc.child(doc.child(jobs, String("validate")), String("outputs")), String("validated_set_hash"))
    assert_equal(doc.text(v), String("${{ steps.validated.outputs.set_hash }}"))
    for job in [String("gamma"), String("validate"), String("prod")]:
        var e = doc.child(doc.child(doc.child(jobs, job), String("env")), String("RELEASE_SET_HASH"))
        var want = String("${{ needs.validate.outputs.validated_set_hash }}") if job == String("prod") else String(
            "${{ needs.build.outputs.set_hash }}"
        )
        assert_equal(doc.text(e), want, job)


# A validate-job flag that no validation target passes is one a caller of the
# target supplies (`./buck2 run ... -- <these>`, or its launcher's default:
# --scratch-dir, --run-id, --attempt), or the CI run's own record.
def _supplied_flags() -> List[String]:
    var out = List[String]()
    for f in [
        "--release-dir", "--revision-id", "--scratch-dir", "--result-file", "--plan", "--run-id", "--attempt",
        "--context", "--summary-file", "--release-set-hash",
    ]:
        out.append(String(f))
    return out^


def _in(names: List[String], s: String) -> Bool:
    for i in range(len(names)):
        if names[i] == s:
            return True
    return False


def _flags(args: List[String], start: Int, where: String) raises -> List[List[String]]:
    """`args[start:]` as [flag, value] pairs (value "" for --plan); the job's
    `"$@"` (its --plan, when DRY_RUN) is the only other word allowed."""
    var out = List[List[String]]()
    var k = start
    while k < len(args):
        var a = args[k].copy()
        if a == String("$@"):
            k += 1
            continue
        if not a.startswith(String("--")):
            raise Error(where + String(": '") + a + String("' is not a flag"))
        var pair = List[String]()
        var eq = a.find(String("="))
        if eq > 0:
            pair.append(String(a[byte=0:eq]))
            pair.append(String(a[byte = eq + 1 :]))
        elif a == String("--plan") or k + 1 >= len(args):
            pair.append(a.copy())
            pair.append(String(""))
        else:
            pair.append(a.copy())
            pair.append(args[k + 1].copy())
            k += 1
        out.append(pair^)
        k += 1
    return out^


def _values(pairs: List[List[String]], flag: String) -> List[String]:
    var out = List[String]()
    for i in range(len(pairs)):
        if pairs[i][0] == flag:
            out.append(pairs[i][1].copy())
    return out^


def test_the_validate_job_runs_what_the_validation_targets_run() raises:
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var validate = doc.child(doc.child(0, String("jobs")), String("validate"))
    var calls = List[KciRunCall]()
    var vsteps = doc.items(doc.child(validate, String("steps")))
    for i in range(len(vsteps)):
        var r = doc.child(vsteps[i], String("run"))
        if r >= 0 and doc.kind(r) == NODE_SCALAR:
            calls.extend(kci_run_calls(doc.text(r)))
    assert_equal(len(calls), 1, String("the validate job runs `kci run` once"))
    var job = _flags(calls[0].args, 0, String("the validate job's kci run"))
    var stage = _values(job, String("--stage"))
    assert_equal(len(stage), 1)
    var lines = Path(String("validations.txt")).read_text().split(String("\n"))
    var target_flags = List[String]()
    var want_only = List[String]()
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var words = List[String]()
        var parts = line.split(String(" "))
        for p in range(len(parts)):
            words.append(String(parts[p]))
        var where = String("validation target '") + words[0] + String("'")
        assert_true(len(words) > 4 and words[2] == String("<kci>") and words[3] == String("run"), where)
        if words[1] != stage[0]:
            continue
        want_only.append(String("validation:") + words[0])
        # every argument the target passes, the job passes: the same value,
        # or for a path or the platform's pin, the job's own
        var mine = _flags(words, 4, where)
        for f in range(len(mine)):
            var flag = mine[f][0].copy()
            var value = mine[f][1].copy()
            target_flags.append(flag.copy())
            var theirs = _values(job, flag)
            if flag == String("--machine"):
                # the job reads kci's default machine file, the one the
                # target names (R10 holds every kci run of kci.yml to it)
                assert_equal(value, String("<machine>"), where)
                assert_equal(len(theirs), 0, String("the validate job passes --machine"))
                continue
            assert_true(
                len(theirs) > 0,
                where + String(" passes ") + flag + String(", which the validate job's kci run does not"),
            )
            if value == String("<pixi>") or value == String("<pixi-sha256>"):
                assert_equal(len(theirs), 1, flag)
                continue
            assert_true(
                _in(theirs, value),
                where + String(" passes ") + flag + String(" ") + value + String("; the validate job passes ")
                + flag + String(" ") + theirs[0],
            )
    # the job's validations are exactly the targets of its stage
    var job_only = _values(job, String("--only"))
    assert_true(len(want_only) > 0, String("no validation target runs stage ") + stage[0])
    assert_equal(len(job_only), len(want_only))
    for i in range(len(want_only)):
        assert_true(_in(job_only, want_only[i]), String("the validate job does not run ") + want_only[i])
    # and every flag of the job is a target's, a caller's or the run record's
    for i in range(len(job)):
        var flag = job[i][0].copy()
        assert_true(
            _in(target_flags, flag) or _in(_supplied_flags(), flag),
            String("the validate job passes ") + flag + String(", which no validation target passes and no caller supplies"),
        )


def test_kci_yml_names_no_removed_input_and_no_other_channel() raises:
    var text = Path(String("kci.yml")).read_text()
    for gone in [String("ci check"), String("claim"), String("expect_set_hash"), String("approved_names"), String("rehearsal"), String("publish_prod")]:
        assert_true(text.find(gone) < 0, String("kci.yml still names '") + gone + String("'"))
    # every prefix.dev channel path kci.yml names is one the machine file publishes to
    var g = _graph()
    var allowed = List[String]()
    var channels = parse_channels_file(Path(String("channels.textproto")).read_text())
    for i in range(len(g.stages)):
        for k in range(len(g.stages[i].steps)):
            ref step = g.stages[i].steps[k]
            if step.is_publish():
                var loc = find_channel(channels, step.channel).repositories[0].location
                allowed.append(String(loc[byte = String("https://prefix.dev/").byte_length() :]))
    var at = text.find(String("komira-ai/"))
    var seen = 0
    while at >= 0:
        var end = at + String("komira-ai/").byte_length()
        var b = text.as_bytes()
        while end < len(b) and ((b[end] >= 97 and b[end] <= 122) or (b[end] >= 48 and b[end] <= 57) or b[end] == 45 or b[end] == 95):
            end += 1
        var path = String(text[byte = at:end])
        if path != String("komira-ai/komira"):
            var ok = False
            for i in range(len(allowed)):
                if allowed[i] == path:
                    ok = True
            assert_true(ok, String("kci.yml names channel '") + path + String("', which no stage of the machine file publishes to"))
            seen += 1
        at = text.find(String("komira-ai/"), end)
    assert_true(seen > 0, String("kci.yml names neither channel"))


def test_an_empty_pixi_sha_is_refused_before_run_time() raises:
    # A workflow edit that empties the pin's sha256, or has the build job
    # write one, is refused by this build, not by `kci run` in the job.
    var text = Path(String("kci.yml")).read_text()
    var pin = Path(String("pixi_pin.txt")).read_text()
    var at = pin.find(String("\nsha256 "))
    assert_true(at >= 0, String("pixi_pin.txt has no sha256 line"))
    var sha = String(pin[byte = at + String("\nsha256 ").byte_length() :]).strip()
    var line = String("      PIXI_SHA256: ") + String(sha) + String("\n")
    assert_true(text.find(line) >= 0, String("kci.yml has no PIXI_SHA256 line to mutate"))
    for empty in [String("      PIXI_SHA256: ''\n"), String("      PIXI_SHA256: \"\"\n"), String("      PIXI_SHA256:\n"), String("")]:
        var refused = False
        try:
            refused = len(_pixi_pin_findings(text.replace(line, empty), pin)) > 0
        except:
            refused = True  # the reader cannot tell: the check fails closed
        assert_true(refused, String("an emptied PIXI_SHA256 is not refused: '") + empty + String("'"))
    # the old shape: the build job ships a pixi and its sha in the release tar
    var tar = String("kci release kci-result-build.json\n")
    assert_true(text.find(tar) >= 0, String("kci.yml has no release tar line to mutate"))
    var shipped = text.replace(tar, String("kci release kci-result-build.json pixi\n"))
    var found = _pixi_pin_findings(shipped, pin)
    assert_true(len(found) > 0, String("a build job writing a pixi sha is not refused"))


def _in_job(text: String, job: String, anchor: String, added: String) raises -> String:
    """`text` with `added` written right after the first `anchor` that
    follows the job `job`'s header line; the step is then read back to
    prove the edit landed in that job's `run:`."""
    var head = text.find(String("\n  ") + job + String(":\n"))
    assert_true(head >= 0, String("kci.yml has no job ") + job)
    var at = text.find(anchor, head)
    assert_true(at >= 0, String("kci.yml's job ") + job + String(" has no line to mutate: ") + anchor)
    var end = at + anchor.byte_length()
    var out = String(text[byte = 0:end]) + added + String(text[byte = end:])
    var doc = read_workflow(out)
    var steps = doc.items(doc.child(doc.child(doc.child(0, String("jobs")), job), String("steps")))
    var landed = False
    for i in range(len(steps)):
        var r = doc.child(steps[i], String("run"))
        if r >= 0 and doc.kind(r) == NODE_SCALAR and doc.text(r).find(added) >= 0:
            landed = True
    assert_true(landed, String("the mutation did not land in job ") + job)
    return out^


def test_only_the_validate_job_handles_pixi() raises:
    # The rule "a job other than validate handles pixi", alone: each of
    # build, gamma and prod given one more word `pixi` in a `run:` (the
    # pin, the downloads and the release tar line untouched) is refused
    # with exactly that finding; the same word in validate itself is not.
    var text = Path(String("kci.yml")).read_text()
    var pin = Path(String("pixi_pin.txt")).read_text()
    var base = _pixi_pin_findings(text, pin)
    assert_equal(len(base), 0, _joined(base))
    var added = String(" && echo pixi")
    var version = String("run: tools/build/package/release_version.sh \"$REVISION\" | tee \"$RUNNER_TEMP/release_version.txt\"")
    var build_kci = String("run: ./buck2 build '//bin/kci:kci[runnable]' --out \"$RUNNER_TEMP/kci\"")
    var unpack = String("run: tar -C \"$RUNNER_TEMP\" -xf \"$RUNNER_TEMP/in/kci-release.tar\"")
    var cases = List[Tuple[String, String]]()
    cases.append((String("build"), build_kci.copy()))
    cases.append((String("gamma"), version.copy()))
    cases.append((String("prod"), version.copy()))
    for c in cases:
        var job = c[0].copy()
        var found = _pixi_pin_findings(_in_job(text, job, c[1], added), pin)
        assert_equal(len(found), 1, String("job ") + job + String(" handling pixi:") + _joined(found))
        assert_equal(found[0], String("a job other than validate handles pixi"))
    var own = _pixi_pin_findings(_in_job(text, String("validate"), unpack, added), pin)
    assert_equal(len(own), 0, String("the validate job handling pixi is refused:") + _joined(own))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
