# Glyn ✨

[![Package Version](https://img.shields.io/hexpm/v/glyn)](https://hex.pm/packages/glyn)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glyn/)

**Type-safe PubSub and Registry for Gleam actors with distributed clustering support.**

Built on the Erlang [syn](https://github.com/ostinelli/syn) library.

Glyn provides two complementary systems for actor communication:
- **PubSub**: Broadcast events to multiple subscribers
- **Registry**: Direct command routing to named processes

Both systems integrate seamlessly with Gleam's actor model using selector composition patterns.

## Installation

```sh
gleam add glyn
```

## Creating Message Types and Decoders

First, define your message types and corresponding decoder functions.
Explicit decoders are required to ensure messages sent between nodes in a cluster are handled with type safety.
Note the Glyn does not JSON encode messages, they are sent directly as erlang terms and should be decoded from tuples.

```gleam
// my_app/orders.gleam
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}

// Define your message types
pub type Event {
  OrderCreated(id: String, amount: Int)
  OrderShipped(id: String, tracking: String)
  SystemAlert(message: String)
}

pub type Command {
  ProcessOrder(id: String, reply_with: Subject(Bool))
  GetStatus(reply_with: Subject(String))
  Shutdown
}

// Helper function to match specific atoms
fn expect_atom(expected: String) -> decode.Decoder(atom.Atom) {
  use value <- decode.then(atom.decoder())
  case atom.to_string(value) == expected {
    True -> decode.success(value)
    False -> decode.failure(value, "Expected atom: " <> expected)
  }
}

// Unsafe cast for Subject decoding - use with caution
@external(erlang, "gleam_stdlib", "identity")
fn unsafe_cast_subject(value: Dynamic) -> Subject(a)

// Create decoder functions
pub fn event_decoder() -> decode.Decoder(Event) {
  decode.one_of(
    {
      use _ <- decode.field(0, expect_atom("order_created"))
      use id <- decode.field(1, decode.string)
      use amount <- decode.field(2, decode.int)
      decode.success(OrderCreated(id, amount))
    },
    or: [
      {
        use _ <- decode.field(0, expect_atom("order_shipped"))
        use id <- decode.field(1, decode.string)
        use tracking <- decode.field(2, decode.string)
        decode.success(OrderShipped(id, tracking))
      },
      {
        use _ <- decode.field(0, expect_atom("system_alert"))
        use message <- decode.field(1, decode.string)
        decode.success(SystemAlert(message))
      },
    ]
  )
}

pub fn command_decoder() -> decode.Decoder(Command) {
  decode.one_of(
    // Shutdown is a simple variant - encoded as bare atom
    decode.map(expect_atom("shutdown"), fn(_) { Shutdown }),
    or: [
      // ProcessOrder has data - encoded as tuple
      {
        use _ <- decode.field(0, expect_atom("process_order"))
        use id <- decode.field(1, decode.string)
        use reply_with <- decode.field(2, decode.dynamic)
        decode.success(ProcessOrder(id, unsafe_cast_subject(reply_with)))
      },
      // GetStatus has data - encoded as tuple
      {
        use _ <- decode.field(0, expect_atom("get_status"))
        use reply_with <- decode.field(1, decode.dynamic)
        decode.success(GetStatus(unsafe_cast_subject(reply_with)))
      },
    ]
  )
}
```

## Quick Example: PubSub

```gleam
import glyn/pubsub
import my_app/orders
import gleam/erlang/process

pub fn main() {
  // Create PubSub system with decoder and error default
  let pubsub = pubsub.new(
    "orders",
    orders.event_decoder(),
    orders.SystemAlert("decode_error")
  )

  // Subscribe returns a Selector that can be composed
  let selector =
    process.new_selector()
    |> process.merge_selector(
      pubsub.subscribe(pubsub, "processing")
      |> process.map_selector(OrderEvent)
    )

  // Publish events (returns Result(Int, PubSubError) with subscriber count)
  let assert Ok(reached) = pubsub.publish(pubsub, "processing",
    orders.OrderCreated("ORDER123", 99))
  // reached == 1

  // Receive messages through selector
  let assert Ok(OrderEvent(orders.OrderCreated(id, amount))) =
    process.selector_receive(selector, 100)
}
```

## Quick Example: Registry

```gleam
import glyn/registry
import my_app/orders  // Using same orders module from above
import gleam/erlang/process.{type Subject}

pub fn main() {
  // Create Registry system with decoder and error default
  let registry = registry.new(
    "orders",
    orders.command_decoder(),
    orders.Shutdown
  )

  // Register returns a Selector for receiving commands
  let assert Ok(command_selector) = registry.register(registry, "order_processor", "v1.0")

  // Compose with other selectors
  let selector =
    process.new_selector()
    |> process.merge_selector(
      process.map_selector(command_selector, UserCommand)
    )

  // Send commands to registered processes
  let assert Ok(_) = registry.send(registry, "order_processor",
    orders.ProcessOrder("ORDER123", process.new_subject()))

  // Or use call for request/reply pattern
  let assert Ok(status) = registry.call(registry, "order_processor", waiting: 1000,
    sending: fn(reply) { orders.GetStatus(reply) })
}
```

## Multi-Channel Actor Integration

The real power of Gleam's typed actor system comes from composing multiple message channels in a single actor:

```gleam
import glyn/pubsub
import glyn/registry
import my_app/orders  // Using the orders module we defined above
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

// Actor message type that composes multiple channels
pub type ProcessorMessage {
  DirectCommand(DirectMessage)  // Direct actor commands
  OrderCommand(orders.Command)  // Registry commands
  OrderEvent(orders.Event)      // PubSub events
  Shutdown
}

pub type DirectMessage {
  GetStats(reply_with: Subject(String))
  Reset
}

pub fn start_order_processor() {
  actor.new_with_initialiser(5000, fn(subject) {
    // Create PubSub and Registry systems
    let event_pubsub = pubsub.new(
      "events",
      orders.event_decoder(),
      orders.SystemAlert("event_decode_error")
    )

    let command_registry = registry.new(
      "commands",
      orders.command_decoder(),
      orders.Shutdown
    )

    // Get selectors from both systems
    let event_selector = pubsub.subscribe(event_pubsub, "orders")
    let assert Ok(command_selector) = registry.register(command_registry, "order_processor", "v1.0")

    // Create direct command channel
    let direct_subject = process.new_subject()

    // Compose all channels using selectors
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(direct_subject, DirectCommand)
      |> process.merge_selector(process.map_selector(command_selector, OrderCommand))
      |> process.merge_selector(process.map_selector(event_selector, OrderEvent))

    // Return initialized actor
    actor.initialised(ProcessorState(status: "ready", processed: 0))
    |> actor.selecting(selector)
    |> actor.returning(direct_subject)  // Return direct command interface
    |> Ok
  })
  |> actor.on_message(handle_processor_message)
  |> actor.start()
}

fn handle_processor_message(state, message) {
  case message {
    OrderCommand(orders.ProcessOrder(id, reply_with)) -> {
      // Handle registry command
      process.send(reply_with, True)
      actor.continue(ProcessorState(..state, processed: state.processed + 1))
    }
    OrderCommand(orders.GetStatus(reply_with)) -> {
      // Return status
      process.send(reply_with, state.status)
      actor.continue(state)
    }
    OrderEvent(orders.OrderCreated(id, amount)) -> {
      // React to PubSub event
      actor.continue(ProcessorState(..state, status: "Processing order " <> id))
    }
    OrderEvent(orders.SystemAlert(message)) -> {
      // Handle system-wide alerts
      actor.continue(ProcessorState(..state, status: "Alert: " <> message))
    }
    DirectCommand(user_command) -> {
      // Handle direct commands
      actor.continue(state)
    }
    Shutdown -> {
      actor.stop()
    }
  }
}
```

## Development

```sh
gleam test           # Run tests
gleam docs build     # Build documentation
```

## License

This project is licensed under the MIT License.
