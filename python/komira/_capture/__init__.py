"""Capture of a user function for the komira/python runtime (private).

`udf` declares a function's call shape, types and read set; `Udf.spec()`
captures it once into a `komira._ops._expr.UdfSpec`, and `write_code` puts the
code object the spec names under a code root by its sha256. Nothing here is
exported from `komira`: the public verbs come with the query door.
"""

from __future__ import annotations

from ._decorator import Udf, udf, write_code

__all__ = ["Udf", "udf", "write_code"]
