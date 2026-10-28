"""The hello test of python_binding_test: pyarrow imports and builds a table,
and the Mojo shared library `plain` (examples/shared_lib) is loaded by path
with ctypes and called.

    hello_test.py --lib-dir <dir> [--add-expect N] [--sum-expect N]

`--lib-dir` is put first by the rule. The expectations default to the right
answers; a twin target passes a wrong one to show the test fails on a wrong
result.
"""

import ctypes
import os
import sys

import pyarrow as pa


def flag(args, name, default):
    if name in args:
        return int(args[args.index(name) + 1])
    return default


def main(args):
    libdir = args[args.index("--lib-dir") + 1]
    path = os.path.join(libdir, "plain.so")
    if not os.path.exists(path):
        raise FileNotFoundError("the lib dir has no plain.so: " + ", ".join(sorted(os.listdir(libdir))))
    lib = ctypes.CDLL(path)

    lib.plain_add.argtypes = [ctypes.c_int32, ctypes.c_int32]
    lib.plain_add.restype = ctypes.c_int32
    lib.plain_sum_squares.argtypes = [ctypes.c_int32]
    lib.plain_sum_squares.restype = ctypes.c_int64

    # Arrow data goes in, the library's answers come out into a table.
    xs = pa.array([1, 2, 3, 40], type=pa.int32())
    adds = [lib.plain_add(x, 2) for x in xs.to_pylist()]
    table = pa.table({"x": xs, "x_plus_2": pa.array(adds, type=pa.int32())})
    assert table.num_rows == 4, table.num_rows
    assert table.column("x_plus_2").to_pylist() == [3, 4, 5, 42], table.column("x_plus_2").to_pylist()

    got = lib.plain_add(40, 2)
    want = flag(args, "--add-expect", 42)
    assert got == want, "plain_add(40, 2) = %d, want %d" % (got, want)
    got = lib.plain_sum_squares(10)
    want = flag(args, "--sum-expect", 285)
    assert got == want, "plain_sum_squares(10) = %d, want %d" % (got, want)
    print("hello: pyarrow %s, %d rows, plain.so called" % (pa.__version__, table.num_rows))


if __name__ == "__main__":
    main(sys.argv[1:])
