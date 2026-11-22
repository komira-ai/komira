"""The Python UDF runtime: the zygote, the workers it forks, and their private wire.

Private to komira. `zygote.py` is run by path under `python -I -X utf8`; it loads its
sibling modules by file path, so nothing here is imported through the `komira` package.
"""
