"""komira: SQL over local files, with libkomira, the komira query engine, in process.

This is an early release: a `Session` registers Parquet files and runs SQL over
them, and each `Result` reads as Arrow (pyarrow). The public names are exactly `__all__`;
every other module is private (docs/design/python_package.md). Importing the
package does not load the library: the first `Session()` or `abi_version()`
does.

The package logs to the standard `logging` logger "komira": at DEBUG the
library it loaded and each query's plan segments, at INFO a query stopped by
an exception (a Ctrl-C's `KeyboardInterrupt`). It writes no query text. The
logger has a `NullHandler`, so nothing is printed unless the application
configures logging.
"""

import logging as _logging
from importlib import metadata as _metadata

from . import _native
from ._errors import KomiraError, LibraryLoadError, UnsupportedCpuError
from ._session import Result, Session

_logging.getLogger("komira").addHandler(_logging.NullHandler())

try:
    __version__: str = _metadata.version("komira")
except _metadata.PackageNotFoundError:
    # Run from a source tree, with no installed distribution.
    __version__ = "0.0.0"


def abi_version() -> int:
    """The C ABI version of the loaded libkomira, major * 1000 + minor (1001
    is 1.1). Loads the library if no call has yet; raises `LibraryLoadError`
    when it cannot."""
    return _native.load().abi_version


__all__ = [
    "KomiraError",
    "LibraryLoadError",
    "Result",
    "Session",
    "UnsupportedCpuError",
    "__version__",
    "abi_version",
]
