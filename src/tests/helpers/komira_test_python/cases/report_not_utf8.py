import os

os.write(1, b'{"a": "\xff"}')
