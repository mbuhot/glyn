# Glyn ✨

[![Package Version](https://img.shields.io/hexpm/v/glyn)](https://hex.pm/packages/glyn)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glyn/)

**Type-safe PubSub and Registry for Gleam actors with distributed clustering support.**

Built on the Erlang [syn](https://github.com/ostinelli/syn) library.


Glyn provides two complementary systems for actor communication:
- **PubSub**: Broadcast events to multiple subscribers
- **Registry**: Direct command routing to named processes


## Installation

```sh
gleam add glyn
```

## Quick Example: PubSub

```gleam
import glyn
import glyn/pubsub
import gleam/erlang/process

// Define your event type
pub type OrderEvent {
  OrderCreated(id: String, amount: Int)
  OrderShipped(id: String, tracking: String)
  OrderCancelled(id: String, reason: String)
}

// Create a MessageType for compile-time safety
pub const order_event_type: glyn.MessageType(OrderEvent) = glyn.MessageType("OrderEvent_v1")

pub fn main() {
  // Create PubSub system
  let pubsub = pubsub.new(scope: "orders", message_type: order_event_type)
  
  // Subscribe to events
  let subscription = pubsub.subscribe(pubsub, "processing", process.self())
  
  // Publish events (returns number of subscribers reached)
  let reached = pubsub.publish(pubsub, "processing", OrderCreated("ORDER123", 99))
  // reached == 1
}
```

## Quick Example: Registry

```gleam
import glyn
import glyn/registry
import gleam/erlang/process.{type Subject}

// Define your command type
pub type UserCommand {
  GetProfile(reply_with: Subject(String))
  UpdateEmail(email: String, reply_with: Subject(Bool))
}

// Create a MessageType for compile-time safety  
pub const user_command_type: glyn.MessageType(UserCommand) = glyn.MessageType("UserCommand_v1")

pub fn main() {
  // Create Registry system
  let registry = registry.new(scope: "users", message_type: user_command_type)
  
  // Register a process under a name
  let user_subject = process.new_subject()
  let assert Ok(_registration) = registry.register(registry, "user_123", user_subject, "active")
  
  // Send commands to registered processes
  let reply_subject = process.new_subject()
  let assert Ok(_) = registry.send(registry, "user_123", GetProfile(reply_subject))
  
  // Or use call for request/reply pattern
  let assert Ok(profile) = registry.call(registry, "user_123", waiting: 1000, sending: GetProfile)
}
```

## Integration Pattern: Actor with Both PubSub and Registry

The real power of Glyn comes from combining both systems in a single Gleam actor:

```gleam
import glyn
import glyn/pubsub
import glyn/registry
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

// Separate command and event types for clean separation of concerns
pub type Command {
  ProcessOrder(id: String, reply_with: Subject(Bool))
  GetStatus(reply_with: Subject(String))
}

pub type Event {
  OrderCreated(id: String, amount: Int)
  PaymentProcessed(id: String)
  SystemAlert(message: String)
}

// Actor message type that composes both
pub type ProcessorMessage {
  CommandMessage(Command)
  PubSubMessage(Event)
}

// MessageTypes for each system
pub const command_type: glyn.MessageType(Command) = glyn.MessageType("Command_v1")
pub const event_type: glyn.MessageType(Event) = glyn.MessageType("Event_v1")

pub fn start_order_processor() {
  // Create both systems
  let event_pubsub = pubsub.new(scope: "events", message_type: event_type)
  let command_registry = registry.new(scope: "commands", message_type: command_type)

  actor.new_with_initialiser(5000, fn(subject) {
    // Subscribe to events
    let event_subscription = pubsub.subscribe(event_pubsub, "orders", process.self())
    
    // Create command subject and register it
    let command_subject = process.new_subject()
    let assert Ok(_) = registry.register(command_registry, "order_processor", command_subject, "v1.0")

    // Compose messages using selector
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(command_subject, CommandMessage)
      |> process.select_map(event_subscription.subject, PubSubMessage)

    // Return initialized actor
    actor.initialised(ProcessorState(status: "ready", processed: 0))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_processor_message)
  |> actor.start()
}

fn handle_processor_message(state, message) {
  case message {
    CommandMessage(ProcessOrder(id, reply_with)) -> {
      // Handle direct command
      process.send(reply_with, True)
      actor.continue(ProcessorState(..state, processed: state.processed + 1))
    }
    CommandMessage(GetStatus(reply_with)) -> {
      // Return status
      process.send(reply_with, state.status)
      actor.continue(state)
    }
    PubSubMessage(OrderCreated(id, amount)) -> {
      // React to broadcasted event
      actor.continue(ProcessorState(..state, status: "Processing order " <> id))
    }
    PubSubMessage(SystemAlert(message)) -> {
      // Handle system-wide alerts
      actor.continue(ProcessorState(..state, status: "Alert: " <> message))
    }
  }
}

// Usage:
pub fn example_usage() {
  let assert Ok(processor) = start_order_processor()
  
  // Send commands via Registry
  let assert Ok(status) = registry.call(command_registry, "order_processor", waiting: 1000, sending: GetStatus)
  let assert Ok(_) = registry.send(command_registry, "order_processor", ProcessOrder("ORDER456", reply_subject))
  
  // Broadcast events via PubSub  
  let reached = pubsub.publish(event_pubsub, "orders", OrderCreated("ORDER789", 150))
}
```

## Type Safety with MessageType

Glyn enforces type safety at both compile-time and runtime using `MessageType`:

```gleam
// Define MessageTypes with version strings for evolution
pub const chat_type: glyn.MessageType(ChatMessage) = glyn.MessageType("ChatMessage_v1")
pub const metric_type: glyn.MessageType(MetricEvent) = glyn.MessageType("MetricEvent_v1")

// Different MessageTypes are completely isolated
let chat_pubsub = pubsub.new(scope: "app", message_type: chat_type)
let metric_pubsub = pubsub.new(scope: "app", message_type: metric_type)

let chat_subscription = pubsub.subscribe(chat_pubsub, "general", process.self())

// This publishes to metric subscribers only - won't reach chat subscribers
let reached = pubsub.publish(metric_pubsub, "general", CounterIncrement("requests", 1))
// reached == 0 (no chat subscribers receive metric events)
```

## Distributed Clustering

Both PubSub and Registry work across Erlang distributed clusters:

```gleam
// Node A - Start subscriber and register service
let pubsub = pubsub.new(scope: "global_events", message_type: order_event_type)
let registry = registry.new(scope: "global_services", message_type: command_type)

let subscription = pubsub.subscribe(pubsub, "orders", process.self())
let assert Ok(_) = registry.register(registry, "order_service", command_subject, "v1.0")

// Node B - Publish event and call service (same scope and MessageType)
let pubsub = pubsub.new(scope: "global_events", message_type: order_event_type) 
let registry = registry.new(scope: "global_services", message_type: command_type)

// Event published on Node B reaches subscriber on Node A
let reached = pubsub.publish(pubsub, "orders", OrderCreated("GLOBAL123", 200))

// Command sent to service registered on Node A
let assert Ok(result) = registry.call(registry, "order_service", waiting: 5000, sending: ProcessOrder("GLOBAL123"))
```

## API Reference

### PubSub Functions

```gleam
import glyn/pubsub

// Create PubSub system
pubsub.new(scope: String, message_type: MessageType(message)) -> PubSub(message)

// Subscribe to events
pubsub.subscribe(pubsub: PubSub(message), group: String, pid: Pid) -> Subscription(message, String)

// Publish events (returns subscriber count)
pubsub.publish(pubsub: PubSub(message), group: String, message: message) -> Int

// Get current subscribers
pubsub.subscribers(pubsub: PubSub(message), group: String) -> List(Pid)

// Unsubscribe
pubsub.unsubscribe(subscription: Subscription(message, group)) -> Nil
```

### Registry Functions

```gleam
import glyn/registry

// Create Registry system  
registry.new(scope: String, message_type: MessageType(message)) -> Registry(message, metadata)

// Register process under name
registry.register(registry: Registry(message, metadata), name: String, subject: Subject(message), metadata: metadata) -> Result(Registration, String)

// Look up registered process
registry.lookup(registry: Registry(message, metadata), name: String) -> Result(#(Subject(message), metadata), String)

// Send message (fire and forget)
registry.send(registry: Registry(message, metadata), name: String, message: message) -> Result(Nil, String)

// Call and wait for reply
registry.call(registry: Registry(message, metadata), name: String, waiting: Int, sending: fn(Subject(reply)) -> message) -> Result(reply, String)

// Unregister process
registry.unregister(registration: Registration(message, metadata)) -> Result(Nil, String)
```

## Development

```sh
gleam test           # Run tests
gleam docs build     # Build documentation
```

## License

This project is licensed under the MIT License.
