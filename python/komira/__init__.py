"""komira: SQL over local files, with libkomira, the komira query engine, in process.

This is an early release: a `Session` registers Parquet, CSV and
newline-delimited JSON files and runs SQL over them, and each `Result` reads
as Arrow (pyarrow). The pandas-shaped `DataFrame` reads the same files
(`read_parquet`, `read_csv`, `read_json`), groups and reduces them
(`groupby`, `agg`), and builds a plan that runs, with no SQL, at
`materialize()` (docs/design/dataframe_surface.md). The public names
are exactly `__all__`; every other module is private
(docs/design/python_package.md). Importing the package does not load the
library: the first `Session()`, reader or `abi_version()` does. A name the
package does not define raises `AttributeError`, with a replacement when the
name is a pandas one komira refuses (komira/_refusals.py).

The package logs to the standard `logging` logger "komira": at DEBUG the
library it loaded and each query's plan segments, at INFO a query stopped by
an exception (a Ctrl-C's `KeyboardInterrupt`). It writes no query text. The
logger has a `NullHandler`, so nothing is printed unless the application
configures logging.
"""

import logging as _logging
from importlib import metadata as _metadata

from . import _native
from ._errors import (
    BindError,
    CredentialsError,
    KomiraError,
    LibraryLoadError,
    ParseError,
    StorageError,
    UnsupportedCpuError,
    UnsupportedOperation,
)
from ._frame import DataFrame, read_csv, read_json, read_parquet
from ._groupby import GroupBy
from ._refusals import MODULE as _MODULE_REFUSALS
from ._refusals import refused as _refused
from ._series import Series
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


def __getattr__(name: str) -> object:
    message = None if name.startswith("_") else _refused(_MODULE_REFUSALS, name)
    if message is None:
        message = f"module 'komira' has no attribute '{name}'"
    raise AttributeError(message, name=name)


__all__ = [
    "BindError",
    "CredentialsError",
    "DataFrame",
    "GroupBy",
    "KomiraError",
    "LibraryLoadError",
    "ParseError",
    "Result",
    "Series",
    "Session",
    "StorageError",
    "UnsupportedCpuError",
    "UnsupportedOperation",
    "__version__",
    "abi_version",
    "read_csv",
    "read_json",
    "read_parquet",
]
