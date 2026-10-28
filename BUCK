# Lints of the files at the top of the repository. Each is a validation
# (tools/build/lint/defs.bzl), so `./buck2 build //...` fails when one finds
# anything.
load("@komira//tools/build/coverage:census.bzl", "coverage_census")
load("@komira//tools/build/coverage:defs.bzl", "coverage_ci_cases")
load("@komira//tools/build/lint:doc_tree.bzl", "doc_tree", "docs_checked")
load("@komira//tools/build/lint:defs.bzl", "action_pins", "lint_suite", "markdown_docs", "no_endpoint", "pointer_lint", "public_boundary", "retired_names", "shell_lint", "src_layout", "target_suite", "workflow_lint")
load("@komira//tools/build/lint:readme_api_coverage.bzl", "readme_api_coverage")
load("@komira//tools/build/lint:surface_capability_matrix.bzl", "surface_capability_matrix")
load("@komira//tools/build/lint:test_weld.bzl", "test_weld")
load("@komira//tools/build/mojo:toolchain.bzl", "zig_test")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms/limits:limits.bzl", "limits")
load("@komira//tools/build/readme_e2e:defs.bzl", "readme_e2e_complete")
load("@komira//tools/build/selftest:defs.bzl", "graph_check")
load("@komira//tools/build/ci:rules.bzl", "EXCLUDED")
load("//release/readme_e2e:packages.bzl", README_E2E_PACKAGES = "PACKAGES", README_E2E_MOPM = "MOPM", README_E2E_FIRST_MOPM_WITH_OVERLAY = "FIRST_MOPM_WITH_OVERLAY")
load("//tests:python_closure_allowlist.bzl", "PYTHON_CEILING", "PYTHON_SURFACE")
load("//tests:surface_capability_matrix.bzl", "CAPABILITIES", "MATRIX", "NOT_CAPABILITIES", "SURFACES")

# The licence text every published package carries (tools/build/package/conda.bzl).
export_file(name = "LICENSE", visibility = ["PUBLIC"])

# The files under .github/, which the root doc_tree's glob skips, at their
# paths, for the interpreter list (//tools/build/lint:interpreter_budget).
doc_tree(
    name = "github_tree",
    srcs = glob([".github/**"]),
    visibility = [
        "//tools/build/lint:interpreter_budget",
        "//tools/build/lint:no_shell",
        "//tools/build/lint:timing",
    ],
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
        "tools/build/mojo/coverage_branch.bzl": "//tools/build/mojo:coverage_branch.bzl",
    },
)

# The cases of the farm-connect action (.github/actions/farm-connect/action_test.zig
# says what each catches): its input checks and the buckconfig it writes, run
# from action.yml's own scripts with the busybox sh in a HOME of each case's
# own; and every workflow step that uses the action, which must pass `tls`
# from the FARM_TLS variable. A build action, so a failing case fails
# `./buck2 build //...`.
WORKFLOWS = glob([".github/workflows/*.yml"])

zig_test(
    name = "farm_connect_cases",
    exec_compatible_with = LINUX_X86_64,
    src = ".github/actions/farm-connect/action_test.zig",
    data = dict(
        {"action.yml": ".github/actions/farm-connect/action.yml"},
        **{w.removeprefix(".github/"): w for w in WORKFLOWS}
    ),
    busybox = "komira//tools/build/toolchains:busybox",
    zig = "komira//tools/build/toolchains:zig_next",
)

# The cases of the mopm jobs of release.yml: the continuous prod publish (each prod job's
# gate, needs, environment and permissions, the commands), no beta job, no schedule, the
# release-main concurrency group, no secret and the version of every run
# (.github/workflows/release_workflow_test.zig says what each catches). A build action.
zig_test(
    name = "release_workflow_cases",
    exec_compatible_with = LINUX_X86_64,
    src = ".github/workflows/release_workflow_test.zig",
    data = {
        "workflows/release.yml": ".github/workflows/release.yml",
        "packages.bzl": "//release/readme_e2e:packages.bzl",
        "ci.md": "docs/ci.md",
    },
    busybox = "komira//tools/build/toolchains:busybox",
    zig = "komira//tools/build/toolchains:zig_next",
)

