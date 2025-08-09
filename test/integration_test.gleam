import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleeunit
import glyn
import glyn/pubsub
import glyn/registry

pub fn main() -> Nil {
  gleeunit.main()
}

// Integration test types - separate command and event types
pub type Command {
  ProcessOrder(id: String, reply_with: Subject(Bool))
  GetStatus(reply_with: Subject(String))
  GetProcessedOrders(reply_with: Subject(Int))
  Shutdown
}

pub type Event {
  OrderCreated(id: String, amount: Int)
  PaymentProcessed(id: String)
  SystemAlert(message: String)
}

// Integration actor message type - composes commands and events
pub type IntegrationActorMessage {
  CommandMessage(Command)
  PubSubMessage(Event)
  IntegrationActorShutdown
}

// Message type constants for integration tests
pub const command_message_type: glyn.MessageType(Command) = glyn.MessageType("Command_v1")
pub const event_message_type: glyn.MessageType(Event) = glyn.MessageType("Event_v1")

pub type IntegrationActorState {
  IntegrationActorState(status: String, processed_orders: Int)
}

// Handler for integration actor that processes both commands and events
fn handle_integration_message(
  state: IntegrationActorState,
  message: IntegrationActorMessage,
) -> actor.Next(IntegrationActorState, IntegrationActorMessage) {
  case message {
    CommandMessage(command) ->
      case command {
        ProcessOrder(id, reply_with) -> {
          process.send(reply_with, True)
          let new_state =
            IntegrationActorState(
              status: "Processing order " <> id,
              processed_orders: state.processed_orders + 1,
            )
          actor.continue(new_state)
        }
        GetStatus(reply_with) -> {
          process.send(reply_with, state.status)
          actor.continue(state)
        }
        GetProcessedOrders(reply_with) -> {
          process.send(reply_with, state.processed_orders)
          actor.continue(state)
        }
        Shutdown -> {
          actor.stop()
        }
      }
    PubSubMessage(event) -> {
      let new_status = case event {
        OrderCreated(id, amount) -> "Event: Order " <> id <> " created for $" <> int.to_string(amount)
        PaymentProcessed(id) -> "Event: Payment processed for order " <> id
        SystemAlert(message) -> "Alert: " <> message
      }
      let new_state =
        IntegrationActorState(status: new_status, processed_orders: state.processed_orders)
      actor.continue(new_state)
    }
    IntegrationActorShutdown -> {
      actor.stop()
    }
  }
}

// Helper to start integration actor that combines PubSub and Registry
fn start_integration_actor(
  pubsub: pubsub.PubSub(Event),
  registry: registry.Registry(Command, String),
  actor_name: String,
  group: String,
) -> Result(actor.Started(Subject(IntegrationActorMessage)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    // Subscribe to PubSub for events
    let event_subscription = pubsub.subscribe(pubsub, group, process.self())

    // Create a command subject for direct commands
    let command_subject = process.new_subject()

    // Register in Registry for command handling
    let assert Ok(_registration) = registry.register(registry, actor_name, command_subject, "integration_service")

    // Create selector that composes both command and event messages
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(command_subject, CommandMessage)
      |> process.select_map(event_subscription.subject, PubSubMessage)

    let initial_state = IntegrationActorState(status: "Ready", processed_orders: 0)

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_integration_message)
  |> actor.start()
}

pub fn pubsub_registry_integration_test() {
  // Create separate PubSub and Registry systems with different MessageTypes
  let event_pubsub = pubsub.new(scope: "integration_events", message_type: event_message_type)
  let command_registry = registry.new(scope: "integration_commands", message_type: command_message_type)

  // Start integration actor that subscribes to events and registers for commands
  let assert Ok(started) = start_integration_actor(
    event_pubsub,
    command_registry,
    "order_processor",
    "order_events"
  )
  let actor_subject = started.data

  // Test direct command through Registry
  let assert Ok(process_result) = registry.call(
    command_registry,
    "order_processor",
    waiting: 1000,
    sending: fn(reply_with) { ProcessOrder("ord-123", reply_with) }
  )
  assert process_result == True

  // Verify command was processed
  let assert Ok(status1) = registry.call(
    command_registry,
    "order_processor",
    waiting: 1000,
    sending: fn(reply_with) { GetStatus(reply_with) }
  )
  assert status1 == "Processing order ord-123"

  let assert Ok(order_count1) = registry.call(
    command_registry,
    "order_processor",
    waiting: 1000,
    sending: fn(reply_with) { GetProcessedOrders(reply_with) }
  )
  assert order_count1 == 1

  // Test event through PubSub
  let event_subscribers = pubsub.publish(
    event_pubsub,
    "order_events",
    OrderCreated("ord-456", 250)
  )
  assert event_subscribers == 1



  // Verify event was handled
  let assert Ok(status2) = registry.call(
    command_registry,
    "order_processor",
    waiting: 1000,
    sending: fn(reply_with) { GetStatus(reply_with) }
  )
  assert status2 == "Event: Order ord-456 created for $250"

  // Process count should not change from events (only commands increment it)
  let assert Ok(order_count2) = registry.call(
    command_registry,
    "order_processor",
    waiting: 1000,
    sending: fn(reply_with) { GetProcessedOrders(reply_with) }
  )
  assert order_count2 == 1

  // Test more events
  let payment_subscribers = pubsub.publish(
    event_pubsub,
    "order_events",
    PaymentProcessed("ord-456")
  )
  assert payment_subscribers == 1

  let alert_subscribers = pubsub.publish(
    event_pubsub,
    "order_events",
    SystemAlert("System maintenance in 10 minutes")
  )
  assert alert_subscribers == 1



  // Verify final alert was processed
  let assert Ok(final_status) = registry.call(
    command_registry,
    "order_processor",
    waiting: 1000,
    sending: fn(reply_with) { GetStatus(reply_with) }
  )
  assert final_status == "Alert: System maintenance in 10 minutes"

  // Process another command
  let assert Ok(process_result2) = registry.call(
    command_registry,
    "order_processor",
    waiting: 1000,
    sending: fn(reply_with) { ProcessOrder("ord-789", reply_with) }
  )
  assert process_result2 == True

  // Final count should be 2
  let assert Ok(final_order_count) = registry.call(
    command_registry,
    "order_processor",
    waiting: 1000,
    sending: fn(reply_with) { GetProcessedOrders(reply_with) }
  )
  assert final_order_count == 2

  // Shutdown actor
  actor.send(actor_subject, IntegrationActorShutdown)
}
