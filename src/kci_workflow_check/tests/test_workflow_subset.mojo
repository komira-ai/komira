# =============================================================================
# src/kci_workflow_check/tests/test_workflow_subset.mojo -- the YAML subset the
#   workflow reader accepts, held by a table: every spelling that has been
#   found to read one way to kci and another way to GitHub, each of which
#   must end in "cannot tell" (the reader refuses it) or in the rule's own
#   finding. A row that reads green fails the test by its label.
# =============================================================================

from std.testing import TestSuite, assert_equal

from kci_workflow_check import check_workflow
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
    "stage { name: \"pr\" trigger: PULL_REQUEST farm_connected: true\n"
    "  step { name: \"check\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d.textproto\" }\n"
    "}\n"
)

# pr.yml, the pull request's check (the PULL_REQUEST stage alone), which agrees
# with _MACHINE; the table's rows mutate it and are checked as pr.yml.
comptime _PR_WF: String = (
    "name: pr\n"
    "on:\n"
    "  pull_request:\n"
    "    branches: [main]\n"
    "permissions: {}\n"
    "jobs:\n"
    "  check:\n"
    "    if: github.event.pull_request.head.repo.full_name == github.repository\n"
    "    runs-on: ubuntu-24.04\n"
    "    permissions:\n"
    "      contents: read\n"
    "      id-token: write\n"
    "    steps:\n"
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
    "        with:\n"
    "          fetch-depth: 0\n"
    "      - name: farm\n"
    "        uses: ./.github/actions/farm-connect\n"
    "        with:\n"
    "          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"
    "      - name: kci\n"
    "        run: |\n"
    "          if ! git rev-parse --verify --quiet HEAD^2 > /dev/null || ! change_base=$(git rev-parse --verify HEAD^1);"
    " then echo \"::error::the change base is the merge commit's first parent, and HEAD is not a merge commit\"; exit 1; fi\n"
    "          \"$RUNNER_TEMP/kci/kci\" run --stage pr \\\n"
    "            --affected-by \"$change_base\" \\\n"
    "            --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
)

# kci.yml, the release workflow (no pull_request trigger), which agrees with
# _MACHINE; the push-trigger rows mutate it and are checked as the release workflow.
comptime _REL_WF: String = (
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
    "    outputs:\n"
    "      set_hash: ${{ steps.kci.outputs.set_hash }}\n"
    "    environment: build\n"
    "    permissions:\n"
    "      id-token: write\n"
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
    "      - uses: ./.github/actions/farm-connect\n"
    "      - run: kci run --stage build --summary-file \"$GITHUB_STEP_SUMMARY\"\n"
    "      - name: the prod line\n"
    "        if: always()\n"
    "        run: echo prod line\n"
    "  publish-gamma:\n"
    "    needs: build\n"
    "    if: needs.build.outputs.release == 'true'\n"
    "    env:\n"
    "      RELEASE_SET_HASH: ${{ needs.build.outputs.set_hash }}\n"
    "    environment: gamma\n"
    "    permissions:\n"
    "      id-token: write\n"
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
    "      - run: kci run --stage publish-gamma --summary-file \"$GITHUB_STEP_SUMMARY\" --release-set-hash \"$RELEASE_SET_HASH\"\n"
    "      - name: the prod line\n"
    "        if: always()\n"
    "        run: echo prod line\n"
)

comptime _FORK: String = "github.event.pull_request.head.repo.full_name == github.repository"
comptime _FORK_IF: String = "    if: github.event.pull_request.head.repo.full_name == github.repository\n"
comptime _JOB_PERMS: String = "    permissions:\n      contents: read\n      id-token: write\n"
comptime _TOP_PERMS: String = "permissions: {}\n"

# What a row expects: the reader refuses (`cannot tell: ...<needle>`), or a
# finding holding <needle>.
comptime _CANNOT: Int = 0
comptime _FINDING: Int = 1

comptime _R6_FORK: String = "R6: stage 'pr' is a PULL_REQUEST stage, so the job carries `if:"
comptime _R4_SCALAR: String = "R4: `permissions: "
comptime _R4_TOP_TOKEN: String = "R4: `id-token: write` at the workflow level reaches every job"
comptime _R6_PUSH: String = "R17: the push trigger is exactly `branches: [main]`"
comptime _R6_OWN_PERMS: String = "so the job has its own `permissions:` mapping"
comptime _R6_PERMS_FORM: String = "so its `permissions` is a mapping"
comptime _R6_GRANT: String = "so its permissions hold only `contents: read`"
comptime _R6_SECRET: String = "names the `secrets` context"
comptime _R6_SECRET_KEY: String = "passes stored secrets"
comptime _PUSH_MAIN: String = "  push:\n    branches: [main]\n"
comptime _KCI_STEP: String = "      - name: kci\n        run: |\n"


