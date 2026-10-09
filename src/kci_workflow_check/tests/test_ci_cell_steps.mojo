# =============================================================================
# src/kci_workflow_check/tests/test_ci_cell_steps.mojo -- the workflow check for
#   steps that write into a cell (docs/design/deploy_step.md, "The workflow
#   check"): a DEPLOY step and a PUBLISH into a cell put their stage in
#   `id_token_stages` (R4), a PUBLISH into a cell names no channels file, and
#   a part job of a split stage never runs a DEPLOY_PROBE that has a target
#   (R9).
#
# What each test would catch:
#   * the DEPLOY arm of `id_token_stages` dropped: the DEPLOY stage's job
#     without `id-token: write` is accepted (test_a_deploy_stage_job_...);
#   * the cell-PUBLISH arm dropped: the no-channels-file machine raises
#     "the channels file '' was not given" (test_a_publish_into_a_cell_...);
#   * the targeted-probe arm of `_check_split` dropped: a part job running
#     the targeted probe is accepted (test_a_part_job_never_runs_...);
#   * either loop cut to its first item: the cell writer or the targeted
#     probe sits SECOND in every list it is read from.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_release_machine import parse_machine_file
from kci_workflow_check import ChannelsFile, channels_paths, check_running_workflow, check_workflow, id_token_stages

comptime _PATH: String = "release/machine.textproto"

comptime _IMAGE: String = "registry.example.invalid/probe@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

comptime _BUILD_STAGE: String = (
    "schema_version: 1\n"
    "name: \"shop\"\n"
    "stage { name: \"build\" break_glass: true\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
)

comptime _TOKEN_CHANNELS: String = (
    "schema_version: 1\n"
    "channel { name: \"gamma\" visibility: PUBLIC repository { artifact_type: CONDA"
    " location: \"https://prefix.dev/komira-ai/gamma\" push_identity: \"publisher\""
    " credential { kind: API_TOKEN secret_name: \"KOMIRA_TOKEN\" } } }\n"
)
"""A channels file whose one channel publishes by an API token, not OIDC."""


def _deploy_step() -> String:
    """A DEPLOY step with two probes: `smoke` (no target) first, `health`
    (a target) SECOND."""
    return (
        String("  step { name: \"deploy\" kind: DEPLOY cells: \"cells.textproto\" cell: \"staging\"")
        + String(" resources: \"deploy/app.json\"\n")
        + String("    validation { name: \"smoke\" kind: DEPLOY_PROBE image: \"") + String(_IMAGE)
        + String("\" timeout_seconds: 60 expect: \"up\" }\n")
        + String("    validation { name: \"health\" kind: DEPLOY_PROBE image: \"") + String(_IMAGE)
        + String("\" timeout_seconds: 60 expect: \"health\" target { resource: \"api\" output: \"url\" } }\n")
        + String("  }\n")
    )


def _token_publish() -> String:
    return String(
        "  step { name: \"channel\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\""
        " channels: \"c.textproto\" channel: \"gamma\" }\n"
    )


def _cell_publish() -> String:
    return String(
        "  step { name: \"push\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\""
        " cells: \"cells.textproto\" cell: \"staging\" }\n"
    )


def _machine(steps: String) -> String:
    """build, then staging (main only) holding `steps`."""
    return String(_BUILD_STAGE) + String("stage { name: \"staging\" after: \"build\"\n") + steps + String("}\n")


comptime _PROD_LINE: String = "      - name: the prod line\n        if: always()\n        run: echo prod line\n"

comptime _R21: String = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: ${{ env.REVISION }}\n      - name: the revision this run releases\n        run: |\n          case \"$REVISION\" in\n            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n          esac\n          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n          if [ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ] && [ \"$DRY_RUN\" = true ]; then\n            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n          else\n            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n              { echo \"refused: a run that can publish releases the commit it started on ($GITHUB_SHA), not $REVISION (a revision input is for a dry run)\"; exit 1; }\n          fi\n"
"""R21: the first two steps of every release job."""

comptime _R21_MAIN: String = "      - name: only a push to main reaches this job\n        run: |\n          [ \"$GITHUB_EVENT_NAME\" = push ] && [ \"$GITHUB_REF\" = refs/heads/main ] ||\n            { echo \"refused: only a push to refs/heads/main reaches this job; this run is a $GITHUB_EVENT_NAME of $GITHUB_REF\"; exit 1; }\n"
"""R21: the third step of a main-only job."""

comptime _HEAD: String = (
    "name: kci\n"
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
    "      reason:\n"
    "        type: string\n"
    "        required: true\n"
    "      dry_run:\n"
    "        type: boolean\n"
    "        default: false\n"
    "permissions: {}\n"
    "concurrency:\n"
    "  group: kci-${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'release-main' || inputs.dry_run && format('plan-{0}', github.run_id) || format('ref-{0}', github.ref_name) }}\n"
    "  cancel-in-progress: false\n"
    "env:\n"
    "  DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}\n"
    "jobs:\n"
    "  build:\n"
    "    environment: build\n"
    "    outputs:\n"
    "      set_hash: ${{ steps.kci.outputs.set_hash }}\n"
    "    steps:\n"
)

comptime _MAIN_ONLY: String = "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n"

comptime _HASH_ENV: String = "    env:\n      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n"

comptime _SUMMARY: String = " --summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"


