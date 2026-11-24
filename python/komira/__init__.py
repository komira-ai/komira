"""komira: SQL over local files, with libkomira, the komira query engine, in process.

This is an early release: a `Session` registers Parquet files and runs SQL over
them, and each `Result` reads as Arrow (pyarrow). The public names are exactly `__all__`;
every other module is private (docs/design/python_package.md). Importing the
package does not load the library: the first `Session()` or `abi_version()`
does.
"""

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
from ._session import Result, Session

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
    "BindError",
    "CredentialsError",
    "KomiraError",
    "LibraryLoadError",
    "ParseError",
    "Result",
    "Session",
    "StorageError",
    "UnsupportedCpuError",
    "UnsupportedOperation",
    "__version__",
    "abi_version",
]
