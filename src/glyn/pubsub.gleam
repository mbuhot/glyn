////  Glyn PubSub - Selector-Based Type-Safe Event Streaming
////
////  This module provides a selector-based wrapper around Erlang's `syn` PubSub system,
////  enabling distributed event streaming and one-to-many message broadcasting with
////  runtime type safety through dynamic decoding.
////
////  ## Multi-Channel Actor Integration Pattern
////
////  PubSub seamlessly composes with other message channels using selectors:
////
////  ```gleam
////  import gleam/dynamic.{type Dynamic}
////  import gleam/dynamic/decode
////  import gleam/erlang/atom
////  import gleam/erlang/process.{type Subject}
////  import gleam/otp/actor
////  import glyn/pubsub
////  import glyn/registry
////
////  // Define your event types
////  pub type ChatMessage {
////    UserJoined(username: String)
////    UserLeft(username: String)
////    Message(username: String, content: String)
////  }
////
////  pub type MetricEvent {
////    CounterIncrement(name: String, value: Int)
////    GaugeUpdate(name: String, value: Float)
////  }
////
////  pub type ActorMessage {
////    DirectCommand(String)           // Direct commands
////    ChatEvent(ChatMessage)          // Chat PubSub events
////    MetricEvent(MetricEvent)        // Metrics PubSub events
////  }
////
////  // Create decoders for your event types
////  fn expect_atom(expected: String) -> decode.Decoder(atom.Atom) {
////    use value <- decode.then(atom.decoder())
////    case atom.to_string(value) == expected {
////      True -> decode.success(value)
////      False -> decode.failure(value, "Expected atom: " <> expected)
////    }
////  }
////
////  fn chat_message_decoder() -> decode.Decoder(ChatMessage) {
////    decode.one_of(
////      {
////        use _ <- decode.field(0, expect_atom("user_joined"))
////        use username <- decode.field(1, decode.string)
////        decode.success(UserJoined(username))
////      },
////      or: [
////        {
////          use _ <- decode.field(0, expect_atom("message"))
////          use username <- decode.field(1, decode.string)
////          use content <- decode.field(2, decode.string)
////          decode.success(Message(username, content))
////        },
////        // Add other variants as needed
////      ]
////    )
////  }
////
////  fn metric_event_decoder() -> decode.Decoder(MetricEvent) {
////    decode.one_of(
////      {
////        use _ <- decode.field(0, expect_atom("counter_increment"))
////        use name <- decode.field(1, decode.string)
////        use value <- decode.field(2, decode.int)
////        decode.success(CounterIncrement(name, value))
////      },
////      or: [
////        {
////          use _ <- decode.field(0, expect_atom("gauge_update"))
////          use name <- decode.field(1, decode.string)
////          use value <- decode.field(2, decode.float)
////          decode.success(GaugeUpdate(name, value))
////        },
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
////      // Add chat PubSub channel
////      let chat_pubsub = pubsub.new(
////        scope: "chat_events",
////        decoder: chat_message_decoder(),
////      )
////      let chat_selector = pubsub.subscribe(chat_pubsub, "general")
////      let with_chat = base_selector
////        |> process.merge_selector(
////          process.map_selector(chat_selector, ChatEvent)
////        )
////
////      // Add metrics PubSub channel
////      let metrics_pubsub = pubsub.new(
////        scope: "metrics_events",
////        decoder: metric_event_decoder()
////      )
////      let metrics_selector = pubsub.subscribe(metrics_pubsub, "system")
////      let final_selector = with_chat
////        |> process.merge_selector(
////          process.map_selector(metrics_selector, MetricEvent)
////        )
////
////      actor.initialised(initial_state)
////      |> actor.selecting(final_selector)
////      |> actor.returning(command_subject)
////      |> Ok
////    })
////  }
////
////  // Publishing events to subscribers
////  let chat_pubsub = pubsub.new(
////    scope: "chat_events",
////    decoder: chat_message_decoder(),
////  )
////
////  // Publish a chat message to all subscribers in "general" channel
////  let assert Ok(Nil) = pubsub.publish(
////    chat_pubsub,
////    "general",
////    Message("alice", "Hello everyone!")
////  )
////
////  // Check current subscriber count for monitoring
////  let count = pubsub.subscriber_count(chat_pubsub, "general")
////  ```

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/erlang/reference
import gleam/otp/actor
import gleam/string

type SynResult

type SynOk

// FFI bindings for syn PubSub operations
@external(erlang, "syn", "add_node_to_scopes")
fn syn_add_node_to_scopes(scopes: List(atom.Atom)) -> SynOk

@external(erlang, "syn", "join")
fn syn_join(scope: atom.Atom, group: group, pid: Pid) -> SynResult

@external(erlang, "syn", "leave")
fn syn_leave(scope: atom.Atom, group: group, pid: Pid) -> SynResult

@external(erlang, "syn", "members")
fn syn_members(scope: atom.Atom, group: group) -> List(Pid)

