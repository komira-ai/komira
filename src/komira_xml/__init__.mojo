# =============================================================================
# komira_xml — a general XML codec.
# =============================================================================
#
# WHY THIS PACKAGE EXISTS. A hand-written, SHAPE-SPECIFIC string scanner (one
# per response shape) cannot parse an attribute, a self-closing element, a
# CDATA section, a namespace prefix or a numeric character reference, and is
# not reusable for a shape it was not written for. `rest-xml` — the protocol
# S3 and Route53 speak — cannot be generated against such scanners. This
# package is the general codec it needs.
#
# THE LAYERS
#   xml_escape.mojo  escaping / entity decoding, byte-oriented
#   xml_reader.mojo  a forward-only pull parser; events carry byte ranges
#   xml_writer.mojo  a streaming writer over one output buffer
#   xml_tree.mojo    an owned tree + a namespace-aware canonical form
#
# The rest-xml BINDING (flattened lists, xmlAttribute, xmlNamespace,
# timestamps, blobs) is deliberately NOT here — it lives in
# `komira_restxml`, so this package stays a plain XML codec that anything
# can use.
#
# Encapsulation: no `UnsafePointer` crosses this module boundary.
# =============================================================================

from .xml_escape import (
    append_escaped_attr,
    append_escaped_text,
    append_unescaped,
    xml_escape_attr,
    xml_escape_text,
    xml_unescape,
)
from .xml_reader import (
    XML_END,
    XML_EOF,
    XML_START,
    XML_TEXT,
    XmlEvent,
    XmlReader,
)
from .xml_tree import XmlNode, canonical_node, canonical_xml, parse_xml
from .xml_writer import XmlWriter
