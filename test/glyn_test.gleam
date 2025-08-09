import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleeunit
import glyn

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

// Actor message types
pub type ChatActorMessage {
  // Direct actor messages
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

// Actor states
pub type ChatActorState {
  ChatActorState(message_count: Int, last_message: String)
}

pub type MetricActorState {
  MetricActorState(total_count: Int, metric_count: Int)
}

// Chat actor handler
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
    ChatEvent(chat_msg) -> {
      case chat_msg {
        UserJoined(username) -> {
          let msg = username <> " joined"
          actor.continue(ChatActorState(
            message_count: state.message_count + 1,
            last_message: msg,
          ))
        }
        UserLeft(username) -> {
          let msg = username <> " left"
          actor.continue(ChatActorState(
            message_count: state.message_count + 1,
            last_message: msg,
          ))
        }
        Message(username, content) -> {
          let msg = username <> ": " <> content
          actor.continue(ChatActorState(
            message_count: state.message_count + 1,
            last_message: msg,
          ))
        }
      }
    }
    ChatActorShutdown -> actor.stop()
  }
}

// Metric actor handler
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
    MetricEvent(metric_event) -> {
      case metric_event {
        CounterIncrement(_, value) -> {
          actor.continue(MetricActorState(
            total_count: state.total_count + value,
            metric_count: state.metric_count + 1,
          ))
        }
        GaugeUpdate(_, _) -> {
          actor.continue(MetricActorState(
            total_count: state.total_count,
            metric_count: state.metric_count + 1,
          ))
        }
        TimerRecord(_, _) -> {
          actor.continue(MetricActorState(
            total_count: state.total_count,
            metric_count: state.metric_count + 1,
          ))
        }
      }
    }
    MetricActorShutdown -> actor.stop()
  }
}

