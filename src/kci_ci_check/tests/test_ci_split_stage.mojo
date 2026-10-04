# =============================================================================
# src/kci_ci_check/tests/test_ci_split_stage.mojo -- one stage run by several
#   jobs (R1 and R9 as amended, PENDING A RULING): the job named after the
#   stage runs its steps with `--only step:<s>`, a second job runs the
#   validations with `--only validation:<v>`; together they run the whole
#   stage, each step and each validation exactly once. A fixture that agrees,
#   then one mutation per way a split can be wrong, each reported.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from kci_ci_check import check_workflow
from kci_stage_graph import parse_machine_file

comptime _MACHINE: String = (
    "schema_version: 1\n"
    "stage { name: \"build\"\n"
    "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" declarations: \"d.textproto\" }\n"
    "}\n"
    "stage { name: \"gamma\" after: \"build\"\n"
    "  step { name: \"publish\" kind: PUBLISH platform: \"linux-x86_64\" declarations: \"d.textproto\"\n"
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

comptime _WF: String = (
    "name: kci\n"
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "  workflow_dispatch:\n"
    "    inputs:\n"
    "      revision:\n"
    "        type: string\n"
    "permissions: {}\n"
    "jobs:\n"
    "  build:\n"
    "    environment: build\n"
    "    steps:\n"
    "      - run: kci run --stage build --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
    "  gamma:\n"
    "    needs: build\n"
    "    environment: gamma\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - run: kci run --stage gamma --only step:publish --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
    "  validate:\n"
    "    needs: [build, gamma]\n"
    "    permissions:\n"
    "      contents: read\n"
    "    steps:\n"
    "      - run: |\n"
    "          kci run --stage gamma --only validation:install --only=validation:read-back \\\n"
    "            --scratch-dir \"$RUNNER_TEMP/v\" --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
)


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
        _mutated(String("    permissions:\n      contents: read\n    steps:\n      - run: |\n"), String("    permissions:\n      contents: read\n      id-token: write\n    steps:\n      - run: |\n")),
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


def test_a_part_job_of_no_stage_is_r1() raises:
    _reports(
        _mutated(String("kci run --stage gamma --only validation:install"), String("kci run --stage staging --only validation:install")),
        String("R1: job 'validate' is no stage of the machine file"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
