# =============================================================================
# chat_client -- an `LlmClient` over a chat-completions wire.
# =============================================================================
#
# `ChatCompletionsLlmClient` makes the four model calls ingest needs by posting
# a system and a user message through a `ChatTransport` and reading the first
# choice's text:
#
#   * `extract`: the caller's `ExtractionPrompt` with the text and the entities
#     already found filled in; the answer is read as an `Extraction`;
#   * `judge_contradiction` and `judge_same_entity`: the caller's
#     `JudgmentPrompt`; the answer is read as yes or no;
#   * `synthesize`: the two messages the caller passes, sent as they are.
#
# Nothing about the prompts, the model or the address lives here. The prompts are
# arguments of the constructor, the model id has no default, and the address is
# the transport's.
#
# Reading an extraction. A model often puts the JSON in a fenced block or
# follows it with a stop token, so the reader takes the first balanced `{...}`
# of the text (braces inside a string do not count) and parses that; text with no
# balanced object is an error. In the object, an entity needs a non-empty `name`
# and a triple a non-empty `subject` and `object`; anything else is skipped, a
# field of the wrong type reads as empty, and a triple is open-ended from the
# start of time (`valid_at` 0, `invalid_at` the open-interval sentinel) because
# the prompt carries no dates; ingest dates an undated fact itself.
#
# Reading a judgment. The first word of the answer, lower-cased, decides: `yes`,
# `true` or `y` is yes, and anything else, an unsure answer included, is no. No
# is the safe side for both questions (the facts coexist, the entities stay
# distinct).
# =============================================================================

from komira_json import JsonValue, parse_json_bytes
from komira_kg import LlmClient
from komira_kg_format import EntityMention, Extraction, Triple
from komira_kg_format import TS_OPEN_SENTINEL

from .prompt import ExtractionPrompt, JudgmentPrompt
from .transport import ChatTransport
from .wire_json import chat_message_content, chat_request_json


struct ChatCompletionsLlmClient[T: ChatTransport](LlmClient):
    """An `LlmClient` that speaks the chat-completions wire through a
    transport."""

    var _transport: Self.T
    var _model_id: String
    var _extraction: ExtractionPrompt
    var _judgment: JudgmentPrompt

    def __init__(
        out self,
        var transport: Self.T,
        model_id: String,
        var extraction: ExtractionPrompt,
        var judgment: JudgmentPrompt,
    ) raises:
        """A client for one model.

        Args:
            transport: Carries the requests; moved in.
            model_id: The model id sent as `model`, not empty.
            extraction: What to say to extract entities and relations.
            judgment: What to say to ask a yes or no question.

        Raises:
            When the model id is empty.
        """
        if model_id.byte_length() == 0:
            raise Error("ChatCompletionsLlmClient: the model id is empty")
        self._transport = transport^
        self._model_id = model_id
        self._extraction = extraction^
        self._judgment = judgment^

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        """Extract entities and triples from `text` with the model.

        Args:
            text: The text to extract from.
            already_found: Entities already known; named in the prompt so the
                model gives only new ones.

        Returns:
            The extraction the model's answer holds.
        """
        var reply = self._ask(
            self._extraction.system_text,
            self._extraction.render_user(text, already_found),
            self._extraction.response_schema,
        )
        return _read_extraction(reply)

    def judge_contradiction(
        self, new_fact: String, old_fact: String
    ) raises -> Bool:
        """Ask whether `new_fact` replaces `old_fact`.

        Args:
            new_fact: The incoming fact.
            old_fact: The existing fact.

        Returns:
            True when the model's answer begins yes.
        """
        var reply = self._ask(
            self._judgment.system_text,
            self._judgment.render_contradiction(new_fact, old_fact),
            String(),
        )
        return _read_yes_no(reply)

    def judge_same_entity(
        self,
        name_a: String,
        summary_a: String,
        name_b: String,
        summary_b: String,
    ) raises -> Bool:
        """Ask whether two mentions are one entity.

        Args:
            name_a: The first name.
            summary_a: The first summary, or the empty string.
            name_b: The second name.
            summary_b: The second summary, or the empty string.

        Returns:
            True when the model's answer begins yes.
        """
        var reply = self._ask(
            self._judgment.system_text,
            self._judgment.render_same_entity(
                name_a, summary_a, name_b, summary_b
            ),
            String(),
        )
        return _read_yes_no(reply)

    def has_synthesis(self) -> Bool:
        """Whether `synthesize` can be called.

        Returns:
            True: this client always has a generative endpoint.
        """
        return True

    def synthesize(
        self, system_prompt: String, user_prompt: String
    ) raises -> String:
        """Answer from an evidence pack.

        Args:
            system_prompt: The system message, sent as given.
            user_prompt: The user message, sent as given.

        Returns:
            The text of the model's answer.
        """
        return self._ask(system_prompt, user_prompt, String())

    def _ask(
        self,
        system_text: String,
        user_text: String,
        response_schema: String,
    ) raises -> String:
        """Post one exchange and return the first choice's text."""
        var request = chat_request_json(
            self._model_id, system_text, user_text, response_schema
        )
        return chat_message_content(self._transport.complete(request))


