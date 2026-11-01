# =============================================================================
# ingest_gleaning -- the bounded extraction loop of one episode.
# =============================================================================
#
# The first pass asks the `LlmClient` to extract; each later pass asks again with
# the entities found so far, and a model (or stub) answers with only what is
# new. The loop folds the passes into one `Extraction` and stops early on a pass
# that adds nothing. The fold drops a mention whose name is already held and a
# triple already held, field for field, so a model that repeats itself neither
# keeps the loop running nor yields the same edge twice.
# =============================================================================

from komira_kg_format import EntityMention, Extraction, Triple

from .llm_client import LlmClient


def _mention_in(mentions: List[EntityMention], name: String) -> Bool:
    for i in range(len(mentions)):
        if mentions[i].name == name:
            return True
    return False


def _triple_in(triples: List[Triple], t: Triple) -> Bool:
    for i in range(len(triples)):
        ref o = triples[i]
        if (
            o.subject_name == t.subject_name
            and o.predicate == t.predicate
            and o.object_name == t.object_name
            and o.fact == t.fact
            and o.valid_at == t.valid_at
            and o.invalid_at == t.invalid_at
        ):
            return True
    return False


def run_gleaning[
    Llm: LlmClient
](
    ref llm: Llm,
    body: String,
    max_gleanings: Int,
    context_seed: List[EntityMention] = List[EntityMention](),
) raises -> Extraction:
    """Extract from `body`, then re-ask up to `max_gleanings` times, and return
    the union.

    Parameters:
        Llm: The model client (inferred).

    Args:
        llm: The model client; only `extract` is called.
        body: The text to extract from.
        max_gleanings: Extra passes after the first; 0 asks once.
        context_seed: Entities already known for the text's partition, given to
            the model as `already_found` on every pass. They ground the model
            and are not part of the result: a seed entity the body does not
            mention again is left to its stored row.

    Returns:
        The folded union: mentions de-duplicated by exact name (the first one
        wins), triples de-duplicated field for field, both in first-seen order.

    Raises:
        If the model raises.
    """
    var entities = List[EntityMention]()
    var triples = List[Triple]()

    var first = llm.extract(body, context_seed.copy())
    for i in range(len(first.entities)):
        if not _mention_in(entities, first.entities[i].name):
            entities.append(first.entities[i].copy())
    for i in range(len(first.triples)):
        if not _triple_in(triples, first.triples[i]):
            triples.append(first.triples[i].copy())

    var pass_idx = 0
    while pass_idx < max_gleanings:
        var known = List[EntityMention](
            capacity=len(entities) + len(context_seed)
        )
        for i in range(len(context_seed)):
            known.append(context_seed[i].copy())
        for i in range(len(entities)):
            if not _mention_in(known, entities[i].name):
                known.append(entities[i].copy())
        var delta = llm.extract(body, known^)
        var added = False
        for i in range(len(delta.entities)):
            if not _mention_in(entities, delta.entities[i].name):
                entities.append(delta.entities[i].copy())
                added = True
        for i in range(len(delta.triples)):
            if not _triple_in(triples, delta.triples[i]):
                triples.append(delta.triples[i].copy())
                added = True
        if not added:
            break
        pass_idx += 1

    return Extraction(entities^, triples^)
