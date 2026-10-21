"""The rules of affected.bxl that are DATA, not code.

The same widening and inert rules as `rules.txt`, which the Mojo selector
(`affected`) reads; `rules_parity` (a welded test of this package) holds the
two files to the same rows, so changing one without the other is red until
the Mojo selector is gone. A BXL script cannot read a text file, which is
why the rules are Starlark here.

  WIDEN   a changed file matching the pattern affects EVERY target of the
          check set: a change to it cannot be mapped to the targets it
          reaches, so none is left out. Each row is (pattern, reason).
  INERT   a changed file matching the pattern that no target owns is not a
          reason to widen: it builds nothing. A change made only of such
          files reaches no target, and the selector refuses it (VACUOUS).
  UNIVERSE the target patterns of the check set: the graph the selector
          answers over, and the targets the aggregate `//ci:pr` holds
          (ci/targets.bzl). The tests cell is its `functional` tree only:
          the rest of that cell fails by design.

A pattern is a path, `dir/**` (everything under dir), `text*` (a path
starting with text) or `*text` (a path ending with text). WIDEN wins over
INERT. A file no target owns and no INERT row names widens too, so the
list never has to be complete to be safe.

This file lives under tools/build/, so changing it widens too.
"""

WIDEN = [
    (".buckconfig", "the project configuration is part of every target's configuration"),
    (".buckconfig.local.example", "the template of the machine's own configuration"),
    ("buck2", "the wrapper that runs the pinned buck2"),
    ("tools/buck2*", "the pinned buck2 changes how every action runs"),
    ("prelude/**", "the rules every target is declared with"),
    ("tools/build/**", "the Mojo rules, platforms, toolchains and build tooling are loaded by every target"),
    ("third_party/**", "a pinned third-party source or crate version reaches every target that links it"),
]

INERT = [
    "*.md",
    "LICENSE",
    ".gitignore",
    ".github/CODEOWNERS",
]

UNIVERSE = [
    # Not the toolchains cell's directory: its targets are toolchain rules, which exist
    # only configured and may not be the dependency of a plain target.
    "komira//... - komira//tools/build/cells/...",
    "tests//functional/...",
]

# The rule kinds that only name a source file or a group of them: building
# one builds nothing, so the aggregate `//ci:pr` need not hold it and the
# completeness guard does not ask for it. Every other kind is a check.
SOURCE_KINDS = [
    "prelude//rules.bzl:export_file",
    "prelude//rules.bzl:filegroup",
]

# The aggregate every pull request check builds, and its package.
AGGREGATE = "komira//ci:pr"
