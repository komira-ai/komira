# =============================================================================
# komira_aws_core/aws_xml.mojo -- the restXml body codec and restXml errors
# =============================================================================
#
# What a generated restXml client calls to put a shape into an XML body, and
# take one out, over komira_xml (a plain XML codec that knows nothing of
# AWS). The rules are the Smithy restXml protocol's
# (https://smithy.io/2.0/aws/protocols/aws-restxml-protocol.html) and the
# XML binding traits (https://smithy.io/2.0/spec/protocol-traits.html:
# xmlName, xmlNamespace, xmlAttribute, xmlFlattened). The element and
# attribute NAMES are the generator's: it applies xmlName and passes the
# resulting name, so nothing here reads a model.
#
# Scalars. An XML scalar is the same text a REST-bound scalar is
# (aws_text.mojo): "true" / "false"; a decimal integer; a decimal number or
# "NaN" / "Infinity" / "-Infinity"; a blob as standard padded base64; a
# timestamp in the member's timestampFormat, date-time (AWS_TS_ISO8601)
# when it has none -- the body default restXml states. Text is escaped by
# the writer. A string is read as written, whitespace included; every other
# scalar is read with leading and trailing XML whitespace (SP, TAB, CR, LF)
# removed, as botocore's readers do (Python's int() and float() strip it),
# and then as strictly as aws_text.mojo reads it. An empty element is the
# empty string, the empty blob, and refused for every other scalar; an
# ABSENT element is no value (`None`). A scalar element that holds child
# elements is refused.
#
# Structures. A member is an element named by its xmlName (the member name
# when none). Elements are matched by LOCAL name, whatever their namespace,
# as botocore does (`_node_tag`). A non-list member that occurs more than
# once takes its LAST occurrence, as the AWS SDK XML decoders do
# (aws-sdk-go-v2, smithy-rs: each occurrence overwrites the member);
# elements the shape does not name are ignored.
#
# Lists. A wrapped list is one element named for the member, holding one
# element per item named by the list member's xmlName ("member" by
# default); children of the wrapper with another name are ignored. A
# flattened list (xmlFlattened) is one element per item, each named for the
# member, directly in the structure. A wrapped list that is present and
# empty is the empty list; a list with no element at all is `None`.
#
# Maps. A wrapped map is one element named for the member, holding one
# <entry> per entry; a flattened map is one element per entry named for the
# member. Each entry holds the key element and the value element, named by
# the key's and the value's xmlName ("key" and "value" by default). An
# entry with no key or no value, or with any other child, is refused, as
# botocore refuses one ("Unknown tag"). A later entry for the same key
# replaces an earlier one.
#
# Attributes (xmlAttribute) are written on the structure's start tag as
# given; a name with a prefix ("xsi:type") needs that prefix declared with
# `aws_xml_namespace`. Read back, an unprefixed name matches an attribute in
# no namespace, a prefixed one ("p:local") an attribute with that local name
# in a namespace, whatever prefix the document gave it -- botocore's rule
# (it rewrites `{uri}local` to the model's prefix before matching).
#
# Namespaces (xmlNamespace): `aws_xml_namespace` writes `xmlns="uri"`, or
# `xmlns:prefix="uri"`, on the element just started.
#
# Errors. `aws_rest_xml_error` reads the restXml error forms
# (https://smithy.io/2.0/aws/protocols/aws-restxml-protocol.html,
# "Error response serialization"):
#
#   <ErrorResponse><Error><Code/><Message/></Error><RequestId/></ErrorResponse>
#   <Error><Code/><Message/><RequestId/></Error>          (S3, and with
#                                                          @awsQueryError)
#
# and, as botocore's RestXMLParser does (`_do_error_parse`), takes the HTTP
# status as the code of a response whose body is empty (a HEAD) or is not
# XML. A body that is XML but names no code has code "". The request id is
# the `x-amzn-RequestId` header, else `x-amz-request-id` (S3), else the
# body's <RequestId> (botocore's `_populate_response_metadata`, then the
# body). Code and message are cleaned and capped as aws_codec.mojo cleans
# them; nothing else is read from the body, which can hold a secret.
#
# `aws_xml_body_is_error` is S3's 200-with-<Error> check
# (botocore/handlers.py `_looks_like_special_case_error`): a 200 whose body
# is not empty and either is not XML (a body cut short in transit) or has
# the root element <Error> in no namespace. Which operations it applies to
# (those whose output payload is not a blob or a string) is the generator's
# call, not this module's.
# =============================================================================

