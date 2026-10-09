"""`komira_kg_code`: the code graph deriver.

It turns what the build already knows about Mojo code into graph nodes and
edges: `buck2 uquery` JSON (targets, sources, deps, tests), the `mojo doc`
JSON of each library (the compiler's own reading of its declarations, made
by the `mojo_doc_json` build rule), the import lines of each source, and
the `governs:` front matter of Markdown documents. The result is a
`CodeGraph` in canonical order, as text (`dump`) or as two Arrow record
batches (`node_batch`, `edge_batch`).

Modules:
  - graph.mojo     : `KgNode`, `KgEdge`, `CodeGraph`, the node and edge
                     kinds, the batch schemas.
  - deriver.mojo   : `CodeGraphBuilder`, which derives the graph.
  - text_scan.mojo : the line scans: `imported_modules`,
                     `declaration_line`, `read_front_matter`.
"""

from .deriver import CodeGraphBuilder
from .graph import (
    CodeGraph,
    KgEdge,
    KgNode,
    EDGE_CONFORMS,
    EDGE_DECLARES,
    EDGE_DEPS,
    EDGE_GOVERNS,
    EDGE_IMPORTS,
    EDGE_SRCS,
    EDGE_TESTS,
    NODE_ALIAS,
    NODE_DOC,
    NODE_FILE,
    NODE_FUNCTION,
    NODE_METHOD,
    NODE_STRUCT,
    NODE_TARGET,
    NODE_TRAIT,
    edge_schema,
    node_schema,
)
from .text_scan import FrontMatter, declaration_line, imported_modules, read_front_matter
