"""The spelling of target labels."""

from buildtools.bytes import substr, suffix


def strip_config(label: String) -> String:
    """`cell//pkg:name (platform#hash)` -> `cell//pkg:name`."""
    var i = label.find(String(" ("))
    if i >= 0:
        return substr(label, 0, i)
    return label.copy()


def strip_subtarget(label: String) -> String:
    """`//pkg:name[sub]` -> `//pkg:name`."""
    var i = label.find(String("["))
    if i >= 0:
        return substr(label, 0, i)
    return label.copy()


def root_spelling(label: String, root_cell: String) -> String:
    """`<root cell>//pkg:name` -> `//pkg:name`. Other cells keep their name."""
    var prefix = root_cell + String("//")
    if label.startswith(prefix):
        return suffix(label, root_cell.byte_length())
    return label.copy()


def normalize_label(label: String, root_cell: String) -> String:
    """A label as the tool prints it: no configuration, no subtarget, the
    root cell's name left out."""
    return root_spelling(strip_subtarget(strip_config(label)), root_cell)
