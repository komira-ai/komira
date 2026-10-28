"""The rules of affected.bxl that are DATA, not code.

A BXL script cannot read a text file, which is why the rules are Starlark
here. `cases.bxl` holds the shipped rows to the paths that must never be
left out (the build system, the prelude, the pinned buck2, the project
configuration).

  WIDEN   a changed file matching the pattern affects EVERY target of the
          check set: a change to it cannot be mapped to the targets it
          reaches, so none is left out. Each row is (pattern, reason).
  INERT   a changed file matching the pattern that no target owns is not a
          reason to widen: it builds nothing. A change made only of such
          files reaches no target, and the selector refuses it (VACUOUS).
  HEAVY   checks that are costly and of a frozen or rarely edited program: a pull
          request that does not touch what a row owns leaves them out (below).
  UNIVERSE the target patterns of the check set: the graph the selector
          answers over, and the targets the aggregate `//ci:pr` holds
          (ci/targets.bzl). The tests cell is its `functional` tree only:
          the rest of that cell fails by design.

A pattern is a path, `dir/**` (everything under dir), `text*` (a path
starting with text) or `*text` (a path ending with text). WIDEN wins over
INERT. A file no target owns and no INERT row names widens too, so the
list never has to be complete to be safe.

This file lives under tools/build/, so changing it widens too.
"""

WIDEN = [
    (".buckconfig", "the project configuration is part of every target's configuration"),
    (".buckconfig.local.example", "the template of the machine's own configuration"),
    ("buck2", "the wrapper that runs the pinned buck2"),
    ("tools/buck2*", "the pinned buck2 changes how every action runs"),
    ("prelude/**", "the rules every target is declared with"),
    ("tools/build/**", "the Mojo rules, platforms, toolchains and build tooling are loaded by every target"),
    ("third_party/**", "a pinned third-party source or crate version reaches every target that links it"),
]

INERT = [
    "*.md",
    "LICENSE",
    ".gitignore",
    ".github/CODEOWNERS",
]

UNIVERSE = [
    # Not the toolchains cell's directory: its targets are toolchain rules, which exist
    # only configured and may not be the dependency of a plain target.
    "komira//... - komira//tools/build/cells/...",
    "tests//functional/...",
]

# The rule kinds that only name a source file or a group of them: building
# one (or a marker with no action) builds nothing, so the aggregate `//ci:pr` need not hold it and the
# completeness guard does not ask for it. Every other kind is a check.
SOURCE_KINDS = [
    "prelude//rules.bzl:export_file",
    "prelude//rules.bzl:filegroup",
    # `<name>_unmigrated`, the marker of a generated library still in the transition
    # ledger (tools/build/gen/defs.bzl): it has no action and builds nothing.
    "komira//tools/build/gen/defs.bzl:gen_unmigrated",
    # The same rule as the tests cell loads it (its kind carries the loading cell).
    "komira//tools/build/gen/defs.bzl@tests:gen_unmigrated",
]

# The aggregate every pull request check builds, and its package.
AGGREGATE = "komira//ci:pr"

# The aggregate of the same check set without the roots of HEAVY (ci/BUCK declares it from
# the generated lists), which a change that owns none of them builds instead of AGGREGATE.
DEFAULT = "komira//ci:pr_default"

# Checks left off the default set. Each row is (target, own, roots, reason):
#   target  the heavy target: one compile action that needs several GB and minutes.
#   own     the paths whose change keeps it: a change with a file matching one of these
#           (patterns as in WIDEN) builds it and everything above it; a change with none
#           leaves out the target and every check that depends on it, WIDENED or not.
#   roots   the roots of the check set (ci/targets.bzl) that reach the target: DEFAULT is
#           the check set without them, and `default_guard.bxl:check` fails when DEFAULT
#           still reaches the target or a root here reaches nothing heavy.
#   reason  why it is left off.
# What a row costs: a change outside `own` that breaks the target is not found by the pull
# request check. The release builds neither of these roots, so it is not found there either.
HEAVY = [
    (
        "komira//bin/kci:kci",
        [
            "bin/kci/**",
            "src/kci_*",
            "packaging/images/base/**",
            # the selector, the aggregates and their lists: a change to how the check set is
            # chosen runs the whole of it
            "ci/**",
            "tools/build/ci/**",
        ],
        [
            "komira//bin/kci:runnable_readme_examples",
            "komira//bin/kci:test_kci_process",
            "komira//packaging/images/base:komira_base",
        ],
        "kci is frozen and its binary is one Mojo compile of several GB; no job of the release builds it",
    ),
]

# The checks `//ci:pr` leaves out on purpose, each a (pattern, reason). Most are Python, and
# Python serves only the Python SDK and its py_tests (tests/python_closure_allowlist.bzl,
# PYTHON_SURFACE). The aggregate holds no Python rule; `python_guard.bxl:check` fails when it
# reaches one. A pattern that no longer names a package fails the generator and the guards: delete
# the row with the package. (The README e2e's targets, tools/build/readme_e2e/README.md, were
# a row here while the pinned mopm lacked `--overlay`; they are Python-free and in the check now.)
EXCLUDED = [
    ("komira//third_party/python/...", "the pinned CPython and wheels: inputs of Python tests only"),
    ("komira//release/ci/tests:", "py_test of the CI scripts, not of the Python SDK"),
    ("komira//src/tests/e2e/komira_tls_interop_e2e:test_komira_client_vs_cpython_server", "runs a CPython peer, not a test of the Python SDK"),
    ("komira//src/tests/e2e/komira_tls_interop_e2e:test_cpython_client_vs_komira_server", "runs a CPython peer, not a test of the Python SDK"),
    ("komira//src/tests/e2e/komira_tls_interop_e2e:test_komira_client_refuses_cpython_server", "runs a CPython peer, not a test of the Python SDK"),
]