def _read_yes_no(answer: String) -> Bool:
    """Whether the first word of `answer` is yes, true or y (any case)."""
    var bytes = answer.as_bytes()
    var n = len(bytes)
    var i = 0
    while i < n and not _is_letter(bytes[i]):
        i += 1
    var word = List[UInt8]()
    while i < n and _is_letter(bytes[i]):
        var b = bytes[i]
        if b >= 0x41 and b <= 0x5A:
            b += 32
        word.append(b)
        i += 1
    var w = String(from_utf8_lossy=Span(word))
    return w == "yes" or w == "true" or w == "y"


def _is_letter(b: UInt8) -> Bool:
    return (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A)


def _read_extraction(answer: String) raises -> Extraction:
    """The extraction in the first balanced JSON object of `answer`."""
    var span = _first_object_span(answer)
    var bytes = List[UInt8](capacity=span[1] - span[0])
    bytes.extend(answer.as_bytes()[span[0] : span[1]])
    var root = parse_json_bytes(bytes)
    var entities = List[EntityMention]()
    var triples = List[Triple]()
    if root.has("entities"):
        var list = root.get("entities")
        if list.is_array():
            for i in range(list.array_len()):
                var e = list.element_at(i)
                var name = _text_field(e, "name")
                if name.byte_length() > 0:
                    entities.append(
                        EntityMention(
                            name,
                            _text_field(e, "entity_type"),
                            _text_field(e, "summary"),
                        )
                    )
    if root.has("triples"):
        var list = root.get("triples")
        if list.is_array():
            for i in range(list.array_len()):
                var t = list.element_at(i)
                var subject = _text_field(t, "subject")
                var object = _text_field(t, "object")
                if subject.byte_length() > 0 and object.byte_length() > 0:
                    triples.append(
                        Triple(
                            subject,
                            _text_field(t, "predicate"),
                            object,
                            _text_field(t, "fact"),
                            Int64(0),
                            TS_OPEN_SENTINEL,
                        )
                    )
    return Extraction(entities^, triples^)


def _text_field(v: JsonValue, key: String) raises -> String:
    """The string member `key` of `v`, or the empty string."""
    if not v.has(key):
        return String()
    var member = v.get(key)
    if member.is_string():
        return member.as_string()
    return String()


def _first_object_span(text: String) raises -> Tuple[Int, Int]:
    """The byte range `[start, end)` of the first balanced `{...}` in `text`.

    Braces inside a JSON string, and an escaped quote inside one, do not count.
    One pass, so the cost is linear in the length of `text`.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    var start = -1
    for i in range(n):
        if bytes[i] == 0x7B:
            start = i
            break
    if start < 0:
        raise Error("model answer: there is no JSON object in it")
    var depth = 0
    var in_string = False
    var escaped = False
    for i in range(start, n):
        var c = bytes[i]
        if in_string:
            if escaped:
                escaped = False
            elif c == 0x5C:
                escaped = True
            elif c == 0x22:
                in_string = False
        elif c == 0x22:
            in_string = True
        elif c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                return (start, i + 1)
    raise Error("model answer: the JSON object is not closed")