@external(erlang, "syn", "local_member_count")
fn syn_local_member_count(scope: atom.Atom, group: group) -> Int

@external(erlang, "syn", "publish")
fn syn_publish(
  scope: atom.Atom,
  group: group,
  message: message,
) -> Result(Int, Dynamic)

@external(erlang, "syn", "local_publish")
fn syn_local_publish(
  scope: atom.Atom,
  group: group,
  message: message,
) -> Result(Int, Dynamic)

@external(erlang, "syn", "member_count")
fn syn_member_count(scope: atom.Atom, group: group) -> Int

@external(erlang, "syn_ffi", "to_result")
fn to_result(result: SynResult) -> Result(Nil, Dynamic)

// Convert any value to Dynamic
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: a) -> Dynamic

/// Type-safe PubSub with dynamic decoding
pub opaque type PubSub(message) {
  PubSub(
    scope: atom.Atom,
    decoder: decode.Decoder(message),
    tag: reference.Reference,
  )
}

pub type PubSubError {
  PublishFailed(String)
}

/// Create a new PubSub system for a given scope with dynamic decoding
pub fn new(scope: String, decoder: decode.Decoder(message)) -> PubSub(message) {
  let scope = atom.create(scope)
  syn_add_node_to_scopes([scope])
  let tag = reference.new()
  PubSub(scope:, decoder:, tag: tag)
}

/// Subscribe to a PubSub group and compose into a selector
/// Creates an internal Subject(Dynamic) and uses select_map for type safety
pub fn subscribe(
  pubsub pubsub: PubSub(message),
  group group: group,
) -> Selector(message) {
  let current_pid = process.self()

  case syn_local_member_count(pubsub.scope, group) {
    0 -> {
      let assert Ok(_) = start_decoder_actor(pubsub, group)
      Nil
    }
    _ -> Nil
  }

  // Join a tagged group with the current process
  let assert Ok(Nil) =
    syn_join(pubsub.scope, #(pubsub.tag, group), current_pid) |> to_result()

  // Return selector accepting typed messages tagged with this pubsubs internal private tag
  let subject =
    process.unsafely_create_subject(current_pid, to_dynamic(pubsub.tag))
  process.new_selector()
  |> process.select(subject)
}

fn start_decoder_actor(
  pubsub: PubSub(message),
  group: group,
) -> Result(actor.Started(Subject(Dynamic)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject: Subject(Dynamic)) {
    let assert Ok(pid) = process.subject_owner(subject)
    syn_join(pubsub.scope, group, pid)
    let selector: Selector(Dynamic) =
      process.new_selector()
      |> process.select_other(fn(dynamic) { dynamic })

    actor.initialised(#(pubsub, group))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(decode_message)
  |> actor.start()
}

fn decode_message(
  state: #(PubSub(message), group),
  message: Dynamic,
) -> actor.Next(#(PubSub(message), group), Dynamic) {
  let #(pubsub, group) = state
  case decode.run(message, pubsub.decoder) {
    Ok(decoded) -> {
      case local_publish(pubsub, group, decoded) {
        Ok(0) -> actor.stop()
        Ok(_) -> actor.continue(state)
        Error(_e) -> {
          actor.continue(state)
        }
      }
    }
    Error(_e) -> {
      actor.continue(state)
    }
  }
}

/// Unsubscribe from a PubSub group
pub fn unsubscribe(pubsub: PubSub(message), group: group) -> Nil {
  let current_pid = process.self()
  syn_leave(pubsub.scope, #(pubsub.tag, group), current_pid)
  Nil
}

/// Publish a type-safe message to all subscribers of a group
pub fn publish(
  pubsub: PubSub(message),
  group: String,
  message: message,
) -> Result(Nil, PubSubError) {
  // Publish the tagged message through syn
  case syn_publish(pubsub.scope, group, to_dynamic(message)) {
    Ok(_) -> Ok(Nil)
    Error(reason) ->
      Error(PublishFailed("publish failed: " <> string.inspect(reason)))
  }
}

pub fn local_publish(
  pubsub: PubSub(message),
  group: group,
  message: message,
) -> Result(Int, PubSubError) {
  let tagged_message = #(pubsub.tag, message)

  // Publish the tagged message through syn
  case
    syn_local_publish(
      pubsub.scope,
      #(pubsub.tag, group),
      to_dynamic(tagged_message),
    )
  {
    Ok(count) -> Ok(count)
    Error(reason) ->
      Error(PublishFailed("publish failed: " <> string.inspect(reason)))
  }
}

/// Get list of subscriber PIDs for a group (useful for debugging)
pub fn subscribers(pubsub: PubSub(message), group: String) -> List(Pid) {
  syn_members(pubsub.scope, group)
}

/// Get the count of subscribers for a group
pub fn subscriber_count(pubsub: PubSub(message), group: String) -> Int {
  syn_member_count(pubsub.scope, group)
}
