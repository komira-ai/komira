"""parse_manifest: read artifact manifests with kci's parser and writer.

usage: parse_manifest <manifest.json>...

For each path: `read_artifact_manifest` (the parser `kci publish` uses), then
`render_artifact_manifest` (the writer `kci build` uses); prints one line

    OK <type> <name> <version> <subdir> <file> <sha256> render-identical=<yes|no>

where render-identical says the rendered text is the file's bytes exactly. A
manifest the parser refuses prints `REFUSED <the parser's message>` and the
program exits 1 after the last path. A fixture of tools/build/tests: it is run
by tools/build/tests/functional/conda_set.sh, never published.
"""

from std.pathlib import Path
from std.sys import argv, exit

from kci_artifact_manifest import read_artifact_manifest, render_artifact_manifest


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: parse_manifest <manifest.json>...")
        exit(2)
    var refused = False
    for i in range(1, len(args)):
        var path = String(args[i])
        try:
            var m = read_artifact_manifest(path)
            var text = Path(path).read_text()
            var again = render_artifact_manifest(m)
            var same = String("yes") if again == text else String("no")
            print(
                "OK",
                m.artifact_type,
                m.name,
                m.version,
                m.subdir,
                m.file,
                m.sha256_hex,
                "render-identical=" + same,
            )
        except e:
            print("REFUSED", String(e))
            refused = True
    if refused:
        exit(1)
