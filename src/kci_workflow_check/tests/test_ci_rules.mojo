# =============================================================================
# src/kci_workflow_check/tests/test_ci_rules.mojo -- a workflow held to a machine
#   file: a fixture that agrees, then one mutation per rule (R1 to R12, R14), each
#   of which must be reported; the stages that publish by OIDC; and the
#   start-up entry point `kci run` calls.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_workflow_check import (
    ChannelsFile,
    channels_paths,
    check_running_workflow,
    check_workflow,
    documentation_filter_findings,
    id_token_stages,
    kci_run_calls,
    read_workflow,
)
from kci_release_machine import parse_machine_file


comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\" farm_connected: true break_glass: true\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
    "stage { name: \"publish-gamma\" environment: \"gamma\" after: \"build\" break_glass: true\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"gamma\" }\n"
    "}\n"
    "stage { name: \"publish-prod\" environment: \"prod\" after: \"publish-gamma\" break_glass: true\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"prod\" }\n"
    "}\n"
)

comptime _ON: String = (
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "    paths-ignore:\n"
    "      - 'docs/**'\n"
    "      - '**.md'\n"
    "  workflow_dispatch:\n"
    "    inputs:\n"
    "      revision:\n"
    "        type: string\n"
    "        default: \"\"\n"
    "      reason:\n"
    "        type: string\n"
    "        required: true\n"
    "      dry_run:\n"
    "        type: boolean\n"
    "        default: false\n"
)

comptime _PROD_LINE: String = "      - name: the prod line\n        if: always()\n        run: echo prod line\n"

# Every stage is break_glass here, so no job carries R15's main conjunct
# (test_ci_auto_promotion holds R15 on the repository's own files).
comptime _WF: String = (
    "name: kci\n"
    + _ON
    + "permissions: {}\n"
    "concurrency:\n"
    "  group: kci-${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'release-main' || inputs.dry_run && format('plan-{0}', github.run_id) || format('ref-{0}', github.ref_name) }}\n"
    "  cancel-in-progress: false\n"
    "env:\n"
    "  DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}\n"
    "jobs:\n"
    "  build:\n"
    "    runs-on: ubuntu-24.04\n"
    "    environment: build\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
    "    outputs:\n"
    "      set_hash: ${{ steps.kci.outputs.set_hash }}\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          ref: ${{ env.REVISION }}\n"
    "      - name: the revision this run releases\n"
    "        run: |\n"
    "          case \"$REVISION\" in\n"
    "            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n"
    "          esac\n"
    "          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n"
    "          if [ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ] && [ \"$DRY_RUN\" = true ]; then\n"
    "            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n"
    "              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n"
    "          else\n"
    "            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n"
    "              { echo \"refused: a run that can publish releases the commit it started on ($GITHUB_SHA), not $REVISION (a revision input is for a dry run)\"; exit 1; }\n"
    "          fi\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "      - name: farm\n"
    "        uses: ./.github/actions/farm-connect\n"
    "        with:\n"
    "          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"
    "      - name: kci\n"
    "        run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage build \\\n"
    "            --summary-file \"$GITHUB_STEP_SUMMARY\" \\\n"
    "            --run-id \"gh-$GITHUB_RUN_ID\"\n"
    + _PROD_LINE
    + "  publish-gamma:\n"
    "    needs: build\n"
    "    runs-on: ubuntu-24.04\n"
    "    environment: gamma\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
    "    outputs:\n"
    "      set_hash: ${{ steps.kci.outputs.set_hash }}\n"
    "    env:\n"
    "      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          ref: ${{ env.REVISION }}\n"
    "      - name: the revision this run releases\n"
    "        run: |\n"
    "          case \"$REVISION\" in\n"
    "            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n"
    "          esac\n"
    "          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n"
    "          if [ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ] && [ \"$DRY_RUN\" = true ]; then\n"
    "            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n"
    "              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n"
    "          else\n"
    "            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n"
    "              { echo \"refused: a run that can publish releases the commit it started on ($GITHUB_SHA), not $REVISION (a revision input is for a dry run)\"; exit 1; }\n"
    "          fi\n"
    "      - name: kci\n"
    "        run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage publish-gamma \"$@\" --summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"
    + _PROD_LINE
    + "  publish-prod:\n"
    "    needs: publish-gamma\n"
    "    runs-on: ubuntu-24.04\n"
    "    environment: prod\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
    "    env:\n"
    "      RELEASE_SET_HASH: ${{ needs.publish-gamma.outputs.set_hash }}\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          ref: ${{ env.REVISION }}\n"
    "      - name: the revision this run releases\n"
    "        run: |\n"
    "          case \"$REVISION\" in\n"
    "            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n"
    "          esac\n"
    "          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n"
    "          if [ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ] && [ \"$DRY_RUN\" = true ]; then\n"
    "            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n"
    "              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n"
    "          else\n"
    "            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n"
    "              { echo \"refused: a run that can publish releases the commit it started on ($GITHUB_SHA), not $REVISION (a revision input is for a dry run)\"; exit 1; }\n"
    "          fi\n"
    "      - name: kci\n"
    "        run: |\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage publish-prod \"$@\" --summary-file=\"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"
    + _PROD_LINE
)


