# Glyn Process Registry Implementation Plan

Based on analysis of the current Glyn codebase, here's a comprehensive plan for adding process registry functionality while maintaining consistency with existing patterns and design principles.

## Core Design Principles

Following the established Glyn patterns:

1. **Type Safety**: Use opaque types and caller-supplied subjects for compile-time safety
2. **Distributed Consistency**: Same scope pattern works across nodes
3. **Clean Actor Integration**: Registry subjects integrate seamlessly with actor selectors
4. **Metadata-Based Subject Storage**: Store subject tags in syn metadata for type-safe lookups
5. **API Consistency**: Mirror the PubSub API design patterns

## 1. Core Registry Type Structure

Add to existing `glyn.gleam`:

```gleam
/// Type-safe process registry wrapper
pub opaque type Registry(message, metadata) {
  Registry(scope: atom.Atom)
}

/// Registration handle for cleanup
pub type Registration(message, metadata) {
  Registration(
    registry: Registry,
    name: String,
    subject: Subject(message),
    metadata: metadata
  )
}
```

## 2. Required FFI Bindings

Add these FFI bindings to existing `glyn.gleam`:

```gleam
@external(erlang, "syn", "register")
fn syn_register(scope: atom.Atom, name: String, pid: Pid, metadata: Dynamic) -> Dynamic

@external(erlang, "syn", "lookup")
fn syn_lookup(scope: atom.Atom, name: String) -> Dynamic

@external(erlang, "syn", "unregister")
fn syn_unregister(scope: atom.Atom, name: String) -> Dynamic

@external(erlang, "syn", "registered")
fn syn_registered(scope: atom.Atom) -> List(String)
```

## 3. Core Registry Functions

```gleam
/// Create a new Registry system for a given scope
pub fn new_registry(scope scope: String) -> Registry(message, metadata) {
  let scope = atom.create(scope)

  syn_add_node_to_scopes([scope])
  Registry(scope: scope)
}

/// Register a process with a name using a caller-supplied Subject
/// Note: Registration will replace any existing registration with the same name
pub fn register(
  registry: Registry(message, metadata),
  name: String,
  subject: Subject(message),
  metadata: metadata
) -> Result(Registration(message, metadata), String) {
  case process.subject_owner(subject) {
    Ok(pid) -> {
      let result = syn_register(registry.scope, name, pid, to_dynamic(#(subject, metadata)))
      case result == to_dynamic(atom.create("ok")) {
        True -> Ok(Registration(
          registry: registry,
          name: name,
          subject: subject,
          metadata: metadata,
        ))
        False -> Error("Registration failed: " <> string.inspect(result))
      }
    }
    Error(_) -> Error("Invalid subject: process may have terminated")
  }
}

/// Unregister a process
pub fn unregister(registration: Registration(message, metadata)) -> Result(Nil, String) {
  let result = syn_unregister(registration.registry.scope, registration.name)
  case result == to_dynamic(atom.create("ok")) {
    True -> Ok(Nil)
    False -> Error("Unregistration failed: " <> string.inspect(result))
  }
}

/// Look up a registered process and return a type-safe Subject with metadata
pub fn lookup(registry: Registry(message, metadata), name: String) -> Result(#(Subject(message), metadata), String) {
  case syn_whereis(registry.scope, name) {
    Ok(#(_pid, #(subject, metadata))) -> {
      Ok(#(subject, metadata))
    }
    Error(_) -> Error("Process not found: " <> name)
  }
}

/// Send a type-safe message to a registered process
pub fn send_to_registered(registry: Registry(message, metadata), name: String, message: message) -> Result(Nil, String) {
  case lookup(registry, name) {
    Ok(#(subject, _metadata)) -> {
      process.send(subject, message)
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// Get list of all registered names in the registry
pub fn registered_names(registry: Registry) -> List(String) {
  syn_registered(registry.scope)
}
```

## 4. Actor Integration Pattern

Example of how actors would use both PubSub and Registry:

```gleam
pub type ActorMessage {
  // Direct commands via registry
  DirectCommand(UserCommand)
  // PubSub events
  PubSubEvent(SystemEvent)
  // Registry commands
  RegistryCommand(ServiceMessage)
}

fn start_integrated_actor(
  pubsub: glyn.PubSub(SystemEvent),
  registry: glyn.Registry,
  name: String,
) -> Result(actor.Started(Subject(ActorMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(_actor_subject) {
    // Create a subject for Direct commands
    let command_subject = process.new_subject()

    // Subscribe to PubSub
    let pubsub_sub = glyn.subscribe(pubsub, "events", process.self())

    // Create a subject for registry messages
    let registry_subject = process.new_subject()

    // Register in registry using our subject
    let assert Ok(registration) = glyn.register(registry, name, registry_subject)

    let selector =
      process.new_selector()
      |> process.select_map(command_subject, DirectCommand)
      |> process.select_map(pubsub_sub.subject, PubSubEvent)
      |> process.select_map(registry_subject, RegistryCommand)

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(command_subject)
    |> Ok
  })
}
```

## 5. Testing Strategy

Key test cases to implement:

### Core Functionality Tests:
1. **Basic registration and lookup** - Register process, look it up, send message
2. **Type safety enforcement** - Metadata verification prevents type confusion
3. **Send message via registry** - Convenience function works correctly
4. **Multiple registrations in same scope** - Different names don't interfere
5. **Different scopes isolation** - Same name in different scopes are separate
6. **Distributed consistency** - Same scope+type_id across instances
7. **Error handling** - Name conflicts, not found, type mismatches
8. **Integration with actors** - Registry subjects work in actor selectors
9. **Cleanup and unregistration** - Proper resource cleanup
10. **Type violation test** - Demonstrates crash when type safety violated

