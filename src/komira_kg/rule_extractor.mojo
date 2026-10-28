# =============================================================================
# rule_extractor -- an `Extractor` driven by a rule set the host supplies.
# =============================================================================
#
# `RuleExtractor` finds entities by running each `Rule` of its rule set over the
# text, and relates them by co-occurrence. It is the inference-free extractor:
# no model is called, nothing is read but the arguments, and the same text and
# the same `already_found` always give the same answer.
#
# What is an entity, what is it called and how are two entities related are all
# the host's data: the rule set (a type label and a matcher per rule), the
# names to refuse (`stop_names`), and the predicate that labels a co-occurrence
# edge. The package ships no rule set and no default for any of them; an empty
# `cooccurrence_predicate` turns the edges off. Two hosts with two rule sets get
# two vocabularies from the same code.
#
# Findings. The rules run in the order they were given, each in the order its
# matches occur in the text. A name is kept once: the first rule that finds it
# decides its type, and a name equal (ignoring ASCII case) to a stop name is
# dropped.
#
# Edges. Every pair among the first `max_cooccurrence_entities` findings gets a
# triple `(a, predicate, b)` whose fact reads "a predicate b", undated (valid
# from 0) and open (invalid at `TS_OPEN_SENTINEL`).
#
# Gleaning. `already_found` is the context argument of `Extractor`. An entity
# whose name is in it is not returned again, and a pair is returned only if at
# least one of its two names is not in it. So the first pass returns everything,
# a pass that is given the first pass's entities returns nothing, and a host that
# seeds `already_found` from its graph gets only the entities and the edges that
# touch something new.
# =============================================================================

from std.collections import Dict

from komira_kg_format import EntityMention, Extraction, TS_OPEN_SENTINEL, Triple

from .extractor import Extractor
from .rule import Rule, ascii_lower
from .rule_scan import scan_rule


struct RuleExtractor(Extractor):
    """An `Extractor` that applies a host-supplied rule set (see the header)."""

    var _rules: List[Rule]
    var _stop_names: List[String]
    var _predicate: String
    var _max_entities: Int

    def __init__(
        out self,
        var rules: List[Rule],
        var stop_names: List[String],
        var cooccurrence_predicate: String,
        max_cooccurrence_entities: Int,
    ) raises:
        """An extractor over `rules`.

        Args:
            rules: The rule set; may be empty (the extractor then finds nothing).
            stop_names: Names never returned as entities, compared ignoring
                ASCII case.
            cooccurrence_predicate: The predicate of a co-occurrence edge, or
                empty for no edges.
            max_cooccurrence_entities: How many findings take part in edges;
                it bounds the edges at n(n-1)/2 for n findings of a text.

        Raises:
            If `max_cooccurrence_entities` is negative, or a stop name is empty.
        """
        if max_cooccurrence_entities < 0:
            raise Error(
                "RuleExtractor: max_cooccurrence_entities is negative ("
                + String(max_cooccurrence_entities)
                + ")"
            )
        var lowered = List[String](capacity=len(stop_names))
        for i in range(len(stop_names)):
            if len(stop_names[i].as_bytes()) == 0:
                raise Error("RuleExtractor: stop name " + String(i) + " is empty")
            lowered.append(ascii_lower(stop_names[i]))
        self._rules = rules^
        self._stop_names = lowered^
        self._predicate = cooccurrence_predicate^
        self._max_entities = max_cooccurrence_entities

    def num_rules(self) -> Int:
        """The number of rules in the rule set."""
        return len(self._rules)

    def _is_stop(self, name: String) -> Bool:
        var low = ascii_lower(name)
        for i in range(len(self._stop_names)):
            if self._stop_names[i] == low:
                return True
        return False

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        """The entities and co-occurrence edges the rule set finds in `text`
        that `already_found` does not account for.

        Args:
            text: The text to scan.
            already_found: Entities already known for this text.

        Returns:
            The new entities and the edges touching a new one.
        """
        var names = List[String]()
        var types = List[String]()
        var seen = Dict[String, Int]()
        for r in range(len(self._rules)):
            var hits = scan_rule(self._rules[r], text)
            for h in range(len(hits)):
                var name = hits[h]
                if name in seen or self._is_stop(name):
                    continue
                seen[name] = len(names)
                names.append(name)
                types.append(self._rules[r].entity_type)
        var known = Dict[String, Int]()
        for i in range(len(already_found)):
            known[already_found[i].name] = i
        var entities = List[EntityMention]()
        var is_new = List[Bool](capacity=len(names))
        for i in range(len(names)):
            var fresh = names[i] not in known
            is_new.append(fresh)
            if fresh:
                entities.append(EntityMention(names[i], types[i], String("")))
        var triples = List[Triple]()
        if len(self._predicate.as_bytes()) > 0:
            var k = len(names)
            if k > self._max_entities:
                k = self._max_entities
            for i in range(k):
                for j in range(i + 1, k):
                    if not (is_new[i] or is_new[j]):
                        continue
                    triples.append(
                        Triple(
                            names[i],
                            self._predicate,
                            names[j],
                            names[i] + " " + self._predicate + " " + names[j],
                            Int64(0),
                            TS_OPEN_SENTINEL,
                        )
                    )
        return Extraction(entities^, triples^)
