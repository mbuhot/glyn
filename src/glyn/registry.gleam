////  Glyn Registry - Selector-Based Type-Safe Process Registry
////
////  This module provides a selector-based wrapper around Erlang's `syn` process registry,
////  enabling distributed service discovery and direct process communication with
////  runtime type safety through dynamic decoding.
////
////  ## Multi-Channel Actor Integration Pattern
////
////  The registry seamlessly composes with other message channels using selectors:
////
////  ```gleam
////  import gleam/dynamic.{type Dynamic}
////  import gleam/dynamic/decode
////  import gleam/erlang/atom
////  import gleam/erlang/process.{type Subject}
////  import gleam/otp/actor
////  import glyn/registry
////  import glyn/pubsub
////
////  // Define your message types
////  pub type ServiceMessage {
////    ProcessOrder(id: String, reply_with: Subject(Bool))
////    GetStatus(reply_with: Subject(String))
////    Shutdown
////  }
////
////  pub type SystemEvent {
////    ServiceStarted(name: String)
////    ServiceStopped(name: String)
////  }
////
////  pub type ActorMessage {
////    DirectCommand(String)             // Direct commands
////    RegistryMessage(ServiceMessage)   // Registry messages (decoded)
////    PubSubEvent(SystemEvent)          // PubSub events
////  }
////
////  // Create decoders for your message types
////  fn expect_atom(expected: String) -> decode.Decoder(atom.Atom) {
////    use value <- decode.then(atom.decoder())
////    case atom.to_string(value) == expected {
////      True -> decode.success(value)
////      False -> decode.failure(value, "Expected atom: " <> expected)
////    }
////  }
////
////  fn service_message_decoder() -> decode.Decoder(ServiceMessage) {
////    decode.one_of(
////      {
////        use _ <- decode.field(0, expect_atom("shutdown"))
////        decode.success(Shutdown)
////      },
////      or: [
////        {
////          use _ <- decode.field(0, expect_atom("get_status"))
////          use reply_with <- decode.field(1, subject_decoder())
////          decode.success(GetStatus(reply_with))
////        },
////        // Add other variants as needed
////      ]
////    )
////  }
////
////  fn start_multi_channel_actor() {
////    actor.new_with_initialiser(5000, fn(_) {
////      let command_subject = process.new_subject()
////
////      // Create base selector for direct commands
////      let base_selector =
////        process.new_selector()
////        |> process.select_map(command_subject, DirectCommand)
////
////      // Add registry channel
////      let user_registry = registry.new(
////        scope: "user_services",
////        decoder: service_message_decoder(),
////        error_default: Shutdown
////      )
////      let assert Ok(registry_selector) = registry.register(
////        user_registry,
////        "order_processor",
////        "v1.0"
////      )
////      let with_registry = base_selector
////        |> process.merge_selector(
////          process.map_selector(registry_selector, RegistryMessage)
////        )
////
////      // Add pubsub channel for system events
////      let system_pubsub = pubsub.new(
////        scope: "system_events",
////        decoder: system_event_decoder(),
////        error_default: ServiceStarted("unknown")
////      )
////      let pubsub_selector = pubsub.subscribe(system_pubsub, "services")
////      let final_selector = with_registry
////        |> process.merge_selector(
////          process.map_selector(pubsub_selector, PubSubEvent)
////        )
////
////      actor.initialised(initial_state)
////      |> actor.selecting(final_selector)
////      |> actor.returning(command_subject)
////      |> Ok
////    })
////  }
////
////  // Send messages to registered services
////  let user_registry = registry.new(
////    scope: "user_services",
////    decoder: service_message_decoder(),
////    error_default: Shutdown
////  )
////
////  // Send a message
////  let assert Ok(_) = registry.send(
////    user_registry,
////    "order_processor",
////    ProcessOrder("order-123", reply_subject)
////  )
////
////  // Make a call and wait for reply
////  let assert Ok(status) = registry.call(
////    user_registry,
////    "order_processor",
////    waiting: 5000,
////    sending: GetStatus(_)
////  )
////  ```

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/result
import gleam/string

type SynOk

type SynResult

// FFI bindings for syn PubSub operations
@external(erlang, "syn", "add_node_to_scopes")
fn syn_add_node_to_scopes(scopes: List(atom.Atom)) -> SynOk

@external(erlang, "syn", "register")
fn syn_register(
  scope: atom.Atom,
  name: String,
  pid: Pid,
  metadata: metadata,
) -> SynResult

// -spec lookup(Scope :: atom(), Name :: term()) -> {pid(), Meta :: term()} | undefined.
@external(erlang, "syn", "lookup")
fn syn_lookup(scope: atom.Atom, name: String) -> Dynamic

