# =============================================================================
# src/kci_workflow_check/tests/test_ci_auto_promotion.mojo -- continuous
#   auto-promotion (auto_promotion.mojo, R15 to R22, R2's break-glass
#   environment and R4's allow-list),
#   held by a table of mutations of the repository's OWN kci.yml and
#   release/machine.textproto: the canonical pair agrees, and every row that
#   breaks a rule must end in that rule's finding (or the reader's "cannot
#   tell", or the machine file's refusal). A row that reads green fails the
#   test by its label, and every failing row is listed, not just the first.
# =============================================================================
#
# The files are staged as test data (BUCK): `kci.yml`, `machine.textproto`
# and `channels.textproto`.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite

from kci_workflow_check import ChannelsFile, check_running_workflow, read_workflow
from kci_workflow_check.auto_promotion import check_auto_promotion
from kci_release_machine import parse_machine_file

comptime _CLEAN: Int = 0
comptime _FINDING: Int = 1
comptime _CANNOT: Int = 2
comptime _REFUSED: Int = 3

comptime _GROUP_LINE: String = "  group: kci-${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'release-main' || inputs.dry_run && format('plan-{0}', github.run_id) || format('ref-{0}', github.ref_name) }}\n"
comptime _CANCEL_LINE: String = "  cancel-in-progress: false\n"
comptime _PROD_IF: String = "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n"
comptime _GAMMA_IF: String = "    # a break_glass stage: a manual run publishes here, from the\n    # environment gamma-breakglass (R15, R2)\n    if: needs.build.outputs.release == 'true'\n"
comptime _PATHS_IGNORE: String = "    paths-ignore:\n      - 'docs/**'\n      - '**.md'\n"
comptime _PROD_HASH_ENV: String = "      RELEASE_SET_HASH: ${{ needs.validate.outputs.validated_set_hash }}\n"
comptime _GAMMA_KCI_HASH: String = (
    "            --release-set-hash \"$RELEASE_SET_HASH\" \\\n"
    "            --secret-store none --result-file \"$RUNNER_TEMP/kci-result-gamma.json\""
)
comptime _PROD_KCI_HASH: String = (
    "            --release-set-hash \"$RELEASE_SET_HASH\" \\\n"
    "            --secret-store none --result-file \"$RUNNER_TEMP/kci-result-prod.json\""
)
comptime _PROD_REASON: String = (
    "--context reason=\"$REASON\"; fi\n          \"$RUNNER_TEMP/kci/kci\" run --stage prod \\\n"
)
comptime _VALIDATE_PROD_LINE: String = (
    "      # needs a permission no job holds): NEXT says so.\n      - name: the prod line\n        if: always()\n"
)
comptime _PROD_LINE_FAILED: String = (
    "            line=\"prod: FAILED ($JOB_STATUS${rc:+: exit $rc}) $REVISION: see kci-result-prod-$REVISION\"\n"
    "            echo \"### $line\" >> \"$GITHUB_STEP_SUMMARY\"\n"
    "            echo \"$line\" >&2\n"
    "          fi\n"
)
"""R20: the failure branch of prod's prod line, which falls through to the
main-tip comparison (its quoted `exit $rc` is a message, not a command)."""
comptime _VALIDATE_PROD_LINE_FAILED: String = (
    "            line=\"prod: NEXT (runs automatically; it waits only while the prod environment has a required reviewer)\"\n"
    "          fi\n"
)
"""R20: the end of validate's prod line (a release job other than prod)."""
comptime _GAMMA_PERMS: String = "    environment: ${{ github.event_name == 'push' && 'gamma' || 'gamma-breakglass' }}\n    permissions:\n      contents: read\n      id-token: write\n"
comptime _VALIDATE_OUTPUTS: String = (
    "    outputs:\n"
    "      # the set this job installed and validated, from its own kci result\n"
    "      # (never the value it was given): what prod publishes (R19)\n"
    "      validated_set_hash: ${{ steps.validated.outputs.set_hash }}\n"
)
comptime _PROD_HEAD: String = "  prod:\n    # after the stage gamma: its publish AND its validation\n"
comptime _M_PROD: String = "  name: \"prod\"\n  environment: \"prod\"\n  after: \"gamma\"\n"
comptime _M_GAMMA_BG: String = "  after: \"build\"\n  break_glass: true\n  break_glass_environment: \"gamma-breakglass\"\n"
comptime _M_GAMMA_BG_ENV: String = "  break_glass_environment: \"gamma-breakglass\"\n"
comptime _REV_STEP: String = "      # R21: the revision this run releases, checked by THIS file (on a run of\n      # main, main's own) before anything built from the revision runs.\n      - name: the revision this run releases\n        run: |\n          case \"$REVISION\" in\n            *[!0-9a-f]*) echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1 ;;\n          esac\n          [ \"${#REVISION}\" = 40 ] || { echo \"refused: REVISION '$REVISION' is not a full commit id\"; exit 1; }\n          if [ \"$GITHUB_EVENT_NAME\" = workflow_dispatch ] && [ \"$DRY_RUN\" = true ]; then\n            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n              { echo \"refused: $REVISION is not on the history of $GITHUB_SHA, the commit this run started on\"; exit 1; }\n          else\n            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n              { echo \"refused: a run that can publish releases the commit it started on ($GITHUB_SHA), not $REVISION (a revision input is for a dry run)\"; exit 1; }\n          fi\n"
"""R21: the revision step as kci.yml writes it in every release job."""
comptime _MAIN_STEP: String = "      # R21: a push to main, byte for byte (no `if:` can compare case).\n      - name: only a push to main reaches this job\n        run: |\n          [ \"$GITHUB_EVENT_NAME\" = push ] && [ \"$GITHUB_REF\" = refs/heads/main ] ||\n            { echo \"refused: only a push to refs/heads/main reaches this job; this run is a $GITHUB_EVENT_NAME of $GITHUB_REF\"; exit 1; }\n"
comptime _GAMMA_ENV: String = "    environment: ${{ github.event_name == 'push' && 'gamma' || 'gamma-breakglass' }}\n"
comptime _M_BUILD_BG: String = "  farm_connected: true\n  break_glass: true\n"
comptime _VAL_HEAD: String = "  validate:\n    needs: [build, gamma]\n"
comptime _GAMMA_HEAD: String = "  gamma:\n    needs: build\n"
comptime _VAL_KCI_STEP: String = "      - name: kci run --stage gamma --only validation:install-komira-encoding --only validation:install-set\n"
comptime _VAL_ENV_TAIL: String = "      REASON: ${{ inputs.reason }}\n      # The pixi"
comptime _WF_DRY: String = "  DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}\n"
comptime _VAL_PLAN: String = (
    "          if [ \"$DRY_RUN\" = true ]; then set -- --plan; fi\n"
    "          if [ -n \"$REASON\" ]; then set -- \"$@\" --context reason=\"$REASON\"; fi\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage gamma \\\n"
    "            --only validation:install-komira-encoding"
)
comptime _GAMMA_RV_STEP: String = "      # kci compares this with every package before any request.\n      - name: release_version.sh\n"
"""gamma's release_version.sh step, by the comment only gamma's carries."""
comptime _REV_EQ: String = "            [ \"$REVISION\" = \"$GITHUB_SHA\" ] ||\n"


