# An integer out of the range of a double (10^309): json.loads alone would read it as a Python int of any size.
print('{"a": 1' + "0" * 309 + "}")
