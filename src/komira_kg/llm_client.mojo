# =============================================================================
# llm_client -- the seam for the language-model calls ingest makes, and a
# table-driven stub.
# =============================================================================
#
# Ingest needs a model for exactly three judgments, plus one optional call:
#
#   * `extract`            entity and relation extraction from an episode's text
#                          (the model-backed twin of `Extractor.extract`; the
#                          same shape, and the same `already_found` context);
#   * `judge_contradiction` does a new fact supersede an old one? The only
#                          semantic call in the bi-temporal path; the interval
#                          arithmetic around it is plain code;
#   * `judge_same_entity`   are two mentions one real-world entity? The only
#                          semantic call in the dedup path, reached only for a
#                          borderline candidate;
#   * `synthesize`          optional: answer a question from an evidence pack the
#                          caller assembled. A client without it returns False
#                          from `has_synthesis` and is never asked.
#
# Prompts are values. `synthesize` takes its system and user text from the
# caller; a client that wraps a model builds the prompts for the other calls
# from text its caller passed it. This package names no model, vendor or server
# and holds no network code: a transport is a separate package, and a host can
# implement the trait itself.
#
# `StubLlmClient` answers from tables the test fills in. Every answer is a
# lookup, so a test fixes exactly what the "model" says.
# =============================================================================

from komira_kg_format import EntityMention, Extraction

from .extractor import StubExtractor


trait LlmClient(Movable, Deinitable):
    """The language-model calls ingest makes.

    All methods take an immutable `self`. An implementation that talks to a
    service raises on a transport or parse failure; the stub raises only from
    `synthesize` when nothing is registered.
    """

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        """Extract entity mentions and relation triples from `text`.

        Args:
            text: The episode text.
            already_found: Entities already known for this text (empty on a
                first pass); only new findings are returned.

        Returns:
            The extraction, names not yet resolved. Empty when nothing is new.
        """
        ...

    def judge_contradiction(
        self, new_fact: String, old_fact: String
    ) raises -> Bool:
        """Does `new_fact` supersede `old_fact`?

        Args:
            new_fact: The incoming fact sentence.
            old_fact: The existing fact sentence between the same node pair.

        Returns:
            True when the new fact replaces the old one.
        """
        ...

    def judge_same_entity(
        self,
        name_a: String,
        summary_a: String,
        name_b: String,
        summary_b: String,
    ) raises -> Bool:
        """Are the two mentions the same real-world entity?

        Args:
            name_a: The first entity's name.
            summary_a: The first entity's summary, or "" if none.
            name_b: The second entity's name.
            summary_b: The second entity's summary, or "" if none.

        Returns:
            True when they are one entity.
        """
        ...

    def has_synthesis(self) -> Bool:
        """Whether `synthesize` can be called on this client.

        Returns:
            True when a generative call is available.
        """
        ...

    def synthesize(
        self, system_prompt: String, user_prompt: String
    ) raises -> String:
        """Answer a question from an evidence pack the caller assembled.

        Only called when `has_synthesis()` is True.

        Args:
            system_prompt: The instruction, supplied by the caller.
            user_prompt: The evidence and the question, supplied by the caller.

        Returns:
            The answer text.
        """
        ...


