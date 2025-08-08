import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/string



// FFI bindings for syn
@external(erlang, "syn", "add_node_to_scopes")
fn syn_add_node_to_scopes(scopes: List(atom.Atom)) -> atom.Atom

@external(erlang, "syn", "join")
fn syn_join(scope: atom.Atom, group: group, pid: Pid) -> atom.Atom

@external(erlang, "syn", "leave")
fn syn_leave(scope: atom.Atom, group: group, pid: Pid) -> atom.Atom

@external(erlang, "syn", "members")
fn syn_members(scope: atom.Atom, group: group) -> List(Pid)

@external(erlang, "syn", "publish")
fn syn_publish(
  scope: atom.Atom,
  group: group,
  message: message,
) -> Result(Int, Dynamic)

// Convert any value to Dynamic
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn from_dynamic(value: Dynamic) -> a

// Registry FFI bindings
@external(erlang, "syn", "register")
fn syn_register(scope: atom.Atom, name: String, pid: Pid, metadata: metadata) -> Dynamic

@external(erlang, "syn", "lookup")
fn syn_lookup(scope: atom.Atom, name: String) -> Dynamic

@external(erlang, "syn", "unregister")
fn syn_unregister(scope: atom.Atom, name: String) -> Result(atom.Atom, Dynamic)

@external(erlang, "syn", "registered")
fn syn_registered(scope: atom.Atom) -> List(String)

// Type-safe PubSub wrapper
pub opaque type PubSub(message) {
  PubSub(scope: atom.Atom, type_id: atom.Atom)
}

// Subscription handle for cleanup
pub type Subscription(message, group) {
  Subscription(
    pubsub: PubSub(message),
    group: group,
    subject: Subject(message),
    subscriber_pid: Pid,
  )
}

/// Create a new type-safe PubSub system with an explicit type identifier
/// The type_id should be unique per message type across your entire system
pub fn new(scope scope: String, type_id type_id: String) -> PubSub(message) {
  let scope = atom.create(scope)
  let type_id = atom.create(type_id)

  syn_add_node_to_scopes([scope])
  PubSub(scope: scope, type_id: type_id)
}

/// Subscribe to a PubSub group and return a type-safe Subject
pub fn subscribe(
  pubsub: PubSub(message),
  group: group,
  subscriber_pid: Pid,
) -> Subscription(message, group) {
  assert atom.create("ok") == syn_join(pubsub.scope, group, subscriber_pid)

  // Create a Subject using the shared type_id
  let subject = process.unsafely_create_subject(subscriber_pid, to_dynamic(pubsub.type_id))

  Subscription(
    pubsub: pubsub,
    group: group,
    subject: subject,
    subscriber_pid: subscriber_pid,
  )
}

/// Unsubscribe from a PubSub group
pub fn unsubscribe(subscription: Subscription(message, group)) -> Nil {
  assert atom.create("ok") == syn_leave(
    subscription.pubsub.scope,
    subscription.group,
    subscription.subscriber_pid,
  )
  Nil
}

/// Publish a type-safe message to all subscribers of a group
pub fn publish(
  pubsub: PubSub(message),
  group: group,
  message: message,
) -> Int {
  // Create the tagged message that matches what process.send would create
  // We need to extract the actual type_id value from Dynamic
  let tagged_message = #(to_dynamic(pubsub.type_id), message)

  // Publish the tagged message through syn
  let assert Ok(subscriber_count) = syn_publish(pubsub.scope, group, to_dynamic(tagged_message))
  subscriber_count
}

/// Get list of subscriber PIDs for a group (useful for debugging)
pub fn subscribers(pubsub: PubSub(message), group: String) -> List(Pid) {
  syn_members(pubsub.scope, group)
}

// Registry types and functions

/// Type-safe process registry wrapper
pub opaque type Registry(message, metadata) {
  Registry(scope: atom.Atom)
}

/// Registration handle for cleanup
pub type Registration(message, metadata) {
  Registration(
    registry: Registry(message, metadata),
    name: String,
    subject: Subject(message),
    metadata: metadata,
  )
}

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
  metadata: metadata,
) -> Result(Registration(message, metadata), String) {
  case process.subject_owner(subject) {
    Ok(pid) -> {
      let result = syn_register(registry.scope, name, pid, to_dynamic(#(subject, metadata)))
      case result == to_dynamic(atom.create("ok")) {
        True -> {
          Ok(Registration(
            registry: registry,
            name: name,
            subject: subject,
            metadata: metadata,
          ))
        }
        False -> {
          Error("Registration failed: " <> string.inspect(result))
        }
      }
    }
    Error(_) -> {
      Error("Invalid subject: process may have terminated")
    }
  }
}

/// Unregister a process
pub fn unregister(registration: Registration(message, metadata)) -> Result(Nil, String) {
  todo as "implement unregister"
}

/// Look up a registered process and return a type-safe Subject with metadata
pub fn lookup(registry: Registry(message, metadata), name: String) -> Result(#(Subject(message), metadata), String) {
  let result = syn_lookup(registry.scope, name)
  case result == to_dynamic(atom.create("undefined")) {
    True -> {
      Error("Process not found: " <> name)
    }
    False -> {
      let #(_pid, stored_data) = from_dynamic(result)
      let #(subject, metadata) = from_dynamic(stored_data)
      Ok(#(subject, metadata))
    }
  }
}

/// Send a type-safe message to a registered process
pub fn send_to_registered(registry: Registry(message, metadata), name: String, message: message) -> Result(Nil, String) {
  todo as "implement send_to_registered"
}

/// Get list of all registered names in the registry
pub fn registered_names(registry: Registry(message, metadata)) -> List(String) {
  todo as "implement registered_names"
}
