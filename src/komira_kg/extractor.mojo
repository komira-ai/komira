# =============================================================================
# extractor -- the seam that turns text into entities and triples without a
# model, and a table-driven stub of it.
# =============================================================================
#
# An `Extractor` reads one episode's text and returns an `Extraction`: entity
# mentions and relation triples whose subjects and objects are still bare names
# (ingest resolves them to node ids). It is the inference-free half of the
# extraction seam; a model-backed extraction is `LlmClient.extract`, which has
# the same shape. What the entity types and predicates are is the
# implementation's business: the package fixes no vocabulary.
#
# `already_found` is the context argument. Extraction is not context-free: a
# gleaning loop calls `extract` again with what the earlier passes found and
# expects only NEW findings, and a host may seed it with entities already in the
# graph so mentions resolve against them. An empty list means a first pass.
# The contract an implementation keeps, so a gleaning loop terminates:
#
#   * for the same text and the same `already_found`, `extract` returns the
#     same extraction;
#   * once a pass's findings are in `already_found`, a later call for that text
#     returns nothing new (an empty extraction), not the same findings again.
#
# `StubExtractor` is the implementation for tests: canned extractions looked up
# by text, no rules and no model.
# =============================================================================

from komira_kg_format import EntityMention, Extraction, Triple


trait Extractor(Movable, Deinitable):
    """Text to an `Extraction`, with no inference.

    All methods take an immutable `self`: an extractor holds its rules, not
    per-call state.
    """

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        """Extract entity mentions and relation triples from `text`.

        Args:
            text: The episode text to extract from.
            already_found: Entities already known for this text (an earlier
                gleaning pass, or entities seeded from the graph). Empty on a
                first pass. Only findings not already in the list are returned.

        Returns:
            The extraction, with names not yet resolved to node ids. Empty when
            there is nothing new.
        """
        ...


def copy_extraction(source: Extraction) -> Extraction:
    """A deep copy of an `Extraction`, which is movable but not copyable.

    Args:
        source: The extraction to copy (borrowed, left untouched).

    Returns:
        A new extraction with a copy of every entity and triple.
    """
    var entities = List[EntityMention](capacity=len(source.entities))
    for i in range(len(source.entities)):
        entities.append(source.entities[i].copy())
    var triples = List[Triple](capacity=len(source.triples))
    for i in range(len(source.triples)):
        triples.append(source.triples[i].copy())
    return Extraction(entities^, triples^)


struct StubExtractor(Extractor):
    """A table-driven `Extractor` for tests: canned extractions looked up by text.

    Two kinds of row. A sized row, `add_extraction(text, found_size, result)`,
    answers a call whose `already_found` has exactly `found_size` entries, so a
    test can return a first-pass result at 0 and a gleaning delta at the first
    pass's entity count. An any-context row, `add_extraction_any_context`,
    answers the text whatever `already_found` holds; sized rows are tried first.
    A call that matches no row returns an empty extraction ("nothing new"), so a
    gleaning loop over the stub terminates. Registering the same key again
    replaces the row. Lookups copy the stored row; it is never consumed.
    """

    var _sized_text: List[String]
    var _sized_found: List[Int]
    var _sized_entities: List[List[EntityMention]]
    var _sized_triples: List[List[Triple]]
    var _any_text: List[String]
    var _any_entities: List[List[EntityMention]]
    var _any_triples: List[List[Triple]]

    def __init__(out self):
        """An empty stub: every call returns an empty extraction."""
        self._sized_text = List[String]()
        self._sized_found = List[Int]()
        self._sized_entities = List[List[EntityMention]]()
        self._sized_triples = List[List[Triple]]()
        self._any_text = List[String]()
        self._any_entities = List[List[EntityMention]]()
        self._any_triples = List[List[Triple]]()

    def add_extraction(
        mut self, text: String, found_size: Int, result: Extraction
    ):
        """Answer `text` with `result` when `already_found` has `found_size`
        entries.

        Args:
            text: The text key.
            found_size: The `len(already_found)` this row answers.
            result: The extraction to return (copied; the caller keeps it).
        """
        var copy = copy_extraction(result)
        for i in range(len(self._sized_text)):
            if (
                self._sized_text[i] == text
                and self._sized_found[i] == found_size
            ):
                self._sized_entities[i] = copy.entities.copy()
                self._sized_triples[i] = copy.triples.copy()
                return
        self._sized_text.append(text)
        self._sized_found.append(found_size)
        self._sized_entities.append(copy.entities.copy())
        self._sized_triples.append(copy.triples.copy())

    def add_extraction_any_context(mut self, text: String, result: Extraction):
        """Answer `text` with `result` whatever `already_found` holds.

        A call that repeats on a gleaning pass receives the same rows again, so
        use this for a result a gleaning fold treats as nothing new.

        Args:
            text: The text key.
            result: The extraction to return (copied; the caller keeps it).
        """
        var copy = copy_extraction(result)
        for i in range(len(self._any_text)):
            if self._any_text[i] == text:
                self._any_entities[i] = copy.entities.copy()
                self._any_triples[i] = copy.triples.copy()
                return
        self._any_text.append(text)
        self._any_entities.append(copy.entities.copy())
        self._any_triples.append(copy.triples.copy())

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        """The registered extraction for `(text, len(already_found))`, else the
        any-context row for `text`, else an empty extraction.

        Args:
            text: The text to extract from.
            already_found: The running known entities; only its length is read.

        Returns:
            A copy of the matching row, or an empty extraction.
        """
        var found_size = len(already_found)
        for i in range(len(self._sized_text)):
            if (
                self._sized_text[i] == text
                and self._sized_found[i] == found_size
            ):
                return Extraction(
                    self._sized_entities[i].copy(),
                    self._sized_triples[i].copy(),
                )
        for i in range(len(self._any_text)):
            if self._any_text[i] == text:
                return Extraction(
                    self._any_entities[i].copy(), self._any_triples[i].copy()
                )
        return Extraction()