from std.collections import Dict

from komira_xml import XmlNode, XmlWriter, parse_xml

from ._text import ascii_lower, has_control, utf8_valid
from .aws_codec import _clean_message, aws_error_code
from .aws_error import AWS_REQUEST_ID_MAX_BYTES, AwsErrorInfo, aws_request_id
from .aws_request import AwsRequest, AwsResponse
from .aws_text import (
    aws_blob_from_base64,
    aws_bool_from_text,
    aws_f64_from_text,
    aws_int_from_text,
    aws_text_blob,
    aws_text_bool,
    aws_text_f32,
    aws_text_f64,
    aws_text_int,
    aws_text_ts,
    aws_ts_from_text,
)


# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------


def _check_name(name: String, what: StaticString) raises:
    """An element, attribute or prefix name the generator passes. Only what
    would break the document is refused: an empty name, and a byte that
    cannot appear in an XML name (space, control, quote, '<', '>', '&',
    '=', '/')."""
    var b = name.as_bytes()
    if len(b) == 0:
        raise Error("an AWS XML " + String(what) + " name is empty")
    for i in range(len(b)):
        var c = b[i]
        if (
            c <= UInt8(0x20)
            or c == UInt8(0x7F)
            or c == UInt8(0x22)
            or c == UInt8(0x27)
            or c == UInt8(0x3C)
            or c == UInt8(0x3E)
            or c == UInt8(0x26)
            or c == UInt8(0x3D)
            or c == UInt8(0x2F)
        ):
            raise Error(
                "the AWS XML " + String(what) + " name '" + name
                + "' holds a byte no XML name can"
            )


def aws_xml_start(mut w: XmlWriter, name: String) raises:
    """Opens element `name` (a structure, a wrapped list or map, a map
    entry). Attributes and a namespace go on it before its content."""
    _check_name(name, "element")
    w.start_element(name)


def aws_xml_end(mut w: XmlWriter) raises:
    """Closes the innermost open element."""
    w.end_element()


def aws_xml_namespace(mut w: XmlWriter, prefix: String, uri: String) raises:
    """The xmlNamespace trait on the element just started: `xmlns="uri"`
    when `prefix` is "", else `xmlns:prefix="uri"`. Refuses an empty `uri`
    (Namespaces in XML 1.0 cannot undeclare a prefix), the reserved
    prefixes `xml` and `xmlns`, and a prefix holding ':'."""
    if uri.byte_length() == 0:
        raise Error("an AWS XML namespace has an empty uri")
    if prefix.byte_length() == 0:
        w.attr("xmlns", uri)
        return
    _check_name(prefix, "namespace prefix")
    if prefix.find(":") >= 0:
        raise Error("the AWS XML namespace prefix '" + prefix + "' holds ':'")
    if ascii_lower(prefix) == "xml" or ascii_lower(prefix) == "xmlns":
        raise Error("the AWS XML namespace prefix '" + prefix + "' is reserved")
    w.attr("xmlns:" + prefix, uri)


def aws_xml_attr(mut w: XmlWriter, name: String, text: String) raises:
    """An xmlAttribute member, as its text (aws_text.mojo's `aws_text_*`
    for a non-string scalar), on the element just started."""
    _check_name(name, "attribute")
    w.attr(name, text)


def aws_xml_write_text(mut w: XmlWriter, name: String, text: String) raises:
    """`<name>text</name>`, the text escaped."""
    aws_xml_start(w, name)
    w.text(text)
    w.end_element()