@external(erlang, "syn", "unregister")
fn syn_unregister(scope: atom.Atom, name: String) -> SynResult

// Convert any value to Dynamic
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn from_dynamic(value: Dynamic) -> a

@external(erlang, "syn_ffi", "to_result")
fn to_result(result: SynResult) -> Result(Nil, Dynamic)

/// Type-safe process registry with dynamic decoding
pub opaque type Registry(message, metadata) {
  Registry(
    scope: atom.Atom,
    decoder: decode.Decoder(message),
    error_default: message,
  )
}

/// Registration errors
pub type RegistryError {
  Timeout
  ProcessNotFound(name: String)
  RegistrationFailed(reason: String)
  UnregistrationFailed(reason: String)
}

/// Create a new Registry system for a given scope with dynamic decoding
pub fn new(
  scope scope: String,
  decoder decoder: decode.Decoder(message),
  error_default error_default: message,
) -> Registry(message, metadata) {
  let scope = atom.create(scope)
  syn_add_node_to_scopes([scope])
  Registry(scope: scope, decoder: decoder, error_default: error_default)
}

/// Register a process with a name and return a selector for receiving messages
/// Creates an internal Subject(Dynamic) and uses select_map for type safety
pub fn register(
  registry registry: Registry(message, metadata),
  actor_name actor_name: String,
  metadata metadata: metadata,
) -> Result(Selector(message), RegistryError) {
  // Register the current process with a dynamic subject for receiving messages
  let current_pid = process.self()
  let dynamic_subject = process.new_subject()

  let result =
    syn_register(
      registry.scope,
      actor_name,
      current_pid,
      to_dynamic(#(dynamic_subject, metadata)),
    )

  case to_result(result) {
    Ok(Nil) -> {
      // Return a selector with dynamic decoding and error handling
      let selector =
        process.new_selector()
        |> process.select_map(dynamic_subject, fn(dynamic_msg) {
          decode.run(dynamic_msg, registry.decoder)
          |> result.unwrap(registry.error_default)
        })
      Ok(selector)
    }
    Error(e) -> {
      Error(RegistrationFailed("syn registration failed: " <> string.inspect(e)))
    }
  }
}

/// Unregister a process by name
pub fn unregister(
  registry: Registry(message, metadata),
  actor_name: String,
) -> Result(Nil, RegistryError) {
  let result = syn_unregister(registry.scope, actor_name)
  case to_result(result) {
    Ok(Nil) -> Ok(Nil)
    Error(e) ->
      Error(UnregistrationFailed(
        "syn unregistration failed: " <> string.inspect(e),
      ))
  }
}

/// Look up a registered process and return PID with metadata
pub fn whereis(
  registry: Registry(message, metadata),
  actor_name: String,
) -> Result(#(Pid, metadata), RegistryError) {
  let result = syn_lookup(registry.scope, actor_name)
  case result == to_dynamic(atom.create("undefined")) {
    True -> Error(ProcessNotFound(actor_name))
    False -> {
      let #(pid, stored_data) = from_dynamic(result)
      let #(_subject, metadata) = from_dynamic(stored_data)
      Ok(#(pid, metadata))
    }
  }
}

/// Send a message to a registered process using the stored dynamic subject
pub fn send(
  registry: Registry(message, metadata),
  actor_name: String,
  message: message,
) -> Result(Nil, RegistryError) {
  let result = syn_lookup(registry.scope, actor_name)
  case result == to_dynamic(atom.create("undefined")) {
    True -> Error(ProcessNotFound(actor_name))
    False -> {
      let #(_pid, stored_data) = from_dynamic(result)
      let #(dynamic_subject, _metadata) = from_dynamic(stored_data)
      // Send the message as Dynamic to the stored dynamic_subject
      process.send(dynamic_subject, to_dynamic(message))
      Ok(Nil)
    }
  }
}

/// Call a registered process and wait for a reply, similar to actor.call
pub fn call(
  registry: Registry(message, metadata),
  actor_name: String,
  waiting timeout: Int,
  sending message_fn: fn(Subject(reply)) -> message,
) -> Result(reply, RegistryError) {
  // Create a temporary subject for the reply
  let reply_subject = process.new_subject()
  let message = message_fn(reply_subject)

  // Send the message
  case send(registry, actor_name, message) {
    Ok(_) -> {
      // Wait for reply
      case process.receive(reply_subject, timeout) {
        Ok(reply) -> Ok(reply)
        Error(Nil) -> Error(Timeout)
      }
    }
    Error(error) -> Error(error)
  }
}