def _wf(staging_only: String, part_only: String) -> String:
    """build, then `staging` (environment, `id-token: write`) running
    `kci run --stage staging<staging_only>`; when `part_only` is not empty,
    a part job `staging-probes` running `--stage staging<part_only>`."""
    var wf = (
        String(_HEAD) + String(_R21)
        + String("      - run: kci run --stage build --summary-file \"$GITHUB_STEP_SUMMARY\"\n") + String(_PROD_LINE)
        + String("  staging:\n    needs: build\n") + String(_MAIN_ONLY) + String("    environment: staging\n")
        + String("    permissions:\n      contents: read\n      id-token: write\n") + String(_HASH_ENV)
        + String("    steps:\n") + String(_R21) + String(_R21_MAIN)
        + String("      - run: kci run --stage staging") + staging_only + String(_SUMMARY) + String(_PROD_LINE)
    )
    if part_only.byte_length() > 0:
        wf += (
            String("  staging-probes:\n    needs: [build, staging]\n") + String(_MAIN_ONLY)
            + String("    permissions:\n      contents: read\n") + String(_HASH_ENV)
            + String("    steps:\n") + String(_R21) + String(_R21_MAIN)
            + String("      - run: kci run --stage staging") + part_only + String(_SUMMARY) + String(_PROD_LINE)
        )
    return wf^


def _no_token(wf: String) raises -> String:
    var with_token = String("    permissions:\n      contents: read\n      id-token: write\n")
    if wf.find(with_token) < 0:
        raise Error(String("fixture has no staging token"))
    return wf.replace(with_token, String("    permissions:\n      contents: read\n"))


def _all(f: List[String]) -> String:
    var s = String("")
    for i in range(len(f)):
        s += f[i] + String(" | ")
    return s^


def _has(f: List[String], needle: String) raises:
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + _all(f))


def _check(machine: String, wf: String) raises -> List[String]:
    """The start-up check, given NO channels file: a machine whose only
    PUBLISH writes into a cell needs none."""
    var g = parse_machine_file(machine, String("machine file"))
    return check_running_workflow(g, List[ChannelsFile](), wf, String(_PATH))


def _token_files() -> List[ChannelsFile]:
    var files = List[ChannelsFile]()
    files.append(ChannelsFile(String("c.textproto"), String(_TOKEN_CHANNELS)))
    return files^


# ---- R4: a cell writer's stage needs the token --------------------------------


def test_a_deploy_stage_job_carries_the_token_and_is_refused_without_it() raises:
    var m = _machine(_deploy_step())
    var wf = _wf(String(""), String(""))
    # without the token first: dropping the arm makes this the failure
    _has(
        _check(m, _no_token(wf)),
        String("job 'staging': R4: stage 'staging' writes into a cell (a DEPLOY step or a PUBLISH into a cell)"),
    )
    var ok = _check(m, wf)
    assert_equal(len(ok), 0, _all(ok))


def test_a_publish_into_a_cell_stage_job_carries_the_token_and_is_refused_without_it() raises:
    var m = _machine(_cell_publish())
    var wf = _wf(String(""), String(""))
    # without the token first: dropping the arm makes this the failure
    _has(
        _check(m, _no_token(wf)),
        String("job 'staging': R4: stage 'staging' writes into a cell (a DEPLOY step or a PUBLISH into a cell)"),
    )
    var ok = _check(m, wf)
    assert_equal(len(ok), 0, _all(ok))


def test_a_publish_into_a_cell_needs_no_channels_file() raises:
    var g = parse_machine_file(_machine(_cell_publish()), String("machine file"))
    assert_equal(len(channels_paths(g)), 0)
    var s = id_token_stages(g, List[ChannelsFile]())
    assert_equal(len(s), 1)
    assert_equal(s[0], String("staging"))


def test_a_cell_writer_second_in_its_stage_still_needs_the_token() raises:
    # the first step publishes to a channel by an API token (no OIDC): only
    # the second step, a cell writer, makes the stage need the token
    var deploy = parse_machine_file(_machine(_token_publish() + _deploy_step()), String("machine file"))
    var s = id_token_stages(deploy, _token_files())
    assert_equal(len(s), 1)
    assert_equal(s[0], String("staging"))
    var push = parse_machine_file(_machine(_token_publish() + _cell_publish()), String("machine file"))
    var paths = channels_paths(push)
    assert_equal(len(paths), 1)
    assert_equal(paths[0], String("c.textproto"))
    var t = id_token_stages(push, _token_files())
    assert_equal(len(t), 1)
    assert_equal(t[0], String("staging"))
    # and with the channel step alone, no stage needs it: the cell writer is
    # what counted
    var alone = parse_machine_file(_machine(_token_publish()), String("machine file"))
    assert_equal(len(id_token_stages(alone, _token_files())), 0)


# ---- R9: a part job never runs a probe that has a target ----------------------


def test_a_part_job_may_run_a_probe_with_no_target() raises:
    var f = _check(
        _machine(_deploy_step()), _wf(String(" --only step:deploy --only validation:health"), String(" --only validation:smoke"))
    )
    assert_equal(len(f), 0, _all(f))


def test_a_part_job_never_runs_a_probe_with_a_target() raises:
    var m = _machine(_deploy_step())
    var want = String(
        "R9: job 'staging-probes' runs validation 'health' of stage 'staging', a DEPLOY_PROBE with a target"
    )
    # the targeted probe is the step's SECOND validation
    var f = _check(m, _wf(String(" --only step:deploy --only validation:smoke"), String(" --only validation:health")))
    _has(f, want)
    # and the SECOND selector of the part job
    var g = _check(m, _wf(String(" --only step:deploy"), String(" --only validation:smoke --only validation:health")))
    _has(g, want)
    # the untargeted probe it runs alongside is not named
    for i in range(len(g)):
        assert_true(g[i].find(String("validation 'smoke'")) < 0, g[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
