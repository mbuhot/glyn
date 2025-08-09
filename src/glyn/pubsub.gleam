////  Glyn PubSub - Type-Safe Distributed Event Streaming
////
////  This module provides a type-safe wrapper around Erlang's `syn` PubSub system,
////  enabling distributed event streaming and one-to-many message broadcasting with
////  compile-time type safety.
////
////  ## Actor Integration Pattern
////
////  PubSub works seamlessly with Gleam's actor system using the selector pattern:
////
////  ```gleam
////  import gleam/otp/actor
////
////  pub type ChatActorMessage {
////    GetMessageCount(reply_with: Subject(Int))
////    ChatEvent(ChatMessage)
////    ChatActorShutdown
////  }
////
////  fn start_chat_actor(
////    pubsub: pubsub.PubSub(ChatMessage),
////    group: String,
////  ) -> Result(actor.Started(Subject(ChatActorMessage)), actor.StartError) {
////    actor.new_with_initialiser(5000, fn(subject) {
////      let subscription = pubsub.subscribe(pubsub, group, process.self())
////
////      let selector =
////        process.new_selector()
////        |> process.select(subject)
////        |> process.select_map(subscription.subject, ChatEvent)
////
////      let initial_state = ChatActorState(message_count: 0, last_message: "")
////
////      actor.initialised(initial_state)
////      |> actor.selecting(selector)
////      |> actor.returning(subject)
////      |> Ok
////    })
////    |> actor.on_message(handle_chat_message)
////    |> actor.start()
////  }
////  ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}

import glyn.{type MessageType}

// FFI bindings for syn PubSub operations
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

// Hash function for deterministic type identification
@external(erlang, "erlang", "phash2")
fn phash2(term: any) -> Int

/// Type-safe PubSub wrapper
pub opaque type PubSub(message) {
  PubSub(scope: atom.Atom, tag: Int)
}

/// Subscription handle for cleanup
pub type Subscription(message, group) {
  Subscription(
    pubsub: PubSub(message),
    group: group,
    subject: Subject(message),
    subscriber_pid: Pid,
  )
}

/// Create a new type-safe PubSub system with a message type for deterministic type identification
/// The message_type should be a MessageType that uniquely identifies the message type
pub fn new(
  scope scope: String,
  message_type message_type: MessageType(message),
) -> PubSub(message) {
  let scope = atom.create(scope)
  syn_add_node_to_scopes([scope])
  PubSub(scope: scope, tag: phash2(message_type.id))
}

/// Subscribe to a PubSub group and return a type-safe Subject
pub fn subscribe(
  pubsub: PubSub(message),
  group: group,
  subscriber_pid: Pid,
) -> Subscription(message, group) {
  let tagged_group = #(group, pubsub.tag)
  assert atom.create("ok")
    == syn_join(pubsub.scope, tagged_group, subscriber_pid)

  // Create a Subject using the shared tag
  let subject =
    process.unsafely_create_subject(subscriber_pid, to_dynamic(pubsub.tag))

  Subscription(
    pubsub: pubsub,
    group: group,
    subject: subject,
    subscriber_pid: subscriber_pid,
  )
}

/// Unsubscribe from a PubSub group
pub fn unsubscribe(subscription: Subscription(message, group)) -> Nil {
  let tagged_group = #(subscription.group, subscription.pubsub.tag)
  assert atom.create("ok")
    == syn_leave(
      subscription.pubsub.scope,
      tagged_group,
      subscription.subscriber_pid,
    )
  Nil
}

/// Publish a type-safe message to all subscribers of a group
pub fn publish(pubsub: PubSub(message), group: group, message: message) -> Int {
  // Create the tagged message that matches what process.send would create
  // We use the tag for type identification
  let tagged_message = #(to_dynamic(pubsub.tag), message)

  // Use tagged group name to ensure only compatible subscribers receive the message
  let tagged_group = #(group, pubsub.tag)

  // Publish the tagged message through syn
  let assert Ok(subscriber_count) =
    syn_publish(pubsub.scope, tagged_group, to_dynamic(tagged_message))
  subscriber_count
}

/// Get list of subscriber PIDs for a group (useful for debugging)
pub fn subscribers(pubsub: PubSub(message), group: String) -> List(Pid) {
  let tagged_group = #(group, pubsub.tag)
  syn_members(pubsub.scope, tagged_group)
}
