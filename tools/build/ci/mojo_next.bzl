"""The Mojo 1.2.0 part of the pull request check: which of the affected targets are built and tested with the second Mojo compiler.

    mojo_next_select(affected, aggregates) -> struct(kind, targets, reason)

`affected` is the list the selector printed (tools/build/ci/affected.bxl: one label per line, the
targets a change reaches, or an aggregate of the check set). `aggregates` maps each aggregate of the
check set to its twin without the coverage roots (ci/BUCK: `//ci:pr` -> `//ci:pr_mojo_next`,
`//ci:pr_default` -> `//ci:pr_default_mojo_next`).

pr.yml builds the answer with `--target-platforms komira//tools/build/platforms:linux-x86_64-mojo-1.2.0`
(tools/build/toolchains/mojo_versions.bzl), then tests the standalone tests of it:

  WHOLE    the list holds an aggregate: its twin, the same check set without the coverage roots.
  SOME     every label of the list except the coverage roots, in the list's order, once each.
  NONE     the change reaches nothing but coverage roots, or nothing: no 1.2.0 build.
  BROKEN   a line of `affected` is not a target label: the selector's output changed shape, and
           reading it as NONE would pass a change 1.2.0 never built. mojo_next.bxl fails on it.

Coverage is measured with the default compiler only (pr.yml's `build`, and coverage.yml): line and
branch figures, and the IR the branch tools read, are the compiler's, so one compiler's are the
floors. A coverage root is a package's `:coverage` or `:coverage_floor`, or a target of the coverage
tools' own fixtures (`tests//functional/coverage`, `tests//negative/coverage`), which hold one
compiler's counters and reports. Every other target, the libraries, binaries and tests of the same
packages included, is built and tested with both compilers.
"""

load(":rules.bzl", "AGGREGATE", "DEFAULT")

# Each aggregate of the check set, and its twin without the coverage roots (ci/BUCK).
TWINS = {
    AGGREGATE: "komira//ci:pr_mojo_next",
    DEFAULT: "komira//ci:pr_default_mojo_next",
}

WHOLE = "WHOLE"
SOME = "SOME"
NONE = "NONE"
BROKEN = "BROKEN"

# The targets of each package that measure coverage, by name.
COVERAGE_NAMES = ["coverage", "coverage_floor"]

# The packages of the coverage tools' own fixtures: every target of them holds one compiler's figures.
COVERAGE_FIXTURES = ["tests//functional/coverage", "tests//negative/coverage"]

def _normal(label):
    # The selector prints cell-qualified labels; a bare `//` label is the komira cell's.
    label = label.strip()
    if label.startswith("//"):
        return "komira" + label
    return label

def is_coverage_root(label):
    """Whether `label` (cell-qualified) measures coverage: see the module documentation."""
    package, _, name = label.rpartition(":")
    if name in COVERAGE_NAMES:
        return True
    for fixture in COVERAGE_FIXTURES:
        if package == fixture or package.startswith(fixture + "/"):
            return True
    return False

def mojo_next_select(affected, aggregates):
    """See the module documentation."""
    labels = []
    seen = {}
    for line in affected:
        label = _normal(line)
        if not label:
            continue
        if "//" not in label or ":" not in label.split("//", 1)[1]:
            return struct(kind = BROKEN, targets = [], reason = "{} is not a target label: the selector's output changed shape".format(repr(line)))
        if label not in seen:
            seen[label] = True
            labels.append(label)
    for label in labels:
        if label in aggregates:
            return struct(kind = WHOLE, targets = [aggregates[label]], reason = "the change is built as {}, so 1.2.0 builds {}".format(label, aggregates[label]))
    picked = [t for t in labels if not is_coverage_root(t)]
    if not picked:
        return struct(kind = NONE, targets = [], reason = "the change reaches no target but coverage roots" if labels else "the change reaches no target")
    return struct(kind = SOME, targets = picked, reason = "{} of the {} affected targets ({} coverage roots left to the default compiler)".format(len(picked), len(labels), len(labels) - len(picked)))

def mojo_next_answer(affected, aggregates):
    """What mojo_next.bxl:select does with `affected`: struct(failure, log, stdout).

    `failure` is the message it fails with (BROKEN), else None; `log` is the one line it prints to
    the log, `mojo_next: <KIND>: <reason>`; `stdout` the labels it prints, one per line.
    """
    verdict = mojo_next_select(affected, aggregates)
    if verdict.kind == BROKEN:
        return struct(failure = "mojo_next: BROKEN: " + verdict.reason, log = None, stdout = [])
    return struct(failure = None, log = "mojo_next: {}: {}".format(verdict.kind, verdict.reason), stdout = verdict.targets)
