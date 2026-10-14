# =============================================================================
# src/kci_validate/readme_installed.mojo -- an installed library's README
#   examples as the program an ENV validation runs.
# =============================================================================
#
# A released library's package installs its README at
# `share/doc/<conda name>/README.md`, and its metadata.json `doc_files`
# records that file's sha256. The ENV validation runs the README's ```mojo
# examples against the INSTALLED package: what a user reads works on what
# they installed.
#
# The programs are the ones SOURCE mode generates for the welded
# `[tests][readme]` test (tools/build/mojo/readme.bzl `readme_gate`): one per
# example, `readme_<import name>_<line>.mojo`, and the runner that imports
# and runs them all, `readme_<import name>.mojo`. Both modes run the same
# program, the Zig tool //tools/build/readme_examples:tool, with the same
# arguments; there is no second generator:
#
#   display   `<package dir>/README.md`, the package dir read from the
#             package's build label (`komira//src/<pkg>:<pkg>_conda` gives
#             `src/<pkg>`): a failure names the README line in the
#             repository, which is the installed file's line too (same bytes)
#   package   the library's import name
#   links     refused: a README that ships may not link a relative path
#
# THE TOOL SHIPS WITH KCI. kci's runnable directory (`//bin/kci:kci
# [runnable]`) holds it beside the kci executable as `readme_examples`, and
# a bundle of kci holds it in bin/ beside the launcher (bin/kci/BUCK
# `helpers`). `shipped_readme_tool` is that path, read from kci's own
# executable (/proc/self/exe); kci_cli puts it in `ValidateRequest.
# readme_tool`. It runs as a child process (kci_build's SupervisorRunner)
# with an environment of PATH alone, under `<scratch>/readme/<import name>/`
# (the README written there, the programs generated there, then read back).
# A missing tool is a refusal naming the path and where kci ships it.
#
# The runner is named `readme_<import name>.mojo`, never `<import
# name>.mojo`: a file beside the programs named like the package would be
# an import root shadowing the installed package. kci runs the runner, once.
#
# REFUSED, each naming its reason (one failed `readme` row):
#   * the package records no README (`doc_files` absent, or no row for
#     share/doc/<name>/README.md), or the environment holds no such file:
#     "<name> ships no share/doc/<name>/README.md: a release needs a
#     README; add <package dir>/README.md";
#   * the installed bytes are not the ones `doc_files` records;
#   * the README holds no ```mojo example (a validation that runs nothing is
#     not a pass);
#   * anything the tool refuses (a bad fence word, a relative link), in
#     the tool's words, one line per refusal;
#   * a `sh komira-link` block that is not, word for word, the link
#     arguments the package's closure needs (readme_link.mojo), a block
#     missing where the closure links native files, or one the tool refuses;
#   * no tool at the path kci was given, or a tool that does not run.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import makedirs
from std.os.path import isfile

from kci_build.runner import RunResult, RunSpec
from kci_build.supervisor_runner import SupervisorRunner
from kci_release_set.member import file_sha256_hex
from komira_runtime_paths import executable_path

from .container import join_path
from .readme_link import LinkArgs, link_refusal, links_static, parse_link_args, run_link_args
from .request import InstallPin, readme_doc_path

comptime README_TOOL_NAME: String = "readme_examples"
"""The tool's file name beside kci's executable (bin/kci/BUCK `helpers`)."""

comptime README_TOOL_TIMEOUT_S: Int = 120
"""How long one run of the tool may take; a README is read in milliseconds."""


@fieldwise_init
struct ReadmeModule(Copyable, Movable):
    """One generated program: its file `name` and its `text`.

    Layout: two owned Strings. No pointer field."""

    var name: String
    var text: String


struct ReadmeProgram(Copyable, Movable):
    """One installed README, made into programs: `display` (the README's
    path in the repository), `installed` (its path in the environment),
    `package` (the library's import name), `file` (the runner's file name),
    `text` (the runner), `modules` (each example's program, which the runner
    imports from beside it) and `examples` (how many it runs, > 0).
    `run_args`: the `mojo run` arguments of the README's link block, the
    environment in place of `$CONDA_PREFIX` (readme_link.mojo); empty when
    the README has none. `block`: the block itself as the tool read it
    (`$CONDA_PREFIX` kept), for a run in another environment and for the
    `mojo build` arguments (native_rows.mojo). `codecs`: the sonames of the
    system codecs the library's closure opens (request.mojo
    `closure_codecs`), the codecs its `loaded_from` row judges.

    Layout: owned Strings, Lists of owned Programs and Strings, an Int and a
    LinkArgs. No pointer field."""

    var display: String
    var installed: String
    var package: String
    var file: String
    var text: String
    var modules: List[ReadmeModule]
    var examples: Int
    var run_args: List[String]
    var block: LinkArgs
    var codecs: List[String]

    def __init__(out self):
        self.display = String("")
        self.installed = String("")
        self.package = String("")
        self.file = String("")
        self.text = String("")
        self.modules = List[ReadmeModule]()
        self.examples = 0
        self.run_args = List[String]()
        self.block = LinkArgs()
        self.codecs = List[String]()

    def runs_built(self) -> Bool:
        """Whether the README runs built rather than under `mojo run`
        (native_rows.mojo `run_readme`): its block's `mojo build` line links
        a static archive its `mojo run` line does not (readme_link.mojo
        `links_static`; komira_log's holder, which the JIT cannot load), or
        its library's closure opens a system codec (`codecs` not empty).
        The loader's record of a `mojo run` holds every process the run
        starts, the compiler's own among them: on the first run in a fresh
        environment one of them loads libz.so.1 and libzstd.so.1 from the
        system (kci run 38397209148, komira_zlib alone), which the record
        cannot tell from the program's own `dlopen`. A built program run
        directly is the program's process alone."""
        return links_static(self.block) or len(self.codecs) > 0


