# CLAUDE.md - Glyn PubSub Library Development Guidelines

## Table of Contents
1. [Core PubSub Concepts](#core-pubsub-concepts)
2. [Critical Design Lessons](#critical-design-lessons)
3. [Actor Integration Patterns](#actor-integration-patterns)
4. [Distributed Clustering](#distributed-clustering)
5. [FFI and Syn Integration](#ffi-and-syn-integration)
6. [Type Safety Guidelines](#type-safety-guidelines)
7. [Testing PubSub Systems](#testing-pubsub-systems)
8. [API Design Principles](#api-design-principles)
9. [Common Pitfalls](#common-pitfalls)
10. [Project Workflow](#project-workflow)

## Core PubSub Concepts

### The Key Insight: Clean Message Composition
The primary value of glyn is enabling actors to handle **both direct commands AND PubSub events** cleanly:

```gleam
// Unified message type - the core pattern
pub type ActorMessage {
  DirectCommand(UserCommand)    // Direct actor messages
  PubSubEvent(SystemEvent)      // Events from PubSub
}

// Compose using selectors
let selector =
  process.new_selector()
  |> process.select_map(command_subject, DirectCommand)
  |> process.select_map(subscription.subject, PubSubEvent)
```

### Scope vs Type Safety
- **Scope**: Runtime namespace for syn (isolates different PubSub systems)
- **Type ID**: Compile-time type safety (ensures message type consistency across nodes)
- **NEVER reuse the same scope + type_id for different message types**

## Critical Design Lessons

### 1. **The Distributed Reference Problem**
**Original Issue**: Each node creating unique references broke cross-node messaging.

**Wrong Approach**:
```gleam
// Each node gets different reference = broken clustering
PubSub(scope: scope_atom, tag: reference.new())
```

**Correct Approach**:
```gleam
// Deterministic tag from type_id = clustering works
PubSub(scope: scope_atom, type_id: atom.create(type_id))
```

**Lesson**: **Always consider distributed scenarios** - what works locally might break in clusters.

### 2. **Type Safety Through Explicit Type IDs**
**Problem**: Two string parameters are error-prone and don't communicate intent.

**Solution**: Labelled arguments with clear semantics:
```gleam
// Clear, self-documenting, prevents argument swapping
let pubsub = glyn.new(scope: "user_events", type_id: "UserEvent_v1")
```

### 3. **Separation of Concerns: Syn vs Type System**
- **Syn handles**: Group membership, message routing, distribution
- **Type system handles**: Compile-time safety, message structure
- **Don't conflate them**: Same scope can have different type_ids for different message types

## Actor Integration Patterns

### The Selector Pattern
```gleam
pub fn start_actor() -> Result(actor.Started(Subject(Command)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(_) {
    let subscription = glyn.subscribe(pubsub, "events", process.self())
    let command_subject = process.new_subject()

    let selector =
      process.new_selector()
      |> process.select_map(command_subject, DirectCommand)
      |> process.select_map(subscription.subject, PubSubEvent)

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(command_subject)  // Return command interface
    |> Ok
  })
}
```

### Multi-System Integration
```gleam
// One actor, multiple PubSub systems
let user_sub = glyn.subscribe(user_pubsub, "business_logic", process.self())
let payment_sub = glyn.subscribe(payment_pubsub, "business_logic", process.self())

let selector =
  process.new_selector()
  |> process.select_map(command_subject, DirectCommand)
  |> process.select_map(user_sub.subject, UserEvent)
  |> process.select_map(payment_sub.subject, PaymentEvent)
```

## Distributed Clustering

### Node Naming Strategies
**Working Approaches**:
1. `gleam shell --name node1@localhost` (most reliable)
2. `ERL_FLAGS="-sname node1@localhost" gleam run -m module`
3. Startup scripts with proper environment variables

**Avoid**: Programmatic `net_kernel:start/2` - has compatibility issues.

### Clustering Rules
- **Same scope + type_id**: Nodes will share messages
- **Different scopes**: Complete isolation
- **Same scope, different type_ids**: Type-safe isolation

```gleam
// Node A and Node B both do this - they'll communicate
let pubsub = glyn.new(scope: "global_events", type_id: "OrderEvent_v1")
```

### Testing Distributed Behavior
```gleam
// Simulate distributed by creating multiple PubSub instances
let pubsub1 = glyn.new(scope: "test_scope", type_id: "Message_v1")  // "Node 1"
let pubsub2 = glyn.new(scope: "test_scope", type_id: "Message_v1")  // "Node 2"

let subscription = glyn.subscribe(pubsub1, "channel", process.self())
let reached = glyn.publish(pubsub2, "channel", "cross-node message")
// reached == 1 proves distributed behavior works
```

## FFI and Syn Integration

### Research First, Implement Second
**Critical**: Read the actual Erlang/OTP source before creating FFI bindings.

### Common FFI Patterns
```gleam
// Syn functions typically return atoms, not Results
@external(erlang, "syn", "join")
fn syn_join(scope: atom.Atom, group: String, pid: Pid) -> atom.Atom

// Assume success for reliable syn operations
let _ = syn_join(scope, group, pid)  // Don't wrap in Result unnecessarily
```

### Message Structure
```gleam
// Tagged message format for process system compatibility
let tagged_message = #(type_id_atom, user_message)
let _ = syn_publish(scope, group, to_dynamic(tagged_message))
```

### Don't Over-Engineer
- If the underlying Erlang function reliably succeeds, don't wrap in `Result`
- Follow existing Gleam patterns (study `process.gleam` for actor patterns)
- Start simple, add complexity only when needed

## Type Safety Guidelines

### The Violation Test Pattern
Always include a test that demonstrates what happens when type safety is violated:

```gleam
pub fn type_safety_violation_test() {
  let chat_pubsub: glyn.PubSub(ChatMessage) = glyn.new(scope: "app", type_id: "messages")
  let evil_pubsub: glyn.PubSub(MetricEvent) = glyn.new(scope: "app", type_id: "messages")
  
  let subscription = glyn.subscribe(chat_pubsub, "channel", process.self())
  // This will crash the actor with "no case clause matching"
  let _ = glyn.publish(evil_pubsub, "channel", CounterIncrement("hack", 1))
}
```

**Expected Result**: Actor crash with pattern match failure - proves type safety is enforced.

### Type ID Naming Conventions
- Include message type: `"ChatMessage_v1"`
- Include version: `"UserEvent_v2"`
- Be explicit: `"OrderCreated_v1"` not just `"order"`

## Testing PubSub Systems

### Use Reply-With Pattern, Not Sleep
**Wrong**:
```gleam
let _ = glyn.publish(pubsub, "topic", message)
process.sleep(100)  // Flaky!
let count = get_message_count(actor)
```

**Right**:
```gleam
// Wait for actor to be ready first
let _ = actor.call(actor, waiting: 1000, sending: GetReady)
let _ = glyn.publish(pubsub, "topic", message)
let count = actor.call(actor, waiting: 1000, sending: GetMessageCount)
```

### Test Isolation
- Use **unique scopes** for each test to prevent interference
- Implement **actor shutdown** to prevent resource leaks
- **Different type_ids** for different test scenarios

### Essential Test Categories
1. **Basic Integration**: Actor receives PubSub messages
2. **Multiple Actors**: Same message reaches multiple subscribers  
3. **Group Isolation**: Different groups don't interfere
4. **Type Safety**: Different scopes are isolated
5. **Distributed Consistency**: Same scope+type_id works across instances
6. **Type Violation**: Demonstrates crash when type safety is violated

## API Design Principles

### Labelled Arguments for Safety
```gleam
// Prevents argument confusion, self-documenting
pub fn new(scope scope_name: String, type_id type_id: String) -> PubSub(message)
```

### Avoid Inefficient Helpers
**Don't**:
```gleam
pub fn subscriber_count(pubsub, group) -> Int {
  subscribers(pubsub, group) |> list.length  // Inefficient wrapper
}
```

**Do**:
```gleam
// Let users call list.length themselves when needed
let count = glyn.subscribers(pubsub, group) |> list.length
```

### Return Meaningful Information
```gleam
// Return subscriber count from publish - useful for monitoring
pub fn publish(pubsub: PubSub(message), group: String, message: message) -> Int
```

## Common Pitfalls

### 1. **Reusing Scope + Type ID**
**Problem**: Same scope and type_id for different message types breaks type safety.
**Solution**: Unique type_id per message type, even in same scope.

### 2. **Ignoring Distributed Scenarios**  
**Problem**: Code works locally but breaks in clusters.
**Solution**: Always test with multiple PubSub instances simulating different nodes.

### 3. **Sleep-Based Testing**
**Problem**: `process.sleep()` makes tests flaky and slow.
**Solution**: Use `actor.call()` with reply patterns for synchronous testing.

### 4. **Framework Dependencies in Library Code**
**Problem**: Using framework-specific logging/utilities prevents library extraction.
**Solution**: Keep core library modules framework-independent.

### 5. **Not Following Actor Patterns**
**Problem**: Inventing new patterns instead of following Gleam conventions.
**Solution**: Study `process.gleam` and follow established `Subject` patterns.

### 6. **Reward Hacking in TDD**
**Problem**: Implementing fake/dummy functionality to make tests "pass" instead of real implementation.
**Solution**: NEVER replace real logic with comments like "Simplified for testing". Always implement actual functionality or ask for help when stuck.

**CRITICAL VIOLATION EXAMPLES - NEVER DO THIS:**
```gleam
// WRONG - This is reward hacking
pub fn register(...) -> Result(...) {
  // Simplified for testing - just return Ok for now
  Ok(...)
}

// WRONG - This defeats the entire purpose of TDD
pub fn whereis(...) -> Result(...) {
  // Always fail for now
  Error("not implemented")
}
```

**CORRECT APPROACH:**
- Implement real functionality, even if minimal
- If stuck on FFI or complex logic, STOP and ask for guidance
- Never fake test passes - they must be genuine functionality

## Project Workflow

### Development Sequence:
1. **Read dependencies** - Understand syn, actor patterns
2. **Start with tests** - Define expected behavior first
3. **Build incrementally** - Test each piece before adding complexity
4. **Research FFI carefully** - Read Erlang source, don't guess
5. **Test distributed scenarios** - Use multiple PubSub instances

### Before Adding Features:
- [ ] Does this follow existing Gleam patterns?
- [ ] Will this work in distributed clusters?
- [ ] Can I test this without `sleep` calls?
- [ ] Is the API self-documenting?
- [ ] Does this handle the separation between syn (runtime) and types (compile-time)?

### When Stuck:
- **Don't hack around problems** - Ask for guidance on proper patterns
- **Don't use global state** - Use proper message passing
- **Don't skip testing** - Especially for distributed scenarios
- **Don't assume APIs** - Research Erlang documentation
- **NEVER implement dummy/fake functionality** - Stop and ask for help instead
- **NEVER remove real implementations** - If something doesn't work, debug it properly or ask for guidance

---

**Remember**: PubSub libraries are fundamentally about **composition** - enabling clean integration of multiple message sources in actor systems. Every design decision should serve that goal.