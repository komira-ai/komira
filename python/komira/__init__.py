"""komira: SQL over local files, with libkomira, the komira query engine, in process.

The public names are exactly `__all__`; every other module is private
(docs/design/python_package.md).
"""

from ._errors import KomiraError, LibraryLoadError

__all__ = ["KomiraError", "LibraryLoadError"]
