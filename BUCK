# Lints of the files at the top of the repository. Each is a validation
# (tools/build/lint/defs.bzl), so `./buck2 build //...` fails when one finds
# anything.
load("@komira//tools/build/lint:defs.bzl", "action_pins", "lint_suite", "markdown_docs", "no_endpoint", "pointer_lint", "retired_names", "shell_lint", "src_layout", "workflow_lint")
load("@komira//tools/build/lint:readme_api_coverage.bzl", "readme_api_coverage")
load("@komira//tools/build/lint:test_weld.bzl", "test_weld")

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
    srcs = ["buck2"] + glob([".github/ci/*.sh"]),
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
# src/tests/<kind>/<name> (e2e, conformance, support; docs/architecture.md
# says which). So a *_e2e, *_loopback or *_conformance package directly
# under src/ fails the build, and so does a komira_test_* one `shipped` does
# not name. The packages are read from the build graph (every BUCK file under
# src/), so a new one is checked with no edit here. Declared in every
# checkout, so a repository using komira as a cell builds it by name.
src_layout(
    name = "src_layout",
    # The test libraries komira ships, directly under src/ (the harnesses
    # under src/tests/support build on them).
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
    "tests//functional/platform_table:shell_lint",
    "tests//functional/test_data:shell_lint",
    "tests//functional/watchdog:shell_lint",
    "tests//golden:shell_lint",
    # The deps of a package that names its imports (tools/build/lint, mojo_deps).
    "//src/komira_aws_lambda_http:deps_lint",
    "//src/komira_http_client:deps_lint",
    "//src/komira_http_core:deps_lint",
    "//src/komira_http_server:deps_lint",
    "//src/tests/conformance/komira_connect_conformance:deps_lint",
    "//src/tests/conformance/komira_http_conformance:deps_lint",
    "//src/tests/conformance/komira_json_conformance:deps_lint",
    "//src/tests/e2e/komira_azure_blob_e2e:deps_lint",
    "//src/tests/e2e/komira_http_tls_e2e:deps_lint",
    "//src/tests/e2e/komira_job_supervisor_loopback:deps_lint",
    "//src/tests/e2e/komira_secrets_e2e:deps_lint",
    "//src/tests/e2e/komira_udf_e2e:deps_lint",
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
