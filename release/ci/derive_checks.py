"""The derived checks: the `derive_checks` command of the buck2 build system
in release/artifacts.textproto.

  python3 release/ci/derive_checks.py <units file>   # what kci runs
  python3 release/ci/derive_checks.py --from release/artifacts.textproto
                                                     # the same answer, for a reader

The per-change check (`kci run --stage pr --affected-by <base>`) builds units:
the artifacts and checks release/artifacts.textproto declares, and the checks
this tool derives from the live build graph when the check runs. kci hands it
a units file (`<unit>\t<target>` per target of every declared unit) and reads
its answer on stdout (the protocol is src/kci_artifact_proto/artifact.proto's
header):

  CHECK <name> <pattern>     a target pattern of the derived check <name>
  UNMATCHED <unit> <target>  a declared target that matches nothing in the
                             graph (kci refuses it for an artifact and reports
                             it as a notice for a check)
  DERIVED <n>                last: the number of derived checks

THE UNIVERSE is `//...` and `tests//functional/...` (what `./buck2 build //...`
and `./buck2 build tests//functional/...` build), configured for the default
target platform, as `buck2 cquery` sees it: a target incompatible with that
platform is not in it. It is read from the graph on every run; no list of it
is kept in the tree.

THE DERIVATION. Every target of the universe that no declared target names
(an exact label) or matches (a pattern `<cell>//<path>/...` or
`<cell>//<path>:`) is put in its path group, and each group with such a target
is a derived check naming the group's pattern: one check per library package
`//src/<p>/...` (named `<p>`), `repo_root` (`//:`), `tools_<t>` for each
`//tools/<t>/...`, `<d>` for any other top directory `//<d>/...`, and
`functional_tests` (`tests//functional/...`); `-` and `.` become `_`. A name a
declared unit holds gets `_package` (the rest of that artifact's package):
artifacts and checks are one name space. So every target of the universe is
in some unit by construction, a package added to the tree is in a derived
check with no edit anywhere, and a deleted one is simply no longer derived.

Naming a target that DEPENDS on another is not enough for coverage: buck2
builds only the outputs a dependent consumes, so a library's conda package
does not build the library's own default output, and with it the library's
welded tests. That is why the derivation covers every TARGET, not the roots.

`buck2` is found on PATH, or set BUCK2 (e.g. BUCK2=./buck2).
"""

import os
import re
import subprocess
import sys

UNIVERSE = ["//...", "tests//functional/..."]


def _label(configured):
    """`komira//a:b (cfg)` -> `//a:b`; `tests//a:b (cfg)` -> `tests//a:b`."""
    lab = configured.split(" (")[0].strip()
    if lab.startswith("komira//"):
        lab = lab[len("komira"):]
    return lab


