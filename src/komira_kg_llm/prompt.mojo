# =============================================================================
# prompt -- the prompts a chat client sends, as values the caller passes in.
# =============================================================================
#
# The client holds no prompt text of its own. `ExtractionPrompt` is what to say
# to a model to extract entities and relations from a text; `JudgmentPrompt` is
# what to say to ask a yes or no question about two facts or two entities. Each
# is a value the caller builds, so a different vocabulary, language or model is
# a different value, not a different client.
#
# `ExtractionPrompt.neutral()` and `JudgmentPrompt.neutral()` are ordinary
# values with domain-free text: the first asks for the named entities of a text
# and the relations between them, the second asks the question plainly. They are
# there so a host can start without writing prompts; the client never reaches
# for them on its own.
#
# A template is text with named placeholders in braces, filled in one pass: text
# that a placeholder is replaced with is never scanned again, so a document that
# contains `{text}` cannot inject another substitution, and a brace that names
# no placeholder is kept as it is.
#
#   extraction user template: {text}   the episode text (required);
#                             {known}  the entities already found, one per line
#                                      under a heading, or nothing if none;
#                             {types}  the entity types the caller lists, one
#                                      per line under a heading, or nothing.
#   contradiction template:   {new} {old}, both required.
#   same-entity template:     {a} {b}, both required; each is the name and, if
#                             there is one, the summary in parentheses.
#
# The answer of an extraction must be one JSON object of the shape
# `neutral_response_schema()` describes: `entities` (each a `name`, an optional
# `entity_type` and `summary`) and `triples` (each a `subject`, `predicate`,
# `object` and an optional `fact`). That is the contract the client parses, so
# a custom system text has to ask for it.
# =============================================================================

from komira_json import parse_json_value
from komira_kg_format import EntityMention


@fieldwise_init
struct _Binding(Copyable, Movable):
    var name: String
    var value: String


struct ExtractionPrompt(Copyable, Movable):
    """What to say to a model to extract entities and relations from a text.

    Fields:
        system_text: The system message, sent as given.
        user_template: The user message with `{text}`, and optionally `{known}`
            and `{types}`.
        entity_types: Entity types to offer the model, may be empty.
        response_schema: A JSON object (as text) that constrains the answer, or
            the empty string to rely on the prompt alone.
    """

    var system_text: String
    var user_template: String
    var entity_types: List[String]
    var response_schema: String

    def __init__(
        out self,
        system_text: String,
        user_template: String,
        entity_types: List[String],
        response_schema: String,
    ) raises:
        """Check and keep a prompt.

        Args:
            system_text: The system message, not empty.
            user_template: The user message; it must contain `{text}`.
            entity_types: Entity types to offer, each not empty.
            response_schema: A JSON object as text, or the empty string.

        Raises:
            When the system text is empty, the template lacks `{text}`, a type
            is empty, or the schema is not a JSON object.
        """
        if system_text.byte_length() == 0:
            raise Error("extraction prompt: the system text is empty")
        if "{text}" not in user_template:
            raise Error(
                "extraction prompt: the user template has no {text}, so the"
                " text would never reach the model"
            )
        for i in range(len(entity_types)):
            if entity_types[i].byte_length() == 0:
                raise Error("extraction prompt: an entity type is empty")
        if response_schema.byte_length() > 0:
            if not parse_json_value(response_schema).is_object():
                raise Error(
                    "extraction prompt: the response schema is not a JSON"
                    " object"
                )
        self.system_text = system_text
        self.user_template = user_template
        self.entity_types = entity_types.copy()
        self.response_schema = response_schema

    def __init__(out self, *, _neutral: Bool):
        """The neutral prompt, whose texts are known to pass every check."""
        self.system_text = String(_NEUTRAL_EXTRACTION_SYSTEM)
        self.user_template = String(_NEUTRAL_EXTRACTION_USER)
        self.entity_types = List[String]()
        self.response_schema = String()

    @staticmethod
    def neutral() -> ExtractionPrompt:
        """A domain-free prompt: named entities and the relations between them.

        Returns:
            A prompt with no entity types and no response schema.
        """
        return ExtractionPrompt(_neutral=True)

    def render_user(
        self, text: String, already_found: List[EntityMention]
    ) -> String:
        """The user message for one text.

        Args:
            text: The text to extract from, substituted for `{text}` unchanged.
            already_found: Entities already known for this text, listed by name
                for `{known}`; empty lists nothing.

        Returns:
            The filled-in template.
        """
        var known = String()
        if len(already_found) > 0:
            known += (
                "Entities already found (do not list them again; give only new"
                " entities and relations):\n"
            )
            for i in range(len(already_found)):
                known += "- " + already_found[i].name + "\n"
        var types = String()
        if len(self.entity_types) > 0:
            types += "Entity types (use the closest as entity_type):\n"
            for i in range(len(self.entity_types)):
                types += "- " + self.entity_types[i] + "\n"
        var bindings = List[_Binding]()
        bindings.append(_Binding("text", text))
        bindings.append(_Binding("known", known))
        bindings.append(_Binding("types", types))
        return _fill(self.user_template, bindings)


