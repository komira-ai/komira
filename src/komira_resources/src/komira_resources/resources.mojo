"""Find and read the files a program reads at run time.

ONE RULE. A resource is named by its path under the program's `share/`
directory, which sits beside the directory holding the executable:

    <root>/bin/<program>
    <root>/share/<name>

Both places a Komira program runs have that layout, so a caller never says
which one it is in:

- A test (a `test_srcs` entry of a `mojo_library`, or a `mojo_test`) runs
  from a tree staged for it alone, and its declared data sit under `share/`.
  A list entry in `test_data` / `data` is staged at its path in the
  repository, so `read_resource("<repo-relative path>")` opens it; a dict
  entry `{"<name>": <source>}` is staged at `<name>`.
- A shipped program is a `mojo_bundle`, and `mojo_bundle(data = {"share/<name>":
  <source>})` puts the file at `<name>`. Ship it under its repository path and
  the test and the program use the same name.

The lookup goes through the executable's own path (`/proc/self/exe` on Linux,
dyld on macOS), so it does not depend on the current directory or on any
environment variable, and there is no fallback: a file that was not declared
is absent, and asking for it raises an error that names it and says where to
declare it. There is no "does it exist" query on purpose: a test that skips
when its data is missing passes without testing anything.

A name is a relative path with no empty, `.` or `..` segment. It may name a
directory; that directory holds exactly the declared files under it.
"""

from komira_runtime_paths import data_path
from std.os.path import exists


def resource_path(name: String) raises -> String:
    """The absolute path of resource `name` (a file or a directory).

    Raises when `name` is not a relative path, or when nothing was declared
    under that name for this program.
    """
    var path = data_path(name)
    if not exists(path):
        raise Error(
            "komira_resources: '"
            + name
            + "' is not a resource of this program (no "
            + path
            + "). A test declares it as data (mojo_library test_data or"
            + " mojo_test data); a shipped program's mojo_bundle lists it"
            + " in data as 'share/"
            + name
            + "'."
        )
    return path^


def read_resource(name: String) raises -> String:
    """The text of resource file `name`. Raises as `resource_path` does."""
    with open(resource_path(name), "r") as f:
        return f.read()
