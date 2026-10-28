# =============================================================================
# query_synthesis -- the answer a model gives from the retrieved subgraph.
# =============================================================================
#
# The model never sees the stored records. It is given the host's synthesis
# prompt as the system text, unchanged, and as the user text an evidence pack
# built from the query result:
#
#   QUESTION: <the query text>
#
#   EVIDENCE PACK
#   Entities:
#   - <label> (<type>)
#   Relations:
#   - <source label> -> <destination label>: <the edge's relation text>
#
# The pack lists at most `SYNTHESIS_MAX_NODES` entities and `SYNTHESIS_MAX_EDGES`
# relations, in the result's order (most relevant first), so a large
# neighbourhood does not make a large prompt. An edge whose end is not among the
# listed nodes shows the node id in place of a label.
# =============================================================================

from komira_kg import LlmClient
from komira_kg_format import KgQueryResult

comptime SYNTHESIS_MAX_NODES: Int = 32
comptime SYNTHESIS_MAX_EDGES: Int = 48


def _label_of(result: KgQueryResult, id: Int64) -> String:
    for i in range(len(result.nodes)):
        if result.nodes[i].id == id:
            return result.nodes[i].label.copy()
    return String(id)


def evidence_pack(result: KgQueryResult, query: String) -> String:
    """The user text sent to the model for `result` (see the file header)."""
    var out = String("QUESTION: ")
    out += query
    out += "\n\nEVIDENCE PACK\nEntities:\n"
    var n_nodes = min(len(result.nodes), SYNTHESIS_MAX_NODES)
    for i in range(n_nodes):
        out += "- "
        out += result.nodes[i].label
        out += " ("
        out += result.nodes[i].type
        out += ")\n"
    out += "Relations:\n"
    var n_edges = min(len(result.edges), SYNTHESIS_MAX_EDGES)
    for i in range(n_edges):
        ref e = result.edges[i]
        out += "- "
        out += _label_of(result, e.src)
        out += " -> "
        out += _label_of(result, e.dst)
        out += ": "
        out += e.predicate
        out += "\n"
    return out^


def synthesize_answer[
    Llm: LlmClient
](llm: Llm, result: KgQueryResult, query: String, prompt: String) raises -> String:
    """Ask the model to answer `query` from `result`.

    Parameters:
        Llm: The model client.

    Args:
        llm: The model client.
        result: The retrieved subgraph.
        query: The query text.
        prompt: The system text, sent unchanged.

    Returns:
        The model's answer.

    Raises:
        Whatever the model client raises.
    """
    return llm.synthesize(prompt, evidence_pack(result, query))
