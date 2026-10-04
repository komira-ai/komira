"""The unit census: the build targets the per-change check must reach.

  python3 release/ci/unit_census.py --write   # rewrite release/unit_census.txt
  python3 release/ci/unit_census.py --check   # exit 1 when it is not current

The per-change check (`kci run --stage pr --affected-by <base>`) builds units
of release/artifacts.textproto: artifacts, checks and expect_red units, each
naming targets. A target that is in no unit's dependency closure would never
be built by the check. The census is the set of targets whose closures cover
everything: every ROOT of the universe (a target no other target of the
universe depends on) and every test target (`buck2 test` runs it, so building
it as a dependency is not enough).

The universe is `//...` and `tests//functional/...` (what `./buck2 build //...`
and `./buck2 build tests//functional/...` build), configured for the default
target platform, as `buck2 cquery` sees it: a target incompatible with that
platform is not in it. The edges are every dependency `cquery deps(_, 1)`
follows (exec and toolchain deps included), compared by unconfigured label.

The welded test src/kci_artifact/tests/test_release_artifacts_file.mojo
holds release/artifacts.textproto to the census: every census target is a
target of some unit. --check holds the census to the graph; the pr job of
.github/workflows/kci.yml runs it before `kci run`. So a new target that no
unit reaches fails the pull request until it is added to a unit (and here).

--check prints, for each target missing from the census, the check of
release/artifacts.textproto its package maps to (the file's grouping rule).
"""

import os
import re
import subprocess
import sys

UNIVERSE = ["//...", "tests//functional/..."]
CENSUS = "release/unit_census.txt"
HEADER = """\
# The unit census (release/ci/unit_census.py, which says what it is): every
# target of release/artifacts.textproto's universe that some unit must name.
# Generated: run `python3 release/ci/unit_census.py --write` after a BUCK
# change; `--check` (the pr job of .github/workflows/kci.yml) fails while this
# file is not current, and the welded test of release/artifacts.textproto
# fails while a target here is in no unit.
"""

_EDGE = re.compile(r'^\s*"([^"]+)" -> "([^"]+)"')


def _label(configured):
    """`komira//a:b (cfg)` -> `//a:b`; `tests//a:b (cfg)` -> `tests//a:b`."""
    lab = configured.split(" (")[0].strip()
    if lab.startswith("komira//"):
        lab = lab[len("komira"):]
    return lab


def _buck2(args):
    out = subprocess.run(["buck2"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        raise SystemExit("unit_census.py: buck2 %s failed (exit %d)" % (" ".join(args), out.returncode))
    return out.stdout


def census():
    """The census, from the live graph: sorted labels."""
    expr = " + ".join(UNIVERSE)
    universe = {_label(l) for l in _buck2(["cquery", expr]).splitlines() if l.strip()}
    tests = {_label(l) for l in _buck2(["cquery", 'kind("test", %s)' % expr]).splitlines() if l.strip()}
    depended = set()
    for line in _buck2(["cquery", "deps(%s, 1)" % expr, "--output-format", "dot"]).splitlines():
        m = _EDGE.match(line)
        if m:
            a, b = _label(m.group(1)), _label(m.group(2))
            if a != b:
                depended.add(b)
    if not universe:
        raise SystemExit("unit_census.py: the universe is empty; the census cannot be empty")
    return sorted((universe - depended) | (tests & universe))


def check_name(label):
    """The check a target maps to (release/artifacts.textproto's grouping):
    `//src/<p>/...` -> `<p>` (one check per library package), the root
    package -> `repo_root`, `//tools/<t>/...` -> `tools_<t>`, any other
    `//<d>/...` -> `<d>`, the tests cell -> `functional_tests`; `-` and `.`
    become `_`."""
    cell, _, rest = label.partition("//")
    if cell == "tests":
        return "functional_tests"
    parts = rest.split(":")[0].split("/")
    if parts == [""]:
        return "repo_root"
    if parts[0] == "src" and len(parts) > 1:
        name = parts[1]
    elif parts[0] == "tools" and len(parts) > 1:
        name = "tools_" + parts[1]
    else:
        name = parts[0]
    return re.sub(r"[.-]", "_", name)


def _read(path):
    return [l.strip() for l in open(path) if l.strip() and not l.startswith("#")]


def main(argv):
    if len(argv) != 2 or argv[1] not in ("--write", "--check"):
        sys.stderr.write(__doc__)
        return 2
    now = census()
    if argv[1] == "--write":
        with open(CENSUS, "w") as f:
            f.write(HEADER)
            for lab in now:
                f.write(lab + "\n")
        print("unit_census.py: wrote %s (%d targets)" % (CENSUS, len(now)))
        return 0
    old = _read(CENSUS) if os.path.exists(CENSUS) else []
    added = sorted(set(now) - set(old))
    gone = sorted(set(old) - set(now))
    for lab in added:
        print("NEW %s (its unit: the check %s)" % (lab, check_name(lab)))
    for lab in gone:
        print("GONE %s" % lab)
    if added or gone:
        print("unit_census.py: %s is not current: run python3 release/ci/unit_census.py --write, and add each NEW"
              " target to a unit of release/artifacts.textproto" % CENSUS)
        return 1
    print("unit_census.py: %s is current (%d targets)" % (CENSUS, len(now)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
