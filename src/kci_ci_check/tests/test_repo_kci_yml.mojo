# =============================================================================
# src/kci_ci_check/tests/test_repo_kci_yml.mojo -- the repository's own
#   release workflow, .github/workflows/kci.yml, held to its own machine file,
#   release/machine.textproto, by the same check `kci run` makes at start-up
#   (`check_running_workflow`): it finds nothing. A drift between the two (a
#   renamed job or environment, a stage the workflow does not run, a
#   release job a pull request reaches, a pr job a fork reaches, an unpinned
#   action, a split of a stage that does not
#   run all of it exactly once, a `kci run` without --summary-file or reading
#   another machine file, farm-connect on the wrong job) fails this test, and with it `./buck2 build //...` on every pull
#   request. The workflow's KCI_MACHINE (used only to skip a revision without a
#   machine file) must be kci's default machine file, because no `kci` line of
#   the workflow passes --machine. The workflow names no removed input or verb
#   (`ci check`, a claim, an expected set hash) and no channel but the machine
#   file's.
# =============================================================================
#
# The files are staged as test data (BUCK): `kci.yml` (the root BUCK exports
# it), `machine.textproto` and `channels.textproto` (release/BUCK), and the
# program gamma's validation runs (release/smoke/BUCK).
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_ci_check import (
    FARM_CONNECT_ACTION,
    NODE_SCALAR,
    ChannelsFile,
    channels_paths,
    check_running_workflow,
    id_token_stages,
    kci_run_calls,
    read_workflow,
)
from kci_api import DEFAULT_MACHINE_FILE
from kci_release_channel import find_channel, parse_channels_file, push_identity_environment
from kci_release_machine import ReleaseMachine, parse_machine_file


def _graph() raises -> ReleaseMachine:
    return parse_machine_file(Path(String("machine.textproto")).read_text(), String("release/machine.textproto"))


def _channels() raises -> List[ChannelsFile]:
    var files = List[ChannelsFile]()
    files.append(ChannelsFile(String("release/channels.textproto"), Path(String("channels.textproto")).read_text()))
    return files^


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
        # gamma's step carries the install validation; prod's none
        if name == String("gamma"):
            assert_equal(len(p.steps[0].validations), 1)
            ref v = p.steps[0].validations[0]
            assert_equal(v.name, String("install"))
            assert_equal(v.kind, String("CONDA_INSTALL_SMOKE"))
            assert_equal(len(v.installs), 2)
            assert_equal(v.installs[0], String("komira_encoding"))
            assert_equal(v.installs[1], String("komira_all"))
            assert_equal(v.compiler_channel, String("https://conda.modular.com/max"))
            assert_equal(v.program, String("release/smoke/smoke_komira_encoding.mojo"))
            assert_true(v.image.startswith(String("ghcr.io/prefix-dev/pixi:")), v.image)
            assert_equal(v.wait_for_index_seconds, 1800)
            # the program the validation names is there, and states its count
            var program = Path(String("smoke_komira_encoding.mojo")).read_text()
            assert_true(program.find(String("\"komira_encoding validation: \"")) >= 0, String("the smoke program prints no count line"))
        else:
            assert_equal(len(p.steps[0].validations), 0)
        # The stage's environment IS the one the channel's trusted publisher
        # names: kci refuses a trusted publish from any other.
        var ch = find_channel(channels, p.steps[0].channel)
        assert_equal(push_identity_environment(ch.repositories[0]), p.environment)
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
    assert_equal(runs, 5)
    assert_equal(len(only_seen), 2)
    assert_equal(only_seen[0], String("gamma gamma step:publish"))
    assert_equal(only_seen[1], String("validate gamma validation:install"))
    # the build job and the pr job, and only they, join the tailnet
    assert_equal(farm, 2)
    # the validate job: no environment, no identity token, after the publish
    var validate = doc.child(jobs, String("validate"))
    assert_true(validate >= 0, String("kci.yml has no job validate"))
    assert_true(doc.child(validate, String("environment")) < 0, String("the validate job runs in an environment"))
    var perms = doc.child(validate, String("permissions"))
    assert_true(doc.child(perms, String("id-token")) < 0, String("the validate job holds id-token"))
    var needs = doc.scalar_or_list(doc.child(validate, String("needs")))
    assert_equal(len(needs), 2)
    assert_equal(needs[1], String("gamma"))
    # prod waits for the validation
    var prod_needs = doc.scalar_or_list(doc.child(doc.child(jobs, String("prod")), String("needs")))
    assert_equal(len(prod_needs), 2)
    assert_equal(prod_needs[1], String("validate"))


def test_kci_yml_names_no_removed_input_and_no_other_channel() raises:
    var text = Path(String("kci.yml")).read_text()
    for gone in [String("ci check"), String("claim"), String("expect_set_hash"), String("approved_names"), String("rehearsal")]:
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
