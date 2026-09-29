#!/usr/bin/env python3
"""kg: the repository knowledge graph. See `python3 tools/kg/kg.py --help`."""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from kglib.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
