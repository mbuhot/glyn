# Glyn ✨

[![Package Version](https://img.shields.io/hexpm/v/glyn)](https://hex.pm/packages/glyn)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/glyn/)

**A type-safe PubSub library for Gleam that composes with typed actors.**

Glyn is built as a wrapper around the battle-tested Erlang [syn](https://github.com/ostinelli/syn) library, providing seamless integration with Gleam's actor model through typed subjects and selectors.

## Installation

```sh
gleam add glyn
```

## Composing an Actor

The power of Glyn lies in how it enables actors to cleanly handle **both direct messages and PubSub events** using Gleam's selector system. This allows you to build actors that respond to multiple message sources while maintaining full type safety.

```gleam
import glyn
import gleam/erlang/process.{type Subject}
import gleam/otp/actor


// PubSub event types from across your system
pub type SystemEvent {
  UserRegistered(user_id: String, email: String)
  PaymentProcessed(user_id: String, amount: Int)
  ConfigurationChanged(key: String, value: String)
}

fn start_pubsub() -> PubSub(SystemEvent) {
  glyn.new(scope: "system_events", type_id: "SystemEvent_v1")
}

// Your business logic message types
pub type UserCommand {
  GetProfile(reply_with: Subject(UserProfile))
  UpdateName(name: String)
}

// Unified actor message type
type UserActorMessage {
  Command(UserCommand)           // Direct commands
  SystemEvent(SystemEvent)       // PubSub events
}

// Actor that handles both direct commands AND system events
fn handle_message(state: UserState, message: UserActorMessage) {
  case message {
    Command(cmd) -> handle_command(state, cmd)
    SystemEvent(event) -> handle_system_event(state, event)
  }
}

// Start an actor that listens for both UserCommand and SystemEvent
// The subject included in the return value accepts UserCommand messages only, acting as the public message API
pub fn start_user_actor(user_id: String, pubsub: PubSub(SystemEvent)) -> Result(actor.Started(Subject(UserCommand)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(_subject) {
    let subscription = glyn.subscribe(pubsub, "users", process.self())
    let command_subject = process.new_subject()

    // Compose multiple message sources with a selector
    let selector =
      process.new_selector()
      |> process.select_map(command_subject, Command)
      |> process.select_map(subscription.subject, SystemEvent)

    let initial_state = UserState(user_id: user_id)

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(command_subject)  // Return direct command interface
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start()
}
```

## Distributed Clusters

Glyn works seamlessly across Erlang clusters. Actors on different nodes can communicate by using the same `scope` and `type_id`:

```gleam
// Node A - subscriber
let pubsub = glyn.new(scope: "global_events", type_id: "OrderEvent_v1")
let subscription = glyn.subscribe(pubsub, "orders", process.self())

// Node B - publisher
let pubsub = glyn.new(scope: "global_events", type_id: "OrderEvent_v1")  // Same scope and type_id!
let _ = glyn.publish(pubsub, "orders", OrderCreated(order_id: "123", ...))

// The message published on Node B will reach the subscriber on Node A
```

## Development

```sh
gleam test  # Run the tests
gleam docs build  # Build documentation
```