// Helper to start chat actor with PubSub subscription
fn start_chat_actor(
  pubsub: glyn.PubSub(ChatMessage),
  group: String,
) -> Result(actor.Started(Subject(ChatActorMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    let subscription = glyn.subscribe(pubsub, group, process.self())

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
  pubsub: glyn.PubSub(MetricEvent),
  group: String,
) -> Result(actor.Started(Subject(MetricActorMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    let subscription = glyn.subscribe(pubsub, group, process.self())

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

// Test basic actor-PubSub integration
pub fn actor_pubsub_integration_test() {
  let pubsub = glyn.new(scope: "chat_test_scope", type_id: "ChatMessage_v1")

  // Start actor
  let assert Ok(started) = start_chat_actor(pubsub, "general")
  let actor_subject = started.data

  // Wait for actor to be ready
  let _ = actor.call(actor_subject, waiting: 1000, sending: GetReady)

  // Publish a message
  let reached = glyn.publish(pubsub, "general", UserJoined("Alice"))
  assert reached == 1

  // Check actor received the message
  let count = actor.call(actor_subject, waiting: 1000, sending: GetMessageCount)
  let last_msg =
    actor.call(actor_subject, waiting: 1000, sending: GetLastMessage)

  assert count == 1
  assert last_msg == "Alice joined"

  // Publish another message
  let _ = glyn.publish(pubsub, "general", Message("Alice", "Hello everyone!"))

  let count2 =
    actor.call(actor_subject, waiting: 1000, sending: GetMessageCount)
  let last_msg2 =
    actor.call(actor_subject, waiting: 1000, sending: GetLastMessage)

  assert count2 == 2
  assert last_msg2 == "Alice: Hello everyone!"

  // Clean up
  actor.send(actor_subject, ChatActorShutdown)
}

// Test multiple actors receiving same message
pub fn multiple_actors_test() {
  let pubsub = glyn.new(scope: "multi_chat_scope", type_id: "ChatMessage_v2")

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

  // Publish a message - should reach all actors
  let reached = glyn.publish(pubsub, "general", UserJoined("Bob"))
  assert reached == 3

  // Check all actors received the message
  let count1 = actor.call(actor1, waiting: 1000, sending: GetMessageCount)
  let count2 = actor.call(actor2, waiting: 1000, sending: GetMessageCount)
  let count3 = actor.call(actor3, waiting: 1000, sending: GetMessageCount)

  assert count1 == 1
  assert count2 == 1
  assert count3 == 1

  // Clean up
  actor.send(actor1, ChatActorShutdown)
  actor.send(actor2, ChatActorShutdown)
  actor.send(actor3, ChatActorShutdown)
}

// Test different groups isolation
pub fn group_isolation_test() {
  let pubsub = glyn.new(scope: "group_test_scope", type_id: "ChatMessage_v3")

  // Start actors in different groups
  let assert Ok(started1) = start_chat_actor(pubsub, "general")
  let assert Ok(started2) = start_chat_actor(pubsub, "private")

  let actor1 = started1.data
  let actor2 = started2.data

  // Wait for actors to be ready
  let _ = actor.call(actor1, waiting: 1000, sending: GetReady)
  let _ = actor.call(actor2, waiting: 1000, sending: GetReady)

  // Publish to "general" group only
  let reached =
    glyn.publish(pubsub, "general", Message("Charlie", "Hello general!"))
  assert reached == 1

  // Only actor1 should have received the message
  let count1 = actor.call(actor1, waiting: 1000, sending: GetMessageCount)
  let count2 = actor.call(actor2, waiting: 1000, sending: GetMessageCount)

  assert count1 == 1
  assert count2 == 0

  // Publish to "private" group
  let reached2 =
    glyn.publish(pubsub, "private", Message("Diana", "Hello private!"))
  assert reached2 == 1

  // Now actor2 should have a message
  let count1_after = actor.call(actor1, waiting: 1000, sending: GetMessageCount)
  let count2_after = actor.call(actor2, waiting: 1000, sending: GetMessageCount)

  assert count1_after == 1
  // Still 1
  assert count2_after == 1
  // Now has 1

  // Clean up
  actor.send(actor1, ChatActorShutdown)
  actor.send(actor2, ChatActorShutdown)
}

// Test type safety - different message types don't interfere
pub fn type_safety_test() {
  // Different scopes for different message types
  let chat_pubsub = glyn.new(scope: "type_test_chat", type_id: "ChatMessage_v4")
  let metric_pubsub =
    glyn.new(scope: "type_test_metrics", type_id: "MetricEvent_v1")

  // Start actors with different message types
  let assert Ok(chat_started) = start_chat_actor(chat_pubsub, "general")
  let assert Ok(metric_started) = start_metric_actor(metric_pubsub, "counters")

  let chat_actor = chat_started.data
  let metric_actor = metric_started.data

  // Wait for actors to be ready
  let _ = actor.call(chat_actor, waiting: 1000, sending: GetReady)
  let _ = actor.call(metric_actor, waiting: 1000, sending: GetMetricReady)

  // Publish chat message
  let chat_reached =
    glyn.publish(chat_pubsub, "general", Message("Eve", "Hello!"))
  assert chat_reached == 1

  // Publish metric event
  let metric_reached =
    glyn.publish(metric_pubsub, "counters", CounterIncrement("requests", 5))
  assert metric_reached == 1

  // Check each actor only received its own message type
  let chat_count =
    actor.call(chat_actor, waiting: 1000, sending: GetMessageCount)
  let metric_count =
    actor.call(metric_actor, waiting: 1000, sending: GetMetricCount)
  let total_count =
    actor.call(metric_actor, waiting: 1000, sending: GetTotalCount)

  assert chat_count == 1
  assert metric_count == 1
  assert total_count == 5

  // Clean up
  actor.send(chat_actor, ChatActorShutdown)
  actor.send(metric_actor, MetricActorShutdown)
}

// Test distributed consistency - same type_id across instances
pub fn distributed_consistency_test() {
  // Create two PubSub instances with same scope and type_id (simulating different nodes)
  let pubsub1 =
    glyn.new(scope: "distributed_scope", type_id: "ChatMessage_distributed")
  let pubsub2 =
    glyn.new(scope: "distributed_scope", type_id: "ChatMessage_distributed")

  // Start actor subscribed to first instance
  let assert Ok(started) = start_chat_actor(pubsub1, "global")
  let actor_subject = started.data

  // Wait for actor to be ready
  let _ = actor.call(actor_subject, waiting: 1000, sending: GetReady)

  // Publish through second instance - should reach actor subscribed to first
  let reached = glyn.publish(pubsub2, "global", UserJoined("Frank"))
  assert reached == 1

  // Actor should have received the message
  let count = actor.call(actor_subject, waiting: 1000, sending: GetMessageCount)
  let last_msg =
    actor.call(actor_subject, waiting: 1000, sending: GetLastMessage)

  assert count == 1
  assert last_msg == "Frank joined"

  // Clean up
  actor.send(actor_subject, ChatActorShutdown)
}

// Test complex message flow with multiple message types
pub fn complex_message_flow_test() {
  let chat_pubsub =
    glyn.new(scope: "complex_chat", type_id: "ChatMessage_complex")
  let metric_pubsub =
    glyn.new(scope: "complex_metrics", type_id: "MetricEvent_complex")

  // Start multiple actors
  let assert Ok(chat1_started) = start_chat_actor(chat_pubsub, "room1")
  let assert Ok(chat2_started) = start_chat_actor(chat_pubsub, "room2")
  let assert Ok(metric_started) =
    start_metric_actor(metric_pubsub, "app_metrics")

  let chat1 = chat1_started.data
  let chat2 = chat2_started.data
  let metrics = metric_started.data

  // Wait for all actors to be ready
  let _ = actor.call(chat1, waiting: 1000, sending: GetReady)
  let _ = actor.call(chat2, waiting: 1000, sending: GetReady)
  let _ = actor.call(metrics, waiting: 1000, sending: GetMetricReady)

  // Send various messages
  let _ = glyn.publish(chat_pubsub, "room1", UserJoined("Grace"))
  let _ = glyn.publish(chat_pubsub, "room1", Message("Grace", "Hello room 1!"))
  let _ = glyn.publish(chat_pubsub, "room2", UserJoined("Henry"))
  let _ =
    glyn.publish(metric_pubsub, "app_metrics", CounterIncrement("logins", 2))
  let _ =
    glyn.publish(metric_pubsub, "app_metrics", GaugeUpdate("cpu_usage", 75.5))

  // Check final states
  let chat1_count = actor.call(chat1, waiting: 1000, sending: GetMessageCount)
  let chat2_count = actor.call(chat2, waiting: 1000, sending: GetMessageCount)
  let metric_count = actor.call(metrics, waiting: 1000, sending: GetMetricCount)
  let total_count = actor.call(metrics, waiting: 1000, sending: GetTotalCount)

  assert chat1_count == 2
  // Grace joined + Grace's message
  assert chat2_count == 1
  // Henry joined
  assert metric_count == 2
  // login counter + cpu gauge
  assert total_count == 2
  // only counter increment adds to total

  let chat1_last = actor.call(chat1, waiting: 1000, sending: GetLastMessage)
  let chat2_last = actor.call(chat2, waiting: 1000, sending: GetLastMessage)

  assert chat1_last == "Grace: Hello room 1!"
  assert chat2_last == "Henry joined"

  // Clean up
  actor.send(chat1, ChatActorShutdown)
  actor.send(chat2, ChatActorShutdown)
  actor.send(metrics, MetricActorShutdown)
}

// Test subscriber count with real actors
pub fn actor_subscriber_count_test() {
  let pubsub =
    glyn.new(scope: "subscriber_count_test", type_id: "ChatMessage_count")

  // Initially no subscribers
  let initial_count = glyn.subscribers(pubsub, "test_room") |> list.length
  assert initial_count == 0

  // Start an actor
  let assert Ok(started) = start_chat_actor(pubsub, "test_room")
  let actor_subject = started.data

  // Wait for actor to be ready
  let _ = actor.call(actor_subject, waiting: 1000, sending: GetReady)

  // Should now have one subscriber
  let after_start_count = glyn.subscribers(pubsub, "test_room") |> list.length
  assert after_start_count == 1

  // Start another actor
  let assert Ok(started2) = start_chat_actor(pubsub, "test_room")
  let actor2_subject = started2.data

  // Wait for second actor to be ready
  let _ = actor.call(actor2_subject, waiting: 1000, sending: GetReady)

  // Should now have two subscribers
  let after_second_count = glyn.subscribers(pubsub, "test_room") |> list.length
  assert after_second_count == 2

  // Clean up one actor
  actor.send(actor_subject, ChatActorShutdown)

  // Verify we can still communicate with the remaining actor
  let final_count =
    actor.call(actor2_subject, waiting: 1000, sending: GetMessageCount)
  assert final_count == 0
  // Should still be 0 since no messages were sent

  // Clean up remaining actor
  actor.send(actor2_subject, ChatActorShutdown)
}
