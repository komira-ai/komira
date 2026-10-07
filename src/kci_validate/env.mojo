# =============================================================================
# src/kci_validate/env.mojo -- the ENV environment: install the release on
#   THIS machine, with no container, so that nothing of this machine but its
#   kernel, loader and system libraries is under the install.
# =============================================================================
#
# THE SCRATCH DIRECTORY `<scratch>/<validation>/` (fresh: one an earlier run
# left behind is refused, never reused). `--scratch-dir` is absolute and its
# real path is NOT inside the checkout kci runs in (`scratch_refusal`): a
# `.mojoc` records the relative path of its source directory and resolves it
# against the consumer's working directory, so a program run from inside the
# checkout can read the library's SOURCE and pass without the package.
#
#   bin/pixi             a symbolic link to the pixi given with --pixi, whose
#                        bytes are checked against --pixi-sha256 through the
#                        link; the only entry of the child's own PATH
#   work/                `<w>`, every child's working directory:
#     pixi.toml          the manifest (container.mojo `install_manifest_text`)
#     auth.json          `{}`: pixi's --auth-file (pixi refuses a 0-byte one)
#     readme_<import>.mojo
#                        each installed library's README examples as a program
#                        (readme_installed.mojo)
#     home/ pixi_home/ cache/ tmp/ out/
#                        HOME, PIXI_HOME, PIXI_CACHE_DIR, TMPDIR, and the
#                        records kci writes (`out/`, the names the container
#                        script wrote, so readback.mojo reads both)
#
# THE CHILD ENVIRONMENT (`env_child_env`), built from nothing:
#
#   PATH=<scratch>/<validation>/bin:/usr/bin:/bin
#   HOME=<w>/home PIXI_HOME=<w>/pixi_home PIXI_CACHE_DIR=<w>/cache
#   TMPDIR=<w>/tmp LANG=C.UTF-8
#
# Nothing of this process's environment reaches pixi or the program: no CI
# token or token-request variable, no host PATH, no CONDA_OVERRIDE_* (which
# would fake virtual packages such as __glibc), no PIXI_* or RATTLER_*, no
# proxy, no SSL_CERT_FILE.
#
# THE COMMANDS (no shell; pinned by a golden test; every flag is in pixi
# 0.67.2's `--help`):
#
#   pixi install --manifest-path <w>/pixi.toml --auth-file <w>/auth.json
#        --tls-root-certs webpki --no-progress
#   pixi run --manifest-path <w>/pixi.toml --as-is mojo run [<link>] <w>/readme_<import>.mojo
#
# <link> is container.mojo's `native_link_args` over the environment
# `<w>/.pixi/envs/default` when the pins hold the native package
# (`-Xlinker -L<w>/.pixi/envs/default/lib -Xlinker -lkomira_native`), and
# nothing otherwise. argv, no shell: the scratch path is never parsed.
#
# `--manifest-path` is explicit because pixi otherwise finds a workspace by
# walking up from its working directory. `--as-is` is `--no-install
# --frozen`: the run uses exactly what the install made and never re-solves
# or installs (plain `--frozen` re-installs a missing environment from the
# lock). `--tls-root-certs webpki` takes this machine's CA store out of the
# trust path (pixi's bundled Mozilla roots).
#
# A SYSTEM-WIDE PIXI CONFIG is refused, naming each file (`system_configs`):
# pixi reads `/etc/pixi/` whatever HOME and PIXI_HOME say, a workspace-local
# `.pixi/config.toml` overrides its `mirrors` only key by key (a mirror for a
# URL the local file does not name stays in force, and `mirrors = {}` clears
# nothing), and its `detached-environments` moves the environment out of
# `<w>` behind a symbolic link. kci cannot neutralise a file it has not
# read, so it does not run under one.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir
from std.os.path import exists, isdir, realpath

from .container import ENV_DIR, MANIFEST_NAME, join_path

comptime PIXI_SYSTEM_CONFIG_DIR: String = "/etc/pixi"
"""Where pixi reads its system-wide config on Linux and macOS."""
comptime ENV_SYSTEM_PATH: String = "/usr/bin:/bin"
"""The system directories pixi's libc probe and mojo need after the pixi link."""
comptime AUTH_FILE: String = "auth.json"
comptime AUTH_FILE_TEXT: String = "{}"
"""An empty JSON object: pixi refuses a 0-byte auth file (EOF while parsing)."""
comptime PIXI_LINK_DIR: String = "bin"
comptime PIXI_NAME: String = "pixi"
comptime ENV_INSTALL_TIMEOUT_S: Int = 2700
"""The whole solve and download of the release and the compiler."""
comptime ENV_RUN_TIMEOUT_S: Int = 1800
"""One README program: its compile and its run."""


