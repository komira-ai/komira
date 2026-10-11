"""The committed Python-made fixtures (tests/fixtures) against their
generators (producer/*.py), on the pinned interpreter and wheels.

The Mojo tests read only the committed files: the VALUE closure's payload
(closure/payload.gz, gunzipped by the code_layer rule), the VALUE payloads
the worker must refuse or take (value_payloads/), and one-column batches as
pyarrow writes them (pyarrow_batches.txt). This test is where a change in
pickling or in pyarrow's IPC layout shows:

  - every committed file has the sha256 tests/fixtures/SHA256SUMS records
    (closure payloads after gunzip), and closure/info.json names the
    payload's sha256 (a fixture edited by hand, or a stale record);
  - each generator, run as __main__ (cloudpickle captures __main__'s
    functions by value), writes exactly the committed bytes: the same file
    names, the same contents (a cloudpickle, numpy or pyarrow pin that
    changes the bytes, or a generator edited without its fixture).

Mutant planted: make_closure.py's model[0, 0] 1.8 -> 1.9: red here (the
payload differs), while the Mojo tests, reading the committed payload, stay
as they were.
"""

import gzip
import hashlib
import json
import os
import runpy
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
PRODUCER = os.path.join(HERE, "..", "producer")
FAILURES = []


def check(cond, what):
    if not cond:
        FAILURES.append(what)


def committed(rel):
    """A committed fixture's bytes; a closure payload gunzipped."""
    if rel.startswith("closure/payload"):
        with gzip.open(os.path.join(FIX, rel + ".gz"), "rb") as f:
            return f.read()
    with open(os.path.join(FIX, rel), "rb") as f:
        return f.read()


def sums():
    out = {}
    with open(os.path.join(FIX, "SHA256SUMS")) as f:
        for line in f:
            sha, rel = line.split()
            out[rel] = sha
    return out


def generate(script):
    """Runs producer/<script> as __main__ into a new directory; returns
    {relative name: bytes}."""
    out = tempfile.mkdtemp()
    argv = sys.argv
    sys.argv = [os.path.join(PRODUCER, script), out]
    try:
        runpy.run_path(sys.argv[0], run_name="__main__")
    finally:
        sys.argv = argv
    got = {}
    for name in sorted(os.listdir(out)):
        with open(os.path.join(out, name), "rb") as f:
            got[name] = f.read()
    return got


def main():
    recorded = sums()
    for rel, sha in recorded.items():
        check(hashlib.sha256(committed(rel)).hexdigest() == sha, "{}: not the sha256 SHA256SUMS records".format(rel))
    info = json.loads(committed("closure/info.json"))
    check(info["sha256"] == recorded.get("closure/payload"), "closure/info.json names another payload")

    want = {
        "make_closure.py": ("closure", ["info.json", "payload", "payload_bad"]),
        "value_payloads.py": (
            "value_payloads",
            ["bad_pickle", "bad_signature", "good", "info.txt", "not_function", "unresolved_hints"],
        ),
        "pyarrow_batches.py": ("", ["batches.txt"]),
    }
    for script, (where, names) in want.items():
        got = generate(script)
        check(sorted(got) == names, "{} wrote {}".format(script, sorted(got)))
        for name in names:
            rel = "pyarrow_batches.txt" if script == "pyarrow_batches.py" else where + "/" + name
            check(got.get(name) == committed(rel), "{}: {} differs from the committed tests/fixtures/{}".format(
                script, name, rel))
    if FAILURES:
        for f in FAILURES:
            print("test_fixtures: " + f)
        sys.exit(1)
    print("test_fixtures: ok")


if __name__ == "__main__":
    main()