struct JudgmentPrompt(Copyable, Movable):
    """What to say to a model to ask a yes or no question.

    Fields:
        system_text: The system message, sent as given.
        contradiction_template: The user message asking whether a new fact
            supersedes an old one; it must contain `{new}` and `{old}`.
        same_entity_template: The user message asking whether two entities are
            one; it must contain `{a}` and `{b}`.
    """

    var system_text: String
    var contradiction_template: String
    var same_entity_template: String

    def __init__(
        out self,
        system_text: String,
        contradiction_template: String,
        same_entity_template: String,
    ) raises:
        """Check and keep a prompt.

        Args:
            system_text: The system message, not empty.
            contradiction_template: Must contain `{new}` and `{old}`.
            same_entity_template: Must contain `{a}` and `{b}`.

        Raises:
            When the system text is empty or a template lacks a placeholder.
        """
        if system_text.byte_length() == 0:
            raise Error("judgment prompt: the system text is empty")
        if (
            "{new}" not in contradiction_template
            or "{old}" not in contradiction_template
        ):
            raise Error(
                "judgment prompt: the contradiction template needs {new} and"
                " {old}"
            )
        if (
            "{a}" not in same_entity_template
            or "{b}" not in same_entity_template
        ):
            raise Error(
                "judgment prompt: the same-entity template needs {a} and {b}"
            )
        self.system_text = system_text
        self.contradiction_template = contradiction_template
        self.same_entity_template = same_entity_template

    def __init__(out self, *, _neutral: Bool):
        """The neutral prompt, whose texts are known to pass every check."""
        self.system_text = String(_NEUTRAL_JUDGMENT_SYSTEM)
        self.contradiction_template = String(_NEUTRAL_CONTRADICTION)
        self.same_entity_template = String(_NEUTRAL_SAME_ENTITY)

    @staticmethod
    def neutral() -> JudgmentPrompt:
        """A domain-free prompt: the question, then the two facts or entities.

        Returns:
            A prompt that asks for the single word yes or no.
        """
        return JudgmentPrompt(_neutral=True)

    def render_contradiction(self, new_fact: String, old_fact: String) -> String:
        """The user message asking whether `new_fact` supersedes `old_fact`.

        Args:
            new_fact: Substituted for `{new}` unchanged.
            old_fact: Substituted for `{old}` unchanged.

        Returns:
            The filled-in template.
        """
        var bindings = List[_Binding]()
        bindings.append(_Binding("new", new_fact))
        bindings.append(_Binding("old", old_fact))
        return _fill(self.contradiction_template, bindings)

    def render_same_entity(
        self,
        name_a: String,
        summary_a: String,
        name_b: String,
        summary_b: String,
    ) -> String:
        """The user message asking whether two mentions are one entity.

        Args:
            name_a: The first name.
            summary_a: The first summary, or the empty string.
            name_b: The second name.
            summary_b: The second summary, or the empty string.

        Returns:
            The filled-in template; each entity reads `name` or `name (summary)`.
        """
        var bindings = List[_Binding]()
        bindings.append(_Binding("a", _described(name_a, summary_a)))
        bindings.append(_Binding("b", _described(name_b, summary_b)))
        return _fill(self.same_entity_template, bindings)


