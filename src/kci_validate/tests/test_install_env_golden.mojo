# =============================================================================
# src/kci_validate/tests/test_install_env_golden.mojo
#   The ENV environment, golden: the child's WHOLE environment (the pixi
#   link's directory then /usr/bin:/bin, HOME, PIXI_HOME, PIXI_CACHE_DIR and
#   TMPDIR inside the scratch work dir, LANG; nothing of this process), the
#   exact `pixi install` and `pixi run --as-is` argv, the manifest (every
#   install pinned to version AND build on the step's channel; the glibc
#   floor declared on linux-64, nothing on osx-arm64), and the installed
#   README's programs: byte-equal to the programs SOURCE mode
#   generated for the welded `[tests][readme]` test of the same README,
#   read from that gate itself (komira_encoding's `[tests][readme][file]`,
#   its README.md, and `[tests][readme][generated]`, what
#   tools/build/mojo/readme.bzl `readme_gate` made of it), so the gate's
#   arguments are stated in one place and a change to them is red here; the
#   runner named `readme_<import>.mojo`, never `<import>.mojo`, and each
#   example's `readme_<import>_<line>.mojo`. A change to any of the rest is
#   a visible edit of this file.
# =============================================================================

from std.os import listdir, setenv
from std.testing import TestSuite, assert_equal, assert_true

from kci_release_machine import StageValidation
from komira_runtime_paths import data_path, test_tmpdir
from kci_validate import (
    AUTH_FILE_TEXT,
    InstallPin,
    env_child_env,
    install_env_argv,
    install_manifest_text,
    package_dir_of,
    readme_program_of,
    run_program_argv,
)


