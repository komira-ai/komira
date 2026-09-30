"""komira_resources: the files a program reads at run time.

    from komira_resources import read_resource, resource_path

    var text = read_resource("deploy/regions.textproto")

A resource is named by its path under the program's `share/` directory, and
by default that is the file's path in the repository. The same call works in a
test and in a shipped program; see `resources.mojo` for how each declares it.
"""

from .resources import read_resource, resource_path