def _token_stages() -> List[String]:
    var tokens = List[String]()
    tokens.append(String("publish-gamma"))
    tokens.append(String("publish-prod"))
    return tokens^


def _findings_for(wf: String, machine_path: String) raises -> List[String]:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    return check_workflow(wf, g, _token_stages(), machine_path)


def _findings(wf: String) raises -> List[String]:
    return _findings_for(wf, String("release/machine.textproto"))


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
    _reports(_mutated(String("  publish-prod:\n"), String("  prod:\n")), String("R1: job 'prod' is no stage"))
    _reports(_mutated(String("  publish-prod:\n"), String("  prod:\n")), String("R1: stage 'publish-prod' has no job"))


def test_r2_environment_is_the_stages_environment() raises:
    _reports(
        _mutated(String("    environment: prod\n"), String("    environment: production\n")),
        String("job 'publish-prod': R2: runs in environment 'production'; it must run in 'prod' (the stage's environment)"),
    )
    # the job id is not the environment: a stage with `environment` set runs there
    _reports(
        _mutated(String("    environment: gamma\n"), String("    environment: publish-gamma\n")),
        String("job 'publish-gamma': R2: runs in environment 'publish-gamma'; it must run in 'gamma'"),
    )
    # a stage without `environment` runs in the environment of its name
    _reports(_mutated(String("    environment: build\n"), String("")), String("R2: runs in no environment; it must run in `environment: build`"))


def test_r3_needs_is_after() raises:
    _reports(_mutated(String("    needs: build\n"), String("")), String("R3: needs nothing; the stage runs after build"))
    _reports(_mutated(String("    needs: build\n"), String("    needs: [build, other]\n")), String("R3: needs build, other"))


def test_r4_id_token_exactly_where_needed() raises:
    # a publishing stage without it
    _reports(
        _mutated(String("    environment: prod\n    permissions:\n      contents: read\n      id-token: write\n"), String("    environment: prod\n    permissions:\n      contents: read\n")),
        String("job 'publish-prod': R4: stage 'publish-prod' publishes by OIDC trusted publishing, so the job needs"),
    )
    # the farm-connected stage without it
    _reports(
        _mutated(String("    environment: build\n    permissions:\n      contents: read\n      id-token: write\n"), String("    environment: build\n    permissions:\n      contents: read\n")),
        String("job 'build': R4: stage 'build' is farm-connected, so the job needs `id-token: write`"),
    )
    _reports(_mutated(String("permissions: {}\n"), String("permissions:\n  id-token: write\n")), String("R4: `id-token: write` at the workflow level"))


def test_r4_permissions_write_all_is_refused() raises:
    # job level, on a stage that needs the token: write-all grants it and every other permission
    _reports(
        _mutated(String("    environment: build\n    permissions:\n      contents: read\n      id-token: write\n"), String("    environment: build\n    permissions: write-all\n")),
        String("job 'build': R4: `permissions: write-all` grants permissions no map names"),
    )
    # workflow level: it reaches every job, the identity token among it
    var wf = _mutated(String("permissions: {}\n"), String("permissions: write-all\n"))
    _reports(wf, String("workflow: R4: `permissions: write-all` grants permissions no map names"))
    _reports(wf, String("R4: `id-token: write` at the workflow level reaches every job"))
    # read-all is the one scalar accepted
    assert_equal(len(_findings(_mutated(String("permissions: {}\n"), String("permissions: read-all\n")))), 0)


