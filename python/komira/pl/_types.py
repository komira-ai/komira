"""The types komira.pl lowers by: polars 1.44.2's result type where the engine
can give it, and the type the engine computes in where it cannot compute in
that type itself.

The engine evaluates a CASE only into INT64, FLOAT64 or STRING, with every
branch of exactly that type, and casts among INT32, INT64, FLOAT32 and FLOAT64
(and from a narrower integer to a wider one or a float), not to UINT32 or to
a narrower integer than INT32 (src/batch_eval/eval_case.mojo,
src/batch_eval/project_cast.mojo). So:

- an expression of several branches (`when`, `fill_null`, the floor
  correction of `//` and `%`) is computed in its work type, INT64, FLOAT64 or
  STRING, each branch cast to it, and cast once to polars' type when that is
  INT32 or FLOAT32;
- a polars UInt32 answer (a count, `len()`, `str.len_chars()`, the sum of a
  boolean or of a UInt32) is Int64 (rules section 8, ruling 14, "count
  types"), as no cast to UInt32 runs;
- anything else is refused by name at the verb.

A Python `int` or `float` literal is "dynamic", as in polars: it takes the type
of the column beside it, and alone it is Int32 or Float64.
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation
from komira._ops import Cast, Lit, Node

__all__ = [
    "DYN_FLOAT",
    "DYN_INT",
    "NUM4",
    "SMALL_INTEGERS",
    "STRINGS",
    "case_types",
    "finish",
    "kind",
    "to_work",
]

DYN_INT = "dyn_int"
DYN_FLOAT = "dyn_float"
NULL = "null"

NUM4 = frozenset({"int32", "int64", "float32", "float64"})
SMALL_INTEGERS = frozenset({"int8", "int16", "uint8", "uint16", "uint32"})
STRINGS = frozenset({"string", "large_string", "string_view", "utf8_view"})


def kind(node: Node, scope) -> str:
    """The type of `node` as these rules read it: a dynamic literal, a null,
    or the Arrow type the engine derives."""
    if isinstance(node, Lit):
        v = node.value
        if v is None:
            return NULL
        if isinstance(v, bool):
            return "bool"
        if isinstance(v, int):
            # A literal outside Int32 is an Int64, as polars types it.
            return DYN_INT if -(2**31) <= v < 2**31 else "int64"
        if isinstance(v, float):
            return DYN_FLOAT
    return scope.arrow_type(node)


def case_types(kinds: list[str], verb: str) -> tuple[str, str]:
    """(work type, polars' result type) of an expression whose branches have
    the types `kinds`; `UnsupportedOperation` when the engine cannot compute
    it."""
    present = [k for k in kinds if k != NULL]
    if not present:
        raise UnsupportedOperation(f"{verb}: every branch is null; give one branch a value")
    if all(k in STRINGS for k in present):
        return "string", "string"
    numeric = NUM4 | {DYN_INT, DYN_FLOAT}
    if any(k in STRINGS for k in present) and all(k in STRINGS or k in numeric for k in present):
        raise UnsupportedOperation(
            f"{verb}: the branches mix strings and numbers; cast them to one type first"
        )
    for k in present:
        if k not in numeric:
            raise UnsupportedOperation(
                f"{verb}: a branch of type {k} is not supported yet; the branches must be "
                "numbers (int32, int64, float32, float64) or strings"
            )
    columns = [k for k in present if k in NUM4]
    if "float64" in columns:
        final = "float64"
    elif "float32" in columns:
        final = "float64" if ("int32" in columns or "int64" in columns) else "float32"
    elif DYN_FLOAT in present:
        final = "float64"
    elif "int64" in columns:
        final = "int64"
    else:
        final = "int32"
    return ("float64" if final.startswith("float") else "int64"), final


def to_work(node: Node, k: str, work: str) -> Node:
    """`node`, of type `k`, as a value of the work type `work`."""
    if k == work or k == NULL and work != "string":
        return node
    if k == NULL:
        return Cast(node, None, arrow="string")
    if k == DYN_INT and work == "float64":
        return Lit(float(node.value))
    if k in (DYN_INT, DYN_FLOAT) and isinstance(node, Lit):
        return node
    if work == "string":
        return node
    return Cast(node, work)


def finish(node: Node, work: str, final: str) -> Node:
    """`node`, computed in `work`, as polars' type `final`."""
    return node if work == final else Cast(node, final)
