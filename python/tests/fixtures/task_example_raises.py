# A common-task example that raises before it prints all it should
# (python/docs/tasks/BUCK, `refuses_example_that_raises`).
print("started")
raise ValueError("the input has no column amount")
