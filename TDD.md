# Test-Driven Development Process for Glyn

This document outlines the TDD process to follow when implementing new features in the Glyn library.

## Core Principles

1. **Test-First**: Write tests before implementation
2. **Red-Green-Refactor**: Fail → Pass → Improve
3. **Minimal Implementation**: Write just enough code to make tests pass
4. **Human Review**: Stop for feedback at key points
5. **One Test at a Time**: Focus on single functionality per iteration

## Step-by-Step Process

### Phase 1: Setup and Stubs

1. **Declare Types**: Add all necessary type definitions to the main module
2. **Stub Functions**: Implement function signatures with `todo "descriptive message"`
   ```gleam
   pub fn register(registry: Registry(message, metadata), name: String, subject: Subject(message), metadata: metadata) -> Result(Registration(message, metadata), String) {
     todo "implement register function"
   }
   ```
3. **Verify Compilation**: Ensure all stubs compile successfully
4. **Add FFI Bindings**: Add external function declarations (can also use `todo`)

### Phase 2: Test-Driven Implementation

#### For Each Feature:

1. **Define ONE Test**
   - Focus on a single piece of functionality
   - Use descriptive test names that explain the behavior
   - Example: `basic_registration_and_lookup_test()`

2. **Ensure Test Fails with Assertion**
   - The test MUST execute to the point of assertion failure
   - Compilation errors don't count as proper test failures
   - If test fails due to `todo` panic, implement just enough to reach assertions

3. **Implement Minimum Code**
   - Write the smallest amount of code to make the test pass
   - Don't over-engineer or anticipate future needs
   - Focus only on making THIS test green

4. **Stop for Human Review**
   - Present the failing test and minimal implementation
   - Wait for feedback before proceeding

### Phase 3: Refactoring Cycle

1. **Apply Human Feedback**
   - Make suggested improvements
   - Maintain test passing state
   - Focus on code quality, not new features

2. **Iterative Refinement**
   - Continue refactoring based on feedback
   - Stop after each round for review
   - Don't move to next test until human is satisfied

3. **Proceed to Next Test**
   - Only after refactoring is complete
   - Repeat the entire cycle for the next piece of functionality

## Test Implementation Guidelines

### Test Structure
```gleam
pub fn descriptive_test_name() {
  // Arrange: Set up test data and dependencies
  let registry = glyn.new_registry(scope: "test_scope")
  let subject = process.new_subject()
  
  // Act: Perform the action being tested
  let result = glyn.register(registry, "test_name", subject, "test_metadata")
  
  // Assert: Verify the expected outcome
  assert Ok(registration) = result
  assert registration.name == "test_name"
}
```

### Test Categories (in order of implementation)
1. **Basic Functionality**: Core operations work as expected
2. **Error Handling**: Invalid inputs produce appropriate errors
3. **Edge Cases**: Boundary conditions and unusual scenarios
4. **Integration**: Components work together correctly
5. **Distributed**: Multiple instances behave consistently

### Test Naming Convention
- Use descriptive names that explain what is being tested
- Include the expected behavior in the name
- Examples:
  - `basic_registration_succeeds_test()`
  - `registration_with_invalid_subject_fails_test()`
  - `whereis_returns_subject_and_metadata_test()`

## Key Rules

### DO:
- Write tests that fail for the right reason (assertion failure)
- Implement minimal code to pass tests
- Stop for review at designated points
- Focus on one test at a time
- Use meaningful test and variable names

### DON'T:
- Implement multiple features at once
- Write complex implementations before tests require them
- Skip the review process
- Continue to next test while current one needs refactoring
- Accept compilation errors as "test failures"

## Example Session Flow

```
1. Human: "Implement registry functionality"
2. Claude: Creates type stubs, verifies compilation
3. Claude: "Ready for first test. What should I implement first?"
4. Human: "Basic registration and lookup"
5. Claude: Writes failing test, minimal implementation
6. Claude: "Test passes, ready for review"
7. Human: "Refactor the error handling"
8. Claude: Applies refactoring, confirms test still passes
9. Human: "Good, now implement metadata retrieval"
10. Repeat cycle...
```

This process ensures high-quality, well-tested code with clear human oversight at each critical decision point.