# komira_kg_llm

## Responsibility

The network half of the model seams of `komira_kg`, from
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md):
an `Embedder` and an `LlmClient` that talk to a server over HTTP, and the choice between extracting by rules and
extracting by a model.

The two wires are named for their shape, a **chat-completions wire** (a model id and a system and a user message
in, the text of the first choice out) and an **embeddings wire** (a model id and a batch of texts in, one vector per
text out). Many servers speak them. The package names no vendor, product or model, and it is configured only by
arguments:

- the address (host and port), the request path, the model id, the embedding dimension, the credential header
  and the prompts are all supplied by the caller, and none has a default;
- credentials come from an `AuthHeaderProvider` the host passes in; the package reads no environment variable;
- the prompts are values (`ExtractionPrompt`, `JudgmentPrompt`), not text inside a client;
- time enters as a number of milliseconds handed to the HTTP client; nothing here reads a clock;
- a call is made once. There is no retry.

## API

Everything is exported from `komira_kg_llm`:

- `ChatTransport` and `EmbedTransport`: post a JSON body, return the response body. The conformers over HTTP are
  `HttpChatTransport[C, A]` and `HttpEmbedTransport[C, A]` (`C` a connector, `A` an `AuthHeaderProvider`); the
  scripted ones for tests are `ScriptedChatTransport` and `ScriptedEmbedTransport`.
- `WireEndpoint`: host, port, request path, `timeout_ms` and `max_response_bytes`, all required and checked.
- `AuthHeaderProvider`, `AuthHeader`, `NoAuth`, `StaticAuthHeader`, `validate_auth_header`.
- `EmbeddingsWireEmbedder[T]`: an `Embedder` over an `EmbedTransport`; the model id and the dimension are
  constructor arguments.
- `ExtractionPrompt` (system text, user template, optional entity types, optional response schema),
  `JudgmentPrompt`, and `neutral_response_schema()`. `ExtractionPrompt.neutral()` and `JudgmentPrompt.neutral()` are
  domain-free starting values the host may use or replace.
- `ChatCompletionsLlmClient[T]`: an `LlmClient` over a `ChatTransport`.
- `KgExtractClient[X, L]`: an `LlmClient` that sends each call to an `Extractor` (rules mode) or to an `LlmClient`
  (model mode); it names neither concrete type.

## Behaviour worth knowing

- **The HTTP transports.** Each call makes a fresh connector from the factory the caller supplies (which is told
  the time bound), runs one synchronous request on a runtime of its own and drops both. A plaintext connector posts
  `http`, a TLS connector `https`; a credential sent over plaintext is for loopback tests only. A status outside
  200 to 299 raises, quoting the status and the first 256 bytes of the body but never the request. A body that ends
  before its declared length raises. A body over `max_response_bytes` raises (a response whose error body is over the
  bound raises the size error, not the status). A body that is not UTF-8 raises.
- **The credential header.** The provider is asked once per request. Its header is checked before anything is
  dialed: the name must be an HTTP token and not one the transport writes itself (`host`, `content-length`, and the
  like), and the value must hold no control byte, so a provider cannot split the request. A refusal never quotes the
  value.
- **The embedder.** A batch is one request; an empty batch makes none. A response is held to what was asked: one row
  per text, each of exactly `dimension` finite numbers, and rows that carry an `index` must be a permutation of the
  positions. Anything else is an error, never a partial result. Where the server lists rows out of order, they come
  back in input order.
- **The chat client.** The user message is the template with `{text}`, `{known}` and `{types}` filled in once, so
  a text that contains `{known}` is not substituted again. A response schema is sent as a `json_schema` response
  format only when the prompt has one. The answer to an extraction is the first balanced `{...}` of the reply (a
  fenced block or a trailing stop token is fine); an entity needs a `name`, a triple a `subject` and an `object`,
  and a triple is open from the start (`valid_at` 0, `invalid_at` the open-interval sentinel) because the prompt
  carries no dates. The answer to a judgment is yes when its first word is `yes`, `true` or `y`, and no
  otherwise, an unsure answer included.
- **Choosing the mode.** `KgExtractClient` takes a mode of `komira_kg_mode`. Rules sends `extract` to the extractor
  and answers both judgments False without asking; model sends all three calls to the model. An unknown mode is
  rules, a name from a flag is parsed with `parse_extract_mode` (only `model` is model), and model without a model is
  an error.
- **Request bodies** are built as JSON values, so any text (quotes, line breaks, NUL, non-ASCII) reaches the wire as
  the same text; responses are parsed from bytes by `komira_json`, which refuses malformed JSON and ill-formed UTF-8.

## Examples

An embedder over a scripted transport: the dimension is the caller's, and a response of another width is an error.

