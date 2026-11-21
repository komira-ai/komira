"""The Mojo runtime laid out as an installed mojo-compiler, for the tests that
load a library: `runtime_site(runtime_dir)` is a scratch directory whose
modular/lib links to the three Mojo runtime libraries in `runtime_dir` (the
toolchain's, which a `python_binding_test` passes as `--runtime-dir`). The
tests point the runtime preload at it.
"""

import os
import sys
import tempfile

from komira import _runtime


def runtime_site(runtime_dir):
    site = tempfile.mkdtemp()
    libdir = os.path.join(site, "modular", "lib")
    os.makedirs(libdir)
    for name in _runtime._library_names(sys.platform):
        os.symlink(os.path.join(runtime_dir, name), os.path.join(libdir, name))
    return site