def _join(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


def test_child_environment_is_golden() raises:
    # this process holds what a CI job holds; none of it may reach the list
    for kv in [
        ("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "held-by-the-job"),
        ("ACTIONS_ID_TOKEN_REQUEST_URL", "https://token.example.invalid/"),
        ("ACTIONS_RUNTIME_TOKEN", "held-by-the-job"),
        ("GITHUB_TOKEN", "held-by-the-job"),
        ("CONDA_OVERRIDE_GLIBC", "2.99"),
        ("CONDA_PREFIX", "/parent/conda"),
        ("PIXI_HOME", "/parent/pixi_home"),
        ("PIXI_CACHE_DIR", "/parent/pixi_cache"),
        ("RATTLER_AUTH_FILE", "/parent/auth.json"),
        ("SSL_CERT_FILE", "/parent/cert.pem"),
        ("HTTPS_PROXY", "http://proxy.example.invalid:3128"),
    ]:
        _ = setenv(String(kv[0]), String(kv[1]), True)
    var got = env_child_env(String("/scratch/install-env/bin"), String("/scratch/install-env/work"))
    var want = List[String]()
    for e in [
        "PATH=/scratch/install-env/bin:/usr/bin:/bin",
        "HOME=/scratch/install-env/work/home",
        "PIXI_HOME=/scratch/install-env/work/pixi_home",
        "PIXI_CACHE_DIR=/scratch/install-env/work/cache",
        "TMPDIR=/scratch/install-env/work/tmp",
        "LANG=C.UTF-8",
    ]:
        want.append(String(e))
    assert_equal(_join(got), _join(want))


def test_install_argv_is_golden() raises:
    var want = List[String]()
    for w in [
        "install",
        "--manifest-path",
        "/scratch/install-env/work/pixi.toml",
        "--auth-file",
        "/scratch/install-env/work/auth.json",
        "--tls-root-certs",
        "webpki",
        "--no-progress",
    ]:
        want.append(String(w))
    assert_equal(_join(install_env_argv(String("/scratch/install-env/work"))), _join(want))
    # pixi refuses a 0-byte auth file; kci writes an empty JSON object
    assert_equal(String(AUTH_FILE_TEXT), String("{}"))


def test_run_argv_is_golden() raises:
    var want = List[String]()
    for w in [
        "run",
        "--manifest-path",
        "/scratch/install-env/work/pixi.toml",
        "--as-is",
        "mojo",
        "run",
        "/scratch/install-env/work/readme_komira_encoding.mojo",
    ]:
        want.append(String(w))
    assert_equal(
        _join(run_program_argv(String("/scratch/install-env/work"), String("readme_komira_encoding.mojo"))), _join(want)
    )


def _pin() -> InstallPin:
    var lib = InstallPin(String("komira_encoding"))
    lib.version = String("1.0.0")
    lib.build = String("h0a1b2c3d_7")
    lib.sha256 = String("1111111111111111111111111111111111111111111111111111111111111111")
    lib.subdir = String("linux-64")
    lib.is_library = True
    return lib^


def test_manifest_pins_version_and_build() raises:
    var v = StageValidation(1)
    v.name = String("install-env")
    v.kind = String("CONDA_INSTALL_ENV")
    v.installs.append(String("komira_encoding"))
    v.compiler_channel = String("https://conda.example.invalid/max")
    v.extra_channels.append(String("conda-forge"))
    var pins = List[InstallPin]()
    pins.append(_pin())
    assert_equal(
        install_manifest_text(v, String("https://conda.example.invalid/example/gamma"), String("linux-64"), pins, String("1.0.0")),
        String(
            "# Written by kci for validation 'install-env': installs the release from its channel only.\n"
            "[workspace]\nname = \"kci-install-env\"\n"
            "channels = [\"https://conda.example.invalid/example/gamma\", \"https://conda.example.invalid/max\","
            " \"conda-forge\"]\nplatforms = [\"linux-64\"]\n\n[system-requirements]\n"
            "libc = { family = \"glibc\", version = \"2.34\" }\n\n[dependencies]\n"
            "komira_encoding = { version = \"==1.0.0\", build = \"h0a1b2c3d_7\","
            " channel = \"https://conda.example.invalid/example/gamma\" }\n"
            "mojo-compiler = { version = \"==1.0.0\", channel = \"https://conda.example.invalid/max\" }\n"
        ),
    )
    # a subdir with no glibc floor (kci_release_set's glibc_floors names
    # linux-64 only) declares no system requirement: pixi's own default holds
    assert_equal(
        install_manifest_text(v, String("https://conda.example.invalid/example/gamma"), String("osx-arm64"), pins, String("1.0.0")),
        String(
            "# Written by kci for validation 'install-env': installs the release from its channel only.\n"
            "[workspace]\nname = \"kci-install-env\"\n"
            "channels = [\"https://conda.example.invalid/example/gamma\", \"https://conda.example.invalid/max\","
            " \"conda-forge\"]\nplatforms = [\"osx-arm64\"]\n\n[dependencies]\n"
            "komira_encoding = { version = \"==1.0.0\", build = \"h0a1b2c3d_7\","
            " channel = \"https://conda.example.invalid/example/gamma\" }\n"
            "mojo-compiler = { version = \"==1.0.0\", channel = \"https://conda.example.invalid/max\" }\n"
        ),
    )


def test_installed_program_is_byte_equal_to_source_mode() raises:
    # SOURCE mode is the gate's own output for //src/komira_encoding; INSTALLED
    # mode is kci's run of the tool it ships on the same README bytes, the
    # display from the package's build label, the package its import name
    var tool = data_path(String("readme_examples"))
    var text = open(data_path(String("encoding_readme")), "r").read()
    var src = data_path(String("encoding_generated"))
    var dir = package_dir_of(String("komira//src/komira_encoding:komira_encoding_conda"))
    assert_equal(dir, String("src/komira_encoding"))
    var installed = readme_program_of(
        text, String("komira_encoding"), dir + String("/README.md"), tool, test_tmpdir() + String("/installed")
    )
    assert_true(installed.examples > 0)
    assert_equal(installed.text, open(src + String("/readme_komira_encoding.mojo"), "r").read())
    assert_equal(len(installed.modules), installed.examples)
    for i in range(len(installed.modules)):
        ref m = installed.modules[i]
        assert_true(m.name.startswith(String("readme_komira_encoding_")), m.name)
        assert_equal(m.text, open(src + String("/") + m.name, "r").read(), m.name)
    # nothing the gate made is missing from kci's: the runner and each example
    assert_equal(len(listdir(src)), installed.examples + 1)
    # never `<import>.mojo`: a file beside the program named like the
    # package is an import root that would shadow the installed package
    assert_equal(installed.file, String("readme_komira_encoding.mojo"))
    assert_true(installed.text.find(String("readme_komira_encoding validation: ")) >= 0)


def test_package_dir_of_refuses_another_shape() raises:
    for bad in ["komira_encoding", "komira//:x", "komira///abs:x"]:
        var refused = String("")
        try:
            _ = package_dir_of(String(bad))
        except e:
            refused = String(e)
        assert_true(refused.find(String("the package's label")) >= 0, String(bad) + String(": ") + refused)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
