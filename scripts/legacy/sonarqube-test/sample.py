# Sample Python file with intentional issues for SonarQube analysis testing.


def calculate(a, b):
    unused = 42  # noqa — intentional: unused variable (code smell)
    if a == None:  # intentional: should use 'is None' (bug)
        return 0
    result = a + b
    result = a * b  # intentional: overwritten before use (bug)
    return result


def greet(name):
    # intentional: duplicated block
    if name:
        print("Hello,", name)
        print("Welcome to the factory.")
        print("Have a great day!")
    if name:
        print("Hello,", name)
        print("Welcome to the factory.")
        print("Have a great day!")


def process(items):
    results = []
    for item in items:
        value = item * 2
        results.append(value)
    return results
