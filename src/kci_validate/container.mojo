# =============================================================================
# src/kci_validate/container.mojo -- the consumer's sandbox: a scratch
#   directory, the pixi manifest kci writes into it, and the exact `docker`
#   command lines that install the release and run the program inside a
#   digest-pinned image.
# =============================================================================
#
# THE SCRATCH DIRECTORY `<scratch>/<validation>/` (fresh: one an earlier run
# left behind is refused, never reused):
#
#   work/                mounted at /work, the container's only writable
#                        path besides /tmp:
#     pixi.toml          `install_manifest_text`
#     smoke.mojo         a COPY of the program, read from the repository at
#                        the revision being released (the checkout is never
#                        mounted)
#     home/ pixi_home/ cache/ tmp/ out/
#                        HOME, PIXI_HOME, PIXI_CACHE_DIR, TMPDIR, and what the
#                        script records (`out/`)
#   docker/              HOME and DOCKER_CONFIG of the docker CLI itself:
#                        empty, so no registry login of this machine is used
#                        (the image is pulled anonymously)
#
# THE MANIFEST pins every install name to the release's version AND build
# and to the step's channel, and `mojo-compiler` to the libraries' mojo_pin
# and the compiler channel. Channels, in order: the step's, the compiler
# channel, the extra channels.
#
# THE COMMANDS (`pull_argv`, `run_argv`; pinned by a golden test):
#
#   docker pull <image>          a digest reference: docker checks the bytes
#   docker run --rm --pull=never --network=bridge --user <uid>:<gid>
#     --read-only --tmpfs /tmp:rw,size=256m --cap-drop=ALL
#     --security-opt=no-new-privileges
#     -e HOME=/work/home -e PIXI_HOME=/work/pixi_home
#     -e PIXI_CACHE_DIR=/work/cache -e TMPDIR=/work/tmp
#     -v <scratch>/<validation>/work:/work:rw -w /work
#     <image> sh -c <script>
#
# Nothing else reaches the container: `docker run` passes none of this
# process's environment except the four `-e` it names, so a CI job's token
# request variables and secrets never reach the consumer. The docker CLI
# itself is started with exactly PATH, HOME and DOCKER_CONFIG
# (`docker_child_env`).
#
# THE SCRIPT (`container_script`) runs inside: `pixi install`, then the
# sha256 of each library's installed payload, then `mojo run` of the
# program. Each phase writes its exit status or output under /work/out, and
# the script stops after a failed install; it never decides a verdict. kci
# reads everything back from the mount (readback.mojo). Every value written
# into the script was checked to be a plain relative path or version
# (request.mojo), so nothing in it is interpreted by the shell.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_release_machine import EXTRA_CHANNEL_CONDA_FORGE, StageValidation

from .request import InstallPin

comptime WORK_MOUNT: String = "/work"
comptime ENV_DIR: String = ".pixi/envs/default"
"""Where pixi puts the default environment, under the manifest's directory."""
comptime MANIFEST_NAME: String = "pixi.toml"
comptime PROGRAM_COPY: String = "smoke.mojo"
comptime COMPILER_PACKAGE: String = "mojo-compiler"
comptime CONDA_FORGE_URL: String = "https://conda.anaconda.org/conda-forge"
"""Where pixi records a `conda-forge` package as coming from."""

comptime PULL_TIMEOUT_S: Int = 900
comptime RUN_TIMEOUT_S: Int = 2700
"""The whole install and program run, the compile included."""


def join_path(a: String, b: String) -> String:
    if a.byte_length() == 0:
        return b.copy()
    if a.endswith(String("/")):
        return a + b
    return a + String("/") + b


def _toml_string(s: String) -> String:
    """A TOML basic string: `\\` and `"` escaped."""
    return String('"') + s.replace(String("\\"), String("\\\\")).replace(String('"'), String('\\"')) + String('"')


def channel_url_of(channel: String) -> String:
    """The URL a channel's packages are recorded under: `conda-forge` is
    conda-forge's; any other channel is its own URL."""
    if channel == EXTRA_CHANNEL_CONDA_FORGE:
        return String(CONDA_FORGE_URL)
    return channel.copy()


