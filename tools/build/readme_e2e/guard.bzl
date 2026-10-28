"""The completeness guard of the README e2e: every package a release moves to mopm has an e2e target.

A package is moved when `src/<name>/mopm.toml` exists. `findings` is pure: it takes the paths of the
cell's files (the root `doc_tree` holds them all) and the package names that have a target in
//release/readme_e2e/verify, and answers what is out of step, or "". The rule that applies it is
`readme_e2e_complete` (defs.bzl); cases.bxl holds its cases.
"""

def moved_packages(paths):
    """The names of the packages that have a `src/<name>/mopm.toml` in `paths`, sorted."""
    names = []
    for p in paths:
        parts = p.split("/")
        if len(parts) == 3 and parts[0] == "src" and parts[2] == "mopm.toml" and parts[1]:
            names.append(parts[1])
    return sorted(names)

def findings(paths, covered):
    """What is out of step between the moved packages of `paths` and the names in `covered`, as one text; "" when none."""
    moved = moved_packages(paths)
    lacking = [m for m in moved if m not in covered]
    stale = sorted([c for c in covered if c not in moved])
    problems = []
    if lacking:
        problems.append("{} moved package(s) have no README e2e target: {}. Add each to PACKAGES in release/readme_e2e/packages.bzl (its version is the one in its mopm.toml)".format(len(lacking), ", ".join(lacking)))
    if stale:
        problems.append("{} README e2e target(s) are for a package with no src/<name>/mopm.toml: {}. Delete each from PACKAGES in release/readme_e2e/packages.bzl".format(len(stale), ", ".join(stale)))
    return "; ".join(problems)

# The row of EXCLUDED (tools/build/ci/rules.bzl) that leaves the release's README e2e out of the
# pull request check while the pinned mopm cannot install with `--overlay`.
EXCLUDED_PATTERN = "komira//release/readme_e2e/verify:"

def _mopm_version(label):
    """The version of a mopm label such as `toolchains//:mopm_0_0_25`, as a tuple of numbers."""
    name = label.split(":")[-1]
    if not name.startswith("mopm_"):
        fail("{} is not a mopm label (`...:mopm_<major>_<minor>_<patch>`)".format(label))
    return tuple([int(n) for n in name[len("mopm_"):].split("_")])

def mopm_findings(mopm, first_with_overlay, excluded):
    """What is out of step between the pinned `mopm`, the first mopm with `--overlay`, and the EXCLUDED rows; "" when none.

    `first_with_overlay` is the label of the first mopm that has `mopm add --overlay`, or None while
    no release has it. `excluded` are the patterns of EXCLUDED. The row of `EXCLUDED_PATTERN` is
    present exactly while `mopm` predates the first one with `--overlay`, so the pin bump that makes
    the e2e installable is the change that puts it into the pull request check.
    """
    has_overlay = first_with_overlay != None and _mopm_version(mopm) >= _mopm_version(first_with_overlay)
    row = EXCLUDED_PATTERN in excluded
    if has_overlay and row:
        return "MOPM ({}) has --overlay (first: {}), and EXCLUDED of tools/build/ci/rules.bzl still leaves {} out of //ci:pr. Delete that row, then regenerate ci/targets.bzl".format(mopm, first_with_overlay, EXCLUDED_PATTERN)
    if not has_overlay and not row:
        return "MOPM ({}) has no --overlay (first: {}), and EXCLUDED of tools/build/ci/rules.bzl has no row for {}: the pull request check would build targets that fail at their install step. Restore the row, or pin a mopm that has --overlay and set FIRST_MOPM_WITH_OVERLAY in release/readme_e2e/packages.bzl".format(mopm, first_with_overlay, EXCLUDED_PATTERN)
    return ""
