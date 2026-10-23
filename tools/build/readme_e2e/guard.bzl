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