def aws_xml_write_string(mut w: XmlWriter, name: String, value: String) raises:
    aws_xml_write_text(w, name, value)


def aws_xml_write_bool(mut w: XmlWriter, name: String, value: Bool) raises:
    aws_xml_write_text(w, name, aws_text_bool(value))


def aws_xml_write_int(mut w: XmlWriter, name: String, value: Int64) raises:
    """Any integer kind (byte, short, integer, long, intEnum), widened."""
    aws_xml_write_text(w, name, aws_text_int(value))


def aws_xml_write_f64(mut w: XmlWriter, name: String, value: Float64) raises:
    """A double: the number, or "NaN" / "Infinity" / "-Infinity"."""
    aws_xml_write_text(w, name, aws_text_f64(value))


def aws_xml_write_f32(mut w: XmlWriter, name: String, value: Float32) raises:
    """A float, at Float32 precision."""
    aws_xml_write_text(w, name, aws_text_f32(value))


def aws_xml_write_blob(
    mut w: XmlWriter, name: String, data: Span[UInt8, _]
) raises:
    """A blob: standard base64, padded."""
    aws_xml_write_text(w, name, aws_text_blob(data))


def aws_xml_write_ts(
    mut w: XmlWriter, name: String, epoch_seconds: Float64, fmt: Int
) raises:
    """A timestamp in `fmt` (AWS_TS_ISO8601, the restXml body default;
    AWS_TS_RFC822; AWS_TS_UNIX). Refuses NaN and anything outside
    1970..9999."""
    aws_xml_write_text(w, name, aws_text_ts(epoch_seconds, fmt))


def aws_xml_list_start(mut w: XmlWriter, name: String, flattened: Bool) raises:
    """Opens a list member: its wrapper element `name`, or nothing for a
    flattened list, whose items are each named `name`."""
    if not flattened:
        aws_xml_start(w, name)


def aws_xml_list_end(mut w: XmlWriter, flattened: Bool) raises:
    """Closes what `aws_xml_list_start` opened."""
    if not flattened:
        w.end_element()


def aws_xml_map_start(mut w: XmlWriter, name: String, flattened: Bool) raises:
    """Opens a map member: its wrapper element `name`, or nothing for a
    flattened map."""
    if not flattened:
        aws_xml_start(w, name)


def aws_xml_map_end(mut w: XmlWriter, flattened: Bool) raises:
    """Closes what `aws_xml_map_start` opened."""
    if not flattened:
        w.end_element()


def aws_xml_map_entry_start(
    mut w: XmlWriter, name: String, flattened: Bool
) raises:
    """Opens one map entry: <entry> in a wrapped map, <name> in a flattened
    one. The key and value elements go in it; `aws_xml_end` closes it."""
    aws_xml_start(w, name if flattened else String("entry"))


def aws_xml_write_string_list(
    mut w: XmlWriter,
    name: String,
    member_name: String,
    values: List[String],
    flattened: Bool,
) raises:
    """A list of strings: in a wrapper `name`, each item `member_name`; or,
    flattened, each item `name`."""
    aws_xml_list_start(w, name, flattened)
    var item = name if flattened else member_name
    for i in range(len(values)):
        aws_xml_write_string(w, item, values[i])
    aws_xml_list_end(w, flattened)


def aws_xml_write_string_map(
    mut w: XmlWriter,
    name: String,
    key_name: String,
    value_name: String,
    entries: Dict[String, String],
    flattened: Bool,
) raises:
    """A map of strings to strings, entries in the map's order."""
    aws_xml_map_start(w, name, flattened)
    for e in entries.items():
        aws_xml_map_entry_start(w, name, flattened)
        aws_xml_write_string(w, key_name, e.key)
        aws_xml_write_string(w, value_name, e.value)
        w.end_element()
    aws_xml_map_end(w, flattened)


def aws_xml_set_body(mut req: AwsRequest, mut w: XmlWriter) raises:
    """Sets `req.body` to the document `w` holds. Refuses one with an
    element still open."""
    req.set_body_text(w.finish())


# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------


def aws_xml_parse(body: List[UInt8]) raises -> XmlNode:
    """The root element of a restXml body. An empty body is an empty
    element (no members), as botocore reads one. Refuses a body that is not
    well-formed UTF-8 or not well-formed XML, quoting none of it."""
    if len(body) == 0:
        return XmlNode()
    if not utf8_valid(Span(body)):
        raise Error("the AWS XML body is not well-formed UTF-8")
    try:
        return parse_xml(StringSlice(unsafe_from_utf8=Span(body)))
    except:
        raise Error("the AWS XML body is not well-formed XML")


def aws_xml_child(node: XmlNode, name: String) -> Int:
    """The position in `node.children` of the LAST direct child with local
    name `name`, or -1."""
    var i = len(node.children) - 1
    while i >= 0:
        if node.children[i].local == name:
            return i
        i -= 1
    return -1


def _scalar_text(node: XmlNode) raises -> String:
    if len(node.children) > 0:
        raise Error(
            "the AWS XML scalar <" + node.local + "> holds child elements"
        )
    return node.text.copy()


def _scalar_trimmed(node: XmlNode) raises -> String:
    if len(node.children) > 0:
        raise Error(
            "the AWS XML scalar <" + node.local + "> holds child elements"
        )
    return node.trimmed_text()


def aws_xml_string_of(node: XmlNode) raises -> String:
    """A string element's text, as written: "" for an empty element."""
    return _scalar_text(node)


def aws_xml_bool_of(node: XmlNode) raises -> Bool:
    return aws_bool_from_text(_scalar_trimmed(node))


def aws_xml_int_of(node: XmlNode, bits: Int) raises -> Int64:
    """A `bits`-bit signed integer (8, 16, 32 or 64)."""
    return aws_int_from_text(_scalar_trimmed(node), bits)


def aws_xml_f64_of(node: XmlNode) raises -> Float64:
    return aws_f64_from_text(_scalar_trimmed(node))


def aws_xml_f32_of(node: XmlNode) raises -> Float32:
    return Float32(aws_f64_from_text(_scalar_trimmed(node)))


def aws_xml_blob_of(node: XmlNode) raises -> List[UInt8]:
    """A blob from its base64 text; an empty element is the empty blob."""
    var t = _scalar_trimmed(node)
    if t.byte_length() == 0:
        return List[UInt8]()
    return aws_blob_from_base64(t)


def aws_xml_ts_of(node: XmlNode, fmt: Int) raises -> Float64:
    """Epoch seconds from a timestamp written in `fmt`."""
    return aws_ts_from_text(_scalar_trimmed(node), fmt)


def aws_xml_get_string(node: XmlNode, name: String) raises -> Optional[String]:
    """Member `name` of a structure element: `None` when absent."""
    var i = aws_xml_child(node, name)
    if i < 0:
        return None
    return aws_xml_string_of(node.children[i])


def aws_xml_get_bool(node: XmlNode, name: String) raises -> Optional[Bool]:
    var i = aws_xml_child(node, name)
    if i < 0:
        return None
    return aws_xml_bool_of(node.children[i])


def aws_xml_get_int(
    node: XmlNode, name: String, bits: Int
) raises -> Optional[Int64]:
    var i = aws_xml_child(node, name)
    if i < 0:
        return None
    return aws_xml_int_of(node.children[i], bits)


def aws_xml_get_f64(node: XmlNode, name: String) raises -> Optional[Float64]:
    var i = aws_xml_child(node, name)
    if i < 0:
        return None
    return aws_xml_f64_of(node.children[i])


def aws_xml_get_f32(node: XmlNode, name: String) raises -> Optional[Float32]:
    var i = aws_xml_child(node, name)
    if i < 0:
        return None
    return aws_xml_f32_of(node.children[i])


