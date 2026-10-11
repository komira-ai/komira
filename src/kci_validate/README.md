# kci_validate

The validations a kci stage runs on its steps. Two kinds:

- **CONDA_INSTALL_ENV** (`run_install_env`) installs the release with a
  pinned pixi into a scratch directory outside the checkout, under a
  cleared environment, and runs each installed library's README examples
  against the installed package. The programs (one per example, and a
  runner that runs them all) are made from the installed
  `share/doc/<name>/README.md` by the program that makes them for the
  build's `[tests][readme]` test, the README examples tool, so the two are
  byte-equal for the same README. kci ships the tool beside its executable
  (`shipped_readme_tool`) and runs it as a child process; without it the
  README is refused, naming the path. A
  library that ships no README, a README with other bytes than its
  `metadata.json` records, or one with no example is refused. No network at
  all is `INDETERMINATE` (exit 5) with a skip reason, never a pass.
- **CONDA_INSTALL_SMOKE** (`run_install_smoke`), after a PUBLISH step, reads
  the step's channel anonymously until its index lists each pinned file with
  the build's sha256 and serves those bytes, then runs a digest-pinned
  container that installs the release from that channel and runs a program
  against it.

Either kind then reads back what was installed (version, build, sha256 and
channel of every record, the compiler pin, nothing from an undeclared
channel), each library's payload, and the program's `N of N checks passed`.
Every failure is `VALIDATION_FAILED` (exit 7); under `--plan` nothing runs.
An ENV validation can install from a local `file:///` channel instead
(`FileChannelTransport`).

Processes, the channel and waits go through seams (`ProcessRunner`,
`PkgTransport`, `Sleeper`); the pure pieces (the generated program, the
`pixi.toml`, argv lists, the child environment) are public and shown below.

## Examples

An installed README's programs are made by the README examples tool, which
kci ships beside its own executable; a tool that is not there is refused by
name before anything is written:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_validate import package_dir_of, readme_doc_path, readme_program_of, shipped_readme_tool

var dir = package_dir_of("komira//src/komira_encoding:komira_encoding_conda")
assert_equal(dir, "src/komira_encoding")
assert_equal(readme_doc_path("komira_encoding"), "share/doc/komira_encoding/README.md")
assert_true(shipped_readme_tool().endswith("/readme_examples"))

var fence = "`" * 3
var readme = "# komira_encoding\n\n" + fence + "mojo\nprint(1)\n" + fence + "\n"
var refused = String()
try:
    _ = readme_program_of(readme, "komira_encoding", dir + "/README.md", "/nonexistent/readme_examples", "/nonexistent/scratch")
except e:
    refused = String(e)
assert_true(refused.startswith("the README examples tool /nonexistent/readme_examples is missing"))
```

The environment's `pixi.toml` pins every library to its version, build and
channel, and the compiler to the release's pin:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_release_machine import StageValidation
from kci_validate import InstallPin, install_manifest_text

var v = StageValidation(1)
v.name = "install-env"
v.kind = "CONDA_INSTALL_ENV"
v.installs.append("komira_encoding")
v.compiler_channel = "https://conda.example.invalid/max"
v.extra_channels.append("conda-forge")

var pin = InstallPin("komira_encoding")
pin.version = "1.0.0"
pin.build = "h0a1b2c3d_7"
pin.sha256 = "1" * 64
pin.subdir = "linux-64"
pin.is_library = True
var pins = List[InstallPin]()
pins.append(pin^)

var channel = "https://conda.example.invalid/example/gamma"
assert_equal(
    install_manifest_text(v, channel, "linux-64", pins, "1.0.0"),
    "# Written by kci for validation 'install-env': installs the release from its channel only.\n"
    + "[workspace]\nname = \"kci-install-env\"\n"
    + "channels = [\"https://conda.example.invalid/example/gamma\", \"https://conda.example.invalid/max\","
    + " \"conda-forge\"]\nplatforms = [\"linux-64\"]\n\n[dependencies]\n"
    + "komira_encoding = { version = \"==1.0.0\", build = \"h0a1b2c3d_7\","
    + " channel = \"https://conda.example.invalid/example/gamma\" }\n"
    + "mojo-compiler = { version = \"==1.0.0\", channel = \"https://conda.example.invalid/max\" }\n",
)
```

The installer's child process gets only the variables listed here, and a
channel location is an `https://` URL or a local `file:///` directory:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_validate import ChannelUrl, env_child_env, install_env_argv

var env = env_child_env("/scratch/install-env/bin", "/scratch/install-env/work")
assert_equal(len(env), 6)
assert_equal(env[0], "PATH=/scratch/install-env/bin:/usr/bin:/bin")
assert_equal(env[4], "TMPDIR=/scratch/install-env/work/tmp")
assert_equal(install_env_argv("/scratch/install-env/work")[0], "install")

var remote = ChannelUrl("https://conda.example.invalid/example/gamma/")
assert_equal(remote.host, "conda.example.invalid")
assert_equal(remote.path, "/example/gamma")
assert_false(remote.is_local())

var local = ChannelUrl("file:///srv/channel/")
assert_true(local.is_local())
assert_equal(local.path, "/srv/channel")

var refused = String()
try:
    _ = ChannelUrl("file:///srv/../etc")
except e:
    refused = String(e)
assert_true("is not file:///<absolute directory>" in refused)
```
