import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}


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