def package_dir_of(label: String) raises -> String:
    """The package directory of build label `label`: `cell//<dir>:<name>`
    gives `<dir>`. RAISES when the label has another shape."""
    var at = label.find(String("//"))
    var colon = label.rfind(String(":"))
    if at < 0 or colon <= at + 2:
        raise Error(String("the package's label '") + label + String("' is not cell//<dir>:<name>"))
    var dir = String(label[byte = at + 2 : colon])
    if dir.startswith(String("/")) or dir.find(String("..")) >= 0:
        raise Error(String("the package's label '") + label + String("' names no package directory"))
    return dir^


def _is_identifier(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        var ok = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95 or (i > 0 and c >= 48 and c <= 57)
        if not ok:
            return False
    return True


def shipped_readme_tool() -> String:
    """The README examples tool kci ships: `readme_examples` in the
    directory of kci's own executable (file header); "" when that path
    cannot be read."""
    try:
        var exe = executable_path()
        var at = exe.rfind(String("/"))
        if at < 0:
            return String("")
        return String(exe[byte=0:at]) + String("/") + String(README_TOOL_NAME)
    except:
        return String("")


def _check_tool(tool: String) raises:
    if tool.byte_length() == 0:
        raise Error(
            String("kci was given no README examples tool: kci ships `") + String(README_TOOL_NAME)
            + String("` beside its executable (//tools/build/readme_examples:tool), and its own path could not be read")
        )
    if not isfile(tool):
        raise Error(
            String("the README examples tool ") + tool + String(" is missing: kci ships it beside its executable")
            + String(" (//tools/build/readme_examples:tool, in //bin/kci:kci[runnable] and in kci's bundle);")
            + String(" copy kci's whole directory, not the executable alone")
        )


def _drop_final_newline(s: String) -> String:
    if s.endswith(String("\n")):
        return String(s[byte = 0 : s.byte_length() - 1])
    return s.copy()


def _run_tool(tool: String, var argv: List[String], scratch: String, stdout_path: String) raises -> RunResult:
    """`tool argv...` in `scratch`, its stdout to `stdout_path`. RAISES
    when the tool is missing or cannot be started."""
    _check_tool(tool)
    var spec = RunSpec(
        tool.copy(), argv^, scratch.copy(), README_TOOL_TIMEOUT_S, stdout_path.copy(),
        join_path(scratch, String("tool.stderr")),
    )
    spec.set_env([String("PATH=/usr/bin:/bin")])
    var runner = SupervisorRunner()
    try:
        return runner.run(spec)
    except e:
        raise Error(String("the README examples tool ") + tool + String(" could not be run: ") + String(e))


def _tool_failed(tool: String, what: String, r: RunResult, stdout_path: String) -> Error:
    var said = _drop_final_newline(_read(stdout_path))
    if r.stderr_tail.byte_length() > 0:
        said += String(" ") + _drop_final_newline(r.stderr_tail)
    return Error(String("the README examples tool ") + tool + String(" failed on ") + what + String(" (") + r.describe() + String("): ") + said)


def _read(path: String) -> String:
    try:
        return open(path, "r").read()
    except:
        return String("")


def readme_program_of(text: String, import_name: String, display: String, tool: String, scratch: String) raises -> ReadmeProgram:
    """The program for README `text` of the library imported as
    `import_name`, named `display` in its messages, made by the README
    examples tool `tool` under the directory `scratch` (file header).
    RAISES with the tool's refusals, or when there is no example or no
    tool."""
    if not _is_identifier(import_name):
        raise Error(String("import name '") + import_name + String("' is not a Mojo identifier"))
    _check_tool(tool)
    makedirs(scratch, exist_ok=True)
    var readme = join_path(scratch, String("README.md"))
    var f = open(readme, "w")
    f.write_bytes(text.as_bytes())
    f.close()
    var out_dir = join_path(scratch, String("programs"))
    var examples_file = join_path(scratch, String("examples"))
    var stdout_path = join_path(scratch, String("generate.stdout"))
    var r = _run_tool(
        tool,
        [
            String("generate"), String("--readme"), readme, String("--display"), display.copy(),
            String("--package"), import_name.copy(), String("--links"), String("refuse"),
            String("--out-dir"), out_dir, String("--examples"), examples_file,
        ],
        scratch,
        stdout_path,
    )
    if r.exit_code == Int32(1) and not r.signaled and not r.timed_out:
        # refused: the tool's words, one refusal per line
        raise Error(_drop_final_newline(_read(stdout_path)))
    if not r.ok():
        raise _tool_failed(tool, display, r, stdout_path)
    var lines = List[String]()
    for line in open(examples_file, "r").read().split(String("\n")):
        if line.byte_length() > 0:
            lines.append(String(line))
    if len(lines) == 0:
        raise Error(
            display + String(" holds no ```mojo example, so the validation would run nothing; add one")
        )
    var p = ReadmeProgram()
    p.display = display.copy()
    p.package = import_name.copy()
    p.file = String("readme_") + import_name + String(".mojo")
    p.text = open(join_path(out_dir, p.file), "r").read()
    for i in range(len(lines)):
        var name = String("readme_") + import_name + String("_") + lines[i] + String(".mojo")
        var body = open(join_path(out_dir, name), "r").read()
        p.modules.append(ReadmeModule(name^, body^))
    p.examples = len(lines)
    return p^


def map_report_file(tool: String, report: String, package: String, display: String, dest: String, scratch: String) raises:
    """Writes to `dest` the report in file `report` with each
    `readme_<package>_<line>.mojo:<n>` rewritten to `<display>:<n>` (the
    tool's `map`), run under the directory `scratch`. RAISES when the tool
    is missing or fails."""
    makedirs(scratch, exist_ok=True)
    var r = _run_tool(
        tool,
        [
            String("map"), String("--package"), package.copy(), String("--display"), display.copy(),
            String("--report"), report.copy(),
        ],
        scratch,
        dest,
    )
    if not r.ok():
        raise _tool_failed(tool, report, r, dest)


def readme_link_args_of(tool: String, readme: String, display: String, scratch: String) raises -> LinkArgs:
    """The arguments of README file `readme`'s `sh komira-link` block, read
    by the README examples tool's `link` (run under `scratch`), named
    `display` in its refusals; empty when there is no block. RAISES with the
    tool's refusal, or when it fails."""
    makedirs(scratch, exist_ok=True)
    var out = join_path(scratch, String("link_args"))
    var stdout_path = join_path(scratch, String("link.stdout"))
    var r = _run_tool(
        tool,
        [String("link"), String("--readme"), readme.copy(), String("--display"), display.copy(), String("--out"), out],
        scratch,
        stdout_path,
    )
    if r.exit_code == Int32(1) and not r.signaled and not r.timed_out:
        raise Error(_drop_final_newline(_read(stdout_path)))
    if not r.ok():
        raise _tool_failed(tool, display, r, stdout_path)
    return parse_link_args(_read(out))


def installed_readme(pin: InstallPin, env_dir: String, tool: String, scratch: String) raises -> ReadmeProgram:
    """The program for library `pin`'s installed README under the
    environment `env_dir`, made by `tool` under `scratch` (file header).
    RAISES with the refusal."""
    var dir = package_dir_of(pin.label)
    var display = dir + String("/README.md")
    var rel = readme_doc_path(pin.name)
    var path = join_path(env_dir, rel)
    var no_readme = (
        pin.name + String(" ships no ") + rel + String(": a release needs a README; add ") + display
    )
    if not pin.has_doc_files or pin.readme_sha256.byte_length() == 0:
        raise Error(no_readme + String(" (its metadata.json records no doc_files row for it)"))
    if not isfile(path):
        raise Error(no_readme + String(" (the environment holds no such file)"))
    var got = file_sha256_hex(path)
    if got != pin.readme_sha256:
        raise Error(
            String("the installed ") + rel + String(" has sha256 ") + got + String(", its metadata.json doc_files records ")
            + pin.readme_sha256
        )
    var text = open(path, "r").read()
    var p = readme_program_of(text, pin.import_name, display, tool, scratch)
    # The link block: the arguments the README run is given, refused unless
    # they are exactly what the closure needs (readme_link.mojo).
    var block = readme_link_args_of(tool, join_path(scratch, String("README.md")), display, scratch)
    var why = link_refusal(pin.link, block, rel)
    if why.byte_length() > 0:
        raise Error(why)
    p.run_args = run_link_args(block, env_dir)
    p.block = block^
    p.codecs = pin.codecs.copy()
    p.installed = rel^
    return p^
