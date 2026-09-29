---
summary: "kg, the repository knowledge graph: generated library pages, a docs graph and a Buck2 code graph, committed, with the git hooks and the CI check that keep them fresh."
entry_points: ["main (kglib/cli.py)", "derive (kglib/layer1.py)", "export (kglib/graph.py)", "check (kglib/ops.py)"]
key_files: [kg.py, kglib/layer1.py, kglib/docsgraph.py, kglib/graph.py, kglib/ops.py, kglib/cli.py]
---

# kg

`python3 tools/kg/kg.py <verb>`; standard library only (Python 3.9 or newer, git 2.25 or newer).
`graph` and `check --graph` also need buck2; nothing else does.

| Verb | What it does |
|---|---|
| `setup` | Once per clone: sets `core.hooksPath` to `.githooks` (refusing a different value) and runs `status`. |
| `status` | Versions, the hooks path, each hook, and a dry pre-commit with its wall time. |
| `build --all` | Rebuilds every page under `docs/libraries/`, the map and `docs/kg/docs_graph.json` from the index, and stages the changed ones. `--out DIR` writes them under a scratch directory instead. |
| `fix` | A merge or rebase stopped on a generated file: rebuilds them from the merged inputs and stages them. |
| `check [--commit C] [--base B] [--graph]` | Are C's generated files byte-identical to what C's own generator renders, with no dead doc reference, and was C's Buck2 graph rendered from C's inputs? `--graph` also re-runs buck2, in a scratch checkout of C, and compares bytes. |
| `graph [--out FILE]` | Runs one `buck2 uquery` in a scratch checkout of the index (never the working tree) and writes `docs/kg/buck_graph.json` (staged), or FILE. |
| `deps`, `rdeps <target> [--depth N]` | Transitive dependencies or dependents, from the committed graph. |
| `tests <target or path>` | Its welded `test_srcs`, the test targets that reach it, and the gated libraries that depend on it. |
| `owner <path>` | The targets whose `srcs` or `test_srcs` list a file. |

**Generated files** are never edited or hand-merged. A page's inputs are a library's `BUCK` rule, its package header (the `__init__.mojo` docstring's first paragraph and its `Entry points:` / `Key files:` lines, or a directory library's README front matter), the front matter of the docs that govern it (`governs:`), `.buckconfig` `[cells]` and `docs/kg.toml`.

**If pre-push or the `kg` check says stale:** `python3 tools/kg/kg.py build --all && git commit -m "kg: refresh pages" -- docs/libraries docs/kg`, or for the Buck2 graph `python3 tools/kg/kg.py graph && git commit -m "kg: refresh the Buck2 graph" -- docs/kg`.

**Tests:** `tools/kg/tests/test_layer1.py` (pure, no git), `tools/kg/tests/test_git.py` (real git repositories in a temporary directory, one failing fixture per hook rule) and `tools/kg/tests/test_graph.py` (the docs and Buck2 graphs, with a stub buck2). The `kg` workflow runs all three.
