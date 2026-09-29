"""Small readers for the repository's check and generator tools.

`bytes`: files and byte buffers; `sha256`: the SHA-256 digest; `json`: JSON
flattened to tab-separated lines, and Python's compact sorted form; `tar`: the
members of an uncompressed tar archive (ustar, PAX and GNU long names). Each
refuses what it cannot read instead of guessing.
"""