# The cases of the macOS build of the release (.github/workflows/release_macos_test.zig says
# what each catches): the workflow release-macos.yml builds the macOS set on the farm, in a
# concurrency group of its own, and release.yml holds no macOS job; the build
# holds up nothing, no workflow that runs on a pull request names a macOS platform, the check
# set holds no macOS build, and the set's definition is one list. A build action.
zig_test(
    name = "release_macos_cases",
    exec_compatible_with = LINUX_X86_64,
    src = ".github/workflows/release_macos_test.zig",
    data = dict(
        {
            "packages.bzl": "//release/readme_e2e:packages.bzl",
            "darwin_libs.bzl": "//release:darwin_libs.bzl",
            "release.BUCK": "//release:release_buck",
            "ci_targets": "//ci:target_shards",
        },
        **{"workflows/" + w.removeprefix(".github/workflows/"): w for w in WORKFLOWS}
    ),
    busybox = "komira//tools/build/toolchains:busybox",
    zig = "komira//tools/build/toolchains:zig_next",
)

# The cases of the buck2-farm action (.github/actions/buck2-farm/action_test.zig
# says what each catches): action.yml's shape, and its two run lines run
# end to end over recorded buck2 output with the real //tools/build/ci:assert_remote.
zig_test(
    name = "buck2_farm_cases",
    exec_compatible_with = LINUX_X86_64,
    src = ".github/actions/buck2-farm/action_test.zig",
    data = {
        "action.yml": ".github/actions/buck2-farm/action.yml",
        "pr.yml": ".github/workflows/pr.yml",
        "fixtures": "//tools/build/ci:assert_remote_fixtures",
    },
    exec_tools = {
        "ASSERT_REMOTE": "//tools/build/ci:assert_remote",
        "STAND_IN_BUCK2": "//tools/build/ci:stand_in_buck2",
    },
    busybox = "komira//tools/build/toolchains:busybox",
    zig = "komira//tools/build/toolchains:zig_next",
)

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

# The README e2e covers every package moved to mopm (tools/build/readme_e2e/README.md):
# a `src/<name>/mopm.toml` with no target in //release/readme_e2e/verify fails this
# target's analysis, naming the package, and so does a target for a package that has
# none. The paths are those of the cell's root doc_tree, which holds every file.
# Analysed and never built: the e2e targets it names are not built here.
[readme_e2e_complete(
    name = "readme_e2e_complete",
    covered = sorted(README_E2E_PACKAGES.keys()),
    excluded = [p for p, _ in EXCLUDED],
    first_mopm_with_overlay = README_E2E_FIRST_MOPM_WITH_OVERLAY,
    mopm = README_E2E_MOPM,
    targets = ["//release/readme_e2e/verify:" + name for name in sorted(README_E2E_PACKAGES.keys())],
    tree = ":doc_tree",
) for _ in [1] if docs_checked()]

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
# shell_lint and is named here.
_TESTS_LINTS = [
    "tests//:shell_lint",
    "tests//functional/darwin:shell_lint",
    "tests//functional/install_gate:shell_lint",
    "tests//functional/platform_table:shell_lint",
    "tests//golden:shell_lint",
] if read_root_config("cells", "tests") else []

[lint_suite(
    name = "tests_lints",
    lints = _TESTS_LINTS,
) for _ in _TESTS_LINTS[:1]]

