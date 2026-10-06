# Lints of the files at the top of the repository. Each is a validation
# (tools/build/lint/defs.bzl), so `./buck2 build //...` fails when one finds
# anything.
load("@komira//tools/build/lint:defs.bzl", "action_pins", "lint_suite", "markdown_docs", "no_endpoint", "retired_names", "shell_lint", "workflow_lint")
load("@komira//tools/build/lint:test_weld.bzl", "test_weld")

# The licence text every published package carries (tools/build/package/conda.bzl).
export_file(name = "LICENSE", visibility = ["PUBLIC"])

# The release workflow, read by kci_ci_check's welded test, which holds it to
# release/machine.textproto with the check `kci run` makes at start-up, so a
# drift fails `./buck2 build //...`.
export_file(
    name = "kci.yml",
    src = ".github/workflows/kci.yml",
    visibility = ["//src/kci_ci_check:"],
)

# The pull request's check, held to the same machine file by the same welded test.
export_file(
    name = "pr.yml",
    src = ".github/workflows/pr.yml",
    visibility = ["//src/kci_ci_check:"],
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
# src/ is named by a BUCK file, so it runs; every package with a .mojo source
# welds a test; and no package welds fewer test files or test functions than
# its row in tests/coverage_floor.tsv. The exceptions are the rows of
# tests/known_untested.tsv, which only shrinks. The tree is every file of the
# cell (`:doc_tree`).
[test_weld(
    name = "test_weld",
    coverage_floor = "tests/coverage_floor.tsv",
    known_untested = "tests/known_untested.tsv",
    tree = ":doc_tree",
) for _ in _TESTS_LINTS[:1]]
