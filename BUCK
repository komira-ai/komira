# Lints of the files at the top of the repository. Each is a validation
# (tools/build/lint/defs.bzl), so `./buck2 build //...` fails when one finds
# anything.
load("@komira//tools/build/coverage:census.bzl", "coverage_census")
load("@komira//tools/build/coverage:defs.bzl", "coverage_ci_cases")
load("@komira//tools/build/lint:defs.bzl", "action_pins", "lint_suite", "markdown_docs", "no_endpoint", "pointer_lint", "public_boundary", "retired_names", "shell_lint", "src_layout", "workflow_lint")
load("@komira//tools/build/lint:readme_api_coverage.bzl", "readme_api_coverage")
load("@komira//tools/build/lint:surface_capability_matrix.bzl", "surface_capability_matrix")
load("@komira//tools/build/lint:test_weld.bzl", "test_weld")
load("//tests:surface_capability_matrix.bzl", "CAPABILITIES", "MATRIX", "NOT_CAPABILITIES", "SURFACES")

# The licence text every published package carries (tools/build/package/conda.bzl).
export_file(name = "LICENSE", visibility = ["PUBLIC"])

# The release workflow, read by kci_workflow_check's welded test, which holds it to
# release/machine.textproto with the check `kci run` makes at start-up, so a
# drift fails `./buck2 build //...`.
export_file(
    name = "kci.yml",
    src = ".github/workflows/kci.yml",
    visibility = ["//src/kci_workflow_check:"],
)

# The pull request's check, held to the same machine file by the same welded test.
export_file(
    name = "pr.yml",
    src = ".github/workflows/pr.yml",
    visibility = ["//src/kci_workflow_check:"],
)

shell_lint(
    name = "shell_lint",
    srcs = ["buck2"] + glob([".github/ci/**/*.sh"]),
)

# The cases of the coverage workflow's two scripts (.github/workflows/coverage.yml's
# poster and .github/ci/coverage_measure.sh), against stand-ins for gh, git and
# buck2 and the real covcheck: .github/ci/tests/coverage_ci_cases.sh. A
# validation, so building this target (or `//...`) runs them.
coverage_ci_cases(
    name = "coverage_ci_cases",
    script = ".github/ci/tests/coverage_ci_cases.sh",
    srcs = [
        ".github/ci/coverage_measure.sh",
        ".github/ci/tests/build_report_branch_failed.json",
        ".github/ci/tests/build_report_gate_failed.json",
        ".github/workflows/coverage.yml",
    ],
    data = {
        "tools/build/coverage/policy.bzl": "//tools/build/coverage:policy.bzl",
        "tools/build/coverage/ratchet.tsv": "//tools/build/coverage:ratchet.tsv",
        "tools/build/mojo/coverage_branch.bzl": "//tools/build/mojo:coverage_branch.bzl",
    },
)

WORKFLOWS = glob([".github/workflows/*.yml"])

# The local actions the workflows call (.github/actions/<name>/action.yml): not
# workflows, so actionlint does not read them, but the pins and the endpoint
# lints do.
ACTIONS = glob([".github/actions/*/action.yml"])

workflow_lint(
    name = "workflow_lint",
    srcs = WORKFLOWS,
    config = ".github/actionlint.yaml",
)

action_pins(
    name = "action_pins",
    srcs = WORKFLOWS + ACTIONS,
)

no_endpoint(
    name = "no_endpoint",
    # Every committed buckconfig. The example is not one: it spells the keys, with
    # example.* addresses, so it is only searched for addresses.
    buckconfigs = [".buckconfig", "tools/build/consumer.buckconfig"],
    gitignore = ".gitignore",
    srcs = [".buckconfig.local.example"] + WORKFLOWS + ACTIONS,
)

# The layout of src/ (tools/build/lint/defs.bzl, src_layout): src/<name> holds
# what komira ships; a package that exists only to test others is
# src/tests/<kind>/<name> (e2e, conformance, helpers; docs/architecture.md
# says which). So a *_e2e, *_loopback or *_conformance package directly
# under src/ fails the build, and so does a komira_test_* one `shipped` does
# not name. The packages are read from the build graph (every BUCK file under
# src/), so a new one is checked with no edit here. `map` is the module map:
# every one of those packages has exactly one row there, and no row names a
# directory that is not a package, so a new, moved or deleted package fails
# here until the map says so. Declared in every checkout, so a repository
# using komira as a cell builds it by name.
src_layout(
    name = "src_layout",
    map = "docs/architecture.md",
    # The test libraries komira ships, directly under src/ (the harnesses
    # under src/tests/helpers build on them).
    shipped = [
        "komira_test_run_id",
        "komira_test_verdict",
    ],
)