struct EnvHost(Copyable, Movable):
    """What this machine contributes to an ENV validation: the directory pixi
    reads its system-wide config from (`PIXI_SYSTEM_CONFIG_DIR` for real; a
    test names its own).

    Layout: owned Strings. No pointer field."""

    var system_config_dir: String

    def __init__(out self, var system_config_dir: String):
        self.system_config_dir = system_config_dir^


def env_child_env(bin_dir: String, work_dir: String) -> List[String]:
    """The whole environment of every child (file header)."""
    var env = List[String]()
    env.append(String("PATH=") + bin_dir + String(":") + String(ENV_SYSTEM_PATH))
    env.append(String("HOME=") + join_path(work_dir, String("home")))
    env.append(String("PIXI_HOME=") + join_path(work_dir, String("pixi_home")))
    env.append(String("PIXI_CACHE_DIR=") + join_path(work_dir, String("cache")))
    env.append(String("TMPDIR=") + join_path(work_dir, String("tmp")))
    env.append(String("LANG=C.UTF-8"))
    return env^


def install_env_argv(work_dir: String) -> List[String]:
    """`pixi install ...` (file header), argv without the program."""
    var a = List[String]()
    a.append(String("install"))
    a.append(String("--manifest-path"))
    a.append(join_path(work_dir, String(MANIFEST_NAME)))
    a.append(String("--auth-file"))
    a.append(join_path(work_dir, String(AUTH_FILE)))
    a.append(String("--tls-root-certs"))
    a.append(String("webpki"))
    a.append(String("--no-progress"))
    return a^


def run_program_argv(work_dir: String, program_file: String, link: List[String]) -> List[String]:
    """`pixi run ... --as-is mojo run <link...> <w>/<program_file>` (file
    header)."""
    var a = List[String]()
    a.append(String("run"))
    a.append(String("--manifest-path"))
    a.append(join_path(work_dir, String(MANIFEST_NAME)))
    a.append(String("--as-is"))
    a.append(String("mojo"))
    a.append(String("run"))
    for i in range(len(link)):
        a.append(link[i].copy())
    a.append(join_path(work_dir, program_file))
    return a^


def _parent(path: String) -> String:
    var slash = path.rfind(String("/"))
    if slash <= 0:
        return String("/")
    return String(path[byte=0:slash])


def real_path_of(path: String) raises -> String:
    """The real path of absolute `path`, which need not exist yet: the real
    path of its nearest existing ancestor joined with the rest."""
    var rest = String("")
    var p = path.copy()
    while p.byte_length() > 1 and p.endswith(String("/")):
        var t = String(p[byte = 0 : p.byte_length() - 1])
        p = t^
    while not exists(p):
        var slash = p.rfind(String("/"))
        var leaf = String(p[byte = slash + 1 :])
        if rest.byte_length() > 0:
            rest = leaf + String("/") + rest
        else:
            rest = leaf^
        p = _parent(p)
    var base = realpath(p)
    if rest.byte_length() == 0:
        return base^
    return join_path(base, rest)


def _is_under(path: String, root: String) -> Bool:
    if path == root:
        return True
    if root == String("/"):
        return True
    return path.startswith(root + String("/"))


def scratch_refusal(scratch_dir: String, repo_root: String) -> String:
    """"" when `scratch_dir` may hold an ENV validation; why not, otherwise
    (file header): it is absolute, and its real path is not the checkout
    `repo_root` nor inside it."""
    if not scratch_dir.startswith(String("/")):
        return String("--scratch-dir '") + scratch_dir + String("' is not an absolute path")
    try:
        var real = real_path_of(scratch_dir)
        var root = realpath(repo_root)
        if _is_under(real, root):
            return (
                String("--scratch-dir '") + scratch_dir + String("' is inside the checkout ") + root
                + String(" (real path ") + real + String("): a program run there can read a library's source")
                + String(" and pass without its package")
            )
    except e:
        return String("--scratch-dir '") + scratch_dir + String("': ") + String(e)
    return String("")


def system_configs(dir: String) -> List[String]:
    """Every file under pixi's system config directory `dir`, by full path;
    empty when there is no such directory (file header)."""
    var out = List[String]()
    try:
        if not isdir(dir):
            if exists(dir):
                out.append(dir.copy())
            return out^
        var names = listdir(dir)
        for i in range(len(names)):
            out.append(join_path(dir, String(names[i])))
    except:
        out.append(dir.copy())
    return out^


def env_records_dir(work_dir: String) -> String:
    """Where pixi must have put the environment: `<w>/.pixi/envs/default`."""
    return join_path(work_dir, String(ENV_DIR))
