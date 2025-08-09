import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleeunit
import glyn
import glyn/pubsub

pub fn main() -> Nil {
  gleeunit.main()
}

// Test message types for PubSub
pub type ChatMessage {
  UserJoined(username: String)
  UserLeft(username: String)
  Message(username: String, content: String)
}

pub type MetricEvent {
  CounterIncrement(name: String, value: Int)
  GaugeUpdate(name: String, value: Float)
  TimerRecord(name: String, duration_ms: Int)
}

// Message type constants - these create a compile-time association with message types
pub const chat_message_type: glyn.MessageType(ChatMessage) = glyn.MessageType(
  "ChatMessage_v1",
)

pub const metric_event_type: glyn.MessageType(MetricEvent) = glyn.MessageType(
  "MetricEvent_v1",
)

pub type ChatActorMessage {
  // Direct actor commands
  GetMessageCount(reply_with: Subject(Int))
  GetLastMessage(reply_with: Subject(String))
  GetReady(reply_with: Subject(Nil))
  ChatActorShutdown
  // PubSub events
  ChatEvent(ChatMessage)
}

pub type MetricActorMessage {
  GetTotalCount(reply_with: Subject(Int))
  GetMetricCount(reply_with: Subject(Int))
  GetMetricReady(reply_with: Subject(Nil))
  MetricEvent(MetricEvent)
  MetricActorShutdown
}

pub type ChatActorState {
  ChatActorState(message_count: Int, last_message: String)
}

pub type MetricActorState {
  MetricActorState(total_count: Int, metric_count: Int)
}

// Helper to handle chat messages for testing actors
fn handle_chat_message(
  state: ChatActorState,
  message: ChatActorMessage,
) -> actor.Next(ChatActorState, ChatActorMessage) {
  case message {
    GetMessageCount(reply_with) -> {
      process.send(reply_with, state.message_count)
      actor.continue(state)
    }
    GetLastMessage(reply_with) -> {
      process.send(reply_with, state.last_message)
      actor.continue(state)
    }
    GetReady(reply_with) -> {
      process.send(reply_with, Nil)
      actor.continue(state)
    }
    ChatActorShutdown -> {
      actor.stop()
    }
    ChatEvent(chat_message) -> {
      let new_count = state.message_count + 1
      let last_message = case chat_message {
        UserJoined(username) -> "User joined: " <> username
        UserLeft(username) -> "User left: " <> username
        Message(username, content) -> username <> ": " <> content
      }
      let new_state =
        ChatActorState(message_count: new_count, last_message: last_message)
      actor.continue(new_state)
    }
  }
}

// Helper to handle metric messages for testing actors
fn handle_metric_message(
  state: MetricActorState,
  message: MetricActorMessage,
) -> actor.Next(MetricActorState, MetricActorMessage) {
  case message {
    GetTotalCount(reply_with) -> {
      process.send(reply_with, state.total_count)
      actor.continue(state)
    }
    GetMetricCount(reply_with) -> {
      process.send(reply_with, state.metric_count)
      actor.continue(state)
    }
    GetMetricReady(reply_with) -> {
      process.send(reply_with, Nil)
      actor.continue(state)
    }
    MetricActorShutdown -> {
      actor.stop()
    }
    MetricEvent(metric_event) -> {
      let new_metric_count = state.metric_count + 1
      let new_total_count = case metric_event {
        CounterIncrement(_, value) -> state.total_count + value
        GaugeUpdate(_, _) -> state.total_count
        TimerRecord(_, duration) -> state.total_count + duration
      }
      let new_state =
        MetricActorState(
          total_count: new_total_count,
          metric_count: new_metric_count,
        )
      actor.continue(new_state)
    }
  }
}

