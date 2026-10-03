# =============================================================================
# src/kci_ci_check/tests/test_repo_kci_yml.mojo -- the repository's own
#   release workflow, .github/workflows/kci.yml, held to its own machine file,
#   release/machine.textproto: `kci ci check` finds nothing. A drift between
#   the two (a renamed job or environment, a stage the workflow does not run,
#   a pull_request trigger, an unpinned action) fails this test, and with it
#   `./buck2 build //...` on every pull request.
# =============================================================================
#
# The three files are staged as test data (BUCK): `kci.yml` (the root BUCK
# exports it), `machine.textproto` and `channels.textproto` (release/BUCK).
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from kci_ci_check import ChannelsFile, channels_paths, check_workflow, id_token_stages
from kci_release_channel import find_channel, parse_channels_file, push_identity_environment
from kci_stage_graph import StageGraph, parse_machine_file


def _graph() raises -> StageGraph:
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
    var findings = check_workflow(Path(String("kci.yml")).read_text(), g, tokens)
    if len(findings) > 0:
        var all = String("")
        for i in range(len(findings)):
            all += String("\n  ") + findings[i]
        raise Error(String(".github/workflows/kci.yml disagrees with release/machine.textproto:") + all)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
