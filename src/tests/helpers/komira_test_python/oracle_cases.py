"""oracle_run.py, the runner of every python_oracle, gives each case its verdict.

Argument: the path of oracle_run.py. Each case runs the runner in a process of
its own, as the python_oracle action does (`sys.executable -I -S
oracle_run.py ...`), on a script of oracle_cases/, and holds the exit
status, the last stderr line and the files left in `--out` to what is
expected; on a pass it also requires `--tmpdir` to be empty. They pin what
makes an oracle's output deterministic: a script whose two runs write
different bytes, files, file kinds or modes is red, and so is one that writes
a symlink, fails (raises, or exits non-zero, in either run: `second_fails.py`
exits 4 only in the second run), is killed or ends with a raw exit status
other than 0 or 1 in either run (`killed.py` dies in the first run,
`killed_second.py` only in the second, `exit_second.py` calls `os._exit(5)`
only in the second), writes nothing, or writes other files than `outs` names. `writes_tree` passes only because the runner fixes the hash
seed: its `set.txt` is a set of 64 strings in iteration order. `tz.py` pins
the zone setup each run gets: run with a relative `TZDIR`, the child sees it
absolute, as `zoneinfo`'s only path, with `TZ=UTC0`; run with none, the path
is empty (never the interpreter's built-in one, which names the worker's
/usr/share/zoneinfo).
"""

import os
import subprocess
import sys
import tempfile

RUNNER = os.path.abspath(sys.argv[1])
CASES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "oracle_cases")
TREE = ["a.txt", "copy.txt", "set.txt", "sub/b.txt"]


def files(root):
    out = []
    for parent, _, names in os.walk(root):
        out += [os.path.relpath(os.path.join(parent, n), root) for n in names]
    return sorted(out)


def run(script, outs, env=None, text=None):
    work = tempfile.mkdtemp()
    out, tmp, data = (os.path.join(work, d) for d in ("out", "tmp", "data"))
    os.makedirs(data)
    os.makedirs(os.path.join(work, "zones"))
    with open(os.path.join(data, "in.txt"), "w") as f:
        f.write("from the data directory\n")
    cmd = [sys.executable, "-I", "-S", RUNNER, "--out", out, "--tmpdir", tmp, "--data", data]
    for p in outs:
        cmd += ["--outs", p]
    cmd += ["--", os.path.join(CASES, script)]
    # From `work`, so a relative TZDIR ("zones") names work/zones.
    p = subprocess.run(cmd, capture_output=True, text=True, env=env or {}, cwd=work)
    last = p.stderr.rstrip("\n").rsplit("\n", 1)[-1] if p.stderr else ""
    if p.returncode == 0:
        assert os.listdir(tmp) == [], "{}: --tmpdir not emptied: {}".format(script, os.listdir(tmp))
    if p.returncode == 0 and script == "writes_tree.py":
        with open(os.path.join(out, "copy.txt")) as f:
            assert f.read() == "from the data directory\n", "{}: copy.txt is not the data file".format(script)
    if p.returncode == 0 and text is not None:
        with open(os.path.join(out, "tz.txt")) as f:
            got = f.read()
        assert got == text, "{}: tz.txt is {!r}, want {!r}".format(script, got, text)
    return p.returncode, last, files(out) if os.path.isdir(out) else None


CASES_TABLE = [
    # (name, script, outs, (exit status, last stderr line, files in --out))
    ("tree", "writes_tree.py", [], (0, "", TREE)),
    ("tree_outs", "writes_tree.py", TREE, (0, "", TREE)),
    ("tree_outs_short", "writes_tree.py", ["a.txt", "set.txt", "sub/b.txt"], (1, "python_oracle: writes_tree.py wrote copy.txt, which outs does not declare", TREE)),
    ("tree_outs_missing", "writes_tree.py", TREE + ["sub/c.txt"], (1, "python_oracle: writes_tree.py did not write sub/c.txt", TREE)),
    ("tree_outs_dir", "writes_tree.py", ["a.txt", "copy.txt", "set.txt", "sub"], (1, "python_oracle: writes_tree.py wrote sub/b.txt, which outs does not declare", TREE)),
    ("clock", "clock.py", [], (1, "python_oracle: two runs of clock.py differ at stamp.txt: the bytes", ["stamp.txt"])),
    ("its_path", "writes_its_path.py", [], (1, "python_oracle: two runs of writes_its_path.py differ at where.txt: the bytes", ["where.txt"])),
    ("first_only", "first_run_only.py", [], (1, "python_oracle: two runs of first_run_only.py differ at once.txt: only the first run wrote it", ["always.txt", "once.txt"])),
    ("exec_bit", "exec_bit.py", [], (1, "python_oracle: two runs of exec_bit.py differ at tool.sh: the executable bit", ["tool.sh"])),
    ("nothing", "writes_nothing.py", [], (1, "python_oracle: writes_nothing.py wrote nothing", [])),
    ("symlink", "symlink.py", [], (1, "python_oracle: symlink.py wrote a symlink at link", ["a.txt", "link"])),
    ("raises", "raises.py", [], (1, "python_oracle: raises.py failed: ValueError: planted: 7", [])),
    ("exits", "exits.py", [], (1, "python_oracle: exits.py failed: SystemExit: 3", [])),
    ("second_fails", "second_fails.py", [], (1, "python_oracle: second_fails.py failed: SystemExit: 4", ["always.txt"])),
    ("kind", "kind.py", [], (1, "python_oracle: two runs of kind.py differ at x: a dir in the first run, a file in the second", ["always.txt"])),
    ("killed", "killed.py", [], (1, "python_oracle: the first run of killed.py exited -9", [])),
    ("killed_second", "killed_second.py", [], (1, "python_oracle: the second run of killed_second.py exited -9", ["always.txt"])),
    ("exit_second", "exit_second.py", [], (1, "python_oracle: the second run of exit_second.py exited 5", ["always.txt"])),
]

# (name, environment, what tz.py writes)
TZ_TABLE = [
    ("tz_with_tzdir", {"TZDIR": "zones"}, "TZDIR zones\n"),
    ("tz_without_tzdir", {}, "no TZDIR\n"),
]

bad = []
for name, env, text in TZ_TABLE:
    try:
        got = run("tz.py", [], env, text)
    except AssertionError as e:
        got = str(e)
    if got != (0, "", ["tz.txt"]):
        bad.append("{}: got {!r}, want {!r}".format(name, got, (0, "", ["tz.txt"])))
    else:
        print("ok", name)
for name, script, outs, want in CASES_TABLE:
    got = run(script, outs)
    if got != want:
        bad.append("{}: got {!r}, want {!r}".format(name, got, want))
    else:
        print("ok", name)
assert not bad, "\n".join(bad)
