# =============================================================================
# src/kci_workflow_check/tests/test_repo_kci_yml.mojo -- the repository's own
#   release workflow, .github/workflows/kci.yml, held to the machine file,
#   release/machine.textproto, by the same check `kci run` makes at start-up
#   (`check_running_workflow`): it finds nothing. (pr.yml, the pull request's
#   check, runs Buck2 targets and no longer runs kci, so it is not held to the
#   machine file.) A drift (a renamed job or environment, a stage the workflow
#   does not run, a `pull_request` trigger in kci.yml, an unpinned
#   action, a `kci run` without --summary-file or reading another machine
#   file, farm-connect on the wrong job) fails this test, and with it
#   `./buck2 build //...` on every pull request. The workflow's KCI_MACHINE
#   (used only to skip a revision without a machine file) must be kci's
#   default machine file, because no `kci` line of the workflow passes
#   --machine.
#
#   komira publishes to no channel for now: the machine file has the build
#   stage alone, no stage publishes, and the workflow names no channel and no
#   publishing token. The rules that guard a publishing job (R15 to R22) are
#   tested against a fixture pair in test_ci_auto_promotion.mojo.
# =============================================================================
#
# Test data (BUCK): `kci.yml` (the root BUCK), `machine.textproto`
# (release/BUCK) and `release_version.sh` (the script whose documentation
# filter the push trigger must share).
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_workflow_check import (
    FARM_CONNECT_ACTION,
    NODE_SCALAR,
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
from kci_release_machine import ReleaseMachine, parse_machine_file


def _graph() raises -> ReleaseMachine:
    return parse_machine_file(Path(String("machine.textproto")).read_text(), String("release/machine.textproto"))


def _no_channels() -> List[ChannelsFile]:
    """The machine file names no channels file: no stage publishes."""
    return List[ChannelsFile]()


def test_the_release_machine_is_one_build_stage_and_publishes_nowhere() raises:
    var g = _graph()
    var names = g.stage_names()
    assert_equal(len(names), 1)
    assert_equal(names[0], String("build"))
    # the pull request's check is no stage: pr.yml runs buck2, not kci
    assert_false(g.stage(String("build")).is_pull_request())
    # a manual run (of a branch or of main) reaches build, which is break-glass
    assert_true(g.stage(String("build")).break_glass)
    var b = g.stage(String("build"))
    assert_equal(b.environment, String("build"))
    assert_true(b.farm_connected)
    assert_equal(len(b.steps), 1)
    assert_true(b.steps[0].is_build())
    assert_equal(b.steps[0].platform, String("linux-x86_64"))
    assert_equal(b.steps[0].artifacts, String("release/artifacts.textproto"))
    assert_equal(len(b.steps[0].validations), 0)
    # no step of any stage publishes, so no channels file is named
    for i in range(len(g.stages)):
        for k in range(len(g.stages[i].steps)):
            assert_false(g.stages[i].steps[k].is_publish(), g.stages[i].name)
    assert_equal(len(channels_paths(g)), 0)


def test_kci_yml_agrees_with_the_machine_file() raises:
    var g = _graph()
    # no stage publishes by OIDC trusted publishing: no job holds a publishing token
    assert_equal(len(id_token_stages(g, _no_channels())), 0)
    # the machine file checked is kci's default: every `kci run` reads it (R10);
    # the same entry point `kci run` calls at start-up
    var findings = check_running_workflow(g, _no_channels(), Path(String("kci.yml")).read_text(), String(DEFAULT_MACHINE_FILE))
    if len(findings) > 0:
        var all = String("")
        for i in range(len(findings)):
            all += String("\n  ") + findings[i]
        raise Error(String(".github/workflows/kci.yml disagrees with release/machine.textproto:") + all)


def test_the_release_workflow_is_refused_when_read_as_the_pull_requests() raises:
    var g = _graph()
    var tokens = id_token_stages(g, _no_channels())
    var kci_as_pr = check_workflow(Path(String("kci.yml")).read_text(), g, tokens, String(DEFAULT_MACHINE_FILE), True)
    assert_true(len(kci_as_pr) > 0, String("kci.yml read as the pull request's workflow is not refused"))
    # the real kci.yml has no pull_request trigger
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var triggers = doc.keys(doc.child(0, String("on")))
    for i in range(len(triggers)):
        assert_true(triggers[i] != String("pull_request"), String("kci.yml has a pull_request trigger"))


def test_kci_yml_has_one_job_one_kci_run_and_reads_the_default_machine_file() raises:
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var env = doc.child(0, String("env"))
    var m = doc.child(env, String("KCI_MACHINE"))
    assert_true(m >= 0 and doc.kind(m) == NODE_SCALAR, String("kci.yml sets no env KCI_MACHINE"))
    assert_equal(doc.text(m), String(DEFAULT_MACHINE_FILE))
    # every `kci run`: no --machine (the default, R10), a --summary-file (R12),
    # no --only (R9: the one stage is not split)
    var jobs = doc.child(0, String("jobs"))
    var ids = doc.keys(jobs)
    assert_equal(len(ids), 1)
    assert_equal(ids[0], String("build"))
    var nodes = doc.items(jobs)
    var runs = 0
    var farm = 0
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
                assert_equal(len(calls[k].only), 0)
                assert_true(not calls[k].has_machine, String("a kci run in kci.yml passes --machine"))
                assert_true(calls[k].has_summary_file, String("a kci run in kci.yml passes no --summary-file"))
    assert_equal(runs, 1)
    # the build job, and only it, joins the tailnet (pr.yml's check, which runs no kci, joins it too)
    assert_equal(farm, 1)


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


def test_kci_yml_hands_the_set_hash_out_of_build() raises:
    # build's set hash is read from its own kci result (R19)
    var doc = read_workflow(Path(String("kci.yml")).read_text())
    var jobs = doc.child(0, String("jobs"))
    var b = doc.child(doc.child(doc.child(jobs, String("build")), String("outputs")), String("set_hash"))
    assert_equal(doc.text(b), String("${{ steps.set_hash.outputs.set_hash }}"))


def test_kci_yml_names_no_removed_input_no_channel_and_no_publishing_token() raises:
    var text = Path(String("kci.yml")).read_text()
    for gone in [
        String("ci check"), String("claim"), String("expect_set_hash"), String("approved_names"), String("rehearsal"),
        String("publish_prod"), String("prefix.dev"), String("beta_validate"), String("--only"),
    ]:
        assert_true(text.find(gone) < 0, String("kci.yml still names '") + gone + String("'"))
    # the only `komira-ai/` path kci.yml names is this repository: it names no channel
    var at = text.find(String("komira-ai/"))
    while at >= 0:
        var end = at + String("komira-ai/").byte_length()
        var b = text.as_bytes()
        while end < len(b) and ((b[end] >= 97 and b[end] <= 122) or (b[end] >= 48 and b[end] <= 57) or b[end] == 45 or b[end] == 95):
            end += 1
        assert_equal(String(text[byte = at:end]), String("komira-ai/komira"), String("kci.yml names a path other than this repository"))
        at = text.find(String("komira-ai/"), end)
    # `id-token: write` is the farm connection's alone: exactly one job holds it, and it is build
    var doc = read_workflow(text)
    var jobs = doc.child(0, String("jobs"))
    var held = 0
    var job_ids = doc.keys(jobs)
    var job_nodes = doc.items(jobs)
    for j in range(len(job_nodes)):
        var perms = doc.child(job_nodes[j], String("permissions"))
        if perms >= 0 and doc.child(perms, String("id-token")) >= 0:
            held += 1
            assert_equal(job_ids[j], String("build"))
    assert_equal(held, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
