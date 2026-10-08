"""The `mojo precompile` command, shared by every rule that builds a `.mojoc`.

The compiler records each source file of a package in the `.mojoc` by the
path it was given, so a package compiled as `buck-out/<isolation dir>/.../
src/<name>` would carry the buck-out path: the same sources would give
different bytes under another isolation directory, and so would every
package and conda archive built from them. `--source-root` names the staged
package directory; for `precompile` the compile wrapper runs the compiler
from that directory's parent and names the package by its basename alone, so
the recorded paths are `<name>/<file>.mojo` wherever the action runs
(mojo_wrapper.sh; `-strip-file-prefix` does not reach `precompile`).
tools/build/tests/functional/mojoc_path checks it.
"""

def precompile_cmd(tc, include, src_dir, out, wrapper_flags = []):
    """The command line of one `mojo precompile` action.

    `tc` is the MojoToolchainInfo, `include` the `-I` arguments of the
    dependency closure, `src_dir` the staged package directory (its basename
    is the import name), `out` the `.mojoc` output, `wrapper_flags` further
    flags for the wrapper (the watchdog's).
    """
    return cmd_args(
        tc.busybox,
        "sh",
        tc.wrapper,
        tc.busybox,
        tc.compiler,
        tc.link,
        tc.cc_target,
        cmd_args(src_dir, format = "--source-root={}"),
        wrapper_flags,
        "--",
        # No `--target-cpu`: `mojo precompile` rejects it ("unrecognized
        # argument"). A `.mojoc` holds no machine code; the CPU is fixed
        # where code is generated, in `mojo build`.
        "precompile",
        include,
        src_dir,
        "-o",
        out,
    )
