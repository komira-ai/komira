"""The Mojo runtime libraries libkomira needs at load time.

The wheel does not carry them (docs/design/python_package.md, decision 6).
They come from Modular's own published package, `mojo-compiler`, which
installs them in `<site-packages>/modular/lib/`
(docs/design/mojo_runtime_pypi_vs_conda.md). libkomira's run path
(`$ORIGIN/lib:$ORIGIN`) does not reach that directory, so `_native.load` calls
`_preload_runtime_libraries` before it opens libkomira: the hook opens the
three libraries by absolute path, with RTLD_GLOBAL, in dependency order, and
libkomira's NEEDED names then resolve to the libraries already loaded.

Where it looks: `<dir>/modular/lib/` for each absolute directory `<dir>` of
the search path (`sys.path` unless a test passes its own), in order. The
first one holding all three libraries is the runtime. A relative entry (the
empty string of `python -c` is one) is skipped, so the working directory never
supplies a library. No environment variable and no flag picks the directory.

What it refuses, before any library is opened:

- No directory holds all three: `RuntimeNotFoundError` naming the missing
  libraries, every directory searched, and the install line.
- The `mojo-compiler` distribution installed in that directory is another
  version than `_MOJO_RUNTIME_VERSION`: `RuntimeNotFoundError` naming both
  versions and the install line. With no `mojo-compiler` metadata in that
  directory (the libraries were put there another way), nothing is checked.

A library that is found but cannot be opened is a `LibraryLoadError` with the
loader's reason. The process holds one runtime, as it holds one libkomira: once
a library of a directory is open, another directory is refused. Once all
three are open, the hook does nothing for that directory; after a failure
part way, it opens the three again (opening an open library again is a
no-op).
"""

from __future__ import annotations

import ctypes
import os
import sys
from collections.abc import Sequence
from importlib import metadata

from ._errors import LibraryLoadError, RuntimeNotFoundError

# The version of Modular's `mojo-compiler` this package is built with
# (docs/design/mojo_runtime_pypi_vs_conda.md); the wheel's `Requires-Dist`
# must pin the same version.
_MOJO_RUNTIME_VERSION = "1.0.0"

# The distribution that installs the libraries, as `importlib.metadata` names it.
_MOJO_DISTRIBUTION = "mojo-compiler"

# The directory under a site directory that holds the libraries.
_SUBDIR = os.path.join("modular", "lib")

# Their names without the platform's suffix, in dependency order:
# libAsyncRTRuntimeGlobals needs libMSupportGlobals, and libKGENCompilerRTShared
# needs both.
_STEMS = ("libMSupportGlobals", "libAsyncRTRuntimeGlobals", "libKGENCompilerRTShared")

# The `<dir>/modular/lib` the runtime is opened from, set once one library of
# it is open, and whether all three are.
_loaded_from: str | None = None
_loaded_all = False


def _library_names(platform: str) -> tuple[str, ...]:
    """The three file names on `platform` (a `sys.platform` value), in the
    order they are opened."""
    suffix = ".dylib" if platform == "darwin" else ".so"
    return tuple(stem + suffix for stem in _STEMS)


def _candidates(search_path: Sequence[str | os.PathLike[str]]) -> list[tuple[str, str]]:
    """(site directory, its `modular/lib`) for each absolute entry of
    `search_path`, in order, without repeats."""
    out = []
    seen = set()
    for entry in search_path:
        directory = os.fspath(entry)
        if not isinstance(directory, str) or not os.path.isabs(directory):
            continue
        directory = os.path.normpath(directory)
        if directory in seen:
            continue
        seen.add(directory)
        out.append((directory, os.path.join(directory, _SUBDIR)))
    return out


def _install_line() -> str:
    return "pip install {}=={}".format(_MOJO_DISTRIBUTION, _MOJO_RUNTIME_VERSION)


def _find(names: tuple[str, ...], candidates: list[tuple[str, str]]) -> tuple[str, str]:
    """The first candidate whose `modular/lib` holds every one of `names`, or
    the RuntimeNotFoundError naming those missing from the candidate that
    holds the most of them (the first such; all of them when none holds any)."""
    best: list[str] = list(names)
    for site, libdir in candidates:
        missing = [n for n in names if not os.path.isfile(os.path.join(libdir, n))]
        if not missing:
            return site, libdir
        if len(missing) < len(best):
            best = missing
    searched = ", ".join(libdir for _, libdir in candidates) or "no absolute directory"
    raise RuntimeNotFoundError(
        "the Mojo runtime {} is not installed: {} not found (searched {}); install it with: {}".format(
            _MOJO_RUNTIME_VERSION, ", ".join(best), searched, _install_line()
        )
    )


def _check_version(site: str, libdir: str) -> None:
    """Refuses a `mojo-compiler` installed in `site` at another version than
    the one this package needs; accepts a directory with no such metadata."""
    versions = sorted({d.version for d in metadata.distributions(name=_MOJO_DISTRIBUTION, path=[site])})
    if not versions or versions == [_MOJO_RUNTIME_VERSION]:
        return
    raise RuntimeNotFoundError(
        "the Mojo runtime in {} is {} {}; komira needs {}: install it with: {}".format(
            libdir, _MOJO_DISTRIBUTION, " and ".join(versions), _MOJO_RUNTIME_VERSION, _install_line()
        )
    )


def _preload_runtime_libraries(
    *, search_path: Sequence[str | os.PathLike[str]] | None = None, platform: str = sys.platform
) -> None:
    """Opens the Mojo runtime libraries before libkomira is opened.

    `search_path` is the directories to look in, each for `modular/lib/`;
    None means `sys.path`, where an installed `mojo-compiler` puts them. Tests
    pass their own. `platform` picks the file names (`.dylib` on "darwin",
    `.so` otherwise). An error it raises stops the load. `_native.load` calls
    it under its lock.
    """
    global _loaded_from, _loaded_all
    names = _library_names(platform)
    site, libdir = _find(names, _candidates(sys.path if search_path is None else search_path))
    if _loaded_from is not None:
        if _loaded_from == libdir and _loaded_all:
            return
        if _loaded_from != libdir:
            raise LibraryLoadError(
                "the Mojo runtime is already loaded from {}; it cannot also be loaded from {}".format(
                    _loaded_from, libdir
                )
            )
    _check_version(site, libdir)
    for name in names:
        path = os.path.join(libdir, name)
        try:
            ctypes.CDLL(path, mode=ctypes.RTLD_GLOBAL)
        except OSError as e:
            raise LibraryLoadError("cannot load the Mojo runtime library {}: {}".format(path, e)) from None
        _loaded_from = libdir
    _loaded_all = True
