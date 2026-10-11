# A number out of the range of a double: json.loads alone would read it as infinity.
print('{"a": 1e999}')
