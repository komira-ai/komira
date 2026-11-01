# =============================================================================
# wire_json -- the request bodies and response readers of the two wires.
# =============================================================================
#
# The chat-completions wire and the embeddings wire are named for their shape,
# which many servers speak; nothing here is specific to one of them.
#
#   chat request       {"model": M, "messages": [{"role": "system", "content": S},
#                       {"role": "user", "content": U}]}
#                      with, when a response schema is given,
#                      "response_format": {"type": "json_schema",
#                      "json_schema": {"name": "extraction", "schema": SCHEMA}}
#   chat response      {"choices": [{"message": {"content": TEXT}}]}
#   embeddings request {"model": M, "input": [TEXT, ...]}
#   embeddings response {"data": [{"embedding": [f, ...], "index": i}, ...]}
#
# Requests are built as JSON values and serialised by komira_json, so any text
# (quotes, line breaks, control bytes, non-ASCII) reaches the wire as the same
# text. Responses are parsed from bytes by komira_json, which refuses malformed
# JSON, ill-formed UTF-8 and nesting beyond its depth limit. A server that
# answered with an `error` object has its message quoted, cut to
# `WIRE_ERROR_QUOTE_BYTES`, in the error raised.
#
# An embeddings response is held to what the caller asked: exactly one row per
# input, each row with `dimension` finite numbers, and, where rows carry an
# `index`, a permutation of the input positions. The check on the row count and
# on each row's length comes before anything is allocated from the response, so
# a hostile server cannot make the reader allocate more than it already sent.
# =============================================================================

from std.math import isfinite

from komira_json import JsonValue, parse_json_bytes, parse_json_value

# How much of a server's error message an error quotes.
comptime WIRE_ERROR_QUOTE_BYTES: Int = 512


def chat_request_json(
    model_id: String,
    system_text: String,
    user_text: String,
    response_schema: String,
) raises -> String:
    """The body of a chat-completions request.

    Args:
        model_id: The model id sent as `model`.
        system_text: The system message, sent as given.
        user_text: The user message, sent as given.
        response_schema: A JSON object that constrains the answer, or the empty
            string for none.

    Returns:
        The compact JSON body.

    Raises:
        When `response_schema` is not empty and not a JSON object.
    """
    var root = JsonValue.empty_object()
    root.set_member("model", JsonValue.from_string(model_id))
    var messages = JsonValue.empty_array()
    messages.push(_message("system", system_text))
    messages.push(_message("user", user_text))
    root.set_member("messages", messages^)
    if response_schema.byte_length() > 0:
        var schema = parse_json_value(response_schema)
        if not schema.is_object():
            raise Error("the response schema is not a JSON object")
        var inner = JsonValue.empty_object()
        inner.set_member("name", JsonValue.from_string("extraction"))
        inner.set_member("schema", schema^)
        var format = JsonValue.empty_object()
        format.set_member("type", JsonValue.from_string("json_schema"))
        format.set_member("json_schema", inner^)
        root.set_member("response_format", format^)
    return root.serialize()


def _message(role: String, content: String) raises -> JsonValue:
    var m = JsonValue.empty_object()
    m.set_member("role", JsonValue.from_string(role))
    m.set_member("content", JsonValue.from_string(content))
    return m^


def chat_message_content(response_body: String) raises -> String:
    """The text of the first choice of a chat-completions response.

    Args:
        response_body: The response body.

    Returns:
        `choices[0].message.content`.

    Raises:
        On malformed JSON, on an `error` object (quoting its message), and on a
        response with no choices or whose first choice has no string content.
    """
    var root = _parse_object(response_body)
    _raise_if_error(root)
    if not root.has("choices"):
        raise Error("chat response: there is no 'choices'")
    var choices = root.get("choices")
    if not choices.is_array() or choices.array_len() == 0:
        raise Error("chat response: 'choices' is not a non-empty array")
    var first = choices.element_at(0)
    if not first.is_object() or not first.has("message"):
        raise Error("chat response: the first choice has no 'message'")
    var message = first.get("message")
    if not message.is_object() or not message.has("content"):
        raise Error("chat response: the message has no 'content'")
    var content = message.get("content")
    if not content.is_string():
        raise Error("chat response: the message content is not text")
    return content.as_string()


def embeddings_request_json(
    model_id: String, texts: List[String]
) raises -> String:
    """The body of an embeddings request for a batch of texts.

    Args:
        model_id: The model id sent as `model`.
        texts: The inputs, sent in order as the array `input`.

    Returns:
        The compact JSON body.
    """
    var root = JsonValue.empty_object()
    root.set_member("model", JsonValue.from_string(model_id))
    var input = JsonValue.empty_array()
    for i in range(len(texts)):
        input.push(JsonValue.from_string(texts[i]))
    root.set_member("input", input^)
    return root.serialize()


