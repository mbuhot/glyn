////  Glyn Registry - Type-Safe Distributed Process Registry
////
////  This module provides a type-safe wrapper around Erlang's `syn` process registry,
////  enabling distributed service discovery and direct process communication with
////  compile-time type safety.
////
////  ## Actor Integration Pattern
////
////  The registry works seamlessly with Gleam's actor system and composes with PubSub:
////
////  ```gleam
////  import gleam/otp/actor
////  import glyn/pubsub
////
////  pub type ActorMessage {
////    CommandMessage(Command)      // Direct commands via Registry
////    PubSubMessage(Event)         // Events via PubSub
////    ActorShutdown
////  }
////
////  fn start_integration_actor(
////    registry: registry.Registry(Command, String),
////    pubsub: pubsub.PubSub(Event),
////  ) -> Result(actor.Started(Subject(ActorMessage)), actor.StartError) {
////    actor.new_with_initialiser(5000, fn(subject) {
////      // Create command subject for Registry
////      let command_subject = process.new_subject()
////      let assert Ok(_registration) = registry.register(
////        registry, "my_service", command_subject, "service_metadata"
////      )
////
////      // Subscribe to PubSub events
////      let event_subscription = pubsub.subscribe(pubsub, "events", process.self())
////
////      // Compose both message sources
////      let selector =
////        process.new_selector()
////        |> process.select(subject)
////        |> process.select_map(command_subject, CommandMessage)
////        |> process.select_map(event_subscription.subject, PubSubMessage)
////
////      actor.initialised(initial_state)
////      |> actor.selecting(selector)
////      |> actor.returning(subject)
////      |> Ok
////    })
////    |> actor.on_message(handle_message)
////    |> actor.start()
////  }
////  ```

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor
import gleam/string
import glyn.{type MessageType}

// FFI bindings for syn registry operations
@external(erlang, "syn", "add_node_to_scopes")
fn syn_add_node_to_scopes(scopes: List(atom.Atom)) -> atom.Atom

@external(erlang, "syn", "register")
fn syn_register(
  scope: atom.Atom,
  name: String,
  pid: Pid,
  metadata: metadata,
) -> Dynamic

@external(erlang, "syn", "lookup")
fn syn_lookup(scope: atom.Atom, name: String) -> Dynamic

@external(erlang, "syn", "unregister")
fn syn_unregister(scope: atom.Atom, name: String) -> Dynamic

// Convert any value to Dynamic
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn from_dynamic(value: Dynamic) -> a

// Hash function for deterministic type identification
@external(erlang, "erlang", "phash2")
fn phash2(term: any) -> Int

/// Type-safe process registry wrapper
pub opaque type Registry(message, metadata) {
  Registry(scope: atom.Atom, tag: Int)
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
/// The message_type should be a MessageType that uniquely identifies the message type
pub fn new(scope scope: String, message_type message_type: MessageType(message)) -> Registry(message, metadata) {
  let scope = atom.create(scope)
  syn_add_node_to_scopes([scope])
  Registry(scope: scope, tag: phash2(message_type.id))
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
      let result =
        syn_register(
          registry.scope,
          name,
          pid,
          to_dynamic(#(subject, registry.tag, metadata)),
        )
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
pub fn unregister(
  registration: Registration(message, metadata),
) -> Result(Nil, String) {
  let result = syn_unregister(registration.registry.scope, registration.name)
  case result == to_dynamic(atom.create("ok")) {
    True -> Ok(Nil)
    False -> Error("Unregistration failed: " <> string.inspect(result))
  }
}

/// Look up a registered process and return a type-safe Subject with metadata
pub fn lookup(
  registry: Registry(message, metadata),
  name: String,
) -> Result(#(Subject(message), metadata), String) {
  let result = syn_lookup(registry.scope, name)
  case result == to_dynamic(atom.create("undefined")) {
    True -> {
      Error("Process not found: " <> name)
    }
    False -> {
      let #(_pid, stored_data) = from_dynamic(result)
      let #(subject, tag, metadata) = from_dynamic(stored_data)
      case tag == registry.tag {
        True -> Ok(#(subject, metadata))
        False -> Error("Process registered under incompatible type: " <> name)
      }
    }
  }
}

/// Send a type-safe message to a registered process
pub fn send(
  registry: Registry(message, metadata),
  name: String,
  message: message,
) -> Result(Nil, String) {
  case lookup(registry, name) {
    Ok(#(subject, _metadata)) -> {
      process.send(subject, message)
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// Call a registered process and wait for a reply, similar to actor.call
pub fn call(
  registry: Registry(message, metadata),
  name: String,
  waiting timeout: Int,
  sending message_fn: fn(Subject(reply)) -> message,
) -> Result(reply, String) {
  case lookup(registry, name) {
    Ok(#(subject, _metadata)) -> {
      let reply = actor.call(subject, waiting: timeout, sending: message_fn)
      Ok(reply)
    }
    Error(reason) -> Error(reason)
  }
}
