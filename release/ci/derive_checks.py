"""The derived checks: the `derive_checks` command of the buck2 build system
in release/artifacts.textproto.

  python3 release/ci/derive_checks.py <units file>   # what kci runs
  python3 release/ci/derive_checks.py --from release/artifacts.textproto
                                                     # the same answer, for a reader
  python3 release/ci/derive_checks.py --selftest     # the naming and pattern tables (SELFTEST, PATTERN_SELFTEST)

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
  BROKEN <reason>            alone, instead of the above: the universe query
                             failed, for any reason (a target with an
                             unknown or invisible dependency, a transport
                             error); the reason is one line holding buck2's
                             error (its stderr whole up to 8 KiB, else the
                             first and last 4 KiB). kci FAILS the check
                             (KCI-E-BUILD-FAILED): a graph the tool cannot
                             query is never a widening. The target buck2
                             names, when it names one, leads the reason; it
                             decides nothing.

THE UNIVERSE is `//...` and `tests//functional/...` (what `./buck2 build //...`
and `./buck2 build tests//functional/...` build), configured for the default
target platform, as `buck2 cquery` sees it: a target incompatible with that
platform is not in it. It is read from the graph on every run; no list of it
is kept in the tree.

THE DERIVATION. Every target of the universe that no declared target names
(an exact label) or matches (a pattern `<cell>//<path>/...` or
`<cell>//<path>:`) is put in its path group, and each group with such a target
is a derived check naming the group's pattern: one check per library package
`//src/<p>/...` (named `<p>`) and per test-only package
`//src/tests/<kind>/<p>/...` (named `<p>`: src/tests is not a package but
holds them by kind), `repo_root` (`//:`), `tools_<t>` for each
`//tools/<t>/...`, `<d>` for any other top directory `//<d>/...`, and
`functional_tests` (`tests//functional/...`). A name is one kci accepts,
`[a-z][a-z0-9_]*`, whatever the directory is called: upper case becomes lower,
any other character outside `[a-z0-9_]` becomes `_`, and a name that does not
start with a letter gets `pkg_` before it; groups whose names meet are one
check. A name a declared unit holds gets `_package` (the rest of that
artifact's package), again until it is free: artifacts and checks are one
name space. So every target of the universe is in some unit by construction,
a package added to the tree is in a derived check with no edit anywhere, and a
deleted one is simply no longer derived. Every run first holds the naming to
the table SELFTEST and answers nothing (exit 1) if it fails; it also refuses
to answer a name kci would refuse.

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

# A name kci accepts for a unit (src/kci_artifact/validate.mojo,
# is_valid_artifact_name).
VALID_NAME = re.compile(r"^[a-z][a-z0-9_]*$")


def _label(configured):
    """`komira//a:b (cfg)` -> `//a:b`; `tests//a:b (cfg)` -> `tests//a:b`."""
    lab = configured.split(" (")[0].strip()
    if lab.startswith("komira//"):
        lab = lab[len("komira"):]
    return lab


STDERR_KEPT_WHOLE = 8192
STDERR_KEPT_EACH_END = 4096


class QueryFailed(Exception):
    """A buck2 query that failed; the text is buck2's error."""


def kept_stderr(text):
    """buck2's stderr as a failure carries it: whole up to 8 KiB, else the
    first and last 4 KiB around a line saying how many bytes were cut."""
    raw = text.encode("utf-8", "replace")
    if len(raw) <= STDERR_KEPT_WHOLE:
        return text
    head = raw[:STDERR_KEPT_EACH_END].decode("utf-8", "replace")
    tail = raw[-STDERR_KEPT_EACH_END:].decode("utf-8", "replace")
    return "%s\n[... %d bytes of buck2's stderr cut ...]\n%s" % (head, len(raw) - 2 * STDERR_KEPT_EACH_END, tail)


_LOOKUP = re.compile(r"Error looking up configured node\s+(\S+)")
_CHAIN = re.compile(r"dependency chain follows[^\n]*?\):\s+(\S+)")


def named_target(error):
    """For the message only, never for a decision: the target buck2's
    error names as one it could not configure (`Error looking up configured
    node <label>`, or the first label of a `dependency chain follows`), or
    ""."""
    m = _LOOKUP.search(error) or _CHAIN.search(error)
    return m.group(1) if m else ""


def broken_line(error):
    """The answer when the universe query failed: one `BROKEN` line."""
    reason = "the universe query failed"
    named = named_target(error)
    if named:
        reason += ", naming " + named
    reason += ": " + error
    return "BROKEN " + " ".join(reason.split()) + "\n"