def parse_embeddings(
    response_body: String, expected: Int, dimension: Int
) raises -> List[List[Float64]]:
    """The vectors of an embeddings response, in input order.

    Args:
        response_body: The response body.
        expected: How many inputs the request carried.
        dimension: The width every vector must have.

    Returns:
        One vector of `dimension` finite components per input. A row's
        `index`, where present, says which input it answers.

    Raises:
        On malformed JSON, on an `error` object (quoting its message), on a
        number of rows other than `expected`, on a row without an array
        `embedding`, on a row of another width or with a component that is not
        a finite number, and on an `index` that is not an integer, is out of
        range or repeats.
    """
    var root = _parse_object(response_body)
    _raise_if_error(root)
    if not root.has("data"):
        raise Error("embeddings response: there is no 'data'")
    var data = root.get("data")
    if not data.is_array():
        raise Error("embeddings response: 'data' is not an array")
    var n = data.array_len()
    if n != expected:
        raise Error(
            "embeddings response: "
            + String(n)
            + " rows for "
            + String(expected)
            + " inputs"
        )
    var out = List[List[Float64]](capacity=n)
    for _ in range(n):
        out.append(List[Float64]())
    var seen = List[Bool](capacity=n)
    for _ in range(n):
        seen.append(False)
    for i in range(n):
        var row = data.element_at(i)
        if not row.is_object() or not row.has("embedding"):
            raise Error(
                "embeddings response: row " + String(i) + " has no 'embedding'"
            )
        var slot = i
        if row.has("index"):
            var raw = row.get("index")
            if not raw.is_integral_number():
                raise Error(
                    "embeddings response: row "
                    + String(i)
                    + " has an 'index' that is not an integer"
                )
            var idx = raw.as_int64()
            if idx < 0 or idx >= Int64(n):
                raise Error(
                    "embeddings response: row "
                    + String(i)
                    + " has an 'index' outside 0 to "
                    + String(n - 1)
                )
            slot = Int(idx)
        if seen[slot]:
            raise Error(
                "embeddings response: two rows answer input " + String(slot)
            )
        seen[slot] = True
        var cells = row.get("embedding")
        if not cells.is_array():
            raise Error(
                "embeddings response: row "
                + String(i)
                + " 'embedding' is not an array"
            )
        if cells.array_len() != dimension:
            raise Error(
                "embeddings response: row "
                + String(i)
                + " has "
                + String(cells.array_len())
                + " components, the embedder's dimension is "
                + String(dimension)
            )
        var vec = List[Float64](capacity=dimension)
        for j in range(dimension):
            var cell = cells.element_at(j)
            if not cell.is_number():
                raise Error(
                    "embeddings response: row "
                    + String(i)
                    + " component "
                    + String(j)
                    + " is not a number"
                )
            var x = cell.as_float64()
            if not isfinite(x):
                raise Error(
                    "embeddings response: row "
                    + String(i)
                    + " component "
                    + String(j)
                    + " is not finite"
                )
            vec.append(x)
        out[slot] = vec^
    return out^


def _parse_object(body: String) raises -> JsonValue:
    """The response body as a JSON object, or an error."""
    var bytes = List[UInt8](capacity=body.byte_length())
    bytes.extend(body.as_bytes())
    var root = parse_json_bytes(bytes)
    if not root.is_object():
        raise Error("response: the body is not a JSON object")
    return root^


def _raise_if_error(root: JsonValue) raises:
    """Raise, quoting the message, when the body carries an `error` object."""
    if not root.has("error"):
        return
    var err = root.get("error")
    # A server that always includes the member says `"error": null` on success.
    if err.is_null():
        return
    if err.is_object() and err.has("message"):
        var message = err.get("message")
        if message.is_string():
            raise Error(
                "server error: "
                + bounded_text(message.as_string(), WIRE_ERROR_QUOTE_BYTES)
            )
    raise Error("server error: the response carries an error and no message")


def bounded_text(text: String, limit: Int) -> String:
    """The first `limit` bytes of `text`, cut at a character boundary.

    Args:
        text: The text.
        limit: The most bytes to keep, at least zero.

    Returns:
        `text` when it fits, else its longest prefix of at most `limit` bytes
        that ends between characters.
    """
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n <= limit:
        return text
    var cut = limit
    # Back off a UTF-8 continuation byte so the cut falls between characters.
    while cut > 0 and (bytes[cut] & 0xC0) == 0x80:
        cut -= 1
    return String(from_utf8_lossy=bytes[0:cut])
