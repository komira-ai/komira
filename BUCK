# Lints of the files at the top of the repository. Each is a validation
# (tools/build/lint/defs.bzl), so `./buck2 build //...` fails when one finds
# anything.
load("@komira//tools/build/lint:defs.bzl", "action_pins", "lint_suite", "markdown_docs", "no_endpoint", "push_verdicts", "shell_lint", "workflow_lint")

# The licence text every published package carries (tools/build/package/conda.bzl).
export_file(name = "LICENSE", visibility = ["PUBLIC"])

shell_lint(
    name = "shell_lint",
    srcs = ["buck2"] + glob([".github/ci/*.sh"]),
)

WORKFLOWS = glob([".github/workflows/*.yml"])

workflow_lint(
    name = "workflow_lint",
    srcs = WORKFLOWS,
    config = ".github/actionlint.yaml",
)

action_pins(
    name = "action_pins",
    srcs = WORKFLOWS,
)

push_verdicts(
    name = "push_verdicts",
    srcs = WORKFLOWS,
)

no_endpoint(
    name = "no_endpoint",
    # Every committed buckconfig. The example is not one: it spells the keys, with
    # example.* addresses, so it is only searched for addresses.
    buckconfigs = [".buckconfig", "tools/build/consumer.buckconfig"],
    gitignore = ".gitignore",
    srcs = [".buckconfig.local.example"] + WORKFLOWS,
)

# The shell lints of the tests cell (tools/build/tests: run_tests.sh and
# the scripts it runs). `//...` does not reach into another cell, so this
# target names them: `./buck2 build //...` fails on a finding in a test
# script as in any other. A repository using komira as a cell has no
# `tests` cell, so there the list is empty and the target is not declared.
# A package of the tests cell that holds a shell script declares its
# shell_lint and is named here.
_TESTS_LINTS = [
    "tests//:shell_lint",
    "tests//functional/aws_codegen:shell_lint",
    "tests//functional/bundle_parity:shell_lint",
    "tests//functional/darwin:shell_lint",
    "tests//functional/test_data:shell_lint",
    "tests//functional/watchdog:shell_lint",
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
