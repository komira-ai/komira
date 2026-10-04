# =============================================================================
# src/kci_validate/tests/test_install_smoke_container_golden.mojo
#   The consumer's sandbox, golden: the exact `docker pull` and `docker run`
#   argv (digest-pinned image, --pull=never, --read-only, --cap-drop=ALL,
#   no-new-privileges, the caller's uid:gid, only the four -e it names, one
#   mount), the script the container runs, the pixi.toml kci writes, and the
#   docker CLI's whole environment. A change to any of them is a visible
#   edit of this file.
# =============================================================================

from std.testing import TestSuite, assert_equal

from kci_stage_graph import StageValidation
from kci_validate import (
    InstallPin,
    container_script,
    docker_child_env,
    install_manifest_text,
    pull_argv,
    run_argv,
)

comptime IMAGE: String = (
    "registry.example.invalid/pixi:1-slim@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
)


def _pins() -> List[InstallPin]:
    var lib = InstallPin(String("komira_encoding"))
    lib.version = String("1.0.0")
    lib.build = String("h0a1b2c3d_7")
    lib.sha256 = String("1111111111111111111111111111111111111111111111111111111111111111")
    lib.subdir = String("linux-64")
    lib.is_library = True
    lib.payload_path = String("lib/mojo/komira_encoding.mojoc")
    lib.payload_sha256 = String("2222222222222222222222222222222222222222222222222222222222222222")
    var meta = InstallPin(String("komira_all"))
    meta.version = String("1.0.0")
    meta.build = String("h0a1b2c3d_7")
    meta.sha256 = String("3333333333333333333333333333333333333333333333333333333333333333")
    meta.subdir = String("linux-64")
    var out = List[InstallPin]()
    out.append(lib^)
    out.append(meta^)
    return out^


def _validation() -> StageValidation:
    var v = StageValidation(1)
    v.name = String("install")
    v.kind = String("CONDA_INSTALL_SMOKE")
    v.image = String(IMAGE)
    v.installs.append(String("komira_encoding"))
    v.installs.append(String("komira_all"))
    v.compiler_channel = String("https://conda.example.invalid/max")
    v.extra_channels.append(String("conda-forge"))
    v.program = String("release/smoke/smoke_komira_encoding.mojo")
    return v^


def _join(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


def test_pull_argv_is_golden() raises:
    var want = List[String]()
    want.append(String("pull"))
    want.append(String(IMAGE))
    assert_equal(_join(pull_argv(String(IMAGE))), _join(want))


def test_run_argv_is_golden() raises:
    var got = run_argv(String(IMAGE), String("/scratch/install/work"), String("1001:118"), String("SCRIPT"))
    var want = List[String]()
    for word in [
        "run",
        "--rm",
        "--pull=never",
        "--network=bridge",
        "--user",
        "1001:118",
        "--read-only",
        "--tmpfs",
        "/tmp:rw,size=256m",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "-e",
        "HOME=/work/home",
        "-e",
        "PIXI_HOME=/work/pixi_home",
        "-e",
        "PIXI_CACHE_DIR=/work/cache",
        "-e",
        "TMPDIR=/work/tmp",
        "-v",
        "/scratch/install/work:/work:rw",
        "-w",
        "/work",
    ]:
        want.append(String(word))
    want.append(String(IMAGE))
    want.append(String("sh"))
    want.append(String("-c"))
    want.append(String("SCRIPT"))
    assert_equal(_join(got), _join(want))


def test_script_is_golden() raises:
    assert_equal(
        container_script(_pins()),
        String(
            "cd /work\n"
            "pixi install --manifest-path /work/pixi.toml > /work/out/install.log 2>&1\n"
            "echo $? > /work/out/install.exit\n"
            "[ \"$(cat /work/out/install.exit)\" = 0 ] || exit 0\n"
            "sha256sum /work/.pixi/envs/default/lib/mojo/komira_encoding.mojoc > /work/out/payload.komira_encoding 2>&1\n"
            "pixi run --manifest-path /work/pixi.toml --frozen mojo run /work/smoke.mojo"
            " > /work/out/smoke.out 2> /work/out/smoke.err\n"
            "echo $? > /work/out/smoke.exit\n"
        ),
    )


def test_manifest_is_golden() raises:
    assert_equal(
        install_manifest_text(
            _validation(), String("https://conda.example.invalid/example/gamma"), String("linux-64"), _pins(), String("1.0.0")
        ),
        String(
            "# Written by kci for validation 'install': installs the release from its channel only.\n"
            "[workspace]\nname = \"kci-install\"\n"
            "channels = [\"https://conda.example.invalid/example/gamma\", \"https://conda.example.invalid/max\","
            " \"conda-forge\"]\nplatforms = [\"linux-64\"]\n\n[dependencies]\n"
            "komira_encoding = { version = \"==1.0.0\", build = \"h0a1b2c3d_7\","
            " channel = \"https://conda.example.invalid/example/gamma\" }\n"
            "komira_all = { version = \"==1.0.0\", build = \"h0a1b2c3d_7\","
            " channel = \"https://conda.example.invalid/example/gamma\" }\n"
            "mojo-compiler = { version = \"==1.0.0\", channel = \"https://conda.example.invalid/max\" }\n"
        ),
    )


def test_docker_cli_environment_is_golden() raises:
    var env = docker_child_env(String("/scratch/install/docker"), String("/usr/bin:/bin"))
    var want = List[String]()
    want.append(String("PATH=/usr/bin:/bin"))
    want.append(String("HOME=/scratch/install/docker"))
    want.append(String("DOCKER_CONFIG=/scratch/install/docker"))
    assert_equal(_join(env), _join(want))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
