# =============================================================================
# src/kci_workflow_check/tests/test_ci_split_stage.mojo -- one stage run by several
#   jobs (R1 and R9 as amended, PENDING A RULING): the job named after the
#   stage runs its steps with `--only step:<s>`, a second job runs the
#   validations with `--only validation:<v>`; together they run the whole
#   stage, each step and each validation exactly once. A fixture that agrees,
#   then one mutation per way a split can be wrong, each reported.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_workflow_check import check_workflow
from kci_release_machine import parse_machine_file

comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\" break_glass: true\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
    "stage { name: \"gamma\" after: \"build\" break_glass: true\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"\n"
    "         channels: \"c.textproto\" channel: \"gamma\"\n"
    "    validation { name: \"install\" kind: CONDA_INSTALL_SMOKE install: \"komira_all\" program: \"release/s.mojo\"\n"
    "      image: \"r.example.invalid/p@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"\n"
    "      compiler_channel: \"https://c.example.invalid/max\" }\n"
    "    validation { name: \"read-back\" kind: CONDA_INSTALL_SMOKE install: \"komira_all\" program: \"release/s.mojo\"\n"
    "      image: \"r.example.invalid/p@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"\n"
    "      compiler_channel: \"https://c.example.invalid/max\" }\n"
    "  }\n"
    "}\n"
)

comptime _PROD_LINE: String = "      - name: the prod line\n        if: always()\n        run: echo prod line\n"

# build and gamma are break_glass (no main conjunct, R15); the set hash goes
# build -> gamma and validate (R19); every release job ends with the prod
# line (R20).
comptime _WF: String = (
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
    "      - run: kci run --stage build --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
    + _PROD_LINE
    + "  gamma:\n"
    "    needs: build\n"
    "    environment: gamma\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
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
    "      - run: kci run --stage gamma --only step:publish --summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"
    + _PROD_LINE
    + "  validate:\n"
    "    needs: [build, gamma]\n"
    "    env:\n"
    "      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n"
    "    outputs:\n"
    "      validated_set_hash: ${{ steps.kci.outputs.set_hash }}\n"
    "    permissions:\n"
    "      contents: read\n"
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
    "      - run: |\n"
    "          kci run --stage gamma --only validation:install --only=validation:read-back \\\n"
    "            --scratch-dir \"$RUNNER_TEMP/v\" --summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"
    + _PROD_LINE
)


comptime _R19: String = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: ${{ env.REVISION }}\n      - name: the revision this run releases\n        run: |\n          case \"$REVISION\" in\n            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n          esac\n          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n          if [ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ] && [ \"$DRY_RUN\" = true ]; then\n            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n          else\n            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n              { echo \"refused: a run that can publish releases the commit it started on ($GITHUB_SHA), not $REVISION (a revision input is for a dry run)\"; exit 1; }\n          fi\n"
"""R21: the first two steps of every release job (auto_promotion.mojo)."""
comptime _R19_MAIN: String = "      - name: only a push to main reaches this job\n        run: |\n          [ \"$GITHUB_EVENT_NAME\" = push ] && [ \"$GITHUB_REF\" = refs/heads/main ] ||\n            { echo \"refused: only a push to refs/heads/main reaches this job; this run is a $GITHUB_EVENT_NAME of $GITHUB_REF\"; exit 1; }\n"
"""R21: the third step of a main-only job."""


def _token_stages() -> List[String]:
    var tokens = List[String]()
    tokens.append(String("gamma"))
    return tokens^


def _findings(wf: String) raises -> List[String]:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    return check_workflow(wf, g, _token_stages(), String("release/machine.textproto"))


