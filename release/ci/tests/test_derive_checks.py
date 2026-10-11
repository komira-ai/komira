"""The cases of release/ci/derive_checks.py's answer when its universe query
fails, run by the py_test //release/ci/tests:test_derive_checks as a build
action: building the target is running them.

The rule they hold: ANY failure of the query (buck2 exits non-zero, or
cannot be started) is one `BROKEN <reason>` line on stdout, exit 0, which
kci turns into a FAILED check (KCI-E-BUILD-FAILED). Before, the script
exited non-zero and kci answered INDETERMINATE (KCI-E-AFFECTED). buck2's
error is in the reason; the target it names, when it names one, leads it
and decides nothing. The stderr texts are what buck2 printed, byte for
byte, for `cquery '//... + tests//...'` over a tree with one planted target
in tools/build/ci/BUCK.

- the unknown-dependency text (buck2's "dependency chain follows" form) and
  the invisible-dependency text ("Error looking up configured node") are
  each BROKEN, naming the planted target: a reader that recognised only one
  form, or that decided by the text, is red.
- a transport failure that names no target, and a buck2 that cannot be
  started, are BROKEN too: a script that let either through as an exit
  (INDETERMINATE) or an empty answer is red.
- a stderr over 8 KiB keeps its first and last 4 KiB: a tail-only cut
  loses the chain's header, and the name with it.
- a healthy universe still answers CHECK lines and DERIVED: a script that
  answered BROKEN always is red.
"""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import derive_checks  # noqa: E402  (staged next to this file by the py_test)

UNKNOWN_DEPENDENCY_STDERR = '''[2026-10-09T23:48:30.370-05:00] Starting new buck2 daemon...
[2026-10-09T23:48:30.435-05:00] Connected to new buck2 daemon.
[2026-10-09T23:48:30.437-05:00] Build ID: 7bfa5b7e-ebba-42e0-b748-640e03bc7d92
Command failed: 
Error in configured node dependency, dependency chain follows (-> indicates depends on, ^ indicates same configuration as previous):
       komira//tools/build/ci:planted_unknown (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)
    -> komira//src/komira_hash:no_such_target_here (^)


Caused by:
    0: looking up unconfigured target node `komira//src/komira_hash:no_such_target_here`
    1: Unknown target `no_such_target_here` from package `komira//src/komira_hash`.
       Did you mean one of the 3 targets in komira//src/komira_hash:BUCK?
       
       Available targets:
         komira//src/komira_hash:doc_tree
         komira//src/komira_hash:komira_hash
         komira//src/komira_hash:komira_hash_conda
'''
UNKNOWN_DEPENDENCY_LABEL = "komira//tools/build/ci:planted_unknown"

INVISIBLE_DEPENDENCY_STDERR = '''[2026-10-09T23:48:34.256-05:00] Build ID: a1ce274c-c2d5-4960-a8cf-59f4c55b7d84
[2026-10-09T23:48:34.270-05:00] File changed: komira//tools/build/ci/BUCK
Command failed: 
Error looking up configured node komira//tools/build/ci:planted_invisible (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)

Caused by:
    `komira//third_party/node:node` is not visible to `komira//tools/build/ci:planted_invisible` (run `buck2 uquery --output-attribute visibility komira//third_party/node:node` to check the visibility)
'''
INVISIBLE_DEPENDENCY_LABEL = "komira//tools/build/ci:planted_invisible"

TRANSPORT_STDERR = (
    "Command failed: \nError: the remote execution service did not answer in 600s"
    " (transport error: connection reset by peer)\n"
)

QUERY = "buck2 cquery //... + tests//functional/..."


def _completed(code, stdout="", stderr=""):
    return subprocess.CompletedProcess(args=["buck2"], returncode=code, stdout=stdout, stderr=stderr)


def _run(fake):
    """main() over a one-line units file, buck2 answered by `fake`:
    (exit code, stdout, stderr)."""
    with tempfile.TemporaryDirectory() as d:
        units = os.path.join(d, "units.tsv")
        with open(units, "w") as f:
            f.write("lints\t//docs:\n")
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(derive_checks.subprocess, "run", fake):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = derive_checks.main(["derive_checks.py", units])
        return code, out.getvalue(), err.getvalue()


class TheUniverseQueryFailingIsBroken(unittest.TestCase):
    def assertBroken(self, stdout, named, cause):
        lines = stdout.split("\n")
        self.assertEqual(len(lines), 2, stdout)
        self.assertEqual(lines[1], "")
        head = "BROKEN the universe query failed"
        if named:
            head += ", naming " + named
        self.assertTrue(lines[0].startswith(head + ": " + QUERY), stdout)
        self.assertIn(cause, lines[0])

    def test_an_unknown_dependency_is_broken(self):
        code, out, _ = _run(lambda *a, **k: _completed(3, stderr=UNKNOWN_DEPENDENCY_STDERR))
        self.assertEqual(code, 0)
        self.assertBroken(out, UNKNOWN_DEPENDENCY_LABEL, "Unknown target `no_such_target_here`")

    def test_an_invisible_dependency_is_broken(self):
        code, out, _ = _run(lambda *a, **k: _completed(3, stderr=INVISIBLE_DEPENDENCY_STDERR))
        self.assertEqual(code, 0)
        self.assertBroken(out, INVISIBLE_DEPENDENCY_LABEL, "is not visible to")

    def test_any_other_failure_is_broken(self):
        code, out, _ = _run(lambda *a, **k: _completed(1, stderr=TRANSPORT_STDERR))
        self.assertEqual(code, 0)
        self.assertBroken(out, "", "failed (exit 1): Command failed: Error: the remote execution service")
        self.assertIn("connection reset by peer", out)

    def test_a_buck2_that_cannot_start_is_broken(self):
        def missing(*a, **k):
            raise FileNotFoundError(2, "No such file or directory", "buck2")

        code, out, _ = _run(missing)
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("BROKEN the universe query failed: " + QUERY + " could not be started"), out)

    def test_a_long_stderr_keeps_both_ends(self):
        long = UNKNOWN_DEPENDENCY_STDERR + "y" * 20000 + "THE-LAST-LINE"
        kept = derive_checks.kept_stderr(long)
        self.assertTrue(kept.startswith(long[:4096]))
        self.assertTrue(kept.endswith(long[-4096:]))
        self.assertIn("[... %d bytes of buck2's stderr cut ...]" % (len(long) - 8192), kept)
        self.assertEqual(derive_checks.kept_stderr(UNKNOWN_DEPENDENCY_STDERR), UNKNOWN_DEPENDENCY_STDERR)
        code, out, _ = _run(lambda *a, **k: _completed(3, stderr=long))
        self.assertBroken(out, UNKNOWN_DEPENDENCY_LABEL, "THE-LAST-LINE")

    def test_a_healthy_universe_still_derives(self):
        stdout = "komira//src/new_pkg:new_pkg (komira//tools/build/platforms:linux-x86_64#0)\n"
        code, out, _ = _run(lambda *a, **k: _completed(0, stdout=stdout))
        self.assertEqual(code, 0)
        self.assertEqual(out, "UNMATCHED lints //docs:\nCHECK new_pkg //src/new_pkg/...\nDERIVED 1\n")


if __name__ == "__main__":
    unittest.main()