def aws_xml_get_blob(
    node: XmlNode, name: String
) raises -> Optional[List[UInt8]]:
    var i = aws_xml_child(node, name)
    if i < 0:
        return None
    return aws_xml_blob_of(node.children[i])


def aws_xml_get_ts(
    node: XmlNode, name: String, fmt: Int
) raises -> Optional[Float64]:
    var i = aws_xml_child(node, name)
    if i < 0:
        return None
    return aws_xml_ts_of(node.children[i], fmt)


def aws_xml_get_struct(node: XmlNode, name: String) -> Optional[XmlNode]:
    """A copy of the structure member `name`, `None` when absent."""
    var i = aws_xml_child(node, name)
    if i < 0:
        return None
    return node.children[i].copy()


def aws_xml_get_attr(node: XmlNode, name: String) -> Optional[String]:
    """The xmlAttribute `name` of `node`, `None` when absent. "local"
    matches an attribute in no namespace; "p:local" an attribute named
    `local` in any namespace."""
    var want_ns = False
    var local = name
    var colon = name.find(":")
    if colon >= 0:
        want_ns = True
        local = String(
            StringSlice(unsafe_from_utf8=name.as_bytes()[colon + 1 :])
        )
    for i in range(len(node.attr_local)):
        if node.attr_local[i] != local:
            continue
        if (node.attr_ns[i].byte_length() > 0) == want_ns:
            return node.attr_value[i].copy()
    return None


def aws_xml_list_items(
    node: XmlNode, name: String, member_name: String, flattened: Bool
) -> Optional[List[XmlNode]]:
    """The item elements of list member `name`, copied, in document order:
    the `member_name` children of the (last) wrapper `name`, or, flattened,
    every `name` child of `node`. `None` when the list has no element."""
    var out = List[XmlNode]()
    if flattened:
        for i in range(len(node.children)):
            if node.children[i].local == name:
                out.append(node.children[i].copy())
        if len(out) == 0:
            return None
        return out^
    var w = aws_xml_child(node, name)
    if w < 0:
        return None
    ref wrapper = node.children[w]
    for i in range(len(wrapper.children)):
        if wrapper.children[i].local == member_name:
            out.append(wrapper.children[i].copy())
    return out^


def aws_xml_map_entries(
    node: XmlNode, name: String, flattened: Bool
) -> Optional[List[XmlNode]]:
    """The entry elements of map member `name`, copied, in document order:
    the <entry> children of the (last) wrapper `name`, or, flattened, every
    `name` child of `node`. `None` when the map has no element."""
    return aws_xml_list_items(node, name, String("entry"), flattened)


def _entry_part(
    entry: XmlNode, key_name: String, value_name: String, want_key: Bool
) raises -> Int:
    var at = -1
    for i in range(len(entry.children)):
        var n = entry.children[i].local
        if n == key_name:
            if want_key:
                at = i
        elif n == value_name:
            if not want_key:
                at = i
        else:
            raise Error(
                "an AWS XML map entry holds <" + n + ">, neither its key nor"
                + " its value"
            )
    if at < 0:
        raise Error(
            "an AWS XML map entry has no <"
            + (key_name if want_key else value_name)
            + ">"
        )
    return at


def aws_xml_entry_key(
    entry: XmlNode, key_name: String, value_name: String
) raises -> String:
    """The key of a map entry, as written. Refuses an entry with no key or
    with a child that is neither the key nor the value."""
    return aws_xml_string_of(
        entry.children[_entry_part(entry, key_name, value_name, True)]
    )


def aws_xml_entry_value(
    entry: XmlNode, key_name: String, value_name: String
) raises -> XmlNode:
    """A copy of the value element of a map entry, for the value's reader.
    Refuses an entry with no value or with a child that is neither the key
    nor the value."""
    return entry.children[
        _entry_part(entry, key_name, value_name, False)
    ].copy()