def _mutated(old: String, new: String) raises -> String:
    var s = String(_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _all(f: List[String]) -> String:
    var s = String("")
    for i in range(len(f)):
        s += f[i] + String(" | ")
    return s^


def _reports(wf: String, needle: String) raises:
    var f = _findings(wf)
    for i in range(len(f)):
        if f[i].find(needle) >= 0:
            return
    raise Error(String("no finding containing '") + needle + String("'; findings: ") + _all(f))


def test_a_split_that_covers_the_stage_agrees() raises:
    var f = _findings(String(_WF))
    assert_equal(len(f), 0, _all(f))


def test_a_lone_job_with_only_is_still_refused() raises:
    # one job, a selection: the stage's validations would never run
    var lone = _mutated(String("  validate:\n"), String("  dropped:\n")).replace(
        String("kci run --stage gamma --only validation:install --only=validation:read-back"), String("kci run --stage build")
    )
    _reports(lone, String("job 'dropped' is no stage"))
    var only_main = String(_WF)[byte = 0 : String(_WF).find(String("  validate:\n"))]
    _reports(String(only_main), String("R9: stage 'gamma' is split over job gamma, and none of them runs validation 'install'"))
    _reports(String(only_main), String("validation 'read-back'"))


def test_every_part_is_run_exactly_once() raises:
    # a validation no job runs
    _reports(
        _mutated(String(" --only=validation:read-back"), String("")),
        String("R9: stage 'gamma' is split over jobs gamma, validate, and none of them runs validation 'read-back'"),
    )
    # a validation two jobs run
    _reports(
        _mutated(String("--only step:publish"), String("--only step:publish --only validation:install")),
        String("R9: stage 'gamma': validation 'install' is run by 2 jobs (gamma, validate)"),
    )
    # the main job runs the whole stage (its validations too) while another
    # job runs them again
    _reports(
        _mutated(String("kci run --stage gamma --only step:publish"), String("kci run --stage gamma")),
        String("R9: stage 'gamma': validation 'read-back' is run by 2 jobs (gamma, validate)"),
    )


def test_a_part_job_runs_validations_only() raises:
    _reports(
        _mutated(String("--only validation:install --only=validation:read-back"), String("--only step:publish --only validation:install --only=validation:read-back")),
        String("R9: job 'validate' runs step 'publish' of stage 'gamma'; only the job named after the stage runs its steps"),
    )


def test_a_selector_must_be_literal_and_match() raises:
    _reports(
        _mutated(String("--only validation:install "), String("--only \"$WHICH\" ")),
        String("R9: job 'validate': `--only $WHICH` is not a literal step:<name> or validation:<name>"),
    )
    _reports(
        _mutated(String("--only validation:install "), String("--only validation:smoke ")),
        String("R9: job 'validate': --only 'validation:smoke' matches no validation of stage 'gamma'"),
    )


def test_a_part_job_holds_no_token_no_environment_and_needs_the_step_job() raises:
    _reports(
        _mutated(String("    permissions:\n      contents: read\n    steps:\n"), String("    permissions:\n      contents: read\n      id-token: write\n    steps:\n")),
        String("job 'validate': R4: runs only validations of stage 'gamma', so it must not hold `id-token: write`"),
    )
    _reports(
        _mutated(String("  validate:\n    needs: [build, gamma]\n"), String("  validate:\n    needs: [build, gamma]\n    environment: gamma\n")),
        String("job 'validate': R2: runs only validations of stage 'gamma', so it runs in no environment"),
    )
    _reports(
        _mutated(String("    needs: [build, gamma]\n"), String("    needs: build\n")),
        String("job 'validate': R3: needs build; a job that runs validations of stage 'gamma' needs 'gamma'"),
    )
    _reports(
        _mutated(String("    needs: [build, gamma]\n"), String("    needs: [gamma, other]\n")),
        String("job 'validate': R3: needs gamma, other; besides 'gamma' it may need only 'build'"),
    )


def test_a_later_stage_needs_every_job_of_a_split_stage() raises:
    var three = String(_MACHINE) + String(
        "stage { name: \"prod\" after: \"gamma\"\n"
        "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" artifacts: \"d.textproto\"\n"
        "         channels: \"c.textproto\" channel: \"prod\" }\n"
        "}\n"
    )
    var g = parse_machine_file(three, String("machine file"))
    var tokens = _token_stages()
    tokens.append(String("prod"))
    # prod is not break_glass: main only (R15); it publishes the set validate
    # validated (R19)
    var prod = (
        String("  prod:\n    needs: [gamma, validate]\n    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n    environment: prod\n")
        + String("    permissions:\n      id-token: write\n")
        + String("    env:\n      RELEASE_SET_HASH: ${{ needs.validate.outputs.validated_set_hash }}\n")
        + String("    steps:\n") + String(_R19) + String(_R19_MAIN) + String("      - run: kci run --stage prod --summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n")
        + String(_PROD_LINE)
    )
    var ok = check_workflow(String(_WF) + prod, g, tokens, String("release/machine.textproto"))
    assert_equal(len(ok), 0, _all(ok))
    # prod may not start before gamma's validations end
    var early = check_workflow(
        String(_WF) + prod.replace(String("[gamma, validate]"), String("gamma")), g, tokens, String("release/machine.textproto")
    )
    assert_equal(len(early), 1, _all(early))
    assert_true(
        early[0].find(String("job 'prod': R3: needs gamma; the stage runs after gamma (run by jobs gamma, validate)")) >= 0,
        early[0],
    )


def test_a_part_job_of_no_stage_is_r1() raises:
    _reports(
        _mutated(String("kci run --stage gamma --only validation:install"), String("kci run --stage staging --only validation:install")),
        String("R1: job 'validate' is no stage of the machine file"),
    )


def test_a_part_job_holds_no_connect_action_and_needs_something() raises:
    _reports(
        _mutated(
            String("    permissions:\n      contents: read\n    steps:\n"),
            String("    permissions:\n      contents: read\n    steps:\n      - name: farm\n        uses: ./.github/actions/farm-connect\n"),
        ),
        String("job 'validate': R11: runs only validations of stage 'gamma', so it must not use ./.github/actions/farm-connect"),
    )
    _reports(
        _mutated(String("    needs: [build, gamma]\n"), String("")),
        String("job 'validate': R3: needs nothing; a job that runs validations of stage 'gamma' needs 'gamma'"),
    )


def test_a_split_main_job_with_two_kci_runs_is_r5_alone() raises:
    # the main job's selection cannot be read, so R9 says nothing of the
    # split (R5 does), not even that its first, whole-stage call repeats
    # validate's validations
    var f = _findings(
        _mutated(
            String("      - run: kci run --stage gamma --only step:publish"),
            String("      - run: kci run --stage gamma --summary-file x --release-set-hash \"$RELEASE_SET_HASH\"\n      - run: kci run --stage gamma --only step:publish"),
        )
    )
    var r5 = False
    for i in range(len(f)):
        assert_true(f[i].find(String("R9")) < 0, _all(f))
        if f[i].find(String("job 'gamma': R5: invokes `kci run` 2 times")) >= 0:
            r5 = True
    assert_true(r5, _all(f))


def test_an_only_without_a_value() raises:
    _reports(
        _mutated(
            String("--only step:publish --summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"),
            String("--summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\" --only\n"),
        ),
        String("R9: job 'gamma': `--only` has no value"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
