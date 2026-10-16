"""VALUE code objects the worker must refuse at LOAD, or take, for the
worker protocol cases (native/probe_worker.c):
    not_function      a pickled int
    bad_pickle        bytes that are not a pickle
    unresolved_hints  a function whose type hint names no type
    bad_signature     a function taking a str
    good              a function int -> int
Run by tests/test_fixtures.py (a py_test), which compares what it writes
with the committed tests/fixtures/value_payloads. Writes each under its
name and out/info.txt, one line per payload:
name sha256hex. The functions are __main__'s, so cloudpickle captures them
by value.
"""

import hashlib
import os
import pickle
import sys

import cloudpickle


def unresolved(x: "NoSuchType") -> int:  # noqa: F821
    return 0


def takes_str(x: str) -> int:
    return 0


def plus_one(x: int) -> int:
    return x + 1


def _path_free(f):
    """The file name cloudpickle keeps, and the module's __file__, set to the
    script's bare name: the bytes do not depend on where the script runs."""
    f.__code__ = f.__code__.replace(co_filename="value_payloads.py")
    f.__globals__["__file__"] = "value_payloads.py"


def main(out):
    for f in (unresolved, takes_str, plus_one):
        _path_free(f)
    payloads = {
        "not_function": pickle.dumps(5, protocol=4),
        "bad_pickle": b"these bytes are not a pickle",
        "unresolved_hints": cloudpickle.dumps(unresolved, protocol=4),
        "bad_signature": cloudpickle.dumps(takes_str, protocol=4),
        "good": cloudpickle.dumps(plus_one, protocol=4),
    }
    lines = []
    for name, data in payloads.items():
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)
        lines.append("{} {}".format(name, hashlib.sha256(data).hexdigest()))
    with open(os.path.join(out, "info.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
