"""The Mojo runtime libraries libkomira needs at load time.

The wheel does not carry them (docs/design/python_package.md, decision 6):
they come from Modular's own published package. `_native.load` calls
`_preload_runtime_libraries` before it opens libkomira, so the runtime can be
loaded from where it is installed first. It loads nothing yet.
"""

from __future__ import annotations

import os
from collections.abc import Sequence


def _preload_runtime_libraries(search_path: Sequence[str | os.PathLike[str]] | None = None) -> None:
    """Loads the Mojo runtime libraries before libkomira is opened.

    `search_path` is the directories to look in, which tests pass (the
    toolchain's runtime directory); None means where an installed package
    finds them. It does nothing yet; an error it raises stops the load.
    """
