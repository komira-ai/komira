# Lints of the files at the top of the repository. Each is a validation
# (tools/build/lint/defs.bzl), so `./buck2 build //...` fails when one finds
# anything.
load("@komira//tools/build/lint:defs.bzl", "action_pins", "lint_suite", "markdown_docs", "no_endpoint", "push_verdicts", "shell_lint", "workflow_lint")

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
    "tests//functional/bundle_parity:shell_lint",
    "tests//functional/darwin:shell_lint",
    "tests//functional/numa:shell_lint",
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
# repository: this package's own files, the doc_tree target of every other
# package (each names only its own files), and the tests cell's. Test 17
# fails when a package of either cell is missing from it. A repository
# using komira as a cell has no `tests` cell, so there the target is not
# declared.
[markdown_docs(
    name = "docs",
    srcs = glob(["*.md"]),
    tree = glob(["**"], exclude = ["*.md"]) + [
        ".buckconfig",
        ".buckconfig.local.example",
        ".gitignore",
    ] + glob([".github/**"]),
    packages = [
        "//src/kci_logs:doc_tree",
        "//src/kci_params:doc_tree",
        "//src/kci_validator_rows:doc_tree",
        "//src/komira_atomic_alias:doc_tree",
        "//src/komira_core_ffi:doc_tree",
        "//src/komira_crypto:doc_tree",
        "//src/komira_lz4:doc_tree",
        "//src/komira_protobuf:doc_tree",
        "//src/komira_resources:doc_tree",
        "//src/komira_rowcell:doc_tree",
        "//src/komira_snapshotter:doc_tree",
        "//src/komira_uuid:doc_tree",
        "//src/komira_validation_run:doc_tree",
        "//src/komira_xml:doc_tree",
        "//src/komira_zlib:doc_tree",
        "//third_party/aws-lc:doc_tree",
        "//third_party/rust:doc_tree",
        "//third_party/s2n-tls:doc_tree",
        "//third_party/snappy:doc_tree",
        "//tools/build/examples:doc_tree",
        "//tools/build/examples/aws_lc:doc_tree",
        "//tools/build/examples/cshim:doc_tree",
        "//tools/build/examples/libgate_ok:doc_tree",
        "//tools/build/examples/rust:doc_tree",
        "//tools/build/examples/s2n_tls:doc_tree",
        "//tools/build/examples/snappy:doc_tree",
        "//tools/build/inspect:doc_tree",
        "//tools/build/lint:doc_tree",
        "//tools/build/mojo:doc_tree",
        "//tools/build/mojo/darwin:doc_tree",
        "//tools/build/mojo/runtime_paths:doc_tree",
        "//tools/build/package:doc_tree",
        "//tools/build/package/launcher:doc_tree",
        "//tools/build/platforms:doc_tree",
        "//tools/build/platforms/default:doc_tree",
        "//tools/build/proto-codegen:doc_tree",
        "//tools/build/rust:doc_tree",
        "//tools/build/third_party_srcs:doc_tree",
        "//tools/build/toolchains:doc_tree",
        "//tools/build/toolchains/darwin:doc_tree",
        "//tools/build/toolchains/proto:doc_tree",
        "//tools/build/toolchains/rust:doc_tree",
    ],
    # A directory source does not descend into another cell.
    cells = {"tools/build/tests": "tests//:doc_tree"},
    # The planted dead links of test 17.
    unchecked = ["tools/build/tests/negative/doc_links/dead.md"],
) for _ in _TESTS_LINTS[:1]]
