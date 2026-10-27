# =============================================================================
# extract_client -- choose between extracting by rules and extracting by a model.
# =============================================================================
#
# `KgExtractClient` is an `LlmClient` that sends each call to one of two things
# the host gives it: an `Extractor` (no model: rules, or anything else that needs
# none) or an `LlmClient` (a model). It names neither concrete type, so any
# extractor and any client fit.
#
# The mode is the integer of `komira_kg_mode`.
#
#   rules  `extract` goes to the extractor. The two judgments answer False
#          (facts coexist, entities stay distinct) without asking anything. A
#          model, if one was given, is used for `synthesize` only.
#   model  `extract` and both judgments go to the model, and so does
#          `synthesize`. The extractor is not called.
#
# Rules is the default and the fallback: `select` normalises its mode with
# `normalize_extract_mode`, so an integer this build does not know is rules, and
# `from_flag` parses a name with `parse_extract_mode`, so anything but `model`
# is rules. A mode of model needs a model: asking for it without one is an
# error, not a silent fall back to rules, because the host asked for something
# it did not provide.
#
# Why a wrapper at all: the ingest code takes one `LlmClient` type. A client
# that carries the mode as data keeps one instantiation of everything above it,
# where a type per mode would double it.
# =============================================================================

from komira_kg import Extractor, LlmClient
from komira_kg_format import EntityMention, Extraction
from komira_kg_mode import (
    EXTRACT_MODE_MODEL,
    EXTRACT_MODE_RULES,
    KgExtractMode,
    normalize_extract_mode,
    parse_extract_mode,
)


struct KgExtractClient[X: Extractor, L: LlmClient](LlmClient):
    """An `LlmClient` that routes by extraction mode between an `Extractor` and
    an `LlmClient`."""

    var _mode: Int
    var _extractor: Self.X
    var _model: Optional[Self.L]

    def __init__(
        out self,
        mode: Int,
        var extractor: Self.X,
        var model: Optional[Self.L],
    ) raises:
        """Select a mode.

        Args:
            mode: An extraction mode of `komira_kg_mode`; an unknown integer is
                taken as rules.
            extractor: The extractor of rules mode.
            model: The model of model mode, if there is one.

        Raises:
            When the mode is model and no model was given.
        """
        var resolved = normalize_extract_mode(mode)
        if resolved == EXTRACT_MODE_MODEL and not model:
            raise Error(
                "KgExtractClient: the mode is model but no model was given"
            )
        self._mode = resolved
        self._extractor = extractor^
        self._model = model^

    @staticmethod
    def from_flag(
        name: String, var extractor: Self.X, var model: Optional[Self.L]
    ) raises -> Self:
        """Select a mode by name, as a flag gives it.

        Args:
            name: `model` (any ASCII case) for model mode; anything else,
                including the empty string, is rules.
            extractor: The extractor of rules mode.
            model: The model of model mode, if there is one.

        Returns:
            The client.

        Raises:
            When the name selects model and no model was given.
        """
        return Self(parse_extract_mode(name), extractor^, model^)

    def mode(self) -> KgExtractMode:
        """The mode in force.

        Returns:
            `EXTRACT_MODE_RULES` or `EXTRACT_MODE_MODEL`.
        """
        return self._mode

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        """Extract with the model in model mode, else with the extractor.

        Args:
            text: The text to extract from.
            already_found: Entities already known for the text.

        Returns:
            The extraction.
        """
        if self._mode == EXTRACT_MODE_MODEL:
            return self._model.value().extract(text, already_found)
        return self._extractor.extract(text, already_found)

    def judge_contradiction(
        self, new_fact: String, old_fact: String
    ) raises -> Bool:
        """Ask the model in model mode; in rules mode the facts coexist.

        Args:
            new_fact: The incoming fact.
            old_fact: The existing fact.

        Returns:
            The model's verdict, or False in rules mode.
        """
        if self._mode == EXTRACT_MODE_MODEL:
            return self._model.value().judge_contradiction(new_fact, old_fact)
        return False

    def judge_same_entity(
        self,
        name_a: String,
        summary_a: String,
        name_b: String,
        summary_b: String,
    ) raises -> Bool:
        """Ask the model in model mode; in rules mode the entities are distinct.

        Args:
            name_a: The first name.
            summary_a: The first summary, or the empty string.
            name_b: The second name.
            summary_b: The second summary, or the empty string.

        Returns:
            The model's verdict, or False in rules mode.
        """
        if self._mode == EXTRACT_MODE_MODEL:
            return self._model.value().judge_same_entity(
                name_a, summary_a, name_b, summary_b
            )
        return False

    def has_synthesis(self) -> Bool:
        """Whether a model is present and can synthesize.

        Returns:
            True when a model was given and it reports synthesis.
        """
        if self._model:
            return self._model.value().has_synthesis()
        return False

    def synthesize(
        self, system_prompt: String, user_prompt: String
    ) raises -> String:
        """Answer with the model, in either mode.

        Args:
            system_prompt: The system message.
            user_prompt: The user message.

        Returns:
            The model's answer.

        Raises:
            When no model was given.
        """
        if not self._model:
            raise Error("KgExtractClient.synthesize: no model was given")
        return self._model.value().synthesize(system_prompt, user_prompt)
