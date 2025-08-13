import decode_utils
import gleam/erlang/process.{type Subject}
import gleam/list
import gleeunit
import glyn/pubsub

pub fn main() -> Nil {
  gleeunit.main()
}

// Actor message types for testing multi-channel composition
pub type TestActorMessage {
  DirectCommand(DirectMessage)
  PubSubEvent(decode_utils.ChatMessage)
  SystemEvent(decode_utils.MetricEvent)
  Shutdown
}

pub type DirectMessage {
  Ping(reply_with: Subject(String))
  SetState(state: String)
  GetState(reply_with: Subject(String))
}

// Test basic pubsub subscription with selector composition
pub fn basic_subscription_with_selector_test() {
  // Arrange: Create pubsub with chat message decoder
  let pubsub =
    pubsub.new(
      "test_basic_pubsub_selector",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  // Create base selector for direct commands
  let command_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select_map(command_subject, DirectCommand)
    |> process.merge_selector(
      pubsub.subscribe(pubsub, "test_group")
      |> process.map_selector(PubSubEvent),
    )

  // Publish a message to the group
  let message = decode_utils.UserJoined("alice")
  let assert Ok(subscriber_count) =
    pubsub.publish(pubsub, "test_group", message)

  // Assert: Should have 1 subscriber
  assert subscriber_count == 1

  // Test receiving the message through the selector
  let assert Ok(PubSubEvent(decode_utils.UserJoined("alice"))) =
    process.selector_receive(selector, 100)
}

// Test multi-channel actor composition with both chat and metrics
pub fn multi_channel_actor_composition_test() {
  // Arrange: Create pubsubs for different message types
  let chat_pubsub =
    pubsub.new(
      "test_multi_channel_chat",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("chat_decode_error"),
    )

  let metrics_pubsub =
    pubsub.new(
      "test_multi_channel_metrics",
      decode_utils.metric_event_decoder(),
      decode_utils.TimerRecord("decode_error", 0),
    )

  // Create actor with multi-channel selector
  let command_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select_map(command_subject, DirectCommand)
    |> process.merge_selector(
      pubsub.subscribe(chat_pubsub, "general")
      |> process.map_selector(PubSubEvent),
    )
    |> process.merge_selector(
      pubsub.subscribe(metrics_pubsub, "system")
      |> process.map_selector(SystemEvent),
    )

  // Act & Assert: Test that all three channels work

  // Test direct command
  process.send(command_subject, Ping(process.new_subject()))
  let assert Ok(DirectCommand(Ping(_))) =
    process.selector_receive(selector, 100)

  // Test chat pubsub message
  let assert Ok(_) =
    pubsub.publish(
      chat_pubsub,
      "general",
      decode_utils.Message("alice", "hello world"),
    )
  let assert Ok(PubSubEvent(decode_utils.Message("alice", "hello world"))) =
    process.selector_receive(selector, 100)

  // Test metrics pubsub message
  let assert Ok(_) =
    pubsub.publish(
      metrics_pubsub,
      "system",
      decode_utils.CounterIncrement("requests", 1),
    )
  let assert Ok(SystemEvent(decode_utils.CounterIncrement("requests", 1))) =
    process.selector_receive(selector, 100)
}

// Test multiple subscribers receiving same message
pub fn multiple_subscribers_test() {
  // Arrange: Create pubsub
  let pubsub =
    pubsub.new(
      "test_multiple_subscribers",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  // Create confirmation subject to receive results from spawned processes
  let confirmation_subject = process.new_subject()

  // Create first subscriber process
  let _subscriber1_pid =
    process.spawn(fn() {
      let command_subject = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select_map(command_subject, DirectCommand)
        |> process.merge_selector(
          pubsub.subscribe(pubsub, "broadcast")
          |> process.map_selector(PubSubEvent),
        )

      // Wait for message and confirm receipt
      let assert Ok(PubSubEvent(decode_utils.AdminMessage(received_msg))) =
        process.selector_receive(selector, 1000)
      process.send(confirmation_subject, #("subscriber1", received_msg))
    })

  // Create second subscriber process
  let _subscriber2_pid =
    process.spawn(fn() {
      let command_subject = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select_map(command_subject, DirectCommand)
        |> process.merge_selector(
          pubsub.subscribe(pubsub, "broadcast")
          |> process.map_selector(PubSubEvent),
        )

      // Wait for message and confirm receipt
      let assert Ok(PubSubEvent(decode_utils.AdminMessage(received_msg))) =
        process.selector_receive(selector, 1000)
      process.send(confirmation_subject, #("subscriber2", received_msg))
    })

  // Give processes time to subscribe
  process.sleep(50)

  // Act: Publish one message
  let message = decode_utils.AdminMessage("System maintenance in 5 minutes")
  let assert Ok(subscriber_count) = pubsub.publish(pubsub, "broadcast", message)

  // Assert: Should reach 2 subscribers
  assert subscriber_count == 2

  // Receive confirmations from both processes
  let assert Ok(#("subscriber1", "System maintenance in 5 minutes")) =
    process.receive(confirmation_subject, 1000)
  let assert Ok(#("subscriber2", "System maintenance in 5 minutes")) =
    process.receive(confirmation_subject, 1000)
}

// Test group isolation (messages to different groups don't interfere)
pub fn group_isolation_test() {
  // Arrange: Create pubsub and subscribe to different groups
  let pubsub =
    pubsub.new(
      "test_group_isolation",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  let command_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select_map(command_subject, DirectCommand)
    |> process.merge_selector(
      pubsub.subscribe(pubsub, "general")
      |> process.map_selector(PubSubEvent),
    )

  // Publish to "private" group (different group)
  let assert Ok(subscriber_count) =
    pubsub.publish(
      pubsub,
      "private",
      decode_utils.Message("bob", "secret message"),
    )

  // Assert: Should have 0 subscribers in private group
  assert subscriber_count == 0

  // Should not receive message in general group
  let assert Error(_) = process.selector_receive(selector, 50)

  // But should receive message sent to correct group
  let assert Ok(general_count) =
    pubsub.publish(
      pubsub,
      "general",
      decode_utils.Message("alice", "public message"),
    )
  assert general_count == 1

  let assert Ok(PubSubEvent(decode_utils.Message("alice", "public message"))) =
    process.selector_receive(selector, 100)
}

// Test distributed behavior simulation (same scope works across instances)
pub fn distributed_behavior_simulation_test() {
  // Arrange: Create two pubsub instances with same scope (simulating different nodes)
  let pubsub1 =
    pubsub.new(
      "test_distributed_pubsub",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  let pubsub2 =
    pubsub.new(
      "test_distributed_pubsub",
      // Same scope = distributed behavior
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  let command_subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select_map(command_subject, DirectCommand)
    |> process.merge_selector(
      pubsub.subscribe(pubsub1, "distributed_group")
      |> process.map_selector(PubSubEvent),
    )

  // Act: Publish from second "node" to same group
  let assert Ok(subscriber_count) =
    pubsub.publish(
      pubsub2,
      "distributed_group",
      decode_utils.UserJoined("distributed_user"),
    )

  // Assert: Should find the subscriber from the first "node"
  assert subscriber_count == 1

  // Subscriber should receive the message
  let assert Ok(PubSubEvent(decode_utils.UserJoined("distributed_user"))) =
    process.selector_receive(selector, 100)
}

// Test type safety through different scopes and decoders
pub fn type_safety_through_scopes_test() {
  // Arrange: Create two pubsubs with different scopes and decoders
  let chat_pubsub =
    pubsub.new(
      "type_safety_chat",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  let metrics_pubsub =
    pubsub.new(
      "type_safety_metrics",
      // Different scope
      decode_utils.metric_event_decoder(),
      decode_utils.TimerRecord("decode_error", 0),
    )

  let command_subject = process.new_subject()
  let _base_selector =
    process.new_selector() |> process.select_map(command_subject, DirectCommand)
  // Same name, different scope

  // Create selectors to receive messages
  let chat_selector = pubsub.subscribe(chat_pubsub, "shared_name")
  let metrics_selector = pubsub.subscribe(metrics_pubsub, "shared_name")

  // Act: Publish to both scopes with same group name
  let assert Ok(chat_count) =
    pubsub.publish(
      chat_pubsub,
      "shared_name",
      decode_utils.Message("user", "hello"),
    )

  let assert Ok(metrics_count) =
    pubsub.publish(
      metrics_pubsub,
      "shared_name",
      decode_utils.GaugeUpdate("cpu", 0.75),
    )

  // Assert: Each should only reach its own scope
  assert chat_count == 1
  assert metrics_count == 1

  // Verify messages are received in correct scopes
  let assert Ok(decode_utils.Message("user", "hello")) =
    process.selector_receive(chat_selector, 100)
  let assert Ok(decode_utils.GaugeUpdate("cpu", 0.75)) =
    process.selector_receive(metrics_selector, 100)
}

// Test unsubscribe functionality
pub fn unsubscribe_test() {
  // Arrange: Create pubsub and subscribe
  let pubsub =
    pubsub.new(
      "test_unsubscribe",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  let command_subject = process.new_subject()
  let _base_selector =
    process.new_selector() |> process.select_map(command_subject, DirectCommand)

  let _subscriber_selector = pubsub.subscribe(pubsub, "temp_group")

  // Verify subscription exists
  let assert Ok(count_before) =
    pubsub.publish(
      pubsub,
      "temp_group",
      decode_utils.Message("test", "before unsubscribe"),
    )
  assert count_before == 1

  // Act: Unsubscribe
  pubsub.unsubscribe(pubsub, "temp_group")

  // Assert: Should have no subscribers now
  let assert Ok(count_after) =
    pubsub.publish(
      pubsub,
      "temp_group",
      decode_utils.Message("test", "after unsubscribe"),
    )
  assert count_after == 0
}

// Test error handling for invalid operations
pub fn error_handling_test() {
  let pubsub =
    pubsub.new(
      "test_errors_pubsub",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  // Test unsubscribe without subscribe - this now just succeeds silently
  pubsub.unsubscribe(pubsub, "nonexistent_group")

  // Test publish to empty group (should succeed but reach 0 subscribers)
  let assert Ok(count) =
    pubsub.publish(
      pubsub,
      "empty_group",
      decode_utils.Message("user", "message to empty group"),
    )
  assert count == 0
}

// Test subscriber count and debugging functions
pub fn subscriber_utilities_test() {
  let pubsub =
    pubsub.new(
      "test_utilities",
      decode_utils.chat_message_decoder(),
      decode_utils.AdminMessage("decode_error"),
    )

  // Initially no subscribers
  assert pubsub.subscriber_count(pubsub, "util_group") == 0
  assert pubsub.subscribers(pubsub, "util_group") == []

  let _selector = pubsub.subscribe(pubsub, "util_group")

  // Should now have 1 subscriber
  assert pubsub.subscriber_count(pubsub, "util_group") == 1

  let subscribers = pubsub.subscribers(pubsub, "util_group")
  assert list.length(subscribers) == 1
}
