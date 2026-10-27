# =============================================================================
# embedder -- an `Embedder` over an embeddings wire.
# =============================================================================
#
# `EmbeddingsWireEmbedder` turns texts into vectors by posting them to an
# embeddings endpoint through an `EmbedTransport`. The model id and the
# dimension are constructor arguments with no default; the embedder reports the
# dimension, and a response whose rows have another width is refused rather than
# passed on, so the width an ingest compares with its manifest is the width
# every vector really has.
#
# A batch goes out as one request and comes back as one row per text, in input
# order. An empty batch makes no request. The embedder does not retry, and does
# not split a batch: the caller sizes its batches.
# =============================================================================

from komira_kg import Embedder

from .transport import EmbedTransport
from .wire_json import embeddings_request_json, parse_embeddings


struct EmbeddingsWireEmbedder[T: EmbedTransport](Embedder):
    """An `Embedder` that speaks the embeddings wire through a transport."""

    var _transport: Self.T
    var _model_id: String
    var _dimension: Int

    def __init__(
        out self, var transport: Self.T, model_id: String, dimension: Int
    ) raises:
        """An embedder for one model.

        Args:
            transport: Carries the requests; moved in.
            model_id: The model id sent as `model`, not empty.
            dimension: The width of every vector the model returns, more than
                zero.

        Raises:
            When the model id is empty or the dimension is not positive.
        """
        if model_id.byte_length() == 0:
            raise Error("EmbeddingsWireEmbedder: the model id is empty")
        if dimension <= 0:
            raise Error(
                "EmbeddingsWireEmbedder: dimension must be positive, got "
                + String(dimension)
            )
        self._transport = transport^
        self._model_id = model_id
        self._dimension = dimension

    def dimension(self) -> Int:
        """The width of every vector.

        Returns:
            The dimension given at construction.
        """
        return self._dimension

    def embed(self, text: String) raises -> List[Float64]:
        """Embed one text.

        Args:
            text: The text to embed.

        Returns:
            A vector of `dimension()` finite components.
        """
        var one = List[String]()
        one.append(text)
        var rows = self.embed_batch(one)
        return rows.pop(0)

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        """Embed several texts in one request.

        Args:
            texts: The texts, in order. Empty makes no request.

        Returns:
            One vector per text, in input order, each `dimension()` long.
        """
        if len(texts) == 0:
            return List[List[Float64]]()
        var request = embeddings_request_json(self._model_id, texts)
        var response = self._transport.complete(request)
        return parse_embeddings(response, len(texts), self._dimension)