struct _Row(Copyable, Movable):
    var label: String
    var workflow: String
    var expect: Int
    var needle: String
    var release: Bool

    def __init__(out self, var label: String, var workflow: String, expect: Int, var needle: String, release: Bool = False):
        self.label = label^
        self.workflow = workflow^
        self.expect = expect
        self.needle = needle^
        self.release = release


def _swap(old: String, new: String) raises -> String:
    var s = String(_PR_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _rel_swap(old: String, new: String) raises -> String:
    """The release workflow with `old` replaced by `new`."""
    var s = String(_REL_WF)
    if s.find(old) < 0:
        raise Error(String("fixture has no '") + old + String("'"))
    return s.replace(old, new)


def _push(value: String) raises -> String:
    """The workflow with its push trigger written as `value`."""
    return _rel_swap(String(_PUSH_MAIN), value)


def _step_env(value: String) raises -> String:
    """The workflow with the pr job's kci step given `env: K: <value>`."""
    return _swap(String(_KCI_STEP), String("      - name: kci\n        env:\n          K: ") + value + String("\n        run: |\n"))


def _fork_if(value: String) raises -> String:
    """The workflow with the fork condition's `if:` written as `value` (to
    the line's end; `value` may run on to more lines)."""
    return _swap(String(_FORK_IF), String("    if: ") + value + String("\n"))


def _job_perms(entries: String) raises -> String:
    """The workflow with job 'pr''s permissions block holding `entries`
    (each line indented six spaces, newline-terminated)."""
    return _swap(String(_JOB_PERMS), String("    permissions:\n") + entries)


def _top_perms(value: String) raises -> String:
    """The workflow with the workflow-level `permissions:` written as
    `value` (to the line's end; may run on to more lines)."""
    return _swap(String(_TOP_PERMS), String("permissions: ") + value + String("\n"))


def _rows() raises -> List[_Row]:
    var r = List[_Row]()
    var expr = String("${{ ") + String(_FORK) + String(" }}")

    # ---- template mixing: an `if:` GitHub reads as a format string --------
    r.append(_Row(String("if: text before ${{"), _fork_if(String("x") + expr), _FINDING, String(_R6_FORK)))
    r.append(_Row(String("if: two ${{ }}"), _fork_if(expr + String(" && ${{ true }}")), _FINDING, String(_R6_FORK)))
    r.append(_Row(String("if: space inside double quotes"), _fork_if(String("\"") + expr + String(" \"")), _FINDING, String(_R6_FORK)))
    r.append(_Row(String("if: space inside single quotes"), _fork_if(String("' ") + expr + String("'")), _FINDING, String(_R6_FORK)))
    r.append(_Row(String("if: tab inside quotes"), _fork_if(String("\"") + expr + String("\t\"")), _CANNOT, String("a TAB")))
    r.append(_Row(String("if: tab after a plain scalar"), _fork_if(expr + String("\t")), _CANNOT, String("a TAB")))
    r.append(_Row(String("if: a partial ${{"), _fork_if(String(_FORK) + String(" && ${{ true")), _FINDING, String(_R6_FORK)))

    # ---- block scalars, every style and chomping ---------------------------
    var headers = List[String]()
    for h in ["|", "|-", "|+", ">", ">-", ">+", "|2", "|2-", "|+2", ">1", ">-1"]:
        headers.append(String(h))
    for i in range(len(headers)):
        r.append(
            _Row(
                String("if: block ") + headers[i],
                _fork_if(headers[i] + String("\n      ") + expr),
                _CANNOT,
                String("block scalar"),
            )
        )
        r.append(
            _Row(
                String("if: block (no ${{) ") + headers[i],
                _fork_if(headers[i] + String("\n      ") + String(_FORK)),
                _CANNOT,
                String("block scalar"),
            )
        )
        r.append(
            _Row(
                String("id-token: block ") + headers[i],
                _job_perms(String("      contents: read\n      id-token: ") + headers[i] + String("\n        write\n")),
                _CANNOT,
                String("block scalar"),
            )
        )
        r.append(
            _Row(
                String("permissions: block ") + headers[i],
                _top_perms(headers[i] + String("\n  write-all")),
                _CANNOT,
                String("block scalar"),
            )
        )
        if headers[i] != String("|"):
            r.append(
                _Row(
                    String("run: block ") + headers[i],
                    _swap(String("        run: |\n"), String("        run: ") + headers[i] + String("\n")),
                    _CANNOT,
                    String("block scalar"),
                )
            )
    r.append(
        _Row(
            String("run: | under a key other than run"),
            _swap(String("        run: |\n"), String("        run: x\n        shell: |\n")),
            _CANNOT,
            String("block scalar"),
        )
    )

    # ---- quoted scalars carried past their line, escapes --------------------
    r.append(
        _Row(
            String("if: '' at the line's end carries the scalar on"),
            _fork_if(String("'") + String(_FORK) + String(" ''\n    || ''a: b'''")),
            _CANNOT,
            String("an escaped quote"),
        )
    )
    r.append(
        _Row(
            String("if: '${{ }}'' carried on"),
            _fork_if(String("'") + expr + String("''\n    || ''a: b'''")),
            _CANNOT,
            String("an escaped quote"),
        )
    )
    r.append(_Row(String("if: '' inside a closed single-quoted scalar"), _fork_if(String("'it''s'")), _CANNOT, String("an escaped quote")))
    r.append(
        _Row(
            String("if: backslash in double quotes"),
            _fork_if(String("\"") + String(_FORK) + String(" \\\n    || true\"")),
            _CANNOT,
            String("an escape"),
        )
    )
    r.append(_Row(String("if: \\x escape"), _fork_if(String("\"github.event_name \\x3d= 'push'\"")), _CANNOT, String("an escape")))
    r.append(
        _Row(
            String("if: double-quoted over two lines"),
            _fork_if(String("\"") + String(_FORK) + String("\n    || true\"")),
            _CANNOT,
            String("not closed on its line"),
        )
    )
    r.append(
        _Row(
            String("if: single-quoted over two lines"),
            _fork_if(String("'") + String(_FORK) + String("\n    || true'")),
            _CANNOT,
            String("not closed on its line"),
        )
    )
    r.append(
        _Row(
            String("if: plain over two lines"),
            _fork_if(String(_FORK) + String("\n      || true")),
            _CANNOT,
            String("continues the value"),
        )
    )
    r.append(_Row(String("if: text after a quoted close"), _fork_if(String("'") + String(_FORK) + String("' || true")), _CANNOT, String("text after a quoted scalar")))

    # ---- flow collections ----------------------------------------------------
    r.append(_Row(String("permissions: a flow map"), _top_perms(String("{id-token: write}")), _CANNOT, String("a flow mapping")))
    r.append(
        _Row(
            String("with: a flow map"),
            _swap(String("        with:\n          fetch-depth: 0\n"), String("        with: {fetch-depth: 0}\n")),
            _CANNOT,
            String("a flow mapping"),
        )
    )
    r.append(_Row(String("branches: a map in a flow list"), _swap(String("[main]"), String("[main, {a: b}]")), _CANNOT, String("flow list")))
    r.append(_Row(String("branches: a quoted flow item"), _swap(String("[main]"), String("['main']")), _CANNOT, String("flow list")))
    r.append(_Row(String("branches: a nested flow list"), _swap(String("[main]"), String("[main, [x]]")), _CANNOT, String("flow list")))

    # ---- anchors, aliases, tags, merge keys -----------------------------------
    r.append(_Row(String("an anchor on permissions"), _job_perms(String("      contents: read\n")).replace(String("    permissions:\n"), String("    permissions: &p\n")), _CANNOT, String("an anchor, alias or tag")))
    r.append(_Row(String("an alias as permissions"), _top_perms(String("*p")), _CANNOT, String("an anchor, alias or tag")))
    r.append(_Row(String("a tag on id-token"), _job_perms(String("      contents: read\n      id-token: !!str write\n")), _CANNOT, String("an anchor, alias or tag")))
    r.append(_Row(String("a merge key of an alias"), _job_perms(String("      contents: read\n      <<: *p\n")), _CANNOT, String("a merge key")))
    r.append(_Row(String("a merge key of a block"), _job_perms(String("      contents: read\n      <<:\n        id-token: write\n")), _CANNOT, String("a merge key")))
    r.append(_Row(String("a complex key"), _job_perms(String("      contents: read\n      ? id-token\n      : write\n")), _CANNOT, String("a complex key")))

    # ---- keys: quoted, escaped, case, repeated ---------------------------------
    r.append(_Row(String("an escaped double-quoted key"), _job_perms(String("      contents: read\n      \"id\\x2dtoken\": write\n")), _CANNOT, String("a quoted key")))
    r.append(_Row(String("a single-quoted key"), _job_perms(String("      contents: read\n      'id-token': write\n")), _CANNOT, String("a quoted key")))
    r.append(_Row(String("Id-Token"), _job_perms(String("      contents: read\n      Id-Token: write\n")), _CANNOT, String("in another case")))
    r.append(_Row(String("ID-TOKEN"), _job_perms(String("      contents: read\n      ID-TOKEN: write\n")), _CANNOT, String("in another case")))
    r.append(_Row(String("Permissions on the job"), _swap(String(_JOB_PERMS), String("    Permissions: write-all\n")), _CANNOT, String("in another case")))
    r.append(_Row(String("PERMISSIONS at the top"), _swap(String(_TOP_PERMS), String("PERMISSIONS: write-all\n")), _CANNOT, String("in another case")))
    r.append(_Row(String("If on the job"), _swap(String(_FORK_IF), String("    If: always()\n")), _CANNOT, String("in another case")))
    r.append(_Row(String("Environment on the job"), _swap(String("    runs-on: ubuntu-24.04\n"), String("    runs-on: ubuntu-24.04\n    Environment: pr\n")), _CANNOT, String("in another case")))
    r.append(_Row(String("Run in a step"), _swap(String("      - name: kci\n"), String("      - Run: kci run --stage build\n      - name: kci\n")), _CANNOT, String("in another case")))
    r.append(_Row(String("Pull_Request trigger"), _swap(String("  pull_request:\n"), String("  Pull_Request:\n")), _CANNOT, String("in another case")))
    r.append(_Row(String("keys differing in case"), _job_perms(String("      contents: read\n      Contents: write\n      id-token: write\n")), _CANNOT, String("repeated")))
    r.append(_Row(String("a repeated id-token"), _job_perms(String("      contents: read\n      id-token: write\n      id-token: write\n")), _CANNOT, String("repeated")))

    # ---- write-all spellings -----------------------------------------------------
    r.append(_Row(String("permissions: write-all"), _top_perms(String("write-all")), _FINDING, String(_R4_SCALAR)))
    r.append(_Row(String("permissions: 'write-all'"), _top_perms(String("'write-all'")), _FINDING, String(_R4_SCALAR)))
    r.append(_Row(String("permissions: \"write-all\""), _top_perms(String("\"write-all\"")), _FINDING, String(_R4_SCALAR)))
    r.append(_Row(String("permissions: Write-All"), _top_perms(String("Write-All")), _FINDING, String(_R4_SCALAR)))
    r.append(_Row(String("permissions: write-all # c"), _top_perms(String("write-all # c")), _FINDING, String(_R4_SCALAR)))
    r.append(_Row(String("permissions: 'read-all'"), _top_perms(String("'read-all'")), _FINDING, String(_R4_SCALAR)))
    r.append(_Row(String("permissions: a list"), _top_perms(String("[write-all]")), _FINDING, String("R4: `permissions:` is a list")))
    r.append(_Row(String("permissions: write-all, job"), _swap(String(_JOB_PERMS), String("    permissions: write-all\n")), _FINDING, String(_R4_SCALAR)))
    r.append(_Row(String("id-token: 'read' is a grant"), _top_perms(String("\n  id-token: 'read'")), _FINDING, String(_R4_TOP_TOKEN)))

    # ---- the push trigger: the release branch only (R17, which took over R6's push clause)
    r.append(_Row(String("push: no branch filter"), _push(String("  push:\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: branches '**'"), _push(String("  push:\n    branches:\n      - '**'\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: a branch pattern"), _push(String("  push:\n    branches:\n      - main*\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: branches-ignore"), _push(String("  push:\n    branches-ignore: [main]\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: a second branch"), _push(String("  push:\n    branches: [main, dev]\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: no branch"), _push(String("  push:\n    branches: []\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: tags beside branches"), _push(String(_PUSH_MAIN) + String("    tags: [v1]\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: paths beside branches"), _push(String(_PUSH_MAIN) + String("    paths: [src]\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: Branches in another case"), _push(String("  push:\n    Branches: [main]\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(_Row(String("push: branches a scalar"), _push(String("  push:\n    branches: main\n")), _FINDING, String(_R6_PUSH), release=True))
    r.append(
        _Row(
            String("on: a list of events"),
            _rel_swap(
                String("on:\n") + String(_PUSH_MAIN)
                + String("    paths-ignore:\n      - 'docs/**'\n      - '**.md'\n  workflow_dispatch:\n    inputs:\n")
                + String("      revision:\n        type: string\n      reason:\n        type: string\n        required: true\n")
                + String("      dry_run:\n        type: boolean\n        default: false\n"),
                String("on: [push, workflow_dispatch]\n"),
            ),
            _FINDING,
            String(_R6_PUSH),
            True,
        )
    )

    # ---- the pr job's own permissions (R6) --------------------------------------
    r.append(
        _Row(
            String("pr job: no permissions, workflow-level write"),
            _swap(String(_JOB_PERMS), String("")).replace(String(_TOP_PERMS), String("permissions:\n  contents: write\n  packages: write\n")),
            _FINDING,
            String(_R6_OWN_PERMS),
        )
    )
    r.append(
        _Row(
            String("pr job: no permissions anywhere"),
            _swap(String(_JOB_PERMS), String("")).replace(String(_TOP_PERMS), String("")),
            _FINDING,
            String(_R6_OWN_PERMS),
        )
    )
    r.append(_Row(String("pr job: contents: write"), _job_perms(String("      contents: write\n      id-token: write\n")), _FINDING, String(_R6_GRANT)))
    r.append(_Row(String("pr job: packages: write"), _job_perms(String("      contents: read\n      packages: write\n      id-token: write\n")), _FINDING, String(_R6_GRANT)))
    r.append(_Row(String("pr job: permissions: read-all"), _swap(String(_JOB_PERMS), String("    permissions: read-all\n")), _FINDING, String(_R6_PERMS_FORM)))

    # ---- stored secrets (R6) -----------------------------------------------------
    r.append(_Row(String("pr step env: secrets.X"), _step_env(String("${{ secrets.PREFIX_DEV_API_KEY }}")), _FINDING, String(_R6_SECRET)))
    r.append(_Row(String("pr step env: SECRETS.X"), _step_env(String("${{ SECRETS.PREFIX_DEV_API_KEY }}")), _FINDING, String(_R6_SECRET)))
    r.append(_Row(String("pr step env: secrets['X']"), _step_env(String("\"${{ secrets['PREFIX_DEV_API_KEY'] }}\"")), _FINDING, String(_R6_SECRET)))
    r.append(_Row(String("pr step env: toJSON(secrets)"), _step_env(String("${{ toJSON(secrets) }}")), _FINDING, String(_R6_SECRET)))
    r.append(_Row(String("pr step env: secrets.GITHUB_TOKEN_2"), _step_env(String("${{ secrets.GITHUB_TOKEN_2 }}")), _FINDING, String(_R6_SECRET)))
    r.append(_Row(String("pr step env: secrets.github_token"), _step_env(String("${{ secrets.github_token }}")), _FINDING, String(_R6_SECRET)))
    r.append(
        _Row(
            String("pr run: secrets.X"),
            _swap(String(_KCI_STEP), String("      - name: leak\n        run: |\n          echo ${{ secrets.PREFIX_DEV_API_KEY }}\n") + String(_KCI_STEP)),
            _FINDING,
            String(_R6_SECRET),
        )
    )
    r.append(
        _Row(
            String("pr with: secrets.X"),
            _swap(String("          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n"), String("          ts-client-id: ${{ secrets.TS_CLIENT_ID }}\n")),
            _FINDING,
            String(_R6_SECRET),
        )
    )
    r.append(_Row(String("pr job: secrets: inherit"), _swap(String(_JOB_PERMS), String(_JOB_PERMS) + String("    secrets: inherit\n")), _FINDING, String(_R6_SECRET_KEY)))
    r.append(_Row(String("pr job: Secrets: inherit"), _swap(String(_JOB_PERMS), String(_JOB_PERMS) + String("    Secrets: inherit\n")), _FINDING, String(_R6_SECRET_KEY)))
    r.append(
        _Row(
            String("workflow env: secrets.X"),
            _swap(String(_TOP_PERMS), String(_TOP_PERMS) + String("env:\n  PREFIX_DEV_API_KEY: ${{ secrets.PREFIX_DEV_API_KEY }}\n")),
            _FINDING,
            String(_R6_SECRET),
        )
    )
    r.append(
        _Row(
            String("workflow Env: secrets.X"),
            _swap(String(_TOP_PERMS), String(_TOP_PERMS) + String("Env:\n  PREFIX_DEV_API_KEY: ${{ secrets.PREFIX_DEV_API_KEY }}\n")),
            _FINDING,
            String(_R6_SECRET),
        )
    )

    # ---- documents, directives, bytes, list layout --------------------------------
    r.append(_Row(String("a directive"), String("%YAML 1.1\n---\n") + String(_PR_WF), _CANNOT, String("a directive")))
    r.append(_Row(String("a leading document marker"), String("---\n") + String(_PR_WF), _CANNOT, String("a document marker")))
    r.append(_Row(String("a second document"), String(_PR_WF) + String("---\npermissions: write-all\n"), _CANNOT, String("a document marker")))
    r.append(_Row(String("a document end"), String(_PR_WF) + String("...\n"), _CANNOT, String("a document marker")))
    r.append(_Row(String("a TAB in indentation"), _swap(String("    runs-on:"), String("\truns-on:")), _CANNOT, String("a TAB")))
    r.append(_Row(String("a carriage return"), _swap(String("    runs-on: ubuntu-24.04\n"), String("    runs-on: ubuntu-24.04\r\n")), _CANNOT, String("a carriage return")))
    r.append(
        _Row(
            String("a NEL in a comment"),
            _swap(String("permissions: {}\n"), String("# c") + chr(0x85) + String("permissions: write-all\npermissions: {}\n")),
            _CANNOT,
            String("a YAML 1.1 line break"),
        )
    )
    r.append(_Row(String("a non-ASCII value"), _fork_if(String(_FORK) + String(" ") + chr(0x2028) + String("|| true")), _CANNOT, String("outside printable ASCII")))
    r.append(_Row(String("two spaces after a list dash"), _swap(String("      - name: kci\n        run:"), String("      -   name: kci\n          run:")), _CANNOT, String("one space after")))
    r.append(_Row(String("a ': ' in a plain value"), _fork_if(String(_FORK) + String(" || 'a: b'")), _CANNOT, String("in a plain scalar")))
    return r^


def _outcome(row: _Row) raises -> String:
    """"" when the row ends as it expects, else what happened."""
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    var tokens = List[String]()
    tokens.append(String("publish-gamma"))
    var f: List[String]
    try:
        f = check_workflow(row.workflow, g, tokens, String("release/machine.textproto"), not row.release)
    except e:
        var m = String(e)
        if row.expect == _CANNOT and m.startswith(String("cannot tell: ")) and m.find(row.needle) >= 0:
            return String("")
        return String("raised: ") + m
    var all = String("")
    for i in range(len(f)):
        if row.expect == _FINDING and f[i].find(row.needle) >= 0:
            return String("")
        all += f[i] + String(" | ")
    return String("read, findings: [") + all + String("]")


def test_the_fixture_agrees() raises:
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    var tokens = List[String]()
    tokens.append(String("publish-gamma"))
    var f = check_workflow(String(_PR_WF), g, tokens, String("release/machine.textproto"), True)
    assert_equal(len(f), 0)
    var r = check_workflow(String(_REL_WF), g, tokens, String("release/machine.textproto"), False)
    assert_equal(len(r), 0)


def test_the_pr_job_may_hold_its_own_token() raises:
    # `secrets.GITHUB_TOKEN` is the job's own token, bounded by its permissions
    var g = parse_machine_file(String(_MACHINE), String("machine file"))
    var tokens = List[String]()
    tokens.append(String("publish-gamma"))
    var f = check_workflow(_step_env(String("${{ secrets.GITHUB_TOKEN }}")), g, tokens, String("release/machine.textproto"), True)
    assert_equal(len(f), 0)


def test_every_known_bypass_is_cannot_tell_or_a_finding() raises:
    var rows = _rows()
    var failed = String("")
    for i in range(len(rows)):
        var got = _outcome(rows[i])
        if got.byte_length() > 0:
            var want = String("cannot tell: ...") if rows[i].expect == _CANNOT else String("a finding with ")
            failed += String("\n  ROW '") + rows[i].label + String("': want ") + want + rows[i].needle + String("; ") + got
    if failed.byte_length() > 0:
        raise Error(String("rows not refused:") + failed)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
