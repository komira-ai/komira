# =============================================================================
# ingest_types -- the values that cross the extractor boundary.
# =============================================================================
#
# What an LLM or a rule-based extractor returns for ONE episode: entity mentions
# and relation triples, before any deduplication, alias resolution or bi-temporal
# upsert. Subjects, objects and mentions are still bare NAMES here; the ingest
# step resolves them to dense node ids, because an extractor does not know the
# graph's id space.
#
# Owned `String` and `List` only: no pointer, no wildcard origin. `Triple` and
# `EntityMention` are `Copyable` (their fields are `String` and `Int64`).
# `Extraction` is `Movable` only: it holds two lists and is moved through the
# gleaning fold, and making it `Copyable` would deep-copy both lists on every
# step of a fold that never needs a copy. Construct, move, drain.
# =============================================================================


@fieldwise_init
struct Triple(Copyable, Movable):
    """A relation triple extracted from an episode (names not yet resolved).

    Fields:
        subject_name: The subject entity's name.
        predicate: The relation label (for example "uses" or "supersedes").
        object_name: The object entity's name.
        fact: The natural-language fact sentence (the text that gets the
            fact embedding).
        valid_at: Event-time start the extractor dated the fact at (epoch), or
            the episode's own time when the fact is undated.
        invalid_at: Event-time end (epoch); the schema's open-interval sentinel
            when the fact is still open.
    """

    var subject_name: String
    var predicate: String
    var object_name: String
    var fact: String
    var valid_at: Int64
    var invalid_at: Int64


@fieldwise_init
struct EntityMention(Copyable, Movable):
    """An entity mention extracted from an episode (name not yet resolved).

    Fields:
        name: The entity's surface name.
        entity_type: The extractor's type for it, or "" if untyped.
        summary: A short summary of the entity, or "" if none.
    """

    var name: String
    var entity_type: String
    var summary: String


struct Extraction(Movable):
    """The raw extraction for one episode: entity mentions and relation triples.

    The result of one extract call. The gleaning passes' extractions are folded
    into one, and the union is then deduplicated. A value type, moved not
    copied.

    Fields:
        entities: The extracted entity mentions (names not yet resolved).
        triples: The extracted relation triples (names not yet resolved).
    """

    var entities: List[EntityMention]
    var triples: List[Triple]

    def __init__(out self):
        """An empty extraction (no entities, no triples)."""
        self.entities = List[EntityMention]()
        self.triples = List[Triple]()

    def __init__(
        out self,
        var entities: List[EntityMention],
        var triples: List[Triple],
    ):
        """Construct from owned entity and triple lists.

        Args:
            entities: The extracted entity mentions (moved in).
            triples: The extracted relation triples (moved in).
        """
        self.entities = entities^
        self.triples = triples^

    def num_entities(self) -> Int:
        """Count of extracted entity mentions."""
        return len(self.entities)

    def num_triples(self) -> Int:
        """Count of extracted relation triples."""
        return len(self.triples)
