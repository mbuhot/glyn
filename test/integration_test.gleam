import decode_utils
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleeunit
import glyn/pubsub
import glyn/registry

pub fn main() -> Nil {
  gleeunit.main()
}

// Use Command and Event types from decode_utils
pub type Command = decode_utils.Command
pub type Event = decode_utils.Event

// Integration actor message type - composes commands and events
pub type IntegrationActorMessage {
  CommandMessage(Command)
  PubSubMessage(Event)
  IntegrationActorShutdown
}

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
        decode_utils.ProcessOrder(id, reply_with) -> {
          process.send(reply_with, True)
          let new_state =
            IntegrationActorState(
              status: "Processing order " <> id,
              processed_orders: state.processed_orders + 1,
            )
          actor.continue(new_state)
        }
        decode_utils.GetCommandStatus(reply_with) -> {
          process.send(reply_with, state.status)
          actor.continue(state)
        }
        decode_utils.GetProcessedOrders(reply_with) -> {
          process.send(reply_with, state.processed_orders)
          actor.continue(state)
        }
        decode_utils.CommandShutdown -> {
          actor.stop()
        }
      }
    PubSubMessage(event) -> {
      let new_status = case event {
        decode_utils.OrderCreated(id, amount) ->
          "Event: Order " <> id <> " created for $" <> int.to_string(amount)
        decode_utils.PaymentProcessed(id) -> "Event: Payment processed for order " <> id
        decode_utils.SystemAlert(message) -> "Alert: " <> message
      }
      let new_state =
        IntegrationActorState(
          status: new_status,
          processed_orders: state.processed_orders,
        )
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
    // Get selectors for both PubSub and Registry
    let event_selector = pubsub.subscribe(pubsub, group)
    let assert Ok(command_selector) = registry.register(registry, actor_name, "integration_service")

    // Create selector that composes both command and event messages
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.merge_selector(process.map_selector(command_selector, CommandMessage))
      |> process.merge_selector(process.map_selector(event_selector, PubSubMessage))

    let initial_state =
      IntegrationActorState(status: "Ready", processed_orders: 0)

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_integration_message)
  |> actor.start()
}

pub fn pubsub_registry_integration_test() {
  // Create separate PubSub and Registry systems
  let event_pubsub =
    pubsub.new(
      "integration_events",
      decode_utils.event_decoder(),
      decode_utils.SystemAlert("decode_error")
    )
  let command_registry =
    registry.new(
      "integration_commands",
      decode_utils.command_decoder(),
      decode_utils.CommandShutdown
    )

  // Start integration actor that subscribes to events and registers for commands
  let assert Ok(started) =
    start_integration_actor(
      event_pubsub,
      command_registry,
      "order_processor",
      "order_events",
    )
  let actor_subject = started.data

  // Test direct command through Registry
  let assert Ok(process_result) =
    registry.call(
      command_registry,
      "order_processor",
      waiting: 1000,
      sending: decode_utils.ProcessOrder("ord-123", _),
    )
  assert process_result == True

  // Verify command was processed
  let assert Ok(status1) =
    registry.call(
      command_registry,
      "order_processor",
      waiting: 1000,
      sending: decode_utils.GetCommandStatus(_)
    )
  assert status1 == "Processing order ord-123"

  let assert Ok(order_count1) =
    registry.call(
      command_registry,
      "order_processor",
      waiting: 1000,
      sending: decode_utils.GetProcessedOrders(_),
    )
  assert order_count1 == 1

  // Test event through PubSub
  let assert Ok(event_subscribers) =
    pubsub.publish(event_pubsub, "order_events", decode_utils.OrderCreated("ord-456", 250))
  assert event_subscribers == 1

  // Verify event was handled
  let assert Ok(status2) =
    registry.call(
      command_registry,
      "order_processor",
      waiting: 1000,
      sending: decode_utils.GetCommandStatus(_),
    )
  assert status2 == "Event: Order ord-456 created for $250"

  // Process count should not change from events (only commands increment it)
  let assert Ok(order_count2) =
    registry.call(
      command_registry,
      "order_processor",
      waiting: 1000,
      sending: decode_utils.GetProcessedOrders(_),
    )
  assert order_count2 == 1

  // Test more events
  let assert Ok(payment_subscribers) =
    pubsub.publish(event_pubsub, "order_events", decode_utils.PaymentProcessed("ord-456"))
  assert payment_subscribers == 1

  let assert Ok(alert_subscribers) =
    pubsub.publish(
      event_pubsub,
      "order_events",
      decode_utils.SystemAlert("System maintenance in 10 minutes"),
    )
  assert alert_subscribers == 1

  // Verify final alert was processed
  let assert Ok(final_status) =
    registry.call(
      command_registry,
      "order_processor",
      waiting: 1000,
      sending: decode_utils.GetCommandStatus(_),
    )
  assert final_status == "Alert: System maintenance in 10 minutes"

  // Process another command
  let assert Ok(process_result2) =
    registry.call(
      command_registry,
      "order_processor",
      waiting: 1000,
      sending: decode_utils.ProcessOrder("ord-789", _),
    )
  assert process_result2 == True

  // Final count should be 2
  let assert Ok(final_order_count) =
    registry.call(
      command_registry,
      "order_processor",
      waiting: 1000,
      sending: decode_utils.GetProcessedOrders(_),
    )
  assert final_order_count == 2

  // Shutdown actor
  actor.send(actor_subject, IntegrationActorShutdown)
}
