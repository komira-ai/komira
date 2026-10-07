"""covuser: a library that depends on covlib (test 46): its compile reads
covlib's package, so it shows whether the coverage switch changed it."""

from covlib import clamp


def bounded(x: Int) -> Int:
    return clamp(x, 0, 9)
