"""A module that validates (it parses, and its function has the right
hints) but ends the process that imports it with exit status 3: at LOAD,
the zygote."""

import os

os._exit(3)


def f(x: int) -> int:
    return x