struct _Row(Copyable, Movable):
    """One mutation: of the workflow (`machine` False) or of the machine
    file, `old` replaced by `new` (`old` must occur exactly once), and what
    the check must end in."""

    var label: String
    var machine: Bool
    var old: String
    var new: String
    var expect: Int
    var needle: String

    def __init__(out self, var label: String, machine: Bool, var old: String, var new: String, expect: Int, var needle: String):
        self.label = label^
        self.machine = machine
        self.old = old^
        self.new = new^
        self.expect = expect
        self.needle = needle^


def _wf(label: String, old: String, new: String, expect: Int, needle: String) -> _Row:
    return _Row(label.copy(), False, old.copy(), new.copy(), expect, needle.copy())


def _m(label: String, old: String, new: String, expect: Int, needle: String) -> _Row:
    return _Row(label.copy(), True, old.copy(), new.copy(), expect, needle.copy())


def _rows() -> List[_Row]:
    var r = List[_Row]()
    r.append(_wf(String("1 canonical"), String(""), String(""), _CLEAN, String("")))
    # ---- R15 main-only stages ----------------------------------------------------------------
    r.append(_wf(String("2 prod without the main conjunct"), String(_PROD_IF), String("    if: github.event_name == 'push'\n"), _FINDING, String("job 'prod': R15: stage 'prod' runs only on a push to main")))
    r.append(_wf(String("2b prod without the push conjunct (a manual run of main reaches it)"), String(_PROD_IF), String("    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'\n"), _FINDING, String("job 'prod': R15: stage 'prod' runs only on a push to main")))
    r.append(_wf(String("2c prod on workflow_dispatch"), String(_PROD_IF), String("    if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'\n"), _FINDING, String("job 'prod': R15: stage 'prod' runs only on a push to main")))
    r.append(_wf(String("3 prod on github.ref_name"), String(_PROD_IF), String("    if: github.event_name == 'push' && github.ref_name == 'main'\n"), _FINDING, String("job 'prod': R15: stage 'prod' runs only on a push to main")))
    r.append(_wf(String("4 the main conjunct on gamma (break_glass)"), String(_GAMMA_IF), String(_GAMMA_IF).replace(String("== 'true'\n"), String("== 'true' && github.ref == 'refs/heads/main'\n")), _FINDING, String("job 'gamma': R15: stage 'gamma' is break_glass")))
    r.append(_wf(String("4b the push conjunct on gamma (break_glass)"), String(_GAMMA_IF), String(_GAMMA_IF).replace(String("== 'true'\n"), String("== 'true' && github.event_name == 'push'\n")), _FINDING, String("job 'gamma': R15: stage 'gamma' is break_glass")))
    # GitHub's `==` ignores case: the literal is read ignoring case (D)
    r.append(_wf(String("4c the main conjunct on gamma, in another case"), String(_GAMMA_IF), String(_GAMMA_IF).replace(String("== 'true'\n"), String("== 'true' && github.ref == 'REFS/HEADS/MAIN'\n")), _FINDING, String("job 'gamma': R15: stage 'gamma' is break_glass")))
    r.append(_wf(String("4d the push conjunct on gamma, in another case"), String(_GAMMA_IF), String(_GAMMA_IF).replace(String("== 'true'\n"), String("== 'true' && github.event_name == 'Push'\n")), _FINDING, String("job 'gamma': R15: stage 'gamma' is break_glass")))
    r.append(_wf(String("2d prod's main conjunct in another case is the main conjunct"), String(_PROD_IF), String("    if: github.event_name == 'push' && github.ref == 'Refs/Heads/MAIN'\n"), _CLEAN, String("")))
    r.append(_wf(String("2e prod's push literal in another case is the push conjunct (R15 reads it ignoring case; R6's release-only reading went with the pull_request trigger)"), String(_PROD_IF), String("    if: github.event_name == 'PUSH' && github.ref == 'refs/heads/main'\n"), _CLEAN, String("")))
    r.append(_m(String("5 machine: prod break_glass"), String(_M_PROD), String(_M_PROD) + String("  break_glass: true\n"), _FINDING, String("job 'prod': R15: stage 'prod' is break_glass")))
    r.append(_m(String("5b machine: gamma not break_glass"), String(_M_GAMMA_BG), String("  after: \"build\"\n"), _FINDING, String("job 'validate': R15: stage 'gamma' runs only on a push to main")))
    r.append(_m(String("5d machine: a break_glass_environment on a stage that is not break_glass"), String(_M_GAMMA_BG), String("  after: \"build\"\n") + String(_M_GAMMA_BG_ENV), _REFUSED, String("stage 'gamma' has break_glass_environment 'gamma-breakglass' and is not break_glass")))
    r.append(_m(String("5c machine: build not break_glass, gamma is"), String(_M_BUILD_BG), String("  farm_connected: true\n"), _REFUSED, String("stage 'gamma' is break_glass and runs after 'build', which is not")))
    r.append(_wf(String("18 prod `always() &&`"), String(_PROD_IF), String("    if: always() && github.event_name == 'push' && github.ref == 'refs/heads/main'\n"), _FINDING, String("job 'prod': R15: stage 'prod' runs only on a push to main")))
    # ---- R16 concurrency ------------------------------------------------------------------------
    r.append(_wf(String("6 main's per-revision group"), String(_GROUP_LINE), String("  group: kci-${{ github.event.pull_request.number && format('pr-{0}', github.event.pull_request.number) || inputs.revision || github.sha }}\n"), _FINDING, String("R16: the workflow-level `concurrency:`")))
    r.append(_wf(String("6b #315's first group: every run of main in release-main"), String(_GROUP_LINE), String("  group: kci-${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number) || github.ref == 'refs/heads/main' && 'release-main' || format('breakglass-{0}', github.ref_name) }}\n"), _FINDING, String("R16: the workflow-level `concurrency:`")))
    r.append(_wf(String("6c a dry run in the release group"), String(_GROUP_LINE), String(_GROUP_LINE).replace(String(" || inputs.dry_run && format('plan-{0}', github.run_id)"), String("")), _FINDING, String("R16: the workflow-level `concurrency:`")))
    r.append(_wf(String("6d the release group's ref in another case"), String(_GROUP_LINE), String(_GROUP_LINE).replace(String("'refs/heads/main'"), String("'refs/heads/MAIN'")), _FINDING, String("R16: the workflow-level `concurrency:`")))
    r.append(_wf(String("7 cancel-in-progress: true"), String(_CANCEL_LINE), String("  cancel-in-progress: true\n"), _FINDING, String("R16: the workflow-level `concurrency:`")))
    r.append(_wf(String("7b cancel-in-progress: the pull request's spelling"), String(_CANCEL_LINE), String("  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n"), _FINDING, String("R16: the workflow-level `concurrency:`")))
    r.append(_wf(String("8 concurrency: kci (a scalar)"), String("concurrency:\n  # R16, byte for byte (file header, ONE RELEASE AT A TIME).\n") + String(_GROUP_LINE) + String(_CANCEL_LINE), String("concurrency: kci\n"), _FINDING, String("R16: the workflow-level `concurrency:`")))
    r.append(_wf(String("8b no concurrency"), String("concurrency:\n  # R16, byte for byte (file header, ONE RELEASE AT A TIME).\n") + String(_GROUP_LINE) + String(_CANCEL_LINE), String(""), _FINDING, String("R16: the workflow-level `concurrency:`")))
    r.append(_wf(String("8c a job-level concurrency on prod"), String(_PROD_HEAD), String(_PROD_HEAD) + String("    concurrency: prod\n"), _FINDING, String("job 'prod': R16: a job has no `concurrency:` of its own")))
    r.append(_wf(String("8d a third concurrency key"), String(_CANCEL_LINE), String(_CANCEL_LINE) + String("  queue: max\n"), _FINDING, String("R16: the workflow-level `concurrency:`")))
    # ---- R17 the push filter ---------------------------------------------------------------------
    r.append(_wf(String("9 #288's push (no paths-ignore)"), String(_PATHS_IGNORE), String(""), _FINDING, String("R17: the push trigger is exactly")))
    r.append(_wf(String("10 paths-ignore + 'src/**'"), String(_PATHS_IGNORE), String(_PATHS_IGNORE) + String("      - 'src/**'\n"), _FINDING, String("R17: the push trigger is exactly")))
    r.append(_wf(String("10b paths instead"), String(_PATHS_IGNORE), String(_PATHS_IGNORE).replace(String("paths-ignore"), String("paths")), _FINDING, String("R17: the push trigger is exactly")))
    r.append(_wf(String("10c reordered"), String(_PATHS_IGNORE), String("    paths-ignore:\n      - '**.md'\n      - 'docs/**'\n"), _FINDING, String("R17: the push trigger is exactly")))
    r.append(_wf(String("10d a flow list"), String(_PATHS_IGNORE), String("    paths-ignore: [docs]\n"), _FINDING, String("R17: the push trigger is exactly")))
    r.append(_wf(String("10e a flow list with a glob"), String(_PATHS_IGNORE), String("    paths-ignore: [docs/**]\n"), _CANNOT, String("a flow list item other than plain")))
    r.append(_wf(String("10f plain docs/**"), String("      - 'docs/**'\n"), String("      - docs/**\n"), _FINDING, String("R17: the push trigger is exactly")))
    r.append(_wf(String("10g tags beside branches"), String(_PATHS_IGNORE), String(_PATHS_IGNORE) + String("    tags: [v1]\n"), _FINDING, String("R17: the push trigger is exactly")))
    r.append(_wf(String("10h a pull_request trigger (the pull request's check is pr.yml)"), String("  workflow_dispatch:\n"), String("  pull_request:\n    branches: [main]\n  workflow_dispatch:\n"), _FINDING, String("R6: trigger 'pull_request': the release workflow is triggered by push and workflow_dispatch only")))
    # ---- R18 inputs and no expression in a script ------------------------------------------------
    r.append(_wf(String("12 reason not required"), String("        required: true\n"), String("        required: false\n"), _FINDING, String("`reason` is `required: true`")))
    r.append(_wf(String("12b dry_run default true"), String("        type: boolean\n        default: false\n"), String("        type: boolean\n        default: true\n"), _FINDING, String("`dry_run` is `default: false`")))
    r.append(_wf(String("12c reason with a default"), String("        required: true\n"), String("        required: true\n        default: \"x\"\n"), _FINDING, String("`reason` has no `default`")))
    r.append(_wf(String("12d an extra input"), String("        default: false\n\npermissions: {}\n"), String("        default: false\n      publish_prod:\n        type: boolean\n        default: false\n\npermissions: {}\n"), _FINDING, String("are exactly revision, reason and dry_run; it has 'publish_prod'")))
    r.append(_wf(String("13 inputs.reason in a run:"), String(_PROD_REASON), String(_PROD_REASON).replace(String("\"$REASON\""), String("\"${{ inputs.reason }}\"")), _FINDING, String("job 'prod': R18: a `run:` script holds `${{ inputs.reason }}`")))
    r.append(_wf(String("13b github.event.inputs.reason in a run:"), String(_PROD_REASON), String(_PROD_REASON).replace(String("\"$REASON\""), String("\"${{ github.event.inputs.reason }}\"")), _FINDING, String("R18: a `run:` script holds `${{ github.event.inputs.reason }}`")))
    r.append(_wf(String("13c the event payload in a run:"), String(_PROD_REASON), String(_PROD_REASON).replace(String("\"$REASON\""), String("\"${{ toJSON(github.event) }}\"")), _FINDING, String("R18: a `run:` script holds")))
    r.append(_wf(String("13d inputs.reason in a step's name"), String(_VAL_KCI_STEP), String("      - name: validate ${{ inputs.reason }}\n"), _FINDING, String("job 'validate': R18: a `name:` holds `${{ inputs.reason }}`")))
    r.append(_wf(String("13e github.event.inputs.reason in a job's name"), String(_GAMMA_HEAD), String(_GAMMA_HEAD) + String("    name: gamma ${{ github.event.inputs.reason }}\n"), _FINDING, String("job 'gamma': R18: a `name:` holds")))
    r.append(_wf(String("13f inputs.reason in a github-script `with: script:`"), String(_VAL_KCI_STEP), String("      - uses: actions/github-script@60a0d83039c74a4aee543508d2ffcb1c3799cdea # v7.0.1\n        with:\n          script: core.info('${{ inputs.reason }}')\n") + String(_VAL_KCI_STEP), _FINDING, String("job 'validate': R18: a `with: script:` holds `${{ inputs.reason }}`")))
    # a name is shown, never run: EVERY expression in a name is refused, in any accessor form
    r.append(_wf(String("13g inputs['reason'] in gamma's release_version.sh step (probe P2)"), String(_GAMMA_RV_STEP), String(_GAMMA_RV_STEP).replace(String("name: release_version.sh"), String("name: release_version.sh ${{ inputs['reason'] }}")), _FINDING, String("job 'gamma': R18: a `name:` holds `${{ inputs['reason'] }}`")))
    r.append(_wf(String("13h toJSON(inputs) in a job's name"), String(_GAMMA_HEAD), String(_GAMMA_HEAD) + String("    name: gamma ${{ toJSON(inputs) }}\n"), _FINDING, String("job 'gamma': R18: a `name:` holds `${{ toJSON(inputs) }}`")))
    r.append(_wf(String("13i github['event'] in a step's name"), String(_VAL_KCI_STEP), String("      - name: validate ${{ github['event']['inputs']['reason'] }}\n"), _FINDING, String("job 'validate': R18: a `name:` holds")))
    r.append(_wf(String("13j format('{0}', inputs) in a step's name"), String(_VAL_KCI_STEP), String("      - name: validate ${{ format('{0}', inputs) }}\n"), _FINDING, String("job 'validate': R18: a `name:` holds")))
    r.append(_wf(String("13k any expression in a name, even github.run_id"), String(_VAL_KCI_STEP), String("      - name: validate ${{ github.run_id }}\n"), _FINDING, String("job 'validate': R18: a `name:` holds `${{ github.run_id }}`")))
    # ---- R19 the set hash ------------------------------------------------------------------------
    r.append(_wf(String("14 prod's hash from build"), String(_PROD_HASH_ENV), String("      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n"), _FINDING, String("job 'prod': R19: its `env:` sets RELEASE_SET_HASH to exactly `${{ needs.validate.outputs.validated_set_hash }}`")))
    r.append(_wf(String("14b prod's hash from gamma"), String(_PROD_HASH_ENV), String("      RELEASE_SET_HASH: ${{ needs.gamma.outputs.set_hash }}\n"), _FINDING, String("job 'prod': R19: its `env:` sets RELEASE_SET_HASH")))
    r.append(_wf(String("15 gamma's kci run without --release-set-hash"), String(_GAMMA_KCI_HASH), String("            --secret-store none --result-file \"$RUNNER_TEMP/kci-result-gamma.json\""), _FINDING, String("job 'gamma': R19: its `kci run` passes no `--release-set-hash")))
    r.append(_wf(String("15b a literal set hash"), String(_PROD_KCI_HASH), String(_PROD_KCI_HASH).replace(String("\"$RELEASE_SET_HASH\""), String("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")), _FINDING, String("job 'prod': R19: `--release-set-hash 0123")))
    r.append(_wf(String("15c validate declares no validated_set_hash"), String(_VALIDATE_OUTPUTS), String(""), _FINDING, String("job 'validate': R19: a later job takes the release set's hash")))
    # ---- R20 the prod line ------------------------------------------------------------------------
    r.append(_wf(String("16 validate's last step renamed"), String(_VALIDATE_PROD_LINE), String(_VALIDATE_PROD_LINE).replace(String("name: the prod line"), String("name: summary")), _FINDING, String("job 'validate': R20")))
    r.append(_wf(String("16b validate's prod line not always()"), String(_VALIDATE_PROD_LINE), String(_VALIDATE_PROD_LINE).replace(String("if: always()"), String("if: success()")), _FINDING, String("job 'validate': R20")))
    # prod's prod line reports a main that moved past REVISION on a failure too: an `exit` before
    # that comparison drops it from the failed run's summary (komira-ai/komira#371)
    r.append(_wf(String("16c prod's prod line exits on a failure, before the main-tip comparison"), String(_PROD_LINE_FAILED), String(_PROD_LINE_FAILED).replace(String("            echo \"$line\" >&2\n          fi\n"), String("            echo \"$line\" >&2\n            exit 0\n          fi\n")), _FINDING, String("job 'prod': R20: `the prod line` runs `exit`")))
    r.append(_wf(String("16d an exit after `||` in a prod line"), String(_PROD_LINE_FAILED), String(_PROD_LINE_FAILED).replace(String("          fi\n"), String("          fi\n          [ \"$JOB_STATUS\" = success ] || exit 0\n")), _FINDING, String("job 'prod': R20: `the prod line` runs `exit`")))
    # the scanner reads shell words: no separator before `exit`, a quoted or escaped `exit`, and an
    # apostrophe in a comment (which opens no quote) still find it; `exit` in a comment or inside a
    # quoted message is not run; every release job's prod line is checked, not only prod's
    r.append(_wf(String("16e an exit right after `||`"), String(_PROD_LINE_FAILED), String(_PROD_LINE_FAILED).replace(String("          fi\n"), String("          fi\n          [ \"$JOB_STATUS\" = success ] ||exit 0\n")), _FINDING, String("job 'prod': R20: `the prod line` runs `exit`")))
    r.append(_wf(String("16f an apostrophe in a comment, then an exit"), String(_PROD_LINE_FAILED), String(_PROD_LINE_FAILED).replace(String("          fi\n"), String("          fi\n          # prod's last word\n          [ \"$JOB_STATUS\" = success ] || exit 0\n")), _FINDING, String("job 'prod': R20: `the prod line` runs `exit`")))
    r.append(_wf(String("16g a quoted exit"), String(_PROD_LINE_FAILED), String(_PROD_LINE_FAILED).replace(String("          fi\n"), String("          fi\n          [ \"$JOB_STATUS\" = success ] || \"exit\" 0\n")), _FINDING, String("job 'prod': R20: `the prod line` runs `exit`")))
    r.append(_wf(String("16h an escaped exit"), String(_PROD_LINE_FAILED), String(_PROD_LINE_FAILED).replace(String("          fi\n"), String("          fi\n          [ \"$JOB_STATUS\" = success ] || \\exit 0\n")), _FINDING, String("job 'prod': R20: `the prod line` runs `exit`")))
    r.append(_wf(String("16i exit in a comment is not run"), String(_PROD_LINE_FAILED), String(_PROD_LINE_FAILED).replace(String("          fi\n"), String("          fi\n          # never exit here: the comparison below runs on every path\n")), _CLEAN, String("")))
    r.append(_wf(String("16j exit inside a single-quoted message"), String(_PROD_LINE_FAILED), String(_PROD_LINE_FAILED).replace(String("          fi\n"), String("          fi\n          echo 'no exit here' >&2\n")), _CLEAN, String("")))
    r.append(_wf(String("16k validate's prod line exits in a brace group"), String(_VALIDATE_PROD_LINE_FAILED), String(_VALIDATE_PROD_LINE_FAILED).replace(String("          fi\n"), String("          fi\n          [ \"$JOB_STATUS\" = success ] || { exit; }\n")), _FINDING, String("job 'validate': R20: `the prod line` runs `exit`")))
    # ---- R21 the revision checked by the workflow -------------------------------------------------
    r.append(_wf(String("19 build without the revision step"), String(_REV_STEP) + String("      # The farm connection"), String("      # The farm connection"), _FINDING, String("job 'build': R21: its second step is `name: the revision this run releases`")))
    r.append(_wf(String("19b the revision step after farm-connect"), String(_REV_STEP) + String("      # The farm connection: tailnet join, refusal unless the farm answers, and\n      # the machine buckconfig, from repository variables (docs/ci.md).\n      - uses: ./.github/actions/farm-connect\n"), String("      # The farm connection: tailnet join, refusal unless the farm answers, and\n      # the machine buckconfig, from repository variables (docs/ci.md).\n      - uses: ./.github/actions/farm-connect\n") + String(_REV_STEP), _FINDING, String("job 'build': R21: its second step")))
    r.append(_wf(String("19c the revision step skipped by an if:"), String(_REV_STEP) + String("      - uses: actions/download-artifact"), String(_REV_STEP).replace(String("      - name: the revision this run releases\n"), String("      - name: the revision this run releases\n        if: github.event_name == 'push'\n")) + String("      - uses: actions/download-artifact"), _FINDING, String("job 'gamma': R21: its second step")))
    r.append(_wf(String("19d the revision step carries on past a refusal"), String(_REV_STEP) + String("      - uses: actions/download-artifact"), String(_REV_STEP).replace(String("      - name: the revision this run releases\n"), String("      - name: the revision this run releases\n        continue-on-error: true\n")) + String("      - uses: actions/download-artifact"), _FINDING, String("job 'gamma': R21: its second step")))
    r.append(_wf(String("19e a manual run of main may name any revision"), String(_REV_STEP) + String("      - uses: actions/download-artifact"), String(_REV_STEP).replace(String("git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||"), String("true ||")) + String("      - uses: actions/download-artifact"), _FINDING, String("job 'gamma': R21: its second step")))
    r.append(_wf(String("19f prod without the push-to-main step"), String(_MAIN_STEP), String(""), _FINDING, String("job 'prod': R21: stage 'prod' runs only on a push to main, so its third step")))
    r.append(_wf(String("19g the push-to-main step compares no ref"), String(_MAIN_STEP), String(_MAIN_STEP).replace(String(" && [ \"$GITHUB_REF\" = refs/heads/main ]"), String("")), _FINDING, String("job 'prod': R21: stage 'prod' runs only on a push to main, so its third step")))
    r.append(_wf(String("19h prod checks out another ref"), String("          ref: ${{ env.REVISION }}\n          fetch-depth: 0\n          persist-credentials: false\n") + String(_REV_STEP) + String(_MAIN_STEP), String("          ref: ${{ github.sha }}\n          fetch-depth: 0\n          persist-credentials: false\n") + String(_REV_STEP) + String(_MAIN_STEP), _FINDING, String("job 'prod': R21: its first step is `actions/checkout` with `ref: ${{ env.REVISION }}`")))
    r.append(_wf(String("19i a workflow default shell"), String("permissions: {}\n"), String("permissions: {}\n\ndefaults:\n  run:\n    shell: sh\n"), _FINDING, String("workflow: R21: the workflow has no `defaults:`")))
    r.append(_wf(String("19j continue-on-error on prod"), String(_PROD_HEAD), String(_PROD_HEAD) + String("    continue-on-error: true\n"), _FINDING, String("job 'prod': R21: a release job has no `continue-on-error:`")))
    r.append(_wf(String("19k a publishing manual run may name any revision on its history"), String(_REV_STEP) + String("      - uses: actions/download-artifact"), String(_REV_STEP).replace(String(_REV_EQ), String("            git merge-base --is-ancestor \"$REVISION\" \"$GITHUB_SHA\" ||\n")) + String("      - uses: actions/download-artifact"), _FINDING, String("job 'gamma': R21: its second step")))
    r.append(_wf(String("19l the revision step keyed on the event, not the dry run"), String(_REV_STEP) + String("      - uses: actions/download-artifact"), String(_REV_STEP).replace(String(" && [ \"$DRY_RUN\" = true ]"), String("")) + String("      - uses: actions/download-artifact"), _FINDING, String("job 'gamma': R21: its second step")))
    r.append(_wf(String("19m continue-on-error on the validate job"), String(_VAL_HEAD), String(_VAL_HEAD) + String("    continue-on-error: true\n"), _FINDING, String("job 'validate': R21: a release job has no `continue-on-error:`")))
    r.append(_wf(String("19n continue-on-error on the gamma job"), String(_GAMMA_HEAD), String(_GAMMA_HEAD) + String("    continue-on-error: true\n"), _FINDING, String("job 'gamma': R21: a release job has no `continue-on-error:`")))
    r.append(_wf(String("19o continue-on-error on validate's kci step"), String(_VAL_KCI_STEP), String(_VAL_KCI_STEP) + String("        continue-on-error: true\n"), _FINDING, String("job 'validate': R21: a step of a release job has no `continue-on-error:`")))
    # ---- R22 a push is never a dry run (THE TRAP: #311/#312 pinned a push as a dry run)
    r.append(_wf(String("21a #311/#312's DRY_RUN: a push pinned as a dry run"), String(_WF_DRY), String("  DRY_RUN: ${{ github.event_name != 'workflow_dispatch' || inputs.dry_run }}\n"), _FINDING, String("workflow: R22: the workflow-level `env:` sets DRY_RUN")))
    r.append(_wf(String("21b no DRY_RUN"), String(_WF_DRY), String(""), _FINDING, String("workflow: R22: the workflow-level `env:` sets DRY_RUN")))
    r.append(_wf(String("21c validate's own DRY_RUN, #312's form"), String(_VAL_ENV_TAIL), String("      DRY_RUN: ${{ github.event_name != 'workflow_dispatch' || inputs.dry_run }}\n") + String(_VAL_ENV_TAIL), _FINDING, String("job 'validate': R22: a job sets DRY_RUN in its own `env:`")))
    r.append(_wf(String("21d validate's own DRY_RUN, even the canonical one"), String(_VAL_ENV_TAIL), String(_WF_DRY).replace(String("  DRY_RUN"), String("      DRY_RUN")) + String(_VAL_ENV_TAIL), _FINDING, String("job 'validate': R22: a job sets DRY_RUN in its own `env:`")))
    r.append(_wf(String("21e a step's own DRY_RUN"), String(_VAL_KCI_STEP), String(_VAL_KCI_STEP) + String("        env:\n          DRY_RUN: true\n"), _FINDING, String("job 'validate': R22: a step sets DRY_RUN in its own `env:`")))
    r.append(_wf(String("21f validate runs --plan whatever the run"), String(_VAL_PLAN), String(_VAL_PLAN).replace(String("--only validation:install-komira-encoding"), String("--plan --only validation:install-komira-encoding")), _FINDING, String("job 'validate': R22: a script holds")))
    r.append(_wf(String("21g an unconditional set -- --plan"), String(_VAL_PLAN), String(_VAL_PLAN).replace(String("if [ \"$DRY_RUN\" = true ]; then set -- --plan; fi"), String("set -- --plan")), _FINDING, String("job 'validate': R22: a script holds `set -- --plan`")))
    r.append(_wf(String("21h DRY_RUN in another case is DRY_RUN"), String(_WF_DRY), String("  DRY_RUN: ${{ GitHub.Event_Name == 'WORKFLOW_DISPATCH' && Inputs.Dry_Run }}\n"), _CLEAN, String("")))
    # nothing re-sets DRY_RUN for a later step or line (probe P1: a GITHUB_ENV write overrides the workflow's env:)
    r.append(_wf(String("21i a step writes DRY_RUN to GITHUB_ENV before validate's kci (probe P1)"), String(_VAL_KCI_STEP), String("      - name: tidy\n        run: echo \"DRY_RUN=true\" >> \"$GITHUB_ENV\"\n") + String(_VAL_KCI_STEP), _FINDING, String("job 'validate': R22: a script names GITHUB_ENV")))
    r.append(_wf(String("21j a GITHUB_ENV write of another variable"), String(_GAMMA_RV_STEP), String("      - name: pin\n        run: echo \"REVISION=$GITHUB_SHA\" >> $GITHUB_ENV\n") + String(_GAMMA_RV_STEP), _FINDING, String("job 'gamma': R22: a script names GITHUB_ENV")))
    r.append(_wf(String("21k a GITHUB_ENV write in the brace form, in prod"), String(_MAIN_STEP), String(_MAIN_STEP) + String("      - name: pin\n        run: printf 'RELEASE_SET_HASH=%s\\n' x >> \"${GITHUB_ENV}\"\n"), _FINDING, String("job 'prod': R22: a script names GITHUB_ENV")))
    r.append(_wf(String("21l a shell assignment of DRY_RUN before the plan line"), String(_VAL_PLAN), String("          DRY_RUN=true\n") + String(_VAL_PLAN), _FINDING, String("job 'validate': R22: a script names DRY_RUN outside")))
    r.append(_wf(String("21m export DRY_RUN in a step of its own"), String(_MAIN_STEP), String(_MAIN_STEP) + String("      - name: mode\n        run: export DRY_RUN=true\n"), _FINDING, String("job 'prod': R22: a script names DRY_RUN outside")))
    r.append(_wf(String("21n a github-script exportVariable"), String(_VAL_KCI_STEP), String("      - uses: actions/github-script@60a0d83039c74a4aee543508d2ffcb1c3799cdea # v7.0.1\n        with:\n          script: core.exportVariable('DRY_RUN', 'true')\n") + String(_VAL_KCI_STEP), _FINDING, String("job 'validate': R22: a `with: script:` sets an environment variable")))
    # ---- R2 the break-glass environment ----------------------------------------------------------
    r.append(_wf(String("20 gamma in its own environment on every run"), String(_GAMMA_ENV), String("    environment: gamma\n"), _FINDING, String("job 'gamma': R2: stage 'gamma' has break_glass_environment 'gamma-breakglass'")))
    r.append(_wf(String("20b the environments swapped"), String(_GAMMA_ENV), String("    environment: ${{ github.event_name == 'push' && 'gamma-breakglass' || 'gamma' }}\n"), _FINDING, String("job 'gamma': R2: stage 'gamma' has break_glass_environment")))
    r.append(_wf(String("20c chosen by ref, not by event"), String(_GAMMA_ENV), String("    environment: ${{ github.ref == 'refs/heads/main' && 'gamma' || 'gamma-breakglass' }}\n"), _FINDING, String("job 'gamma': R2: stage 'gamma' has break_glass_environment")))
    r.append(_m(String("20d machine: gamma without its break-glass environment"), String(_M_GAMMA_BG_ENV), String(""), _FINDING, String("job 'gamma': R2: runs in environment '${{ github.event_name == 'push' && 'gamma' || 'gamma-breakglass' }}'; it must run in 'gamma'")))
    # ---- R4 the permission allow-list ----------------------------------------------------------------
    r.append(_wf(String("17 actions: read on gamma"), String(_GAMMA_PERMS), String(_GAMMA_PERMS) + String("      actions: read\n"), _FINDING, String("job 'gamma': R4: permissions grant `actions: read`")))
    r.append(_wf(String("17b contents: write on prod"), String("    environment: prod\n    permissions:\n      contents: read\n"), String("    environment: prod\n    permissions:\n      contents: write\n"), _FINDING, String("job 'prod': R4: permissions grant `contents: write`")))
    return r^