# The greens of the tests cell that the aggregate `//ci:pr` does not hold: it
# holds the checks of this cell and of `tests//functional/...` (rules.bzl
# UNIVERSE in tools/build/ci), so a target of tests//negative or tests//src that must build, beside the
# planted defects it serves, is named here, through its package's
# target_suite (a package's sub-targets need one too, and a suite in the same
# package names them with no visibility to grant). Not declared where there
# is no tests cell.
[target_suite(
    name = "tests_greens",
    targets = [
        "tests//negative/coverage:greens",
        "tests//src/tests/coverage:greens",
    ],
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
# spelt in parts so this file does not hold it. `unchecked` leaves out a
# fixture that must hold a retired name and cannot carry a date.
[retired_names(
    name = "retired_names",
    names = [
        "kci" + "_contract",
        "kci" + "_stage" + "_graph",
        "Stage" + "Graph",
        # The package of the superseded one-library plan for komira's C
        # (docs/design/native_packaging.md).
        "komira" + "_native",
        # A comptime core count is the core count of the build worker that
        # compiled the package, not of the machine the program runs on
        # (komira-ai/komira#994). Query std.sys.num_physical_cores() at run
        # time instead.
        "NUM" + "_CORES",
    ],
    srcs = [".buckconfig.local.example"] + glob([".github/**"]),
    tree = ":doc_tree",
    # The metadata of the release-order fixture that requires that package
    # (tools/build/package/BUCK), so that its exemption cannot come back.
    unchecked = ["tools/build/package/release_order/requires_" + "komira" + "_native.json"],
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
# the pull request's check runs that (.github/workflows/pr.yml).
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
        "src/komira_arrow/src/komira_arrow/write_target.mojo": ["WFMT_"],
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

# The coverage census (tools/build/coverage/census.md): its default output,
# coverage_census.md, is the doc tools/build/coverage/census.sh renders from
# every package's coverage_census.tsv and coverage_held, found in
# `:doc_tree` (`--show-output` prints its path; it is not committed), and the
# build fails while a package the census measured at the 99% target does not
# hold it in its coverage_held.
[coverage_census(
    name = "coverage_census",
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

# The public boundary (tools/build/lint/defs.bzl, public_boundary; the tool's
# tools/build/lint/public_boundary/src/rules.zig says what each rule matches): no file of
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
#
# The public history starts on 2026-09-01. Dates before 2025 in this tree are
# data (epochs, certificates, standards), so the window starts there. A
# narrower window would let a date through, so the values are pinned: loading
# this file fails if the window starts after 2025 or the history before
# 2026-09-01.
_PUBLIC_FROM = "2026-09-01"
_WINDOW_FROM = 2025

[fail("BUCK: public_boundary's window is from {} up to {}; the public rule's is from 2025 (or earlier) up to 2026-09-01 (or later), and a narrower window lets a date through".format(_WINDOW_FROM, _PUBLIC_FROM)) for _ in range(1) if _WINDOW_FROM > 2025 or _PUBLIC_FROM < "2026-09-01"]

[public_boundary(
    name = "public_boundary",
    cells = {"tools/build/tests": "tests//:doc_tree"},
    deny = read_root_config("komira_lint", "public_boundary_deny", None),
    holds = "tests/public_boundary_holds.tsv",
    hosts = "tests/public_boundary_hosts.tsv",
    # The tests cell's dotfile, which its doc_tree's glob skips.
    paths = {"tools/build/tests/.buckconfig": "tests//:buckconfig"},
    public_from = _PUBLIC_FROM,
    srcs = [".buckconfig", ".buckconfig.local.example", ".gitignore"] + glob([".github/**"]),
    tree = ":doc_tree",
    window_from = _WINDOW_FROM,
) for _ in _TESTS_LINTS[:1]]

# The limits of the build (tools/build/platforms/README.md, "Limits, and the
# golden"; the rule is tools/build/platforms/limits/limits.bzl): every place
# the build says it builds for one platform only carries a `komira-limit:<id>`
# marker naming a row of tools/build/platforms/limits.tsv, every row has a
# marker, and the rows are well formed, over every file of the repository but
# Markdown and the check's own directory (its sources and fixtures spell
# both). Whether a row's retiring PR has merged is the platform table's
# check, which reads git (tests//functional/platform_table).
limits(
    name = "limits",
    cells = {"tools/build/tests": "tests//:doc_tree"},
    exclude = ["tools/build/platforms/limits/"],
    limits = "tools/build/platforms/limits.tsv",
    srcs = [".buckconfig", ".buckconfig.local.example", ".gitignore"] + glob([".github/**"]),
    tree = ":doc_tree",
)

# No Python outside the Python surface (the graph check python_closure,
# tools/build/selftest/graph/python_closure.zig says what it refuses): no
# target of `//...` or `tests//functional/...` whose closure (every kind of
# dependency) holds a target under third_party/python/ or
# tools/build/python/, a Python rule or a `.py` source; no `.py` file in the
# repository; no kci textproto or GitHub workflow that runs Python. Building
# it checks nothing: .github/workflows/pr.yml runs `./buck2 bxl
# //tools/build/selftest/graph/checks.bxl:check -- --check //:python_closure`,
# as it does for every graph_check.
#
# The allowlist, tests/python_closure_allowlist.bzl: the Python surface
# (empty today) and the ceiling, every finding allowed today, which only
# shrinks.
[graph_check(
    name = "python_closure",
    check = "python_closure",
    checker = "//tools/build/selftest/graph:graph_checks",
    targets = ["//...", "tests//functional/..."],
    trees = {
        "": "//:doc_tree",
        "tools/build/tests/": "tests//:doc_tree",
    },
    srcs = [".buckconfig", ".buckconfig.local.example", ".gitignore"] + glob([".github/**"]),
    surface = PYTHON_SURFACE,
    ceiling = PYTHON_CEILING,
) for _ in _TESTS_LINTS[:1]]
