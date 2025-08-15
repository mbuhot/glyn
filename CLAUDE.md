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
- **MessageType**: Compile-time type safety (ensures message type consistency across nodes)
- **NEVER reuse the same scope + MessageType for different message types**

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
// Deterministic tag from MessageType = clustering works
PubSub(scope: scope_atom, tag: phash2(message_type.id))
```

**Lesson**: **Always consider distributed scenarios** - what works locally might break in clusters.

### 2. **Type Safety Through Explicit Type IDs**
**Problem**: Generic parameters are error-prone and don't provide type safety.

**Solution**: MessageType pattern with compile-time safety:
```gleam
// Type-safe, self-documenting, prevents message type confusion
pub const user_event_type: glyn.MessageType(UserEvent) = glyn.MessageType("UserEvent_v1")
let pubsub = glyn.new_pubsub(scope: "user_events", message_type: user_event_type)
```

### 3. **True PubSub-Level Type Safety**
- **Syn handles**: Type-tagged group membership, message routing, distribution
- **Type system handles**: Compile-time safety, message structure
- **Groups are tagged**: Different MessageTypes use different syn groups `#(group, tag)`
- **No wasted delivery**: Messages only reach compatible subscribers

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
pub const order_event_type: glyn.MessageType(OrderEvent) = glyn.MessageType("OrderEvent_v1")
let pubsub = glyn.new_pubsub(scope: "global_events", message_type: order_event_type)
```

### Testing Distributed Behavior
```gleam
// Simulate distributed by creating multiple PubSub instances
pub const message_type: glyn.MessageType(Message) = glyn.MessageType("Message_v1")
let pubsub1 = glyn.new_pubsub(scope: "test_scope", message_type: message_type)  // "Node 1"
let pubsub2 = glyn.new_pubsub(scope: "test_scope", message_type: message_type)  // "Node 2"

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
let tagged_message = #(to_dynamic(pubsub.tag), user_message)
// Use tagged group to ensure type safety
let tagged_group = #(group, pubsub.tag)
let _ = syn_publish(scope, tagged_group, to_dynamic(tagged_message))
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
  pub const chat_type: glyn.MessageType(ChatMessage) = glyn.MessageType("ChatMessage_v1")
  pub const metric_type: glyn.MessageType(MetricEvent) = glyn.MessageType("MetricEvent_v1")
  
  let chat_pubsub = glyn.new_pubsub(scope: "app", message_type: chat_type)
  let metric_pubsub = glyn.new_pubsub(scope: "app", message_type: metric_type)
  
  let subscription = glyn.subscribe(chat_pubsub, "channel", process.self())
  // This finds 0 subscribers - PubSub-level type safety prevents delivery
  let reached = glyn.publish(metric_pubsub, "channel", CounterIncrement("hack", 1))
  assert reached == 0
}
```

**Expected Result**: No message delivery to incompatible subscribers - proves PubSub-level type safety.

### MessageType Naming Conventions
- Include message type: `glyn.MessageType("ChatMessage_v1")`
- Include version: `glyn.MessageType("UserEvent_v2")`
- Be explicit: `glyn.MessageType("OrderCreated_v1")` not just `"order"`
- Use constants: `pub const chat_type: glyn.MessageType(ChatMessage) = glyn.MessageType("ChatMessage_v1")`

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

### MessageType Pattern for Safety
```gleam
// Type-safe, prevents message type confusion, self-documenting
pub fn new_pubsub(scope scope: String, message_type message_type: MessageType(message)) -> PubSub(message)
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

## Documentation Guidelines

### What NOT to Include in Module-Level Docs

**Don't include "## Core API" sections**:
- The documentation generator already lists all public functions
- Repeating the API in module docs creates redundancy and maintenance burden
- Focus on usage patterns and examples instead

**Don't include "## Key Features" sections**:
- This reads like marketing copy, not technical documentation
- Users can infer features from examples and function signatures
- Keep module docs focused on practical usage

**Do include**:
- Integration patterns showing how modules work together
- Complete working examples
- Important concepts and design decisions
- Common usage scenarios

## Common Pitfalls

### 1. **Reusing Scope + MessageType**
**Problem**: Same scope and MessageType for different message types breaks type safety.
**Solution**: Unique MessageType per message type, even in same scope.

### 2. **Ignoring Distributed Scenarios**  
**Problem**: Code works locally but breaks in clusters.
**Solution**: Always test with multiple PubSub instances simulating different nodes.

### 3. **Sleep-Based Testing**
**Problem**: `process.sleep()` makes tests flaky and slow.
**Solution**: Use `actor.call()` with reply patterns for synchronous testing.