def _mutated(text: String, old: String, new: String) raises -> String:
    if old.byte_length() == 0:
        return text.copy()
    var at = text.find(old)
    if at < 0 or text.find(old, at + 1) >= 0:
        raise Error(String("the fixture does not hold exactly one '") + old + String("'"))
    return text.replace(old, new)


def _outcome(row: _Row) raises -> String:
    """"" when the row ends as it expects, else what happened."""
    var wf = Path(String("kci.yml")).read_text()
    var machine = Path(String("machine.textproto")).read_text()
    if row.machine:
        machine = _mutated(machine, row.old, row.new)
    else:
        wf = _mutated(wf, row.old, row.new)
    var files = List[ChannelsFile]()
    files.append(ChannelsFile(String("release/channels.textproto"), Path(String("channels.textproto")).read_text()))
    var f: List[String]
    try:
        var g = parse_machine_file(machine, String("release/machine.textproto"))
        f = check_running_workflow(g, files, wf, String("release/machine.textproto"))
    except e:
        var m = String(e)
        if row.expect == _CANNOT and m.startswith(String("cannot tell: ")) and m.find(row.needle) >= 0:
            return String("")
        if row.expect == _REFUSED and m.find(row.needle) >= 0:
            return String("")
        return String("raised: ") + m
    var all = String("")
    for i in range(len(f)):
        if row.expect == _FINDING and f[i].find(row.needle) >= 0:
            return String("")
        all += f[i] + String(" | ")
    if row.expect == _CLEAN and len(f) == 0:
        return String("")
    return String("read, findings: [") + all + String("]")