def aws_xml_get_string_list(
    node: XmlNode, name: String, member_name: String, flattened: Bool
) raises -> Optional[List[String]]:
    """List member `name` of strings; `None` when it has no element."""
    var items = aws_xml_list_items(node, name, member_name, flattened)
    if not items:
        return None
    var out = List[String]()
    for i in range(len(items.value())):
        out.append(aws_xml_string_of(items.value()[i]))
    return out^


def aws_xml_get_string_map(
    node: XmlNode,
    name: String,
    key_name: String,
    value_name: String,
    flattened: Bool,
) raises -> Optional[Dict[String, String]]:
    """Map member `name` of strings to strings; `None` when it has no
    element. A later entry for a key replaces an earlier one."""
    var entries = aws_xml_map_entries(node, name, flattened)
    if not entries:
        return None
    var out = Dict[String, String]()
    for i in range(len(entries.value())):
        ref e = entries.value()[i]
        var k = aws_xml_entry_key(e, key_name, value_name)
        out[k] = aws_xml_string_of(aws_xml_entry_value(e, key_name, value_name))
    return out^


# -----------------------------------------------------------------------------
# Errors
# -----------------------------------------------------------------------------


def _request_id_text(v: String) -> String:
    if v.byte_length() > AWS_REQUEST_ID_MAX_BYTES or has_control(v):
        return String("")
    if v.find(" ") >= 0:
        return String("")
    return v


def _child_trimmed(node: XmlNode, name: String) -> String:
    var i = aws_xml_child(node, name)
    if i < 0 or len(node.children[i].children) > 0:
        return String("")
    return node.children[i].trimmed_text()


def aws_xml_error_info(
    status: Int, body: List[UInt8], request_id: String
) -> AwsErrorInfo:
    """The `AwsErrorInfo` of an XML error body (<ErrorResponse><Error>, a
    bare <Error>, or any root holding an <Error> child). The code is the
    status, as text, when the body is empty or is not XML, and "" when it
    is XML naming none. The request id is `request_id`, else the body's
    <RequestId> (in <Error>, then at the root)."""
    var rid = _request_id_text(request_id)
    if len(body) == 0:
        return AwsErrorInfo(status, String(status), String(""), rid)
    var root = XmlNode()
    try:
        root = aws_xml_parse(body)
    except:
        return AwsErrorInfo(status, String(status), String(""), rid)
    var code = String("")
    var message = String("")
    var body_rid = String("")
    var err = XmlNode()
    var have = False
    if root.local == "Error":
        err = root.copy()
        have = True
    else:
        var i = aws_xml_child(root, "Error")
        if i >= 0:
            err = root.children[i].copy()
            have = True
    if have:
        code = aws_error_code(_child_trimmed(err, "Code"))
        message = _clean_message(_child_trimmed(err, "Message"))
        body_rid = _child_trimmed(err, "RequestId")
    if body_rid.byte_length() == 0:
        body_rid = _child_trimmed(root, "RequestId")
    if rid.byte_length() == 0:
        rid = _request_id_text(body_rid)
    return AwsErrorInfo(status, code, message, rid)


def aws_rest_xml_error(resp: AwsResponse) -> AwsErrorInfo:
    """The `AwsErrorInfo` of a restXml response: see the module header. The
    request id is the `x-amzn-RequestId` header, else `x-amz-request-id`,
    else the body's <RequestId>."""
    var rid = String("")
    if resp.has_header(String("x-amzn-RequestId")):
        rid = aws_request_id(resp, String("x-amzn-RequestId"))
    elif resp.has_header(String("x-amz-request-id")):
        rid = aws_request_id(resp, String("x-amz-request-id"))
    return aws_xml_error_info(resp.status, resp.body, rid)


def aws_xml_body_is_error(resp: AwsResponse) -> Bool:
    """S3's 200-with-<Error>: True for a 200 whose body is not empty and is
    either not well-formed XML or has the root element <Error> in no
    namespace. False for any other status and for an empty body."""
    if resp.status != 200 or len(resp.body) == 0:
        return False
    try:
        var root = aws_xml_parse(resp.body)
        return root.local == "Error" and root.ns.byte_length() == 0
    except:
        return True