// Helper to start chat actor with PubSub subscription
fn start_chat_actor(
  pubsub: pubsub.PubSub(ChatMessage),
  group: String,
) -> Result(actor.Started(Subject(ChatActorMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    let subscription = pubsub.subscribe(pubsub, group, process.self())

    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(subscription.subject, ChatEvent)

    let initial_state = ChatActorState(message_count: 0, last_message: "")

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_chat_message)
  |> actor.start()
}

// Helper to start metric actor with PubSub subscription
fn start_metric_actor(
  pubsub: pubsub.PubSub(MetricEvent),
  group: String,
) -> Result(actor.Started(Subject(MetricActorMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    let subscription = pubsub.subscribe(pubsub, group, process.self())

    let selector =
      process.new_selector()
      |> process.select_map(subject, fn(msg) { msg })
      |> process.select_map(subscription.subject, MetricEvent)

    let initial_state = MetricActorState(total_count: 0, metric_count: 0)

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_metric_message)
  |> actor.start()
}

pub fn actor_pubsub_integration_test() {
  let pubsub =
    pubsub.new(scope: "chat_test_scope", message_type: chat_message_type)

  // Start actor
  let assert Ok(started) = start_chat_actor(pubsub, "general")
  let actor_subject = started.data

  // Wait for actor to be ready
  let _ = actor.call(actor_subject, waiting: 1000, sending: GetReady)

  // Publish a message
  let subscriber_count =
    pubsub.publish(pubsub, "general", Message("alice", "hello world"))
  assert subscriber_count == 1

  // Verify actor received the message
  let message_count =
    actor.call(actor_subject, waiting: 1000, sending: GetMessageCount)
  assert message_count == 1

  let last_message =
    actor.call(actor_subject, waiting: 1000, sending: GetLastMessage)
  assert last_message == "alice: hello world"

  // Shutdown actor
  actor.send(actor_subject, ChatActorShutdown)
}

pub fn multiple_actors_test() {
  let pubsub =
    pubsub.new(scope: "multi_chat_scope", message_type: chat_message_type)

  // Start multiple actors
  let assert Ok(started1) = start_chat_actor(pubsub, "general")
  let assert Ok(started2) = start_chat_actor(pubsub, "general")
  let assert Ok(started3) = start_chat_actor(pubsub, "general")

  let actor1 = started1.data
  let actor2 = started2.data
  let actor3 = started3.data

  // Wait for all actors to be ready
  let _ = actor.call(actor1, waiting: 1000, sending: GetReady)
  let _ = actor.call(actor2, waiting: 1000, sending: GetReady)
  let _ = actor.call(actor3, waiting: 1000, sending: GetReady)

  // Publish a message - should reach all 3 actors
  let subscriber_count = pubsub.publish(pubsub, "general", UserJoined("bob"))
  assert subscriber_count == 3

  // Verify all actors received the message
  let count1 = actor.call(actor1, waiting: 1000, sending: GetMessageCount)
  let count2 = actor.call(actor2, waiting: 1000, sending: GetMessageCount)
  let count3 = actor.call(actor3, waiting: 1000, sending: GetMessageCount)

  assert count1 == 1
  assert count2 == 1
  assert count3 == 1

  // Shutdown actors
  actor.send(actor1, ChatActorShutdown)
  actor.send(actor2, ChatActorShutdown)
  actor.send(actor3, ChatActorShutdown)
}

pub fn group_isolation_test() {
  let pubsub =
    pubsub.new(scope: "group_test_scope", message_type: chat_message_type)

  // Start actors in different groups
  let assert Ok(started1) = start_chat_actor(pubsub, "general")
  let assert Ok(started2) = start_chat_actor(pubsub, "private")

  let actor1 = started1.data
  let actor2 = started2.data

  // Wait for actors to be ready
  let _ = actor.call(actor1, waiting: 1000, sending: GetReady)
  let _ = actor.call(actor2, waiting: 1000, sending: GetReady)

  // Publish to general group - only actor1 should receive it
  let general_count =
    pubsub.publish(pubsub, "general", Message("alice", "general message"))
  assert general_count == 1

  // Publish to private group - only actor2 should receive it
  let private_count =
    pubsub.publish(pubsub, "private", Message("bob", "private message"))
  assert private_count == 1

  // Verify correct isolation
  let count1 = actor.call(actor1, waiting: 1000, sending: GetMessageCount)
  let count2 = actor.call(actor2, waiting: 1000, sending: GetMessageCount)

  assert count1 == 1
  // Only got general message
  assert count2 == 1
  // Only got private message

  let last1 = actor.call(actor1, waiting: 1000, sending: GetLastMessage)
  let last2 = actor.call(actor2, waiting: 1000, sending: GetLastMessage)

  assert last1 == "alice: general message"
  assert last2 == "bob: private message"

  // Shutdown actors
  actor.send(actor1, ChatActorShutdown)
  actor.send(actor2, ChatActorShutdown)
}

pub fn type_safety_test() {
  // Different scopes for different message types
  let chat_pubsub =
    pubsub.new(scope: "type_test_chat", message_type: chat_message_type)
  let metric_pubsub =
    pubsub.new(scope: "type_test_metrics", message_type: metric_event_type)

  // Start actors with different message types
  let assert Ok(chat_started) = start_chat_actor(chat_pubsub, "general")
  let assert Ok(metric_started) = start_metric_actor(metric_pubsub, "counters")

  let chat_actor = chat_started.data
  let metric_actor = metric_started.data

  // Wait for actors to be ready
  let _ = actor.call(chat_actor, waiting: 1000, sending: GetReady)
  let _ = actor.call(metric_actor, waiting: 1000, sending: GetMetricReady)

  // Publish chat message - only chat actor should receive
  let chat_count = pubsub.publish(chat_pubsub, "general", UserJoined("alice"))
  assert chat_count == 1

  // Publish metric event - only metric actor should receive
  let metric_count =
    pubsub.publish(metric_pubsub, "counters", CounterIncrement("requests", 5))
  assert metric_count == 1

  // Verify correct isolation
  let chat_messages =
    actor.call(chat_actor, waiting: 1000, sending: GetMessageCount)
  let metric_messages =
    actor.call(metric_actor, waiting: 1000, sending: GetMetricCount)

  assert chat_messages == 1
  assert metric_messages == 1

  // Verify totals (metric actor adds counter values to total)
  let total_count =
    actor.call(metric_actor, waiting: 1000, sending: GetTotalCount)
  assert total_count == 5

  // Shutdown actors
  actor.send(chat_actor, ChatActorShutdown)
  actor.send(metric_actor, MetricActorShutdown)
}

pub fn distributed_consistency_test() {
  // Create two PubSub instances with same scope and type_id (simulating different nodes)
  let pubsub1 =
    pubsub.new(scope: "distributed_scope", message_type: chat_message_type)
  let pubsub2 =
    pubsub.new(scope: "distributed_scope", message_type: chat_message_type)

  // Start actor subscribed to first instance
  let assert Ok(started) = start_chat_actor(pubsub1, "global")
  let actor_subject = started.data

  // Wait for actor to be ready
  let _ = actor.call(actor_subject, waiting: 1000, sending: GetReady)

  // Publish from second instance - should reach subscriber on first instance
  let subscriber_count =
    pubsub.publish(
      pubsub2,
      "global",
      Message("distributed", "cross-node message"),
    )
  assert subscriber_count == 1

  // Verify actor received the message
  let message_count =
    actor.call(actor_subject, waiting: 1000, sending: GetMessageCount)
  assert message_count == 1

  // Shutdown actor
  actor.send(actor_subject, ChatActorShutdown)
}

pub fn complex_message_flow_test() {
  let chat_pubsub =
    pubsub.new(scope: "complex_chat", message_type: chat_message_type)
  let metric_pubsub =
    pubsub.new(scope: "complex_metrics", message_type: metric_event_type)

  // Start multiple actors
  let assert Ok(chat1_started) = start_chat_actor(chat_pubsub, "room1")
  let assert Ok(chat2_started) = start_chat_actor(chat_pubsub, "room2")
  let assert Ok(metric_started) =
    start_metric_actor(metric_pubsub, "app_metrics")

  let chat1_actor = chat1_started.data
  let chat2_actor = chat2_started.data
  let metric_actor = metric_started.data

  // Wait for all actors to be ready
  let _ = actor.call(chat1_actor, waiting: 1000, sending: GetReady)
  let _ = actor.call(chat2_actor, waiting: 1000, sending: GetReady)
  let _ = actor.call(metric_actor, waiting: 1000, sending: GetMetricReady)

  // Complex message flow
  let room1_count1 = pubsub.publish(chat_pubsub, "room1", UserJoined("alice"))
  let room2_count1 = pubsub.publish(chat_pubsub, "room2", UserJoined("bob"))
  let metric_count1 =
    pubsub.publish(metric_pubsub, "app_metrics", CounterIncrement("users", 2))

  assert room1_count1 == 1
  assert room2_count1 == 1
  assert metric_count1 == 1

  // More messages
  let room1_count2 =
    pubsub.publish(chat_pubsub, "room1", Message("alice", "Hello room 1"))
  let room1_count3 =
    pubsub.publish(chat_pubsub, "room1", Message("charlie", "Hi Alice"))
  let room2_count2 =
    pubsub.publish(chat_pubsub, "room2", Message("bob", "Hello room 2"))

  assert room1_count2 == 1
  assert room1_count3 == 1
  assert room2_count2 == 1

  let metric_count2 =
    pubsub.publish(metric_pubsub, "app_metrics", GaugeUpdate("memory", 85.5))
  let metric_count3 =
    pubsub.publish(metric_pubsub, "app_metrics", TimerRecord("request", 150))

  assert metric_count2 == 1
  assert metric_count3 == 1

  // Verify final message counts
  let chat1_messages =
    actor.call(chat1_actor, waiting: 1000, sending: GetMessageCount)
  let chat2_messages =
    actor.call(chat2_actor, waiting: 1000, sending: GetMessageCount)
  let metric_messages =
    actor.call(metric_actor, waiting: 1000, sending: GetMetricCount)
  let total_count =
    actor.call(metric_actor, waiting: 1000, sending: GetTotalCount)

  assert chat1_messages == 3
  // UserJoined + 2 Messages
  assert chat2_messages == 2
  // UserJoined + 1 Message
  assert metric_messages == 3
  // CounterIncrement + GaugeUpdate + TimerRecord
  assert total_count == 152
  // 2 + 0 + 150 (CounterIncrement + GaugeUpdate + TimerRecord)

  // Shutdown actors
  actor.send(chat1_actor, ChatActorShutdown)
  actor.send(chat2_actor, ChatActorShutdown)
  actor.send(metric_actor, MetricActorShutdown)
}

pub fn actor_subscriber_count_test() {
  let pubsub =
    pubsub.new(scope: "subscriber_count_test", message_type: chat_message_type)

  // Initially no subscribers
  let initial_count = pubsub.subscribers(pubsub, "test_room") |> list.length
  assert initial_count == 0

  // Start an actor
  let assert Ok(started) = start_chat_actor(pubsub, "test_room")
  let actor_subject = started.data

  // Wait for actor to be ready
  let _ = actor.call(actor_subject, waiting: 1000, sending: GetReady)

  // Now should have 1 subscriber
  let after_subscribe_count =
    pubsub.subscribers(pubsub, "test_room") |> list.length
  assert after_subscribe_count == 1

  // Start another actor in same group
  let assert Ok(started2) = start_chat_actor(pubsub, "test_room")
  let actor2_subject = started2.data

  // Wait for second actor to be ready
  let _ = actor.call(actor2_subject, waiting: 1000, sending: GetReady)

  // Now should have 2 subscribers
  let after_subscribe2_count =
    pubsub.subscribers(pubsub, "test_room") |> list.length
  assert after_subscribe2_count == 2

  // Publish should reach both
  let publish_count = pubsub.publish(pubsub, "test_room", UserJoined("test"))
  assert publish_count == 2

  // Shutdown actors
  actor.send(actor_subject, ChatActorShutdown)
  actor.send(actor2_subject, ChatActorShutdown)
}

pub fn pubsub_type_safety_violation_test() {
  // Create two PubSub instances with same scope but different type IDs
  let chat_pubsub =
    pubsub.new(scope: "type_violation_scope", message_type: chat_message_type)
  let metric_pubsub =
    pubsub.new(scope: "type_violation_scope", message_type: metric_event_type)

  // Start a chat actor subscribed to chat messages
  let assert Ok(started) = start_chat_actor(chat_pubsub, "mixed_channel")
  let chat_actor = started.data

  // Wait for actor to be ready
  let _ = actor.call(chat_actor, waiting: 1000, sending: GetReady)

  // Publish a metric event to the metric pubsub - should NOT reach chat actor
  let reached_subscribers =
    pubsub.publish(
      metric_pubsub,
      "mixed_channel",
      CounterIncrement("failed_hack", 1),
    )

  // Should find 0 subscribers - PubSub-level type safety prevents delivery
  assert reached_subscribers == 0

  // Verify chat actor received no messages
  let message_count =
    actor.call(chat_actor, waiting: 1000, sending: GetMessageCount)
  assert message_count == 0

  // Now publish a chat message - should reach the chat actor
  let chat_reached =
    pubsub.publish(
      chat_pubsub,
      "mixed_channel",
      Message("alice", "real message"),
    )
  assert chat_reached == 1

  // Verify chat actor received the chat message
  let final_count =
    actor.call(chat_actor, waiting: 1000, sending: GetMessageCount)
  assert final_count == 1

  // Shutdown actor
  actor.send(chat_actor, ChatActorShutdown)
}