def test_every_row_ends_as_it_expects() raises:
    var rows = _rows()
    var failed = String("")
    var red = 0
    for i in range(len(rows)):
        var got = _outcome(rows[i])
        if got.byte_length() > 0:
            red += 1
            failed += String("\n  ROW '") + rows[i].label + String("': want ") + rows[i].needle + String("; ") + got
    if failed.byte_length() > 0:
        raise Error(String(red) + String(" of ") + String(len(rows)) + String(" rows did not end as expected:") + failed)


def test_a_part_of_a_stage_the_machine_lacks_is_skipped() raises:
    # check_auto_promotion is public: a caller's part_stage may name a stage
    # the machine does not have. That job is skipped (no finding names it) and
    # the jobs after it are still held (R4 on `build`).
    var g = parse_machine_file(
        String(
            "schema_version: 1\n"
            "stage { name: \"build\" farm_connected: true break_glass: true\n"
            "  step { name: \"build\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
            "}\n"
        ),
        String("machine file"),
    )
    var doc = read_workflow(
        String(
            "jobs:\n  ghost-job:\n    permissions:\n      contents: write\n"
            "  build:\n    permissions:\n      contents: write\n"
        )
    )
    var jobs = doc.child(0, String("jobs"))
    var ids = List[String]()
    ids.append(String("ghost-job"))
    ids.append(String("build"))
    var nodes = List[Int]()
    nodes.append(doc.child(jobs, String("ghost-job")))
    nodes.append(doc.child(jobs, String("build")))
    var part_stage = List[String]()
    part_stage.append(String("ghost"))
    part_stage.append(String(""))
    var f = List[String]()
    check_auto_promotion(doc, g, ids, nodes, part_stage, f)
    var all = String("")
    var build_r4 = False
    for i in range(len(f)):
        all += f[i] + String(" | ")
        if f[i].find(String("job 'ghost-job'")) >= 0:
            raise Error(String("a job of a missing stage was held: ") + f[i])
        if f[i].find(String("job 'build': R4: permissions grant `contents: write`")) >= 0:
            build_r4 = True
    if not build_r4:
        raise Error(String("no R4 finding for job 'build': [") + all + String("]"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
