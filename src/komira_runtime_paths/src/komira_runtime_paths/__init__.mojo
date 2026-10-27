"""Where a running program finds its files, from its own executable path.

A bundle (tools/build/package) and a test's staged tree (mojo_test `data`,
mojo_library `test_data`) share one layout: the executable is `<root>/bin/<name>`
and its data sit under `<root>/share/`. These functions find `<root>` through
the executable's own path, so they need no environment variable and no
runfiles tree, and they give the same answer whatever the current directory is.
"""

from .paths import (
    data_path,
    executable_path,
    install_root,
    read_data,
    share_dir,
    test_tmpdir,
)
