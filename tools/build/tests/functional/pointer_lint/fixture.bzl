"""The planted tree of test 41 (the pointer lint), as {path in the tree: file}.

held.mojo holds sites of every rule, and holds.tsv holds each rule at its
exact count there: a site the reader misses leaves a row above its count,
which fails the build, so `ok` building proves each one is found. They are
the forms a statement takes: a field, a dunder, a return type, a trait
method and a six-line signature (public_pointer); two origins in one
signature (wildcard_origin); `unsafe_from_address = ` over three lines;
`UnsafePointer(to=r.f).take_pointee()` on one line, over three, with type
parameters, and the two-statement form, the name plain and typed
(partial_move); `parallelize[` and `algorithm.parallelize[`; and
`external_call["read"` (with a trailing comment, and after a string
holding an escaped quote and `#`) and a three-line
`external_call["open"`.

near.mojo names every banned spelling where it is not a site: in a
docstring, a comment and string literals, inside a longer identifier, in a
field, a private method, a private struct, a private function, a nested
function, a whole-value or subscript move, a field's address never taken
from or rebound before the take, a name bound in one function or method and
taken in another, `external_call` of write, readlink and openat, a banned call in
a trailing comment (after a string holding `#` and an escaped quote), and
a triple quote inside a comment. A public
pointer signature in a private module (_impl.mojo), in a test file (of
komira_a, and of komira_c_e2e, a test-only package under src/tests/e2e/)
and outside src/ (tools/) is not a site; ffi.mojo, which ffi.tsv lists, names
two wildcard origins; ffi_clean.mojo is marked FFI-BOUNDARY and names none.
functional/pointer_lint/BUCK exports the files, so negative/pointer_lint
plants its defects in the same tree.
"""

_DIR = "tests//functional/pointer_lint:"

POINTER_TREE = {
    "src/komira_a/__init__.mojo": _DIR + "init.txt",
    "src/komira_a/_impl.mojo": _DIR + "private_module.txt",
    "src/komira_a/ffi.mojo": _DIR + "ffi.txt",
    "src/komira_a/ffi_clean.mojo": _DIR + "ffi_clean.txt",
    "src/komira_a/held.mojo": _DIR + "held.txt",
    "src/komira_a/near.mojo": _DIR + "near.txt",
    "src/komira_a/tests/test_a.mojo": _DIR + "test_file.txt",
    "src/tests/e2e/komira_c_e2e/tests/test_c.mojo": _DIR + "test_file.txt",
    "tools/gen/main.mojo": _DIR + "tool.txt",
}

POINTER_FFI = _DIR + "ffi.tsv"

POINTER_HOLDS = _DIR + "holds.tsv"