### Test Message Types:
```gleam
pub type ServiceMessage {
  GetStatus(reply_with: Subject(String))
  ProcessRequest(id: String, reply_with: Subject(Bool))
  Shutdown
}

pub type DifferentMessage {
  DifferentCommand(value: Int)
}
```

## 6. Implementation Phases

### Phase 1: Core Registry Functions
- [ ] Add FFI bindings for syn registry functions
- [ ] Implement `Registry(message, metadata)` opaque type
- [ ] Implement `new_registry`, `register`, `unregister`, `whereis`
- [ ] Basic unit tests for core functionality

### Phase 2: Type Safety & Error Handling
- [ ] Add comprehensive error handling with meaningful messages
- [ ] Subject validation and error handling tests
- [ ] Edge case testing (process termination, invalid subjects)

### Phase 3: Advanced Features
- [ ] Implement `send` convenience function
- [ ] Add `registered_names` listing function
- [ ] Performance optimizations if needed
- [ ] Documentation and examples

### Phase 4: Integration & Testing
- [ ] Actor integration examples
- [ ] Distributed testing (multiple registry instances)
- [ ] Mixed PubSub + Registry usage patterns

## 7. API Design Considerations

### Consistency with PubSub API
- Use same labelled argument pattern: `new_registry(scope: "...")`
- Return meaningful types (`Registration`, `Registry`) rather than primitives
- Follow same error handling patterns

### Type Safety Guarantees
- Caller-supplied subjects ensure compile-time type safety
- Opaque types prevent misuse
- Type safety enforced at subject creation time and maintained through metadata storage
- Registry type parameters ensure whereis returns correctly typed subjects and metadata

### Distributed Behavior
- Same scope across nodes = shared registry namespace
- Different scopes = complete isolation
- Full subjects stored in metadata work seamlessly across nodes via distributed erlang
- Registration replacement behavior is consistent across all nodes

## 8. Key Differences from PubSub

| Aspect | PubSub | Registry |
|--------|---------|----------|
| **Cardinality** | 1-to-many | 1-to-1 |
| **Discovery** | Group membership | Name-based lookup |
| **Message Flow** | Broadcast | Direct send |
| **Storage** | Group membership | Name → PID + metadata |
| **Use Case** | Event distribution | Service location |

## 9. Research Notes

### Syn Registry Functions ✅ COMPLETED
Researched actual syn.erl source code and confirmed:
- **`syn:register/4`** - `register(Scope, Name, Pid, Meta) -> ok | {error, Reason}`
- **`syn:lookup/2`** - `lookup(Scope, Name) -> {Pid, Meta} | undefined`  
- **`syn:unregister/2`** - `unregister(Scope, Name) -> ok | {error, Reason}`
- Return values are atoms/tuples, not Gleam Result types
- Process death is handled automatically by syn (cleanup on process exit)

### Subject FFI Functions ✅ COMPLETED
Confirmed: `process.subject_owner/1` exists and returns `Result(Pid, Nil)`
Additional FFI needed:
- `from_dynamic/1` for extracting data from syn responses
- `to_dynamic/1` for converting Gleam data for syn calls

### Error Handling Strategy
- Registration returns `Result` and replaces existing registrations (following syn behavior)
- Handle process death/invalid subjects gracefully with meaningful error messages
- Expose appropriate error detail without exposing internal syn implementation

## 10. Resolved Design Questions

1. **Subject Storage**: ✅ Store full subject in metadata (works with distributed erlang)
2. **Name Conflicts**: ✅ Registration replaces existing (follows syn behavior)  
3. **Process Monitoring**: ✅ Handled automatically by syn
4. **Type Safety**: ✅ Registry type parameters ensure type safety
5. **Type Inference**: ✅ Gleam infers types based on usage context
6. **Metadata Purpose**: ✅ User-defined data stored alongside subjects
7. **FFI Types**: ✅ Syn functions return Dynamic, need comparison with atoms
8. **Function Names**: ✅ Use `syn:lookup/2` not `syn:whereis/2`
9. **Return Types**: ✅ Syn returns atoms (`ok`/`undefined`) not Result types
10. **Implementation Status**: ✅ Basic functionality working and tested

## 11. Implementation Status

### ✅ Completed (Phase 1):
- `new_registry(scope: String) -> Registry(message, metadata)` 
- `register(registry, name, subject, metadata) -> Result(Registration, String)`
- `lookup(registry, name) -> Result(#(Subject, metadata), String)`
- `unregister(registration) -> Result(Nil, String)`
- `send_to_registered(registry, name, message) -> Result(Nil, String)`
- Basic integration test passing
- Error handling tests passing  
- Unregister functionality test passing
- Send to registered with reply verification test passing
- Correct syn FFI bindings confirmed

### 🚧 Next (Phase 2):
- Additional test cases (multiple registrations, distributed scenarios)
- Integration with actors examples

### ❌ Not Available:
- `registered_names(registry) -> List(String)` - syn does not provide a function to list all registered names in a scope

This design maintains Glyn's core principles while adding complementary process registry functionality that integrates seamlessly with the existing PubSub system and actor patterns.