struct StubLlmClient(LlmClient):
    """A table-driven `LlmClient` for tests: it answers only from what was
    registered.

    `extract` is a `StubExtractor`: the rows of `add_extraction` and
    `add_extraction_any_context` behave as documented there, and a miss is an
    empty extraction. `judge_contradiction` is keyed on `(new_fact, old_fact)`
    and `judge_same_entity` on `(name_a, name_b)` (the summaries are accepted
    and not part of the key); a miss is False, meaning the facts coexist and
    the entities are distinct. `has_synthesis` is False until an answer is
    registered with `add_synthesis`; `synthesize` returns the answer registered
    for `(system_prompt, user_prompt)` and raises on a miss. Registering a key
    again replaces its answer.
    """

    var _extractor: StubExtractor
    var _con_new: List[String]
    var _con_old: List[String]
    var _con_verdict: List[Bool]
    var _same_a: List[String]
    var _same_b: List[String]
    var _same_verdict: List[Bool]
    var _syn_system: List[String]
    var _syn_user: List[String]
    var _syn_answer: List[String]

    def __init__(out self):
        """An empty stub: empty extractions, False verdicts, no synthesis."""
        self._extractor = StubExtractor()
        self._con_new = List[String]()
        self._con_old = List[String]()
        self._con_verdict = List[Bool]()
        self._same_a = List[String]()
        self._same_b = List[String]()
        self._same_verdict = List[Bool]()
        self._syn_system = List[String]()
        self._syn_user = List[String]()
        self._syn_answer = List[String]()

    def add_extraction(
        mut self, text: String, found_size: Int, result: Extraction
    ):
        """Answer `extract(text, ...)` with `result` when `already_found` has
        `found_size` entries (see `StubExtractor.add_extraction`).

        Args:
            text: The text key.
            found_size: The `len(already_found)` this row answers.
            result: The extraction to return (copied).
        """
        self._extractor.add_extraction(text, found_size, result)

    def add_extraction_any_context(mut self, text: String, result: Extraction):
        """Answer `extract(text, ...)` with `result` whatever `already_found`
        holds (see `StubExtractor.add_extraction_any_context`).

        Args:
            text: The text key.
            result: The extraction to return (copied).
        """
        self._extractor.add_extraction_any_context(text, result)

    def add_contradiction(
        mut self, new_fact: String, old_fact: String, verdict: Bool
    ):
        """Register the verdict for `(new_fact, old_fact)`.

        Args:
            new_fact: The incoming fact key.
            old_fact: The existing fact key.
            verdict: True when the new fact supersedes the old one.
        """
        for i in range(len(self._con_new)):
            if self._con_new[i] == new_fact and self._con_old[i] == old_fact:
                self._con_verdict[i] = verdict
                return
        self._con_new.append(new_fact)
        self._con_old.append(old_fact)
        self._con_verdict.append(verdict)

    def add_same_entity(
        mut self, name_a: String, name_b: String, verdict: Bool
    ):
        """Register the verdict for `(name_a, name_b)`, in that order.

        Args:
            name_a: The first name key.
            name_b: The second name key.
            verdict: True when the two are one entity.
        """
        for i in range(len(self._same_a)):
            if self._same_a[i] == name_a and self._same_b[i] == name_b:
                self._same_verdict[i] = verdict
                return
        self._same_a.append(name_a)
        self._same_b.append(name_b)
        self._same_verdict.append(verdict)

    def add_synthesis(
        mut self, system_prompt: String, user_prompt: String, answer: String
    ):
        """Register the answer for `(system_prompt, user_prompt)`; the stub
        then reports `has_synthesis()` True.

        Args:
            system_prompt: The system text key.
            user_prompt: The user text key.
            answer: The text `synthesize` returns for that pair.
        """
        for i in range(len(self._syn_system)):
            if (
                self._syn_system[i] == system_prompt
                and self._syn_user[i] == user_prompt
            ):
                self._syn_answer[i] = answer
                return
        self._syn_system.append(system_prompt)
        self._syn_user.append(user_prompt)
        self._syn_answer.append(answer)

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        """The registered extraction, else an empty one.

        Args:
            text: The text to extract from.
            already_found: The running known entities; only its length is read.

        Returns:
            A copy of the matching row, or an empty extraction.
        """
        return self._extractor.extract(text, already_found)

    def judge_contradiction(
        self, new_fact: String, old_fact: String
    ) raises -> Bool:
        """The registered verdict for `(new_fact, old_fact)`, else False."""
        for i in range(len(self._con_new)):
            if self._con_new[i] == new_fact and self._con_old[i] == old_fact:
                return self._con_verdict[i]
        return False

    def judge_same_entity(
        self,
        name_a: String,
        summary_a: String,
        name_b: String,
        summary_b: String,
    ) raises -> Bool:
        """The registered verdict for `(name_a, name_b)`, else False."""
        for i in range(len(self._same_a)):
            if self._same_a[i] == name_a and self._same_b[i] == name_b:
                return self._same_verdict[i]
        return False

    def has_synthesis(self) -> Bool:
        """True once at least one answer is registered."""
        return len(self._syn_answer) > 0

    def synthesize(
        self, system_prompt: String, user_prompt: String
    ) raises -> String:
        """The answer registered for `(system_prompt, user_prompt)`; raises when
        there is none."""
        for i in range(len(self._syn_system)):
            if (
                self._syn_system[i] == system_prompt
                and self._syn_user[i] == user_prompt
            ):
                return self._syn_answer[i]
        raise Error("StubLlmClient.synthesize: no answer registered for prompts")