def install_manifest_text(
    validation: StageValidation, channel_url: String, subdir: String, pins: List[InstallPin], mojo_pin: String
) -> String:
    """The `pixi.toml` kci writes (file header)."""
    var channels = _toml_string(channel_url) + String(", ") + _toml_string(validation.compiler_channel)
    for i in range(len(validation.extra_channels)):
        channels += String(", ") + _toml_string(validation.extra_channels[i])
    var deps = String("")
    for i in range(len(pins)):
        ref p = pins[i]
        deps += (
            p.name + String(" = { version = ") + _toml_string(String("==") + p.version) + String(", build = ")
            + _toml_string(p.build) + String(", channel = ") + _toml_string(channel_url) + String(" }\n")
        )
    deps += (
        String(COMPILER_PACKAGE) + String(" = { version = ") + _toml_string(String("==") + mojo_pin)
        + String(", channel = ") + _toml_string(validation.compiler_channel) + String(" }\n")
    )
    return (
        String("# Written by kci for validation '") + validation.name
        + String("': installs the release from its channel only.\n[workspace]\nname = \"kci-") + validation.name
        + String("\"\nchannels = [") + channels + String("]\nplatforms = [") + _toml_string(subdir)
        + String("]\n\n[dependencies]\n") + deps
    )


def payload_record_name(pin: InstallPin) -> String:
    """The file under /work/out the script writes a library's payload sha256
    to."""
    return String("payload.") + pin.name


def container_script(pins: List[InstallPin]) -> String:
    """The script the container runs (file header). `sh -c`, no `-e`: each
    phase records its own exit status."""
    var w = String(WORK_MOUNT)
    var s = String("cd ") + w + String("\n")
    s += String("pixi install --manifest-path ") + w + String("/") + String(MANIFEST_NAME)
    s += String(" > ") + w + String("/out/install.log 2>&1\n")
    s += String("echo $? > ") + w + String("/out/install.exit\n")
    s += String("[ \"$(cat ") + w + String("/out/install.exit)\" = 0 ] || exit 0\n")
    for i in range(len(pins)):
        if not pins[i].is_library:
            continue
        s += (
            String("sha256sum ") + w + String("/") + String(ENV_DIR) + String("/") + pins[i].payload_path
            + String(" > ") + w + String("/out/") + payload_record_name(pins[i]) + String(" 2>&1\n")
        )
    s += String("pixi run --manifest-path ") + w + String("/") + String(MANIFEST_NAME)
    s += String(" --frozen mojo run ") + w + String("/") + String(PROGRAM_COPY)
    s += String(" > ") + w + String("/out/smoke.out 2> ") + w + String("/out/smoke.err\n")
    s += String("echo $? > ") + w + String("/out/smoke.exit\n")
    return s^


def pull_argv(image: String) -> List[String]:
    var a = List[String]()
    a.append(String("pull"))
    a.append(image.copy())
    return a^


def run_argv(image: String, work_dir: String, user: String, script: String) -> List[String]:
    """`docker run ...` (file header), argv without the program."""
    var a = List[String]()
    for word in [
        "run", "--rm", "--pull=never", "--network=bridge",
    ]:
        a.append(String(word))
    a.append(String("--user"))
    a.append(user.copy())
    for word in [
        "--read-only", "--tmpfs", "/tmp:rw,size=256m", "--cap-drop=ALL", "--security-opt=no-new-privileges",
        "-e", "HOME=/work/home", "-e", "PIXI_HOME=/work/pixi_home", "-e", "PIXI_CACHE_DIR=/work/cache",
        "-e", "TMPDIR=/work/tmp",
    ]:
        a.append(String(word))
    a.append(String("-v"))
    a.append(work_dir + String(":") + String(WORK_MOUNT) + String(":rw"))
    a.append(String("-w"))
    a.append(String(WORK_MOUNT))
    a.append(image.copy())
    a.append(String("sh"))
    a.append(String("-c"))
    a.append(script.copy())
    return a^


def docker_child_env(docker_dir: String, path_env: String) -> List[String]:
    """The docker CLI's whole environment (file header)."""
    var env = List[String]()
    env.append(String("PATH=") + path_env)
    env.append(String("HOME=") + docker_dir)
    env.append(String("DOCKER_CONFIG=") + docker_dir)
    return env^


def work_subdirs() -> List[String]:
    """The directories made under work/ before the container starts."""
    var out = List[String]()
    for d in ["home", "pixi_home", "cache", "tmp", "out"]:
        out.append(String(d))
    return out^
