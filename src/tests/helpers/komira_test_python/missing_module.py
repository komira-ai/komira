"""Imports a module that no wheel in the closure installs; py_test expects exactly that error.

`requests` is not pinned (third_party/python/pins.bzl), and the interpreter's
own site-packages is not on the path, so the import fails even on a worker
that has it installed system-wide.
"""

import requests  # noqa: F401

print("unreachable: requests imported from", requests.__file__)