# The shell lints of the tests cell (tools/build/tests: run_tests.sh and
# the scripts it runs). `//...` does not reach into another cell, so this
# target names them: `./buck2 build //...` fails on a finding in a test
# script as in any other. A repository using komira as a cell has no
# `tests` cell, so there the list is empty and the target is not declared.
# A package of the tests cell that holds a shell script declares its
# shell_lint and is named here. The `deps_lint` of a package whose deps are
# checked against its imports (mojo_deps) is named here too.
_TESTS_LINTS = [
    "tests//:shell_lint",
    "tests//functional/aws_codegen:shell_lint",
    "tests//functional/bundle_parity:shell_lint",
    "tests//functional/coverage:shell_lint",
    "tests//functional/darwin:shell_lint",
    "tests//functional/install_gate:shell_lint",
    "tests//functional/mem_cap:shell_lint",
    "tests//functional/platform_table:shell_lint",
    "tests//functional/test_data:shell_lint",
    "tests//functional/test_deadline:shell_lint",
    "tests//functional/watchdog:shell_lint",
    "tests//golden:shell_lint",
    # The deps of a package that names its imports (tools/build/lint, mojo_deps).
    "//src/kci_cell:deps_lint",
    "//src/komira_authz_api:deps_lint",
    "//src/komira_aws_lambda_http:deps_lint",
    "//src/komira_calendar_ics:deps_lint",
    "//src/komira_contacts:deps_lint",
    "//src/komira_http_auth:deps_lint",
    "//src/komira_http_client:deps_lint",
    "//src/komira_http_core:deps_lint",
    "//src/komira_http_server:deps_lint",
    "//src/komira_optimizer:deps_lint",
    "//src/komira_resource_gate:deps_lint",
    "//src/tests/conformance/komira_calendar_ics_conformance:deps_lint",
    "//src/tests/conformance/komira_connect_conformance:deps_lint",
    "//src/tests/conformance/komira_contacts_store_conformance:deps_lint",
    "//src/tests/conformance/komira_db_conformance:deps_lint",
    "//src/tests/conformance/komira_git_conformance:deps_lint",
    "//src/tests/conformance/komira_git_pack_conformance:deps_lint",
    "//src/tests/conformance/komira_git_protocol_conformance:deps_lint",
    "//src/tests/conformance/komira_http_conformance:deps_lint",
    "//src/tests/conformance/komira_datetime_conformance:deps_lint",
    "//src/tests/conformance/komira_json_conformance:deps_lint",
    "//src/tests/conformance/komira_plan_conformance:deps_lint",
    "//src/tests/conformance/komira_xml_conformance:deps_lint",
    "//src/tests/e2e/komira_azure_blob_e2e:deps_lint",
    "//src/tests/e2e/komira_formats_e2e:deps_lint",
    "//src/tests/e2e/komira_http_tls_e2e:deps_lint",
    "//src/tests/e2e/komira_job_supervisor_loopback:deps_lint",
    "//src/tests/e2e/komira_pandas_door_e2e:deps_lint",
    "//src/tests/e2e/komira_secrets_e2e:deps_lint",
    "//src/tests/e2e/komira_shuffle_e2e:deps_lint",
    "//src/tests/e2e/komira_tls_interop_e2e:deps_lint",
    "//src/tests/e2e/komira_udf_e2e:deps_lint",
    "//src/tests/helpers/komira_plan_harness:deps_lint",
] if read_root_config("cells", "tests") else []

[lint_suite(
    name = "tests_lints",
    lints = _TESTS_LINTS,
) for _ in _TESTS_LINTS[:1]]

