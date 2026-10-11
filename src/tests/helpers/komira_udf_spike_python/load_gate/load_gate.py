"""The load gate: the Mojo runtime starts inside a library loaded by the
embedding host, here CPython (ctypes.CDLL, which releases the GIL around
each call, so engine threads are never blocked on it).

Arguments: the library (load_gate.so) and the Mojo runtime libraries'
directory (lib/ of a runnable Mojo program). The library's run path is
$ORIGIN/lib, so it is copied into a scratch directory beside a link to that
lib/ directory, as a packaged copy would ship it.

Each case runs in a child interpreter of its own, whose exit status is
recorded (a crash is a status, not a lost test):
  main      the call from the interpreter's main thread;
  thread    the call from one threading.Thread (a thread the host made);
  threads4  the call from 4 threading.Threads at once (N > 1).
Each must print the expected sum and exit 0. The outcome of each is pinned
below; a change either way turns this red.

Defects caught: a library whose Mojo runtime libraries are not found
through its run path; a runtime that cannot start in a foreign process, or
that crashes when first entered from a thread it did not create (an
earlier engine segfaulted that way, with no Python involved).

Mutant planted: the link to lib/ left out of the scratch directory: red
(main exits 1, the library does not load).
"""

import os
import shutil
import subprocess
import sys
import tempfile

N = 1000
WANT = sum(i * i for i in range(N))

CHILD = r"""
import ctypes, sys, threading
lib = ctypes.CDLL(sys.argv[1])
f = lib.komira_udf_spike_load_gate
f.argtypes = [ctypes.c_int64]
f.restype = ctypes.c_int64
mode = sys.argv[2]
want = int(sys.argv[3])
got = []
def call():
    got.append(f(1000))
if mode == "main":
    call()
else:
    ts = [threading.Thread(target=call) for _ in range(1 if mode == "thread" else 4)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
assert got and all(g == want for g in got), got
print("ok", mode, len(got))
"""

# mode -> the exit status the child must end with.
PINNED = {"main": 0, "thread": 0, "threads4": 0}


def main(lib, runtime_lib_dir):
    d = tempfile.mkdtemp()
    so = os.path.join(d, "load_gate.so")
    shutil.copy(lib, so)
    os.symlink(os.path.abspath(runtime_lib_dir), os.path.join(d, "lib"))
    got = {}
    for mode in PINNED:
        r = subprocess.run(
            [sys.executable, "-I", "-S", "-c", CHILD, so, mode, str(WANT)],
            capture_output=True,
            text=True,
            timeout=120,
        )
        got[mode] = r.returncode
        print(mode, "exit", r.returncode, r.stdout.strip(), r.stderr.strip()[-400:])
    assert got == PINNED, "exit statuses {}, pinned {}".format(got, PINNED)


main(sys.argv[1], sys.argv[2])
