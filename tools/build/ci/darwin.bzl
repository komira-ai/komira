"""The macOS part of the pull request check: which of the affected targets are built for darwin-arm64.

    darwin_select(affected, packages, aggregates, darwin_set) -> struct(kind, targets, reason)

`affected` is the list the selector printed (tools/build/ci/affected.bxl: one label per line, the
targets a change reaches, or an aggregate of the check set). `packages` is the macOS set, the
directory names under src/ that release/darwin_libs.bzl builds for darwin-arm64 (DARWIN_PACKAGES).

The answer, built by pr.yml's step `build for macOS` on the farm's macOS workers:

  WHOLE    the list holds an aggregate (the change could not be mapped, or touches the build
           system): the whole macOS set, `darwin_set` (//release:mopm_darwin_libs).
  SOME     the `:lib` of each package of the set that the change reaches, in the order of
           `packages`. A `:lib` exists only once the package's welded tests passed, so building it
           runs those tests on a Mac; the `:lib` of every package it depends on is built first.
  NONE     the change reaches no package of the set: no macOS build.
  BROKEN   a line of `affected` is not a target label: the selector's output changed shape, and
           reading it as NONE would pass a change no Mac built. darwin.bxl fails on it.

Only a package's `:lib` is picked, never the other targets of its directory (the adopted label,
`:conda`, the coverage targets): the macOS set is those libraries, and they are what
release-macos.yml builds after the merge. A label of the tests cell is never picked.
"""

WHOLE = "WHOLE"
SOME = "SOME"
NONE = "NONE"
BROKEN = "BROKEN"

def _lib_label(package):
    return "komira//src/{}:lib".format(package)

def _normal(label):
    # The selector prints cell-qualified labels; a bare `//` label is the komira cell's.
    label = label.strip()
    if label.startswith("//"):
        return "komira" + label
    return label

def darwin_select(affected, packages, aggregates, darwin_set):
    """See the module documentation."""
    labels = {}
    for line in affected:
        label = _normal(line)
        if not label:
            continue
        if "//" not in label or ":" not in label.split("//", 1)[1]:
            return struct(kind = BROKEN, targets = [], reason = "{} is not a target label: the selector's output changed shape".format(repr(line)))
        labels[label] = True
    for aggregate in aggregates:
        if aggregate in labels:
            return struct(kind = WHOLE, targets = [darwin_set], reason = "the change is built as {}, so the whole macOS set is".format(aggregate))
    picked = [_lib_label(p) for p in packages if _lib_label(p) in labels]
    if not picked:
        return struct(kind = NONE, targets = [], reason = "the change reaches no library of the macOS set")
    return struct(kind = SOME, targets = picked, reason = "{} of the {} libraries of the macOS set".format(len(picked), len(packages)))
