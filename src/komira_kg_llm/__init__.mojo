# =============================================================================
# komira_kg_llm -- model clients for the knowledge graph over two wires.
# =============================================================================
#
# The network half of the model seams of `komira_kg`: an `Embedder` and an
# `LlmClient` that talk to a server over HTTP, and the selection between
# extracting by rules and extracting by a model. The wires are named for their
# shape, a chat-completions wire and an embeddings wire, and many servers speak
# them. The package names no vendor, product or model; the address, the path,
# the credential header, the model id, the dimension and the prompts are all
# arguments, and none has a default. It reads no environment variable and no
# clock.
#
#   * transport          -- `ChatTransport`, `EmbedTransport`: post a JSON body,
#                           return the body;
#   * wire_endpoint      -- `WireEndpoint`: host, port, path, the time bound and
#                           the size bound of one exchange;
#   * auth_header        -- `AuthHeaderProvider`, `AuthHeader`, `NoAuth`,
#                           `StaticAuthHeader`, `validate_auth_header`;
#   * http_transport     -- `HttpChatTransport`, `HttpEmbedTransport`: the
#                           transports over komira's HTTP client;
#   * scripted_transport -- `ScriptedChatTransport`, `ScriptedEmbedTransport`:
#                           transports that answer from a table, for tests;
#   * embedder           -- `EmbeddingsWireEmbedder`;
#   * prompt             -- `ExtractionPrompt`, `JudgmentPrompt`,
#                           `neutral_response_schema`;
#   * chat_client        -- `ChatCompletionsLlmClient`;
#   * extract_client     -- `KgExtractClient`.
#
# `wire_json` (the request bodies and response readers) is internal.
# =============================================================================

from .auth_header import (
    AUTH_HEADER_MAX_NAME_BYTES,
    AUTH_HEADER_MAX_VALUE_BYTES,
    AuthHeader,
    AuthHeaderProvider,
    NoAuth,
    StaticAuthHeader,
    validate_auth_header,
)
from .chat_client import ChatCompletionsLlmClient
from .embedder import EmbeddingsWireEmbedder
from .extract_client import KgExtractClient
from .http_transport import (
    HTTP_ERROR_QUOTE_BYTES,
    HttpChatTransport,
    HttpEmbedTransport,
)
from .prompt import ExtractionPrompt, JudgmentPrompt, neutral_response_schema
from .scripted_transport import ScriptedChatTransport, ScriptedEmbedTransport
from .transport import ChatTransport, EmbedTransport
from .wire_endpoint import (
    ENDPOINT_MAX_HOST_BYTES,
    ENDPOINT_MAX_PATH_BYTES,
    WireEndpoint,
)