# The repository's documentation: every relative link and #anchor in every
# Markdown file resolves (tools/build/lint/defs.bzl, markdown_docs), so
# `./buck2 build //...` fails on a dead link. The tree is the whole
# repository: `:doc_tree`, which every package's rules declare and which
# collects its subpackages' (tools/build/lint/doc_tree.bzl), the dotfiles
# here that a glob skips, and the tests cell's tree. No BUCK file names its
# package's files for this. The toolchains cell is not in it: it is one BUCK
# file, the template a consuming repository copies, whose targets test 7
# pins equal to a consumer's (test 17 requires it to hold no Markdown). A
# repository using komira as a cell has no `tests` cell, so there the target
# is not declared.
[markdown_docs(
    name = "docs",
    srcs = glob(["*.md"]),
    tree = [
        ".buckconfig",
        ".buckconfig.local.example",
        ".gitignore",
    ] + glob([".github/**"]),
    packages = [":doc_tree"],
    # A directory source does not descend into another cell.
    cells = {"tools/build/tests": "tests//:doc_tree"},
    # The planted dead links of test 17.
    unchecked = ["tools/build/tests/negative/doc_links/dead.md"],
) for _ in _TESTS_LINTS[:1]]

# Retired names: a package or type that was renamed may appear only in a
# dated history note (a line carrying a YYYY-MM-DD date). The tree is every
# file of the cell (`:doc_tree`) plus the dotfiles a glob skips. Each name is
# spelt in parts so this file does not hold it.
[retired_names(
    name = "retired_names",
    names = [
        "kci" + "_contract",
        "kci" + "_stage" + "_graph",
        "Stage" + "Graph",
    ],
    srcs = [".buckconfig.local.example"] + glob([".github/**"]),
    tree = ":doc_tree",
) for _ in _TESTS_LINTS[:1]]

# Test welding (tools/build/lint/test_weld.bzl): every tests/test_*.mojo under
# src/ is welded by a target, so it runs; and every package with a .mojo
# source welds a test. The exceptions are the rows of
# tests/known_untested.tsv, which only shrinks. The .mojo files are those of
# the cell (`:doc_tree`); what is welded is read from the build graph: the
# `test_srcs` of every mojo_library (mojo_proto_library's welded form is one)
# and the `main` of every mojo_test under src/, as the rules received them.
# Building this target checks nothing: `./buck2 bxl
# //tools/build/lint/test_weld.bxl:check -- --lint //:test_weld` checks it, and
# the pull request's check runs that (release/ci/build_targets.sh).
[test_weld(
    name = "test_weld",
    known_untested = "tests/known_untested.tsv",
    tree = ":doc_tree",
    welds = "//src/...",
) for _ in _TESTS_LINTS[:1]]

# README API coverage (tools/build/lint/readme_api_coverage.bzl; the rules and
# today's census: docs/readme_api_coverage.md): per package under src/ (not
# the test-only ones under src/tests/, which publish no API), the
# public API its __init__.mojo exports and which of it the README's examples
# (the welded [tests][readme] test) use. `[report]`, `[packages]` and
# `[symbols]` are the census. The tree is every file of the cell (`:doc_tree`).
# The ledger, tests/readme_api_exceptions.tsv, only shrinks: a malformed or
# repeated row, or one for a symbol no longer exported or used by its README
# now, fails the build. Report-only today: `enforce = True` makes every undocumented symbol
# without a ledger row a finding.
[readme_api_coverage(
    name = "readme_api_coverage",
    enforce = False,
    exceptions = "tests/readme_api_exceptions.tsv",
    tree = ":doc_tree",
) for _ in _TESTS_LINTS[:1]]

# The surface x capability matrix (tools/build/lint/surface_capability_matrix.bzl;
# the rules and today's census: docs/surface_capability_matrix.md): for every
# surface and every capability of the plan, the surface e2e test target that
# exercises it end to end (in src/tests/e2e/<surface>_e2e/), or `-`. The
# ledger is tests/surface_capability_matrix.bzl, Starlark so the build graph
# resolves each named target (one that does not exist fails the build). It
# fails on a malformed or lying row (a duplicate pair, an unknown name, a
# target outside its surface's package or no test), on a capability not
# grounded in the plan constants of the files `grounding` names (or a
# constant of those families no capability or NOT_CAPABILITIES row names),
# and on fewer filled cells than `floor`. Raising the floor to the new count
# in the change that fills a cell, and never lowering it, is a review rule:
# the lint fails only below it. A missing cell is never a finding:
# `[report]` and `[matrix]` are the census.
[surface_capability_matrix(
    name = "surface_capability_matrix",
    capabilities = CAPABILITIES,
    floor = 0,
    grounding = {
        "src/komira_arrow/write_target.mojo": ["WFMT_"],
        "src/komira_plan_expr/expr.mojo": ["EXPR_"],
        "src/komira_plan_expr/fs_descriptor_pod.mojo": ["FS_SCHEME_"],
        "src/komira_plan_expr/udf_data.mojo": ["UDF_KIND_"],
        "src/komira_plan_ir/logical_plan.mojo": ["PLAN_", "SOURCE_", "JOIN_"],
    },
    not_capabilities = NOT_CAPABILITIES,
    rows = MATRIX,
    surfaces = SURFACES,
    tree = ":doc_tree",
) for _ in _TESTS_LINTS[:1]]

