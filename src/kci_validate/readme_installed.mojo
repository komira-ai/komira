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
# `[tests][readme]` test (tools/build/mojo/defs.bzl `_readme_gate`): one per
# example, `readme_<import name>_<line>.mojo`, and the runner that imports
# and runs them all, `readme_<import name>.mojo`. SOURCE mode runs the Zig
# tool //tools/build/readme_examples:tool; this runs the Mojo library of the
# same package, `readme_examples`, which makes the same bytes for the same
# README and arguments (the two are held equal by review: no build action
# compares them):
#
#   display   `<package dir>/README.md`, the package dir read from the
#             package's build label (`komira//src/<pkg>:<pkg>_conda` gives
#             `src/<pkg>`): a failure names the README line in the
#             repository, which is the installed file's line too (same bytes)
#   package   the library's import name
#   links     refused: a README that ships may not link a relative path
#
# The runner is named `readme_<import name>.mojo` (readme_examples
# `program_name`), never `<import name>.mojo`: a file beside the programs
# named like the package would be an import root shadowing the installed
# package. kci runs the runner, once.
#
# REFUSED, each naming its reason (one failed `readme` row):
#   * the package records no README (`doc_files` absent, or no row for
#     share/doc/<name>/README.md), or the environment holds no such file:
#     "<name> ships no share/doc/<name>/README.md: a release needs a
#     README; add <package dir>/README.md";
#   * the installed bytes are not the ones `doc_files` records;
#   * the README holds no ```mojo example (a validation that runs nothing is
#     not a pass);
#   * anything readme_examples refuses (a bad fence word, a relative link).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os.path import isfile

from kci_release_set.member import file_sha256_hex
from readme_examples.examples import extract_examples
from readme_examples.program import Program, generate_programs

from .container import join_path
from .request import InstallPin, readme_doc_path


struct ReadmeProgram(Copyable, Movable):
    """One installed README, made into programs: `display` (the README's
    path in the repository), `installed` (its path in the environment),
    `package` (the library's import name), `file` (the runner's file name),
    `text` (the runner), `modules` (each example's program, which the runner
    imports from beside it) and `examples` (how many it runs, > 0).

    Layout: owned Strings, a List of owned Programs and an Int. No pointer field."""

    var display: String
    var installed: String
    var package: String
    var file: String
    var text: String
    var modules: List[Program]
    var examples: Int

    def __init__(out self):
        self.display = String("")
        self.installed = String("")
        self.package = String("")
        self.file = String("")
        self.text = String("")
        self.modules = List[Program]()
        self.examples = 0


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


def readme_program_of(text: String, import_name: String, display: String) raises -> ReadmeProgram:
    """The program for README `text` of the library imported as
    `import_name`, named `display` in its messages (file header). RAISES
    with readme_examples' refusals, or when there is no example."""
    if not _is_identifier(import_name):
        raise Error(String("import name '") + import_name + String("' is not a Mojo identifier"))
    var examples = extract_examples(text, display, True)
    if len(examples) == 0:
        raise Error(
            display + String(" holds no ```mojo example, so the validation would run nothing; add one")
        )
    var programs = generate_programs(examples, import_name, display)
    var runner = programs.pop()
    var p = ReadmeProgram()
    p.display = display.copy()
    p.package = import_name.copy()
    p.file = runner.name.copy()
    p.text = runner.text.copy()
    p.modules = programs^
    p.examples = len(examples)
    return p^


def installed_readme(pin: InstallPin, env_dir: String) raises -> ReadmeProgram:
    """The program for library `pin`'s installed README under the
    environment `env_dir` (file header). RAISES with the refusal."""
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
    var p = readme_program_of(text, pin.import_name, display)
    p.installed = rel^
    return p^
