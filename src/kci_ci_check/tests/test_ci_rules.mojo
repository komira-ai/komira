# =============================================================================
# src/kci_ci_check/tests/test_ci_rules.mojo -- a workflow held to a machine
#   file: a fixture that agrees, then one mutation per rule (R1 to R8), each
#   of which must be reported; and the stages that need an identity token.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_ci_check import ChannelsFile, channels_paths, check_workflow, id_token_stages, kci_run_calls
from kci_stage_graph import parse_machine_file


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\"\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d.textproto\" }\n"
    "}\n"
    "stage { name: \"prod\" after: \"build\"\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"komira\" }\n"
    "}\n"
)

comptime _WF: String = (
    "name: kci\n"
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "  workflow_dispatch:\n"
    "    inputs:\n"
    "      revision:\n"
    "        type: string\n"
    "        default: \"\"\n"
    "permissions: {}\n"
    "jobs:\n"
    "  build:\n"
    "    runs-on: [self-hosted, komira-farm]\n"
    "    environment: build\n"
    "    permissions:\n"
    "      contents: read\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "      - name: check\n"
    "        run: $RUNNER_TEMP/kci/kci ci check --workflow kci.yml\n"
    "      - name: kci\n"
    "        run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage build \\\n"
    "            --run-id \"gh-$GITHUB_RUN_ID\"\n"
    "  prod:\n"
    "    needs: build\n"
    "    runs-on: ubuntu-24.04\n"
    "    environment: prod\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - name: kci\n"
    "        run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage prod --plan\n"
)


def _findings(wf: String) raises -> List[String]:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    var tokens = List[String]()
    tokens.append(String("prod"))
    return check_workflow(wf, g, tokens)


def _mutated(old: String, new: String) raises -> String:
    var s = String(_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _reports(wf: String, needle: String) raises:
    var f = _findings(wf)
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    var all = String("")
    for i in range(len(f)):
        all += f[i] + String(" | ")
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + all)


def test_the_fixture_agrees() raises:
    var f = _findings(String(_WF))
    if len(f) != 0:
        raise Error(String("unexpected finding: ") + f[0])


def test_r1_jobs_are_the_stages() raises:
    _reports(_mutated(String("  prod:\n"), String("  publish:\n")), String("R1: job 'publish' is no stage"))
    _reports(_mutated(String("  prod:\n"), String("  publish:\n")), String("R1: stage 'prod' has no job"))


def test_r2_environment_is_the_stage() raises:
    _reports(_mutated(String("    environment: prod\n"), String("    environment: production\n")), String("R2: runs in environment 'production'"))
    _reports(_mutated(String("    environment: build\n"), String("")), String("R2: runs in no environment"))


def test_r3_needs_is_after() raises:
    _reports(_mutated(String("    needs: build\n"), String("")), String("R3: needs nothing; the stage runs after build"))
    _reports(_mutated(String("    needs: build\n"), String("    needs: [build, other]\n")), String("R3: needs build, other"))


def test_r4_id_token_exactly_where_needed() raises:
    _reports(_mutated(String("      id-token: write\n"), String("")), String("R4: stage 'prod' publishes by OIDC"))
    _reports(
        _mutated(String("    permissions:\n      contents: read\n    steps:\n      - uses"), String("    permissions:\n      contents: read\n      id-token: write\n    steps:\n      - uses")),
        String("R4: has `id-token: write`, but stage 'build'"),
    )
    _reports(_mutated(String("permissions: {}\n"), String("permissions:\n  id-token: write\n")), String("R4: `id-token: write` at the workflow level"))


def test_r5_one_kci_run_of_its_own_stage() raises:
    _reports(_mutated(String("run --stage prod --plan"), String("run --stage build --plan")), String("R5: `kci run --stage build` in job 'prod'"))
    _reports(_mutated(String("run --stage prod --plan"), String("run --stage \"$STAGE\" --plan")), String("R5: `kci run --stage $STAGE` in job 'prod'"))
    _reports(_mutated(String("run --stage prod --plan"), String("--plan")), String("R5: invokes `kci run` 0 times"))
    _reports(
        _mutated(String("run --stage prod --plan\n"), String("run --stage prod --plan\n          kci run --stage prod\n")),
        String("R5: invokes `kci run` 2 times"),
    )


def test_r6_never_pull_request() raises:
    _reports(_mutated(String("  push:\n"), String("  pull_request:\n  push:\n")), String("R6: trigger 'pull_request'"))
    _reports(_mutated(String("  push:\n"), String("  pull_request_target:\n  push:\n")), String("R6: trigger 'pull_request_target'"))


def test_r7_revision_input() raises:
    _reports(_mutated(String("      revision:\n"), String("      commit:\n")), String("R7: workflow_dispatch takes no input `revision`"))


def test_r8_uses_pinned() raises:
    _reports(
        _mutated(String("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"), String("actions/checkout@v7")),
        String("R8: `uses: actions/checkout@v7` is not pinned"),
    )


def test_unreadable_is_cannot_tell() raises:
    try:
        _ = _findings(_mutated(String("    environment: prod\n"), String("    environment: &e prod\n")))
    except e:
        assert_true(String(e).startswith(String("cannot tell: ")))
        return
    raise Error(String("an anchor was read"))


def test_kci_run_calls() raises:
    var c = kci_run_calls(String("x=1\n/opt/kci/kci run --plan \\\n  --stage=prod\nkci ci check\nkci  run --stage 'build'\n"))
    assert_equal(len(c), 2)
    assert_equal(c[0].stage, String("prod"))
    assert_equal(c[1].stage, String("build"))


comptime _OIDC: String = (
    "schema_version: 1\n"
    "channel { name: \"komira\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira\" push_identity: \"repo:o/r:environment:prod\""
    " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
)
comptime _TOKEN: String = (
    "schema_version: 1\n"
    "channel { name: \"komira\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira\" push_identity: \"publisher\""
    " credential { kind: API_TOKEN secret_name: \"KOMIRA_TOKEN\" } } }\n"
)


def test_id_token_stages() raises:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    var paths = channels_paths(g)
    assert_equal(len(paths), 1)
    assert_equal(paths[0], String("c.textproto"))
    var files = List[ChannelsFile]()
    files.append(ChannelsFile(String("c.textproto"), String(_OIDC)))
    var s = id_token_stages(g, files)
    assert_equal(len(s), 1)
    assert_equal(s[0], String("prod"))
    var tfiles = List[ChannelsFile]()
    tfiles.append(ChannelsFile(String("c.textproto"), String(_TOKEN)))
    assert_equal(len(id_token_stages(g, tfiles)), 0)
    try:
        _ = id_token_stages(g, List[ChannelsFile]())
        raise Error(String("not refused"))
    except e:
        assert_true(String(e).find(String("was not given")) >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
