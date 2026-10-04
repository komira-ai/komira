# =============================================================================
# src/kci_ci_check/tests/test_repo_kci_yml.mojo -- the repository's own
#   release workflow, .github/workflows/kci.yml, held to its own machine file,
#   release/machine.textproto: `kci ci check` finds nothing. A drift between
#   the two (a renamed job or environment, a stage the workflow does not run,
#   a pull_request trigger, an unpinned action, a `kci run` with --only or
#   another machine file) fails this test, and with it `./buck2 build //...`
#   on every pull request. The workflow's KCI_MACHINE (used only to skip a
#   revision without a machine file) must be kci's default machine file,
#   because no `kci` line of the workflow passes --machine.
# =============================================================================
#
# The three files are staged as test data (BUCK): `kci.yml` (the root BUCK
# exports it), `machine.textproto` and `channels.textproto` (release/BUCK).
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from kci_ci_check import (
    NODE_SCALAR,
    ChannelsFile,
    channels_paths,
    check_workflow,
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
    assert_equal(len(names), 2)
    assert_equal(names[0], String("build"))
    assert_equal(names[1], String("prod"))
    var b = g.stage(String("build"))
    assert_equal(len(b.steps), 1)
    assert_true(b.steps[0].is_build())
    assert_equal(b.steps[0].platform, String("linux-x86_64"))
    assert_equal(b.steps[0].declarations, String("release/artifacts.textproto"))
    var p = g.stage(String("prod"))
    assert_equal(p.after, String("build"))
    assert_equal(len(p.steps), 1)
    assert_true(p.steps[0].is_publish())
    assert_equal(p.steps[0].channels, String("release/channels.textproto"))
    assert_equal(p.steps[0].channel, String("komira"))
    # The publish stage IS the environment the channel's trusted publisher
    # names: kci refuses a trusted publish from any other stage.
    var paths = channels_paths(g)
    assert_equal(len(paths), 1)
    assert_equal(paths[0], String("release/channels.textproto"))
    var ch = find_channel(parse_channels_file(Path(String("channels.textproto")).read_text()), String("komira"))
    assert_equal(push_identity_environment(ch.repositories[0]), String("prod"))


def test_kci_yml_agrees_with_the_machine_file() raises:
    var g = _graph()
    var tokens = id_token_stages(g, _channels())
    assert_equal(len(tokens), 1)
    assert_equal(tokens[0], String("prod"))
    # the machine file checked is kci's default: every `kci run` reads it (R10)
    var findings = check_workflow(Path(String("kci.yml")).read_text(), g, tokens, String(DEFAULT_MACHINE_FILE))
    if len(findings) > 0:
        var all = String("")
        for i in range(len(findings)):
            all += String("\n  ") + findings[i]
        raise Error(String(".github/workflows/kci.yml disagrees with release/machine.textproto:") + all)


def test_kci_yml_runs_full_stages_from_the_default_machine_file() raises:
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var env = doc.child(0, String("env"))
    var m = doc.child(env, String("KCI_MACHINE"))
    assert_true(m >= 0 and doc.kind(m) == NODE_SCALAR, String("kci.yml sets no env KCI_MACHINE"))
    assert_equal(doc.text(m), String(DEFAULT_MACHINE_FILE))
    # every `kci run` of every job: no --only (a FULL run, R9), no --machine
    # (the default, R10)
    var jobs = doc.child(0, String("jobs"))
    var nodes = doc.items(jobs)
    var runs = 0
    for j in range(len(nodes)):
        var steps = doc.items(doc.child(nodes[j], String("steps")))
        for i in range(len(steps)):
            var r = doc.child(steps[i], String("run"))
            if r < 0 or doc.kind(r) != NODE_SCALAR:
                continue
            var calls = kci_run_calls(doc.text(r))
            for k in range(len(calls)):
                runs += 1
                assert_true(not calls[k].has_only, String("a kci run in kci.yml carries --only"))
                assert_true(not calls[k].has_machine, String("a kci run in kci.yml passes --machine"))
    assert_equal(runs, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