<!-- mojo-hidden
from std.testing import assert_equal, assert_raises
-->
```mojo
from komira_kg_llm import EmbeddingsWireEmbedder, ScriptedEmbedTransport

var transport = ScriptedEmbedTransport()
transport.add("", '{"data":[{"embedding":[0.5,0.25,0.125]}]}')
var embedder = EmbeddingsWireEmbedder[ScriptedEmbedTransport](
    transport^, "any-embedding-model", 3
)
assert_equal(embedder.dimension(), 3)
assert_equal(embedder.embed("some text")[1], 0.25)

var wrong = ScriptedEmbedTransport()
wrong.add("", '{"data":[{"embedding":[0.5,0.25]}]}')
var strict = EmbeddingsWireEmbedder[ScriptedEmbedTransport](wrong^, "m", 3)
with assert_raises(contains="2 components, the embedder's dimension is 3"):
    _ = strict.embed("some text")
```

A chat client with the caller's own prompt. The scripted row answers only a request that holds the system text, so
the example also shows that the prompt reaches the wire as given:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg import LlmClient
from komira_kg_format import EntityMention
from komira_kg_llm import (
    ChatCompletionsLlmClient,
    ExtractionPrompt,
    JudgmentPrompt,
    ScriptedChatTransport,
)

var prompt = ExtractionPrompt(
    "Extract the things named in the text as JSON.",
    "Text follows.\n{text}",
    List[String](),
    "",
)
var transport = ScriptedChatTransport()
transport.add(
    "Extract the things named in the text as JSON.",
    '{"choices":[{"message":{"content":"{\\"entities\\":[{\\"name\\":\\"Ada\\"}],'
    '\\"triples\\":[{\\"subject\\":\\"Ada\\",\\"predicate\\":\\"met\\",'
    '\\"object\\":\\"Bo\\"}]}"}}]}',
)
var client = ChatCompletionsLlmClient[ScriptedChatTransport](
    transport^, "any-chat-model", prompt^, JudgmentPrompt.neutral()
)
var found = client.extract("Ada met Bo.", List[EntityMention]())
assert_equal(found.entities[0].name, "Ada")
assert_equal(found.triples[0].object_name, "Bo")
```

A prompt is filled in once. Text that holds a placeholder is kept as it is:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg_format import EntityMention
from komira_kg_llm import ExtractionPrompt

var prompt = ExtractionPrompt("system", "[{text}]{known}", List[String](), "")
var known = List[EntityMention]()
known.append(EntityMention("Ada", "", ""))
var user = prompt.render_user("a {known} b", known)
assert_equal(
    user,
    "[a {known} b]Entities already found (do not list them again; give only"
    " new entities and relations):\n- Ada\n",
)
```

An HTTP transport is built from an endpoint, a connector factory and a credential provider. Nothing is sent until
`complete` is called; the client settings it will use show the bounds:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_kg_llm import (
    HttpChatTransport,
    StaticAuthHeader,
    WireEndpoint,
)


def make_connector(timeout_ms: Int) raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


var endpoint = WireEndpoint(
    "model.example.test",
    UInt16(8080),
    "/path/the/server/documents",
    timeout_ms=20_000,
    max_response_bytes=1_048_576,
)
var transport = HttpChatTransport[KernelTcpConnector, StaticAuthHeader](
    make_connector, endpoint^, StaticAuthHeader("X-Credential", "token-value")
)
assert_equal(transport.client_config().request_timeout_us, 20_000_000)
assert_equal(transport.client_config().max_response_body_bytes, 1_048_576)
```

Rules or model, chosen by a flag. Without `model` the extractor answers and the model is not asked:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg import StubExtractor, StubLlmClient
from komira_kg_format import EntityMention, Extraction, Triple
from komira_kg_llm import KgExtractClient
from komira_kg_mode import EXTRACT_MODE_MODEL, EXTRACT_MODE_RULES


def one(name: String) -> Extraction:
    var entities = List[EntityMention]()
    entities.append(EntityMention(name, "", ""))
    return Extraction(entities^, List[Triple]())


def build(flag: String) raises -> KgExtractClient[StubExtractor, StubLlmClient]:
    var extractor = StubExtractor()
    extractor.add_extraction_any_context("text", one("by rules"))
    var model = StubLlmClient()
    model.add_extraction_any_context("text", one("by model"))
    model.add_contradiction("new", "old", True)
    return KgExtractClient[StubExtractor, StubLlmClient].from_flag(
        flag, extractor^, Optional[StubLlmClient](model^)
    )


var rules = build("")
assert_equal(rules.mode(), EXTRACT_MODE_RULES)
assert_equal(rules.extract("text", List[EntityMention]()).entities[0].name, "by rules")
assert_false(rules.judge_contradiction("new", "old"))

var model = build("model")
assert_equal(model.mode(), EXTRACT_MODE_MODEL)
assert_equal(model.extract("text", List[EntityMention]()).entities[0].name, "by model")
assert_true(model.judge_contradiction("new", "old"))
```

## Limits

- One request per call, no retry, no streaming, no connection reuse; a host that wants any of those wraps the
  transport trait.
- A batch is sent whole: the embedder does not split it, so the caller sizes its batches (and `max_response_bytes`).
- The package does not check a response's `model` field, and it reads the first choice only.
- A model that answers an extraction with prose around several JSON objects gets the first balanced one; the
  scan is linear, but a stray `{` before the object can make it read the wrong one.
- The TLS connector, certificate trust and DNS are the HTTP client's: this package passes the host through.