### 4. **Relying on Actor-Level Type Safety**
**Problem**: Letting actors discard incompatible messages wastes resources and provides false safety.
**Solution**: Use PubSub-level type safety with tagged syn groups to prevent message delivery entirely.

### 5. **Not Following Actor Patterns**
**Problem**: Inventing new patterns instead of following Gleam conventions.
**Solution**: Study `process.gleam` and follow established `Subject` patterns.

### 6. **Using io.debug Instead of echo**
**Problem**: Using `io.debug()` for debugging output when `echo` is the preferred method.
**Solution**: ALWAYS use `echo` statement for debugging. `echo` is a language keyword that doesn't need imports or parentheses.

```gleam
// WRONG - Don't use io.debug
import gleam/io
let _ = io.debug(#("debugging", value))

// CORRECT - Use echo
echo #("debugging", value)
```

### 7. **Reward Hacking in TDD**
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

// WRONG - Simulating distributed behavior in single process
let pubsub_node1 = pubsub.new("scope", ...)
let pubsub_node2 = pubsub.new("scope", ...)  // This is NOT clustering!

// WRONG - Returning fake values to make tests pass
pub fn publish(...) -> Int { 0 }  // Hardcoded fake result
pub fn subscribers(...) -> List(Pid) { [] }  // Empty fake list
```

**CORRECT APPROACH:**
- Implement real functionality, even if minimal
- If stuck on FFI or complex logic, STOP and ask for guidance
- Never fake test passes - they must be genuine functionality
- If you don't understand distributed systems concepts, STOP and ask
- NEVER fake distributed behavior - it must be real or not at all

## Project Workflow

### Development Sequence:
1. **Read dependencies** - Understand syn, actor patterns
2. **Start with tests** - Define expected behavior first
3. **Build incrementally** - Test each piece before adding complexity
4. **Research FFI carefully** - Read Erlang source, don't guess
5. **Test distributed scenarios** - Use multiple PubSub instances
6. **Use consistent MessageType pattern** - Both PubSub and Registry use the same MessageType approach

### Before Adding Features:
- [ ] Does this follow existing Gleam patterns?
- [ ] Will this work in distributed clusters?
- [ ] Can I test this without `sleep` calls?
- [ ] Is the API self-documenting?
- [ ] Does this handle the separation between syn (runtime) and types (compile-time)?

### 8. **Stop and Verify Understanding (Distributed Systems)**
**Problem**: Proceeding with implementation when core concepts are misunderstood.
**Solution**: When encountering distributed systems, networking, or clustering concepts:

- **STOP immediately** and state your understanding in plain terms
- **ASK for confirmation** before implementing anything  
- **NEVER proceed** with implementation if you're not 100% certain of the concepts
- **Example**: "My understanding is that Erlang clustering means X. Is this correct before I proceed?"

### 9. **Source Code First**
**Problem**: Guessing APIs and function signatures instead of reading actual source.
**Solution**: When working with external APIs or libraries:

1. **ALWAYS read the actual source code first** (user will point you to it)
2. **NEVER guess** function signatures, return types, or behavior  
3. **If source isn't available**, ask for documentation or examples
4. **State what you found** in the source before implementing

### 10. **Minimal Means Minimal**
**Problem**: Adding complexity when user explicitly asks for minimal approach.
**Solution**: When user says "minimal" or "start over":

- **Implement the absolute minimum** required to test the specific concept
- **Do not add** features, error handling, or comprehensive examples
- **Ask "Is this minimal enough?"** before adding any complexity
- **One concept per iteration**

### 11. **Success Verification**
**Problem**: Claiming things are "working" when they're actually failing.
**Solution**: Before claiming anything is "working":

- **State exactly what evidence** proves success
- **Distinguish between expected behavior and actual observed behavior**
- **If you see errors or failures**, that likely means it's NOT working
- **Ask user to confirm** if ambiguous results indicate success

### When Stuck:
- **Don't hack around problems** - Ask for guidance on proper patterns
- **Don't use global state** - Use proper message passing
- **Don't skip testing** - Especially for distributed scenarios
- **Don't assume APIs** - Research Erlang documentation or READ THE SOURCE CODE
- **NEVER implement dummy/fake functionality** - Stop and ask for help instead
- **NEVER remove real implementations** - If something doesn't work, debug it properly or ask for guidance
- **STOP and verify understanding** - Especially for distributed systems concepts

---

**Remember**: Both PubSub and Registry systems are fundamentally about **composition** - enabling clean integration of multiple message sources and process discovery in actor systems. Both use the same MessageType pattern for consistency and type safety. Every design decision should serve that goal.