# The coverage census (tools/build/coverage/census.md):
# docs/coverage_census.md and the floors of tools/build/coverage/ratchet.tsv
# are exactly what tools/build/coverage/census.sh renders from census.tsv, so
# the doc is never edited by hand and no floor is under what was measured.
[coverage_census(
    name = "coverage_census",
    doc = "docs/coverage_census.md",
) for _ in _TESTS_LINTS[:1]]

# The Mojo pointer rules (docs/design/mojo_safety_and_idioms.md, "What must
# always hold?"; tools/build/lint/defs.bzl, pointer_lint): over every .mojo
# file of the cell (`:doc_tree`), no wildcard origin outside an FFI module, no
# `unsafe_from_address=`, no partial move through a pointer, no `parallelize[`,
# no second declaration of libc read/open, and no public function of a library
# under src/ taking or returning a pointer. tests/pointer_lint_ffi.tsv lists
# the FFI modules (each holds a `# FFI-BOUNDARY:` comment); the sites that
# predate the lint are held, per rule and file with an exact count, in
# tests/pointer_lint_holds.tsv, which only shrinks.
[pointer_lint(
    name = "pointer_lint",
    ffi = "tests/pointer_lint_ffi.tsv",
    holds = "tests/pointer_lint_holds.tsv",
    tree = ":doc_tree",
) for _ in _TESTS_LINTS[:1]]

# The public boundary (tools/build/lint/defs.bzl, public_boundary; the reader
# tools/build/lint/public_boundary.awk says what each rule matches): no file of
# the repository (the cell's `:doc_tree`, the dotfiles a glob skips, and the
# tests cell's tree) holds a date from `window_from` up to `public_from`, a
# home directory naming a person, a private or written-out network address, a
# URL host outside the reserved example names and
# tests/public_boundary_hosts.tsv, an email address outside the reserved
# example domains, or a commit id in prose, in its contents or (dates, home
# directories, deny-list words) its path. Binary data is not read; its path
# is. Nothing committed is upstream bytes (upstream sources are pinned
# downloads), so third_party/ is read whole. Not read: the toolchains cell's
# one BUCK file, the template a consuming repository copies byte for byte
# (test 7 pins its targets equal to a consumer's copy), which so cannot export
# itself to this target; review holds it. The findings a file must keep
# (fixtures, test vectors, planted defects) are held, per rule and file at an
# exact count, in tests/public_boundary_holds.tsv, which only shrinks.
# A repository that keeps words of its own out of this one passes a list of
# them, one per line, kept outside it: `-c komira_lint.public_boundary_deny=`
# a target or a path from the root (`.public_boundary_deny` is gitignored for
# it). No row may hold a word of that list, and no such list is committed here.
[public_boundary(
    name = "public_boundary",
    cells = {"tools/build/tests": "tests//:doc_tree"},
    deny = read_root_config("komira_lint", "public_boundary_deny", None),
    holds = "tests/public_boundary_holds.tsv",
    hosts = "tests/public_boundary_hosts.tsv",
    # The tests cell's dotfile, which its doc_tree's glob skips.
    paths = {"tools/build/tests/.buckconfig": "tests//:buckconfig"},
    # The public history starts on this day. Dates before 2025 in this tree
    # are data (epochs, certificates, standards), so the window starts there.
    public_from = "2026-09-01",
    srcs = [".buckconfig", ".buckconfig.local.example", ".gitignore"] + glob([".github/**"]),
    tree = ":doc_tree",
    window_from = 2025,
) for _ in _TESTS_LINTS[:1]]
