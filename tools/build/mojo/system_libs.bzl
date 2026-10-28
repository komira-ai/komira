"""The pinned system libraries a test run loads, for the Mojo rules.

A package built by buildrules' `mojo_package` that opens a shared library by its bare name (`mode = "load"` in `[native-dependencies]`, `dlopen("libsnappy.so.1")`)
pins the library in its unit graph, and its own tests run with the pinned files on their library path. The label that adopts the package for these rules
(`mojo_adopted_library`, adopt.bzl) hands the same directories on as `MojoInfo.system_libs`, and a library, test or adopted package that depends on it carries them
too, so every test run that loads the package finds the pinned files: the welded tests of a `mojo_library`, its README examples, its coverage runs (the kcov run
and the branch run) and its mutation runs, and a `mojo_test`. The directories are unpacked by buildrules from the sha256-pinned packages of the graph; nothing comes
from the worker.

A run is given them as `--lib-dir <directory>` arguments of the gate (tools/build/run, mojo.zig), written ahead of the run's `--env` and `--arg` arguments in the
same list as the `--env` arguments (`run_args`), because every runner here already passes that list to the gate unchanged. On Linux the gate appends the directories
to `LD_LIBRARY_PATH` after the compiler's lib; on macOS it puts them first in `DYLD_FALLBACK_LIBRARY_PATH`. A compile is never given them: a library a test loads is
no input of its compiled bytes. A run with none has the command it always had, so no cache key moves for a package that depends on no such library.
"""

load("@buildrules//rules/mojo:providers.bzl", "MojoSystemLibsInfo")
load(":providers.bzl", "MojoInfo")

def own_system_libs(lib):
    """The directories a buildrules `:lib` target exports (`MojoSystemLibsInfo`), [] for one that exports none (a mojo_package whose graph pins nothing)."""
    info = lib.get(MojoSystemLibsInfo)
    return list(info.dirs) if info != None else []

def merge_system_libs(lists):
    """The directories of `lists`, in the order met, none twice."""
    seen = {}
    out = []
    for dirs in lists:
        for d in dirs:
            key = str(d)
            if key not in seen:
                seen[key] = True
                out.append(d)
    return out

def dep_system_libs(deps):
    """The directories carried by the Mojo packages among `deps` (targets; a C library among them carries none)."""
    return merge_system_libs([d[MojoInfo].system_libs for d in deps if MojoInfo in d])

def lib_dir_args(dirs):
    """`--lib-dir <directory>` for each of `dirs`: the gate's option (tools/build/run/mojo.zig); [] for none."""
    args = []
    for d in dirs:
        args += ["--lib-dir", d]
    return args

def run_args(env_args, dirs):
    """The runner arguments of a test run: `env_args` (`--env NAME=VALUE`...) then the `--lib-dir` arguments of `dirs`. The gate takes either kind in any order
    ahead of the first `--arg`; the runners that forward this list (cov_run, cov_branch run) forward both."""
    return env_args + lib_dir_args(dirs)