def test_r4_no_token_on_a_stage_that_neither_publishes_nor_connects() raises:
    # build is not farm-connected here, and it publishes nothing: its token goes
    var machine = String(_MACHINE).replace(String(" farm_connected: true"), String(""))
    var g = parse_machine_file(machine, String("machine file"))
    var wf = _mutated(String("      - name: farm\n        uses: ./.github/actions/farm-connect\n        with:\n          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String(""))
    var f = check_workflow(wf, g, _token_stages(), String("release/machine.textproto"))
    assert_equal(len(f), 1)
    assert_true(
        f[0].find(String("job 'build': R4: has `id-token: write`, but stage 'build' publishes to no OIDC channel and is not farm-connected; remove it")) >= 0
    )


def test_r5_one_kci_run_of_its_own_stage() raises:
    _reports(_mutated(String("run --stage publish-prod \"$@\""), String("run --stage build --plan")), String("R5: `kci run --stage build` in job 'publish-prod'"))
    _reports(_mutated(String("run --stage publish-prod \"$@\""), String("run --stage \"$STAGE\" --plan")), String("R5: `kci run --stage $STAGE` in job 'publish-prod'"))
    _reports(_mutated(String("\"$RUNNER_TEMP/kci/kci\" run --stage publish-prod \"$@\""), String("echo --plan")), String("R5: invokes `kci run` 0 times"))
    _reports(
        _mutated(String("run --stage publish-prod \"$@\" --summary-file=\"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"), String("run --stage publish-prod \"$@\" --summary-file=\"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n          kci run --stage publish-prod --summary-file x\n")),
        String("R5: invokes `kci run` 2 times"),
    )


def test_r6_never_pull_request() raises:
    _reports(_mutated(String("  push:\n"), String("  pull_request:\n  push:\n")), String("R6: trigger 'pull_request'"))
    _reports(_mutated(String("  push:\n"), String("  pull_request_target:\n  push:\n")), String("R6: trigger 'pull_request_target'"))


def _other_triggers() -> List[String]:
    """Events other than push and workflow_dispatch: each can
    run code a pull request carries (a review or a comment on it, a
    merge-queue candidate, a calling workflow's event), or is simply not on
    the allow-list (schedule)."""
    var t = List[String]()
    t.append(String("pull_request_review"))
    t.append(String("pull_request_review_comment"))
    t.append(String("issue_comment"))
    t.append(String("workflow_run"))
    t.append(String("merge_group"))
    t.append(String("workflow_call"))
    t.append(String("schedule"))
    return t^


def test_r6_triggers_are_an_allow_list() raises:
    var others = _other_triggers()
    for i in range(len(others)):
        var name = others[i].copy()
        _reports(
            _mutated(String("  push:\n"), String("  ") + name + String(":\n  push:\n")),
            String("R6: trigger '") + name + String("': the release workflow's triggers are push and workflow_dispatch only"),
        )
    # the list form of `on:`
    _reports(
        _mutated(
            String(_ON),
            String("on: [push, workflow_dispatch, merge_group]\n"),
        ),
        String("R6: trigger 'merge_group': the release workflow's triggers are push and workflow_dispatch only"),
    )


def test_r7_revision_input() raises:
    _reports(_mutated(String("      revision:\n"), String("      commit:\n")), String("R7: workflow_dispatch takes no input `revision`"))


def test_r8_uses_pinned() raises:
    _reports(
        _mutated(String("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"), String("actions/checkout@v7")),
        String("R8: `uses: actions/checkout@v7` is not pinned"),
    )
    # the farm-connect action is the one local action allowed; any other is not
    _reports(
        _mutated(String("uses: ./.github/actions/farm-connect\n"), String("uses: ./.github/actions/other\n")),
        String("R8: `uses: ./.github/actions/other` is not pinned"),
    )
    _reports(
        _mutated(String("uses: ./.github/actions/farm-connect\n"), String("uses: ./.github/actions/farm-connect@main\n")),
        String("R8: `uses: ./.github/actions/farm-connect@main` is not pinned"),
    )


def test_r11_farm_connect_exactly_on_farm_connected_stages() raises:
    _reports(
        _mutated(String("      - name: farm\n        uses: ./.github/actions/farm-connect\n        with:\n          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String("")),
        String("job 'build': R11: stage 'build' is farm-connected, so the job needs a step `uses: ./.github/actions/farm-connect`"),
    )
    _reports(
        _mutated(
            String("      RELEASE_SET_HASH: ${{ needs.publish-gamma.outputs.set_hash }}\n    steps:\n"),
            String("      RELEASE_SET_HASH: ${{ needs.publish-gamma.outputs.set_hash }}\n    steps:\n      - uses: ./.github/actions/farm-connect\n"),
        ),
        String("job 'publish-prod': R11: uses ./.github/actions/farm-connect, but stage 'publish-prod' is not farm-connected"),
    )


def test_r12_every_kci_run_writes_the_summary() raises:
    _reports(
        _mutated(String(" --summary-file=\"$GITHUB_STEP_SUMMARY\" "), String(" ")),
        String("job 'publish-prod': R12: `kci run` passes no --summary-file"),
    )
    _reports(
        _mutated(String("            --summary-file \"$GITHUB_STEP_SUMMARY\" \\\n"), String("")),
        String("job 'build': R12: `kci run` passes no --summary-file"),
    )


def test_r14_never_a_local_channel() raises:
    _reports(
        _mutated(String("run --stage build \\\n"), String("run --stage build --channel file:///srv/c \\\n")),
        String("job 'build': R14: `kci run` passes --channel"),
    )
    _reports(
        _mutated(String("run --stage publish-prod \"$@\""), String("run --stage publish-prod \"$@\" --channel=file:///srv/c")),
        String("job 'publish-prod': R14: `kci run` passes --channel"),
    )
    _none_with(String(_WF), String("release/machine.textproto"), String("R14"))


def test_r9_never_selective() raises:
    _reports(
        _mutated(String("run --stage build \\\n"), String("run --stage build --only step:build \\\n")),
        String("job 'build': R9: `kci run` carries --only"),
    )
    _reports(
        _mutated(String("run --stage publish-prod \"$@\""), String("run --stage publish-prod \"$@\" --only=step:publish")),
        String("job 'publish-prod': R9: `kci run` carries --only"),
    )


def _none_with(wf: String, machine_path: String, needle: String) raises:
    var f = _findings_for(wf, machine_path)
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            raise Error(String("unexpected finding: ") + f[i])


def test_r10_reads_the_machine_file_checked() raises:
    # another file named in the job
    _reports(
        _mutated(String("run --stage publish-prod \"$@\""), String("run --stage publish-prod \"$@\" --machine other.textproto")),
        String("job 'publish-prod': R10: `kci run --machine other.textproto` reads another machine file than the one checked (release/machine.textproto)"),
    )
    # a variable is not the file checked either
    _reports(
        _mutated(String("run --stage publish-prod \"$@\""), String("run --stage publish-prod \"$@\" --machine=$KCI_MACHINE")),
        String("R10: `kci run --machine $KCI_MACHINE`"),
    )
    # the checked file named explicitly, with or without ./, agrees
    _none_with(
        _mutated(String("run --stage publish-prod \"$@\""), String("run --stage publish-prod \"$@\" --machine release/machine.textproto")),
        String("release/machine.textproto"),
        String("R10"),
    )
    _none_with(
        _mutated(String("run --stage publish-prod \"$@\""), String("run --stage publish-prod \"$@\" --machine=./release/machine.textproto")),
        String("release/machine.textproto"),
        String("R10"),
    )
    # no --machine reads the default: fine when the default is the file
    # checked, a disagreement when another file is checked
    _none_with(String(_WF), String("./release/machine.textproto"), String("R10"))
    var f = _findings_for(String(_WF), String("ops/machine.textproto"))
    var hits = 0
    for i in range(len(f)):
        if f[i].find(String("R10: `kci run` gives no --machine, so it reads the default release/machine.textproto, not the machine file checked (ops/machine.textproto)")) >= 0:
            hits += 1
    assert_equal(hits, 3)


def test_unreadable_is_cannot_tell() raises:
    try:
        _ = _findings(_mutated(String("    environment: prod\n"), String("    environment: &e prod\n")))
    except e:
        assert_true(String(e).startswith(String("cannot tell: ")))
        return
    raise Error(String("an anchor was read"))


def test_kci_run_calls() raises:
    var c = kci_run_calls(String("x=1\n/opt/kci/kci run --plan \\\n  --stage=prod\nkci --help\nkci  run --stage 'build'\n"))
    assert_equal(len(c), 2)
    assert_equal(c[0].stage, String("prod"))
    assert_equal(c[1].stage, String("build"))
    # Only a word in command position is an invocation: text that mentions
    # `kci run` is not one.
    var said = kci_run_calls(String("echo \"DRY RUN: kci run --stage prod --plan\"\nprintf '%s' kci run\n"))
    assert_equal(len(said), 0)
    var chained = kci_run_calls(String("cd x && kci run --stage a; kci run --stage b\nif true; then kci run --stage c; fi\n"))
    assert_equal(len(chained), 3)
    assert_equal(chained[0].stage, String("a"))
    assert_equal(chained[1].stage, String("b"))
    assert_equal(chained[2].stage, String("c"))
    # --machine and --only are read up to the end of the invocation only
    var m = kci_run_calls(
        String("kci run --stage a --machine m.textproto --only step:x; kci run --stage b\nkci run --stage=c --machine=n\n")
    )
    assert_equal(len(m), 3)
    assert_true(m[0].has_machine)
    assert_equal(m[0].machine, String("m.textproto"))
    assert_true(m[0].has_only)
    assert_false(m[1].has_machine)
    assert_false(m[1].has_only)
    assert_equal(m[1].stage, String("b"))
    assert_equal(m[2].stage, String("c"))
    assert_equal(m[2].machine, String("n"))
    # --summary-file, either spelling, up to the end of the invocation only
    var sf = kci_run_calls(String("kci run --stage a --summary-file x; kci run --stage b\nkci run --stage c --summary-file=y\n"))
    assert_true(sf[0].has_summary_file)
    assert_false(sf[1].has_summary_file)
    assert_true(sf[2].has_summary_file)
    # --channel, either spelling; every argument after `run` kept as written
    var ch = kci_run_calls(String("kci run --stage a --channel file:///c; kci run --stage b --channel=x\nkci run --stage c 'q' \"d e\"\n"))
    assert_true(ch[0].has_channel)
    assert_true(ch[1].has_channel)
    assert_false(ch[2].has_channel)
    assert_equal(len(ch[0].args), 4)
    assert_equal(ch[0].args[3], String("file:///c"))
    assert_equal(ch[1].args[2], String("--channel=x"))
    assert_equal(ch[2].args[2], String("q"))


comptime _OIDC: String = (
    "schema_version: 1\n"
    "channel { name: \"gamma\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/gamma\" push_identity: \"repo:komira-ai/komira:environment:gamma\""
    " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
    "channel { name: \"prod\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/prod\" push_identity: \"repo:komira-ai/komira:environment:prod\""
    " credential { kind: OIDC_TRUSTED_PUBLISHING } } }\n"
)
comptime _TOKEN: String = (
    "schema_version: 1\n"
    "channel { name: \"gamma\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/gamma\" push_identity: \"publisher\""
    " credential { kind: API_TOKEN secret_name: \"KOMIRA_TOKEN\" } } }\n"
    "channel { name: \"prod\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/prod\" push_identity: \"publisher\""
    " credential { kind: API_TOKEN secret_name: \"KOMIRA_TOKEN\" } } }\n"
)


def _oidc_files() -> List[ChannelsFile]:
    var files = List[ChannelsFile]()
    files.append(ChannelsFile(String("c.textproto"), String(_OIDC)))
    return files^


def test_id_token_stages() raises:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    var paths = channels_paths(g)
    assert_equal(len(paths), 1)
    assert_equal(paths[0], String("c.textproto"))
    # the publishing stages only: farm-connected build is R4's own case
    var s = id_token_stages(g, _oidc_files())
    assert_equal(len(s), 2)
    assert_equal(s[0], String("publish-gamma"))
    assert_equal(s[1], String("publish-prod"))
    var tfiles = List[ChannelsFile]()
    tfiles.append(ChannelsFile(String("c.textproto"), String(_TOKEN)))
    assert_equal(len(id_token_stages(g, tfiles)), 0)
    try:
        _ = id_token_stages(g, List[ChannelsFile]())
        raise Error(String("not refused"))
    except e:
        assert_true(String(e).find(String("was not given")) >= 0)


def test_check_running_workflow() raises:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    var path = String("release/machine.textproto")
    # agrees: no finding
    assert_equal(len(check_running_workflow(g, _oidc_files(), String(_WF), path)), 0)
    # drift is reported, every finding
    var f = check_running_workflow(g, _oidc_files(), _mutated(String("  publish-prod:\n"), String("  prod:\n")), path)
    assert_true(len(f) >= 2)
    # the token stages come from the channels files: with token-credential
    # channels, a publish job's id-token is a finding
    var tfiles = List[ChannelsFile]()
    tfiles.append(ChannelsFile(String("c.textproto"), String(_TOKEN)))
    var t = check_running_workflow(g, tfiles, String(_WF), path)
    assert_equal(len(t), 2)
    assert_true(t[0].find(String("R4: has `id-token: write`, but stage 'publish-gamma'")) >= 0)
    # a channels file not given, or an unreadable workflow, raises: never a pass
    try:
        _ = check_running_workflow(g, List[ChannelsFile](), String(_WF), path)
        raise Error(String("not refused"))
    except e:
        assert_true(String(e).find(String("was not given")) >= 0)
    try:
        _ = check_running_workflow(
            g, _oidc_files(), _mutated(String("    environment: prod\n"), String("    environment: &e prod\n")), path
        )
        raise Error(String("not refused"))
    except e:
        assert_true(String(e).startswith(String("cannot tell: ")))


# ---- edges: what is missing, the less common spellings -------------------------


def _all(f: List[String]) -> String:
    var s = String("")
    for i in range(len(f)):
        s += f[i] + String(" | ")
    return s^


def _none_in(f: List[String], needle: String) raises:
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            raise Error(String("unexpected finding: ") + f[i])


def _one_in(f: List[String], needle: String) raises:
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + _all(f))


def test_no_on_and_no_jobs() raises:
    _reports(_mutated(String(_ON), String("")), String("R6: the workflow has no `on:` triggers"))
    var no_jobs = String(_WF)[byte = 0 : String(_WF).find(String("jobs:\n"))]
    _reports(String(no_jobs), String("R1: the workflow has no `jobs:` mapping"))


def test_r8_a_40_byte_id_that_is_not_lowercase_hex() raises:
    _reports(
        _mutated(String("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"), String("actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1")),
        String("R8: `uses: actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1` is not pinned"),
    )


def test_r2_an_environment_mapping_is_read_by_its_name() raises:
    var ok = _findings(_mutated(String("    environment: prod\n"), String("    environment:\n      name: prod\n      url: https://example.invalid\n")))
    assert_equal(len(ok), 0, _all(ok))
    _reports(
        _mutated(String("    environment: prod\n"), String("    environment:\n      name: production\n")),
        String("job 'publish-prod': R2: runs in environment 'production'; it must run in 'prod'"),
    )


def test_r3_a_first_stage_needs_nothing() raises:
    _reports(
        _mutated(String("    environment: build\n"), String("    needs: publish-gamma\n    environment: build\n")),
        String("job 'build': R3: needs publish-gamma; the stage runs after nothing"),
    )


def test_r5_a_kci_run_without_stage() raises:
    _reports(_mutated(String("run --stage publish-prod \"$@\""), String("run \"$@\"")), String("R5: `kci run --stage (none)` in job 'publish-prod'"))


def test_r18_dispatch_input_types() raises:
    _reports(
        _mutated(String("      revision:\n        type: string\n"), String("      revision:\n        type: number\n")),
        String("R18: workflow_dispatch's inputs: `revision` is `type: string`"),
    )
    _reports(
        _mutated(String("      reason:\n        type: string\n"), String("      reason:\n        type: number\n")),
        String("R18: workflow_dispatch's inputs: `reason` is `type: string`"),
    )
    _reports(
        _mutated(String("        type: boolean\n"), String("        type: string\n")),
        String("R18: workflow_dispatch's inputs: `dry_run` is `type: boolean`"),
    )


def test_r18_an_unclosed_expression_runs_to_the_end_of_the_script() raises:
    _reports(
        _mutated(String("--run-id \"gh-$GITHUB_RUN_ID\"\n"), String("--run-id \"gh-${{ github.run_id\"\n")),
        String("job 'build': R18: a `run:` script holds `${{ github.run_id\"\n`"),
    )


def test_r21_the_first_step_is_a_plain_revision_checkout() raises:
    # a first step that is no mapping
    _reports(
        _mutated(String("    steps:\n      - uses: actions/checkout@"), String("    steps:\n      - echo\n      - uses: actions/checkout@")),
        String("job 'build': R21: its first step is `actions/checkout`"),
    )
    # a revision checkout with an `if:`
    _reports(
        _mutated(
            String("      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n"),
            String("      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        if: always()\n        with:\n"),
        ),
        String("job 'publish-prod': R21: its first step is `actions/checkout`"),
    )


def test_r19_a_publish_stage_after_nothing_takes_no_set_hash() raises:
    # publish-gamma runs after no stage: nothing hands it a set hash
    var machine = String(_MACHINE).replace(String(" after: \"build\""), String(""))
    var g = parse_machine_file(machine, String("machine file"))
    var f = check_workflow(String(_WF), g, _token_stages(), String("release/machine.textproto"))
    _none_in(f, String("job 'publish-gamma': R19"))
    _one_in(f, String("job 'publish-gamma': R3: needs build; the stage runs after nothing"))


def test_r19_a_stage_after_no_stage_takes_no_set_hash() raises:
    # parse_machine_file refuses an `after` naming no stage above; a graph
    # built or edited in code is held without one
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    g.stages[2].after = String("ghost")
    var f = check_workflow(String(_WF), g, _token_stages(), String("release/machine.textproto"))
    _none_in(f, String("R19"))
    _one_in(f, String("job 'publish-prod': R3: needs publish-gamma; the stage runs after ghost"))


def test_r19_the_source_jobs_output_is_r1s_when_the_job_is_gone() raises:
    var f = _findings(_mutated(String("  publish-gamma:\n"), String("  gamma:\n")))
    _none_in(f, String("R19: a later job takes the release set's hash from"))
    _one_in(f, String("R1: stage 'publish-gamma' has no job"))


def test_r17_the_documentation_filter() raises:
    var doc = read_workflow(String(_WF))
    var same = String("git log -- . ':(exclude)docs' ':(exclude)*.md' ':(exclude).github'\n")
    assert_equal(len(documentation_filter_findings(same, doc)), 0)
    # .github is no longer excluded
    var f = documentation_filter_findings(String("git log -- . ':(exclude)docs' ':(exclude)*.md'\n"), doc)
    assert_equal(len(f), 1, _all(f))
    assert_equal(f[0], String("R17: release_version.sh no longer excludes '.github' (expected docs, *.md, .github)"))
    # a filter of another length, or the same entries in another order
    var shorter = documentation_filter_findings(String("git log -- . ':(exclude)docs' ':(exclude).github'\n"), doc)
    assert_equal(len(shorter), 1, _all(shorter))
    assert_equal(
        shorter[0],
        String("R17: the push trigger's paths-ignore (docs/**, **.md) is not release_version.sh's documentation (docs/**)"),
    )
    var swapped = documentation_filter_findings(
        String("git log -- . ':(exclude)*.md' ':(exclude)docs' ':(exclude).github'\n"), doc
    )
    assert_equal(len(swapped), 1, _all(swapped))
    assert_true(swapped[0].find(String("(**.md, docs/**)")) >= 0, swapped[0])


def test_kci_run_calls_a_separator_ends_the_call() raises:
    # a separator word, or a word ending in `;`: what follows is another command
    var scripts = List[String]()
    scripts.append(String("kci run --stage build; echo --only x\n"))
    scripts.append(String("kci run --stage build ; echo --only x\n"))
    scripts.append(String("kci run --stage build && echo --only x\n"))
    scripts.append(String("kci run --stage build || echo --only x\n"))
    scripts.append(String("kci run --stage build | tee --only x\n"))
    for i in range(len(scripts)):
        var c = kci_run_calls(scripts[i])
        assert_equal(len(c), 1, scripts[i])
        assert_equal(c[0].stage, String("build"), scripts[i])
        assert_false(c[0].has_only, scripts[i])
        assert_equal(len(c[0].args), 2, scripts[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
