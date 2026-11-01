# =============================================================================
# embedder -- the seam that turns text into vectors, and a deterministic stub.
# =============================================================================
#
# Ingest embeds entity names and edge facts, and the dedup read embeds the query
# name before comparing it to the stored name embeddings. All of that is one
# operation, text to vector, behind the `Embedder` trait. It is a separate seam
# from `LlmClient` because an embedding model is not a chat model.
#
# The embedder REPORTS its dimension; there is no default. A graph's manifest
# records the dimension its embedding columns were written with, and a vector
# of any other length is an error at the boundary (`unpack_embedding_checked`),
# so the dimension an embedder reports is the value the caller compares to the
# manifest. Every vector `embed` returns has exactly `dimension()` components.
#
# `StubEmbedder` is the implementation for tests. It is deterministic (the same
# text gives the same vector on every call) and cosine-meaningful: texts that
# share most of their characters give vectors with a high cosine, so the dedup
# read can be tested without a model. Its dimension is a constructor argument.
# Explicit vectors can be registered for a text, to pin a known cosine.
# =============================================================================

from std.math import sqrt


# The number of character classes the stub's fallback vector counts: the 26
# lowercase letters (upper case is folded onto them), one class for digits and
# one for every other byte.
comptime STUB_CHAR_CLASSES: Int = 28


trait Embedder(Movable, Deinitable):
    """Text to vector.

    All methods take an immutable `self`. An implementation that talks to a
    service raises on a failure; the stub never does.
    """

    def dimension(self) -> Int:
        """The number of components in every vector this embedder returns.

        Returns:
            A positive count, fixed for the life of the embedder.
        """
        ...

    def embed(self, text: String) raises -> List[Float64]:
        """Embed one text.

        Args:
            text: The text to embed (an entity name or an edge fact).

        Returns:
            A vector of exactly `dimension()` components.
        """
        ...

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        """Embed several texts.

        Args:
            texts: The texts to embed.

        Returns:
            One vector per text, in input order, each `dimension()` long.
        """
        ...


struct StubEmbedder(Embedder):
    """A deterministic, cosine-meaningful `Embedder` for tests (no model).

    `embed(text)` returns the vector registered for the text with `add_vector`,
    if any, else the text's character-class histogram folded into `dimension()`
    buckets and scaled to unit length. The same text always gives the same
    vector; texts with similar characters give vectors with a high cosine. A
    registered vector must have exactly `dimension()` components.
    """

    var _dim: Int
    var _keys: List[String]
    var _vecs: List[List[Float64]]

    def __init__(out self, dimension: Int) raises:
        """A stub that returns vectors of `dimension` components.

        Args:
            dimension: The vector width, more than zero. There is no default.
        """
        if dimension <= 0:
            raise Error(
                "StubEmbedder: dimension must be positive, got "
                + String(dimension)
            )
        self._dim = dimension
        self._keys = List[String]()
        self._vecs = List[List[Float64]]()

    def add_vector(mut self, text: String, var vec: List[Float64]) raises:
        """Register an exact vector for `text`; it wins over the fallback.

        Registering the same text again replaces the vector.

        Args:
            text: The text key.
            vec: The vector to return, exactly `dimension()` components.
        """
        if len(vec) != self._dim:
            raise Error(
                "StubEmbedder.add_vector: vector has "
                + String(len(vec))
                + " components, the embedder's dimension is "
                + String(self._dim)
            )
        for i in range(len(self._keys)):
            if self._keys[i] == text:
                self._vecs[i] = vec^
                return
        self._keys.append(text)
        self._vecs.append(vec^)

    def dimension(self) -> Int:
        """The width given at construction."""
        return self._dim

    def embed(self, text: String) raises -> List[Float64]:
        """The registered vector for `text`, else its folded histogram.

        Args:
            text: The text to embed.

        Returns:
            A vector of `dimension()` components. A fallback vector has unit
            length (an empty text puts all its weight on the "other" class).
        """
        for i in range(len(self._keys)):
            if self._keys[i] == text:
                return self._vecs[i].copy()
        return _histogram_vector(text, self._dim)

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        """Embed each text with `embed`, in input order.

        Args:
            texts: The texts to embed.

        Returns:
            One vector per text.
        """
        var out = List[List[Float64]](capacity=len(texts))
        for i in range(len(texts)):
            out.append(self.embed(texts[i]))
        return out^


def _histogram_vector(text: String, dim: Int) -> List[Float64]:
    """The unit-length character-class histogram of `text`, folded to `dim`.

    Class `c` (0 to 25 the lowercase letters, 26 digits, 27 any other byte)
    adds to bucket `c % dim`. Normalizing makes the vector independent of the
    text's length, so "name" and "name " stay close.
    """
    var buckets = List[Float64](capacity=dim)
    for _ in range(dim):
        buckets.append(0.0)
    var bytes = text.as_bytes()
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        var cls = STUB_CHAR_CLASSES - 1
        if c >= 65 and c <= 90:
            c += 32
        if c >= 97 and c <= 122:
            cls = c - 97
        elif c >= 48 and c <= 57:
            cls = 26
        buckets[cls % dim] += 1.0
    if len(bytes) == 0:
        buckets[(STUB_CHAR_CLASSES - 1) % dim] = 1.0
    var sum_sq = 0.0
    for i in range(dim):
        sum_sq += buckets[i] * buckets[i]
    var norm = sqrt(sum_sq)
    for i in range(dim):
        buckets[i] = buckets[i] / norm
    return buckets^