def _buck2(args):
    exe = os.environ.get("BUCK2", "buck2")
    try:
        out = subprocess.run([exe] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as e:
        raise QueryFailed("buck2 %s could not be started: %s" % (" ".join(args), e))
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        raise QueryFailed("buck2 %s failed (exit %d): %s" % (" ".join(args), out.returncode, kept_stderr(out.stderr)))
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
    if parts[:2] == ["src", "tests"] and len(parts) > 3:
        name = parts[3]
    elif parts[0] == "src" and len(parts) > 1:
        name = parts[1]
    elif parts[0] == "tools" and len(parts) > 1:
        name = "tools_" + parts[1]
    else:
        name = parts[0]
    # A directory name is not constrained; a unit name is: lower case, every
    # other character `_`, and `pkg_` before one that does not start with a
    # letter. Two groups whose names meet are one check.
    name = re.sub(r"[^a-z0-9_]", "_", re.sub(r"[A-Z]", lambda m: m.group(0).lower(), name))
    if not re.match(r"[a-z]", name):
        name = "pkg_" + name
    while name in taken:
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
    if parts[:2] == ["src", "tests"]:
        # src/tests holds the test-only packages by kind: one group each.
        if len(parts) > 3:
            return "//src/tests/%s/%s/..." % (parts[2], parts[3])
        return "//%s:" % "/".join(parts)
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
    for name, _ in checks:
        if not VALID_NAME.match(name):
            raise SystemExit("derive_checks.py: the derived check name %r is not [a-z][a-z0-9_]*" % name)
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


# THE SELF-TEST: (label, declared unit names, the check name it must get).
# Each name must also be one kci accepts, `[a-z][a-z0-9_]*`.
SELFTEST = [
    ("//src/komira_clock:komira_clock", [], "komira_clock"),
    ("//src/komira-x.y:t", [], "komira_x_y"),
    ("//src/Komira_Up:komira_clock", [], "komira_up"),
    ("//src/3d:t", [], "pkg_3d"),
    ("//src/_x:t", [], "pkg__x"),
    ("//src/komira+x:t", [], "komira_x"),
    ("//src/komira\u00e9:t", [], "komira_"),
    ("//Bench/a:t", [], "bench"),
    ("//tools/Foo:t", [], "tools_foo"),
    ("//tools/9z:t", [], "tools_9z"),
    ("//src:t", [], "src"),
    ("//src/tests/e2e/komira_x_e2e:t", [], "komira_x_e2e"),
    ("//src/tests/helpers/komira_y/sub:t", [], "komira_y"),
    ("//src/tests/e2e:t", [], "tests"),
    ("//src/tests:t", [], "tests"),
    ("//:t", [], "repo_root"),
    ("tests//functional/x:t", [], "functional_tests"),
    ("//src/Komira_Up:t", ["komira_up"], "komira_up_package"),
    ("//src/a:t", ["a", "a_package"], "a_package_package"),
]


# THE PATTERN SELF-TEST: (label, the pattern of the derived check it lands
# in). A check's pattern is what kci builds for it, so a test-only package
# must keep a pattern of its own, not one shared by all of src/tests.
PATTERN_SELFTEST = [
    ("//src/komira_clock:komira_clock", "//src/komira_clock/..."),
    ("//src/tests/e2e/komira_x_e2e:t", "//src/tests/e2e/komira_x_e2e/..."),
    ("//src/tests/conformance/komira_c_conformance:t", "//src/tests/conformance/komira_c_conformance/..."),
    ("//src/tests/helpers/komira_y/sub:t", "//src/tests/helpers/komira_y/..."),
    ("//src/tests/e2e:t", "//src/tests/e2e:"),
]


def selftest():
    """The failures of SELFTEST and PATTERN_SELFTEST (each a line of text); none is green."""
    failures = []
    for label, want in PATTERN_SELFTEST:
        got = group_pattern(label)
        if got != want:
            failures.append("group_pattern(%s): %r, want %r" % (label, got, want))
        checks, _ = derive([], [label])
        if checks != [(check_name(label), [want])]:
            failures.append("derive() over %s: %r, want the one check %r with [%r]" % (label, checks, check_name(label), want))
    for label, taken, want in SELFTEST:
        got = check_name(label, frozenset(taken))
        if got != want or not VALID_NAME.match(got):
            failures.append("%s (taken %s): %r, want %r" % (label, taken, got, want))
    checks, _ = derive([("u_%d" % i, "//nothing:%d" % i) for i in range(2)], [l for l, _, _ in SELFTEST])
    for name, _ in checks:
        if not VALID_NAME.match(name):
            failures.append("derive() answered check %r" % name)
    return failures


def main(argv):
    if argv[1:] == ["--selftest"]:
        failures = selftest()
        for f in failures:
            sys.stderr.write("derive_checks.py selftest: RED: %s\n" % f)
        sys.stderr.write("derive_checks.py selftest: %s (%d cases)\n" % ("RED" if failures else "GREEN", len(SELFTEST) + len(PATTERN_SELFTEST)))
        return 1 if failures else 0
    # The naming is held on every run: a name kci refuses would turn the
    # check red for a change that only added a package.
    failures = selftest()
    if failures:
        sys.stderr.write("derive_checks.py: the check naming is wrong: %s\n" % "; ".join(failures))
        return 1
    if len(argv) == 2 and not argv[1].startswith("-"):
        declared = read_units_file(argv[1])
    elif len(argv) == 3 and argv[1] == "--from":
        declared = read_artifacts_file(argv[2])
    else:
        sys.stderr.write(__doc__)
        return 2
    try:
        labels = universe()
    except QueryFailed as e:
        # Any failure of the query, whatever buck2 printed: the check fails.
        sys.stdout.write(broken_line(str(e)))
        sys.stderr.write("derive_checks.py: BROKEN: the universe query failed\n")
        return 0
    text, n, u = answer(declared, labels)
    sys.stdout.write(text)
    sys.stderr.write(
        "derive_checks.py: %d targets, %d declared target(s), %d derived check(s), %d unmatched\n"
        % (len(labels), len(declared), n, u)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