def _buck2(args):
    exe = os.environ.get("BUCK2", "buck2")
    out = subprocess.run([exe] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        raise SystemExit("derive_checks.py: buck2 %s failed (exit %d)" % (" ".join(args), out.returncode))
    return out.stdout


def universe():
    """Every target of the universe, from the live graph, sorted."""
    labels = {_label(l) for l in _buck2(["cquery", " + ".join(UNIVERSE)]).splitlines() if l.strip()}
    if not labels:
        raise SystemExit("derive_checks.py: the universe is empty; it cannot be")
    return sorted(labels)


def _split(label):
    """`<cell>//<pkg>:<name>` -> (cell, pkg, name)."""
    cell, _, rest = label.partition("//")
    pkg, _, name = rest.partition(":")
    return cell, pkg, name


def is_pattern(t):
    """`<cell>//<path>/...` (a package and every package below it) or
    `<cell>//<path>:` (the targets of one package; `//:` is the root's)."""
    if "//" not in t:
        return False
    if t.endswith("/..."):
        return len(t.split("//", 1)[1]) > len("/...")
    return t.endswith(":") and ":" not in t[:-1]


def matches(t, label):
    """A unit's target `t` (a pattern or an exact label) names `label`."""
    if not is_pattern(t):
        return t == label
    cell, pkg, _ = _split(label)
    if t.endswith("/..."):
        pcell, _, root = t[: -len("/...")].partition("//")
        return cell == pcell and (pkg == root or pkg.startswith(root + "/"))
    pcell, _, root = t[:-1].partition("//")
    return cell == pcell and pkg == root


def check_name(label, taken=frozenset()):
    """The derived check a target maps to (the grouping by path)."""
    cell, pkg, _ = _split(label)
    if cell == "tests":
        return "functional_tests"
    parts = pkg.split("/")
    if parts == [""]:
        return "repo_root"
    if parts[0] == "src" and len(parts) > 1:
        name = parts[1]
    elif parts[0] == "tools" and len(parts) > 1:
        name = "tools_" + parts[1]
    else:
        name = parts[0]
    name = re.sub(r"[.-]", "_", name)
    if name in taken:
        name += "_package"
    return name


def group_pattern(label):
    """The pattern of `label`'s path group (check_name's grouping)."""
    cell, pkg, _ = _split(label)
    if cell == "tests":
        return UNIVERSE[1]
    parts = pkg.split("/")
    if parts == [""]:
        return "//:"
    if parts[0] in ("src", "tools"):
        if len(parts) == 1:
            return "//%s:" % parts[0]
        return "//%s/%s/..." % (parts[0], parts[1])
    return "//%s/..." % parts[0]


def derive(declared, labels):
    """(checks, unmatched): checks is [(name, [patterns])] in output order;
    unmatched is [(unit, target)] of declared targets matching no label.
    `declared` is [(unit, target)] in unit order."""
    targets = [t for _, t in declared]
    unmatched = [(u, t) for u, t in declared if not any(matches(t, lab) for lab in labels)]
    taken = {u for u, _ in declared}
    groups = {}
    for lab in labels:
        if any(matches(t, lab) for t in targets):
            continue
        pattern = group_pattern(lab)
        if not matches(pattern, lab):
            raise SystemExit("derive_checks.py: the group pattern %s does not match %s" % (pattern, lab))
        groups.setdefault(check_name(lab, taken), set()).add(pattern)
    order = sorted(groups, key=lambda n: (min(groups[n]).startswith("tests//"), min(groups[n])))
    return [(n, sorted(groups[n])) for n in order], unmatched


def answer(declared, labels):
    checks, unmatched = derive(declared, labels)
    out = []
    for unit, target in unmatched:
        out.append("UNMATCHED %s %s" % (unit, target))
    for name, patterns in checks:
        for p in patterns:
            out.append("CHECK %s %s" % (name, p))
    out.append("DERIVED %d" % len(checks))
    return "\n".join(out) + "\n", len(checks), len(unmatched)


def read_units_file(path):
    declared = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            parts = line.split("\t")
            if len(parts) != 2 or not parts[0] or not parts[1]:
                raise SystemExit("derive_checks.py: %s: line %d is not <unit>\\t<target>" % (path, n))
            declared.append((parts[0], parts[1]))
    return declared


def read_artifacts_file(path):
    """[(unit, target)] of the artifacts and checks of a textproto artifacts
    file, read loosely (for a reader; kci hands the tool its units file)."""
    declared = []
    unit = None
    for line in open(path):
        if re.match(r"^(artifacts|checks) \{$", line.rstrip()):
            unit = ""
            continue
        if line.startswith("}"):
            unit = None
            continue
        if unit is None:
            continue
        s = line.strip()
        m = re.match(r'^name: "([^"]+)"$', s)
        if m and unit == "":
            unit = m.group(1)
        m = re.match(r'^targets: "([^"]+)"$', s)
        if m:
            declared.append((unit, m.group(1)))
    return declared


def main(argv):
    if len(argv) == 2 and not argv[1].startswith("-"):
        declared = read_units_file(argv[1])
    elif len(argv) == 3 and argv[1] == "--from":
        declared = read_artifacts_file(argv[2])
    else:
        sys.stderr.write(__doc__)
        return 2
    labels = universe()
    text, n, u = answer(declared, labels)
    sys.stdout.write(text)
    sys.stderr.write(
        "derive_checks.py: %d targets, %d declared target(s), %d derived check(s), %d unmatched\n"
        % (len(labels), len(declared), n, u)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