def neutral_response_schema() -> String:
    """A JSON schema for the answer of an extraction, as text.

    Pass it as the `response_schema` of an `ExtractionPrompt` for a server that
    constrains its output to a schema.

    Returns:
        A schema for an object with `entities` and `triples`.
    """
    return String(_NEUTRAL_SCHEMA)


def _described(name: String, summary: String) -> String:
    if summary.byte_length() == 0:
        return name
    return name + " (" + summary + ")"


def _fill(template: String, bindings: List[_Binding]) -> String:
    """`template` with each `{name}` of `bindings` replaced, in one pass."""
    var src = template.as_bytes()
    var out = List[UInt8](capacity=len(src))
    var i = 0
    var n = len(src)
    while i < n:
        if src[i] == 0x7B:  # '{'
            var matched = False
            for k in range(len(bindings)):
                var name = bindings[k].name.as_bytes()
                var m = len(name)
                # Compare by subtraction: `i + 1 + m < n` cannot overflow.
                if m < n - i - 1 and src[i + 1 + m] == 0x7D:
                    var same = True
                    for j in range(m):
                        if src[i + 1 + j] != name[j]:
                            same = False
                            break
                    if same:
                        out.extend(bindings[k].value.as_bytes())
                        i += m + 2
                        matched = True
                        break
            if matched:
                continue
        out.append(src[i])
        i += 1
    return String(from_utf8_lossy=Span(out))


comptime _NEUTRAL_EXTRACTION_SYSTEM: StaticString = (
    "You extract a knowledge graph from text. Read the text and list the named"
    " entities it mentions and the relations between them. Use each name"
    " exactly as the text writes it. Respond with ONLY a JSON object of the"
    ' form {"entities": [{"name": "...", "entity_type": "...", "summary":'
    ' "..."}], "triples": [{"subject": "...", "predicate": "...", "object":'
    ' "...", "fact": "..."}]} and no other text. A triple names its subject and'
    " object exactly as an entity is named. If the text names nothing, answer"
    ' {"entities": [], "triples": []}.'
)

comptime _NEUTRAL_EXTRACTION_USER: StaticString = "Text:\n{text}\n{known}{types}"

comptime _NEUTRAL_JUDGMENT_SYSTEM: StaticString = (
    'Answer the question with ONLY the single word "yes" or "no".'
)

comptime _NEUTRAL_CONTRADICTION: StaticString = (
    "Does the NEW fact replace the OLD fact, so that the OLD fact is no longer"
    " true?\nNEW: {new}\nOLD: {old}\nAnswer yes or no."
)

comptime _NEUTRAL_SAME_ENTITY: StaticString = (
    "Are A and B the same entity?\nA: {a}\nB: {b}\nAnswer yes or no."
)

comptime _NEUTRAL_SCHEMA: StaticString = (
    '{"type":"object","properties":{"entities":{"type":"array","items":'
    '{"type":"object","properties":{"name":{"type":"string"},"entity_type":'
    '{"type":"string"},"summary":{"type":"string"}},"required":["name"]}},'
    '"triples":{"type":"array","items":{"type":"object","properties":'
    '{"subject":{"type":"string"},"predicate":{"type":"string"},"object":'
    '{"type":"string"},"fact":{"type":"string"}},"required":'
    '["subject","predicate","object"]}}},"required":["entities","triples"]}'
)
