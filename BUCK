# Lints of the files at the top of the repository. Each is a validation
# (tools/build/lint/defs.bzl), so `./buck2 build //...` fails when one finds
# anything.
load("@komira//tools/build/lint:defs.bzl", "action_pins", "no_endpoint", "shell_lint", "workflow_lint")

shell_lint(
    name = "shell_lint",
    srcs = ["buck2"] + glob([".githooks/*", ".github/ci/*.sh"]),
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

no_endpoint(
    name = "no_endpoint",
    buckconfig = ".buckconfig",
    gitignore = ".gitignore",
    srcs = [".buckconfig.local.example"] + WORKFLOWS,
)
