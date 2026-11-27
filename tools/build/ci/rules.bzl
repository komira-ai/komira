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
          (one file per root, ci/roots/: roots.bzl). The tests cell is its `functional` tree only:
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
#   roots   the roots of the check set (ci/roots/, roots.bzl) that reach the target: DEFAULT is
#           the check set without them, and `default_guard.bxl:check` fails when DEFAULT
#           still reaches the target or a root here reaches nothing heavy.
#   reason  why it is left off.
# What a row costs: a change outside `own` that breaks the target is not found by the pull
# request check. The release builds neither of these roots, so it is not found there either.
# No row ships today: the mechanism stays, held by heavy_cases.bzl over rows written there.
HEAVY = []

# The checks `//ci:pr` leaves out on purpose, each a (pattern, reason). Most are Python, and
# Python serves only the Python SDK and its py_tests (tests/python_closure_allowlist.bzl,
# PYTHON_SURFACE). The aggregate holds no Python rule; `python_guard.bxl:check` fails when it
# reaches one. A pattern that no longer names a package fails the generator and the guards: delete
# the row with the package. (The README e2e's targets, tools/build/readme_e2e/README.md, were
# a row here while the pinned mopm lacked `--overlay`; they are Python-free and in the check now.)
EXCLUDED = [
    ("komira//third_party/python/...", "the pinned CPython and wheels: inputs of Python tests only"),
    ("komira//release/ci/tests:", "py_test of the CI scripts, not of the Python SDK"),
    ("komira//release:mopm_darwin_libs", "the macOS arm64 build of the release: it is built for the darwin-arm64 platform on the farm's macOS workers by release-macos.yml (job release-macos) and by pr.yml's macOS part (tools/build/ci/darwin.bxl), never by the Linux part of the check (a Linux build of its libraries is the aggregate's own)"),
    ("komira//release:mopm_release_artifacts", "the directory release.yml's mopm-stage stages: //release:mopm_artifacts and the macOS set, which its transition configures for darwin-arm64, so it needs the macOS execution platform that only the step building it registers (and it is incompatible without -c komira_release.mac_tree=true); pr.yml's last step configures and analyses it (release/darwin_analysis.bxl), and both its halves are checked on their own (//release:mopm_artifacts by the aggregate, the macOS set by pr.yml's macOS part)"),
    ("komira//python:komira_wheel_macos_arm64", "the macOS arm64 wheel: it is built for the darwin-arm64 platform on the farm's macOS workers by pypi.yml (job build-macos-arm64), and never by a pull request (the Linux wheel and the wheel rule's own cases are the aggregate's)"),
    ("komira//python:tpch_via_wheel_test", "TPC-H q1 to q22 at scale factor 1 through the installed wheel against DuckDB: 22 engine queries over staged sf1 data, a validation run and not a build-and-unit-test check (B9); it is built on request (`./buck2 build komira//python:tpch_via_wheel_test`), and the answer check it uses is held in the pull request by `//python/tests:tpch_compare_test`"),
    ("komira//python:wheel_install_test_macos_arm64", "the macOS arm64 wheel's install test: it runs on the farm's macOS workers in pypi.yml (job build-macos-arm64), and never in a pull request (the Linux install tests are the aggregate's)"),
    ("komira//python/docs/tasks:examples_macos_arm64", "the common-task examples on the macOS arm64 wheel: built for darwin-arm64 on the farm's macOS workers by release-macos.yml (step `build the macOS Python harness tests`), never by a pull request (each example's Linux run, `komira//python/docs/tasks:<rank>-<slug>`, is the aggregate's, through `komira//python/docs/tasks:examples`)"),
    ("komira//python/docs/task_tree_fixture/...", "the two task trees of tools/build/ci/tasks_cases.bzl, configured by cases.bxl to hold that a task directory added changes no generated target list; their wheel and driver are placeholders, so they are analysed and never built (a change to them alone selects only these, so the selector answers with the whole aggregate)"),
    ("komira//python/tests:pyarrow-25.0.1-cp313-cp313-macosx_12_0_arm64.whl", "the pinned macOS arm64 pyarrow wheel, which only the macOS wheel's install test reads (komira//python:wheel_install_test_macos_arm64, above): it is compatible with darwin-arm64 alone, so a change to python/tests/BUCK that selects it by name would fail the Linux build as incompatible"),
    ("komira//python/tests:protobuf-7.36.2-cp310-abi3-macosx_10_9_universal2.whl", "the pinned macOS protobuf wheel, which only the macOS wheel's install test reads (komira//python:wheel_install_test_macos_arm64, above): it is compatible with darwin-arm64 alone, so a change to python/tests/BUCK that selects it by name would fail the Linux build as incompatible"),
    ("komira//python:wheel_libs_macos_arm64", "the macOS arm64 wheel read back, its libraries loaded from it alone: built for darwin-arm64 by pypi.yml (job build-macos-arm64) only, never by a pull request (the Linux wheel's check and the tool's unit tests are the aggregate's)"),
    ("komira//python:wheel_same_macos_arm64", "the macOS arm64 wheel held to the Linux wheel's package: built for darwin-arm64 by pypi.yml (job build-macos-arm64) only, never by a pull request (the tool's unit tests are the aggregate's)"),
    ("komira//python/smoke:pypi_smoke_macos_arm64", "the smoke driver built for macOS arm64, which pypi.yml's smoke jobs run on a hosted macOS runner; built for darwin-arm64 by pypi.yml (job build-macos-arm64) only (the Linux driver and its unit tests are the aggregate's)"),
    ("komira//node:package_macos_arm64", "the macOS arm64 npm platform package: it is built for the darwin-arm64 platform on the farm's macOS workers by npm.yml (job build-macos-arm64), and never by a pull request (the linux-x64 package and the npm rule's own cases are the aggregate's); pr.yml's last step configures and analyses it (release/darwin_analysis.bxl)"),
    ("komira//node:install_test_macos_arm64", "the npm packages' macOS arm64 install test: it runs on the farm's macOS workers in npm.yml (job build-macos-arm64), and never in a pull request (the Linux install test, //node:install_test, is the aggregate's); pr.yml's last step configures and analyses it (release/darwin_analysis.bxl)"),
    ("komira//release:npm_packages_macos_arm64", "the npm release set with the macOS arm64 package, which its transition configures for darwin-arm64, so it needs the macOS execution platform that only npm.yml's macOS job registers (and it is incompatible without -c komira_release.mac_tree=true); pr.yml's last step configures and analyses it (release/darwin_analysis.bxl), and its Linux half is the aggregate's (//release:npm_packages, //node:package_with_macos_arm64)"),
    ("komira//src/tests/e2e/komira_tls_interop_e2e:test_komira_client_vs_cpython_server", "runs a CPython peer, not a test of the Python SDK"),
    ("komira//src/tests/e2e/komira_tls_interop_e2e:test_cpython_client_vs_komira_server", "runs a CPython peer, not a test of the Python SDK"),
    ("komira//src/tests/e2e/komira_tls_interop_e2e:test_komira_client_refuses_cpython_server", "runs a CPython peer, not a test of the Python SDK"),
]
