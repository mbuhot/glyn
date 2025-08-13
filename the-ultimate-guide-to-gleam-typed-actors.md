# The Ultimate Guide to Gleam's Typed Actors

*How Gleam builds type-safe concurrent programming on the BEAM*

The BEAM virtual machine (which runs Erlang, Elixir, and now Gleam) is renowned for its actor model concurrency. But traditionally, message passing has been untyped - any process can send any message to any other process, leading to runtime crashes when unexpected messages arrive.

Gleam changes this game entirely by building a sophisticated type-safe layer on top of BEAM's primitives. In this deep dive, we'll explore exactly how Gleam achieves compile-time type safety for concurrent programming, revealing the elegant implementation strategies that make it all work.

## The Foundation: BEAM Processes and Raw Message Passing

At the lowest level, BEAM processes communicate through untyped message passing:

```erlang
% Erlang - completely untyped
Pid ! {hello, "world"},
Pid ! 42,
Pid ! {unexpected, message, here}
```

Any process can send any term to any other process. The receiving process must pattern match in their `receive` blocks to ensure only recognized messages are removed from the mailbox. Unmatched messages remain in the mailbox, potentially wasting memory. Even worse, if receive patterns aren't specific enough (e.g., just matching on tuple structure without validating contents), the application may suffer runtime errors due to mismatched expectations about the message contents. This is powerful but error-prone.

Here's an example showing the problem:

```erlang
receive
    {order, OrderId, Items} when is_list(Items) ->
        % Specific pattern - safe
        process_order(OrderId, Items);

    {Status, Data} ->
        % Too broad! Could match {error, "bad data"} or {ok, 42}
        % Code assumes Data is always valid, leading to runtime errors
        handle_response(Status, Data);

    Msg ->
        % Catches everything - unhandled messages pile up
        % Could accidentally process system messages or garbage
        log_unknown(Msg)
end.
```

## Gleam's Solution: Type-Safe Subjects

Gleam introduces the concept of a `Subject(message)` - a typed channel for sending specific message types to a process. Here's the key insight: **every message sent through a Subject gets tagged with a unique identifier that ensures type-safe routing**.

### The Subject Implementation: Two Variants, One Concept

```gleam
pub opaque type Subject(message) {
  Subject(owner: Pid, tag: Dynamic)      // Reference-based subject
  NamedSubject(name: Name(message))      // Name-based subject
}
```

Both variants achieve the same goal - **type-safe message tagging** - but differ in how they resolve the target process:

- **Reference-based subjects**: Store the PID directly and tag messages with a unique reference
- **Name-based subjects**: Look up the PID at send-time and tag messages with a unique name

### Message Tagging: The Universal Pattern

Regardless of which variant you use, **every message becomes a tagged tuple**:

```gleam
pub fn send(subject: Subject(message), message: message) -> Nil {
  case subject {
    Subject(pid, tag) -> {
      raw_send(pid, #(tag, message))        // #(unique_reference, message)
    }
    NamedSubject(name) -> {
      let assert Ok(pid) = named(name) as "Sending to unregistered name"
      raw_send(pid, #(name, message))       // #(unique_name, message)
    }
  }
}
```

**The key difference**: PID resolution timing
- **Reference subjects**: PID resolved at Subject creation time
- **Named subjects**: PID resolved at message send time

### Creating Reference-Based Subjects

The most common approach uses unique references:

```gleam
pub fn new_subject() -> Subject(message) {
  Subject(owner: self(), tag: reference_to_dynamic(reference.new()))
}
```

Each reference is:
- Unique across the entire BEAM cluster
- Generated at Subject creation time
- Unknown to the calling gleam code that created the subject, due to the opaque type

### Creating Named Subjects with Safe Name Generation

For discoverable services, Gleam uses an external type to represent process names:

```gleam
pub type Name(message)
```

This is an **external type** - it exists only at the type level in Gleam and has no runtime specific representation in the Gleam type system. At runtime, `Name(message)` is simply an Erlang atom, but the type parameter `message` provides compile-time type safety.

Gleam provides `new_name()` to generate unique names safely:

```gleam
/// Generate a new name that a process can register itself with using the
/// `register` function, and other processes can send messages to using
/// `named_subject`.
@external(erlang, "gleam_erlang_ffi", "new_name")
pub fn new_name(prefix prefix: String) -> Name(message)
```

The Erlang implementation ensures uniqueness by appending a system-controlled suffix:

```erlang
new_name(Prefix) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    Name = <<Prefix/bits, "$"/utf8, Suffix/bits>>,
    binary_to_atom(Name).
```

**Developer-controlled prefix + system-controlled suffix** = collision-free atoms like `database_manager$123456`

Once you have a `Name(message)`, you can create a Subject for it:

```gleam
/// Create a subject for a name, which can be used to send and receive messages.
pub fn named_subject(name: Name(message)) -> Subject(message) {
  NamedSubject(name)
}
```

The beauty of this design: `Name(message)` is just an atom at runtime, but the type parameter ensures you can only create subjects that match the intended message type at compile time.

### Complete Usage Example

```gleam
// Reference-based (most common)
let command_subject = process.new_subject()
process.send(command_subject, "hello")
// Sends: #(#Ref<0.123.456.789>, "hello")

// Name-based (for discoverable services)
let service_name = process.new_name("auth_service")
process.register(process.self(), service_name)
let service_subject = process.named_subject(service_name)
process.send(service_subject, "authenticate")
// Sends: #(auth_service$456789, "authenticate")
```

You can observe this message tagging in action using `gleam shell`:

```
1> 'gleam@erlang@process':send('gleam@erlang@process':new_subject(), {hello, 123}).
nil
2> flush().
Shell got {#Ref<0.834841499.1940652033.15265>,{hello,123}}
ok
```

Notice how the tuple `{hello, 123}` becomes `{#Ref<...>, {hello, 123}}` - the message is wrapped with a unique reference tag!

## One Process, Multiple Subjects: The Channel Pattern

Here's a key insight: **a single process can have multiple Subjects, each with different message types**. Since each Subject is just a `pid` plus a unique reference tag, you can create as many Subjects as you need for the same process!

You can see this in action with `gleam shell`:

```
1> CommandSubject = gleam@erlang@process:new_subject().
{subject, <0.101.0>, #Ref<0.834841499.1940652033.15911>}

2> EventSubject = gleam@erlang@process:new_subject().
{subject, <0.101.0>, #Ref<0.834841499.1940652033.15920>}

3> QuerySubject = gleam@erlang@process:new_subject().
{subject, <0.101.0>, #Ref<0.834841499.1940652033.15933>}
```

Notice how all three Subjects have the same PID `<0.101.0>` but different reference tags.

This creates **typed channels** into your process:
- `command_subject` can only receive `Command` messages
- `event_subject` can only receive `Event` messages
- `query_subject` can only receive `Query` messages
- But they all arrive at the same process mailbox!

### The Problem This Creates

Now your process mailbox contains a mix of tagged messages:
```
Process Mailbox:
{#Ref<0.123.456.789>, CreateOrder("order-1")}     % From command_subject
{#Ref<0.987.654.321>, PaymentReceived("order-1")} % From event_subject
{#Ref<0.555.444.333>, GetOrderStatus("order-1")}  % From query_subject
```

**How do you handle multiple message types safely?**

## Basic Message Receiving: Single Subject Approach

Before we tackle multiple subjects, let's see how receiving works with a single Subject using the `receive` function:

```gleam
pub fn receive(
  from subject: Subject(message),
  within timeout: Int
) -> Result(message, Nil)
```

Here's a simple example:

```gleam
let subject = process.new_subject()

// Send a message (from another process)
process.send(subject, "hello")

// Receive the message
case process.receive(subject, 1000) {
  Ok(message) -> io.println("Got: " <> message)
  Error(Nil) -> io.println("Timeout!")
}
```

**What happens under the hood?**

The Erlang implementation shows how this works:

```erlang
'receive'({subject, _Pid, Ref}, Timeout) ->
    receive
        {Ref, Message} -> {ok, Message}
    after Timeout ->
        {error, nil}
    end.
```

The `receive` function waits specifically for messages tagged with this Subject's unique reference, extracts the message from the `{Ref, Message}` tuple, and returns just the message part.

**This works perfectly for single Subjects**, but what about our multi-Subject scenario?

## The Magic of Selectors: Type-Safe Message Routing

Now we get to the brilliant part: **Selectors**. Like `Name(message)`, `Selector(payload)` is an external type:

```gleam
pub type Selector(payload)

/// Create a new `Selector` which can be used to receive messages on multiple
/// `Subject`s at once.
@external(erlang, "gleam_erlang_ffi", "new_selector")
pub fn new_selector() -> Selector(payload)
```

When you have multiple Subjects sending different message types to the same process, you need a way to:

1. **Listen to multiple Subjects simultaneously** - not just one at a time
2. **Handle whichever message arrives first** - from any of the registered Subjects
3. **Transform each message type** to a unified internal format
4. **Maintain compile-time type safety** throughout the process

This is exactly what Selectors solve.

### Basic Selector Usage

Let's start with the simplest selector example:

```gleam
let subject = process.new_subject()

// Create a selector and register the subject
let selector =
  process.new_selector()
  |> process.select(subject)

// Send a message
process.send(subject, "hello")

// Receive using the selector
case process.selector_receive(selector, 1000) {
  Ok(message) -> io.println("Got: " <> message)
  Error(Nil) -> io.println("Timeout!")
}
```

At first glance, this might look like "receiving from a subject with extra steps" - why not just use `process.receive(subject, 1000)` directly?

**The power emerges when you have multiple subjects**:

```gleam
// Define a unified message type that can hold different message types
pub type ProcessorMessage {
  CommandMessage(Command)
  EventMessage(Event)
}

let command_subject: Subject(Command) = process.new_subject()
let event_subject: Subject(Event) = process.new_subject()

// Register MULTIPLE subjects with transformation functions
let selector =
  process.new_selector()
  |> process.select_map(command_subject, CommandMessage)  // Transform to CommandMessage
  |> process.select_map(event_subject, EventMessage)      // Transform to EventMessage

// Now we can receive from EITHER subject with ONE call
case process.selector_receive(selector, 1000) {
  Ok(CommandMessage(cmd)) -> handle_command(cmd)
  Ok(EventMessage(event)) -> handle_event(event)
  Error(Nil) -> io.println("Timeout!")
}
```

**The key insight**: `select_map` transforms each message type into a unified format, allowing a single `selector_receive()` call to handle multiple message types safely.

### Selector Internal Structure

A Selector is implemented as a map in Erlang:

```erlang
% Erlang representation
{selector, #{
  {some_reference, 2} => fun(Message) -> handler(Message) end,
  {another_reference, 2} => fun(Message) -> other_handler(Message) end,
  {name_atom, 2} => fun(Message) -> named_handler(Message) end
}}
```

The keys are tuples of `{tag, tuple_size}`, and values are **handler functions**. When you use `select_map`, it installs a handler that first extracts the message from the tagged tuple `#(tag, message)` and then transforms it into the `payload` type specified by the `Selector(payload)` type.

### The Receive Magic

Here's the Erlang implementation that makes it all work:

```erlang
select({selector, Handlers}, Timeout) ->
    receive
        Msg when is_map_key({element(1, Msg), tuple_size(Msg)}, Handlers) ->
            Fn = maps:get({element(1, Msg), tuple_size(Msg)}, Handlers),
            {ok, Fn(Msg)};
    after Timeout ->
        {error, nil}
    end.
```

**The key insight**: The `receive` expression uses a guard `is_map_key({element(1, Msg), tuple_size(Msg)}, Handlers)` to check if there's a handler for the incoming message's tag and size.

This means:
1. Only messages with registered handlers are received
2. Unknown messages stay in the mailbox
3. The system invokes the handler directly - no additional type checking needed since the message must already be the correct type for that handler
4. Type safety is maintained at runtime



### Dynamic Selector Management

Selectors can be modified at runtime for dynamic message routing:

#### Removing Subjects with `deselect`

```gleam
pub fn deselect(
  selector: Selector(payload),
  subject: Subject(message),
) -> Selector(payload)
```

This removes a Subject from the Selector - useful when you no longer want to listen to certain message types:

```gleam
let selector =
  process.new_selector()
  |> process.select_map(command_subject, CommandMessage)
  |> process.select_map(event_subject, EventMessage)

// Later, stop listening to events
let selector = process.deselect(selector, event_subject)
// Now only receives command messages
```

#### Combining Selectors with `merge_selector`

```gleam
pub fn merge_selector(
  selector_a: Selector(payload),
  selector_b: Selector(payload)
) -> Selector(payload)
```

This combines two Selectors into one - perfect for modular composition:

```gleam
// Create focused selectors
let command_selector =
  process.new_selector()
  |> process.select_map(create_subject, CreateCommand)
  |> process.select_map(update_subject, UpdateCommand)

let monitoring_selector =
  process.new_selector()
  |> process.select_map(health_subject, HealthCheck)
  |> process.select_map(metrics_subject, MetricsReport)

// Combine them
let unified_selector = process.merge_selector(command_selector, monitoring_selector)
```

## Actors: The High-Level Abstraction

Gleam's `actor` module builds on these primitives to provide OTP-compliant processes with lifecycle management.

### Basic Actor Example

Here's a simple actor that maintains a counter:

```gleam
import gleam/otp/actor
import gleam/erlang/process.{type Subject}

pub type CounterMessage {
  Increment
  Decrement
  GetCount(reply_with: Subject(Int))
  Shutdown
}

fn handle_message(state: Int, message: CounterMessage) -> actor.Next(Int, CounterMessage) {
  case message {
    Increment -> actor.continue(state + 1)
    Decrement -> actor.continue(state - 1)
    GetCount(reply_subject) -> {
      process.send(reply_subject, state)
      actor.continue(state)
    }
    Shutdown -> actor.stop()
  }
}

pub fn start_counter() {
  actor.new(0)  // Initial state is 0
  |> actor.on_message(handle_message)
  |> actor.start()
}
```

**Usage:**
```gleam
let assert Ok(started) = start_counter()
let counter_subject = started.data

// Send messages to the actor
process.send(counter_subject, Increment)
process.send(counter_subject, Increment)

// Get the current count
let reply_subject = process.new_subject()
process.send(counter_subject, GetCount(reply_subject))
let assert Ok(count) = process.receive(reply_subject, 1000)
// count == 2
```

This example shows how actors provide a clean abstraction over the lower-level primitives we've explored. Behind the scenes, the actor is using a Selector, but you don't need to manage it explicitly.

**Note on the Reply Pattern**: Notice how the `GetCount` message contains a `reply_subject` that must be explicitly used within the `handle_message` function to send a reply back. This is different from typical Erlang `gen_server` implementations where replies are often part of a return tuple like `{reply, Value, NewState}`. In Gleam's actor system, you explicitly call `process.send(reply_subject, response)` to send replies, giving you more control over when and how responses are sent.

### How Actors Wrap the Primitives

When you create an actor, here's what happens internally:

1. **Initialization**: A Subject is created with `process.new_subject()`
2. **Selector Creation**: A default Selector is built that listens to this Subject
3. **Message Wrapping**: All messages are wrapped in a `Message(msg)` type that handles system messages
4. **Lifecycle Management**: The actor handles OTP system messages for debugging, monitoring, etc.
5. **Error Handling**: Unexpected messages are caught and handled gracefully


The `Message` wrapper allows actors to handle both your application messages and OTP system messages:

```gleam
type Message(message) {
  Message(message)           // Your application message
  System(SystemMessage)      // OTP system message
  Unexpected(Dynamic)        // Fallback for unknown messages
}
```

## Real-World Example: Multi-Channel Order Processor

Let's build a practical example that demonstrates all these concepts:

**Key Pattern: `actor.new_with_initialiser`**

Unlike the simple `actor.new(initial_state)` we used earlier, this example uses `actor.new_with_initialiser()` which provides a dedicated initialization phase. This is where we:

1. **Create multiple Subjects** for different message types
2. **Build a custom Selector** that composes all the subjects
3. **Return a data structure** containing all the subjects for external use

This pattern is essential for multi-channel actors because it allows callers to get access to all the typed channels they need to communicate with the actor.

```gleam
import gleam/otp/actor
import gleam/erlang/process

// Different message types for different channels
pub type OrderCommand {
  CreateOrder(id: String, items: List(String))
  CancelOrder(id: String)
  GetOrderStatus(id: String, reply_with: process.Subject(OrderStatus))
}

pub type PaymentEvent {
  PaymentReceived(order_id: String, amount: Float)
  PaymentFailed(order_id: String, reason: String)
}

pub type SystemAlert {
  HighLoad(cpu_percent: Float)
  DatabaseError(message: String)
}

// Unified internal message type
pub type ProcessorMessage {
  Command(OrderCommand)
  Payment(PaymentEvent)
  Alert(SystemAlert)
}

// External interface with multiple subjects
pub type ProcessorChannels {
  ProcessorChannels(
    command: process.Subject(OrderCommand),
    payment: process.Subject(PaymentEvent),
    alert: process.Subject(SystemAlert),
    main: process.Subject(ProcessorMessage)
  )
}

pub fn start_order_processor() {
  actor.new_with_initialiser(5000, fn(main_subject) {
    // Create subjects for different message types
    let command_subject = process.new_subject()
    let payment_subject = process.new_subject()
    let alert_subject = process.new_subject()

    // Build a Selector that unifies all message types
    let selector =
      process.new_selector()
      |> process.select(main_subject)                    // Direct messages
      |> process.select_map(command_subject, Command)    // Transform to Command
      |> process.select_map(payment_subject, Payment)    // Transform to Payment
      |> process.select_map(alert_subject, Alert)        // Transform to Alert

    let channels = ProcessorChannels(
      command: command_subject,
      payment: payment_subject,
      alert: alert_subject,
      main: main_subject
    )

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(channels)
    |> Ok
  })
  |> actor.on_message(handle_processor_message)
  |> actor.start()
}

fn handle_processor_message(state: State, message: ProcessorMessage) {
  case message {
    Command(command_message) ->  {
      command |> handle_command(state) |> actor.continue()
    }
    Payment(payment_message) -> {
      payment_message |> handle_payment(state) |> actor.continue()
    }
    Alert(alert_message) -> {
      alert_message |> handle_alert(state) |> actor.continue()
    }
  }
}
```

### Using the Multi-Channel Actor

```gleam
// Start the processor
let assert Ok(started) = start_order_processor()
let channels = started.data

// Send different types of messages to different channels
process.send(channels.command, CreateOrder("ord-123", ["item1", "item2"]))
process.send(channels.payment, PaymentReceived("ord-123", 99.99))
process.send(channels.alert, HighLoad(85.5))

// All messages are received and handled with full type safety!
```

## Integration with Dynamic Messages: Erlang/Elixir Interop

Sometimes you need to integrate with existing Erlang or Elixir code that sends untyped messages. Gleam handles this with `select_other`:

```gleam
pub fn select_other(
  selector: Selector(payload),
  mapping transform: fn(Dynamic) -> payload,
) -> Selector(payload)
```

This adds a fallback handler for any message that doesn't match registered Subjects:

```gleam
let selector =
  process.new_selector()
  |> process.select_map(typed_subject, TypedMessage)
  |> process.select_other(fn(dynamic_msg) {
    // Handle unknown messages from Erlang/Elixir
    case decode_erlang_message(dynamic_msg) {
      Ok(decoded) -> LegacyMessage(decoded)
      Error(_) -> UnknownMessage(dynamic_msg)
    }
  })
```

## The Performance Story

You might wonder: "Doesn't all this tagging and transformation add overhead?"

The answer is: **surprisingly little**. Here's why:

1. **References are lightweight**: Erlang references are just integers internally
2. **Tuple creation is fast**: BEAM is highly optimized for tuple operations
3. **Map lookups are O(log n)**: With typically few handlers, this is very fast
4. **Pattern matching is optimized**: BEAM's pattern matching is heavily optimized
5. **No extra copies**: Messages are passed by reference, not copied

The type safety benefits far outweigh the minimal runtime cost.


## Distributed Messaging Limitations

Gleam's typed concurrency system primarily supports single-node messaging. While Subjects can technically be passed between BEAM nodes, the current system lacks built-in support for distributed service discovery and global process registration.

For processes that need to register globally (using Erlang's `:global` module) or join distributed process groups (using Erlang's `:pg` module), you'll need to work with plain PIDs and decode messages from `Dynamic` to ensure type safety.

This represents a trade-off: distributed systems require additional runtime type checking, but single-node systems benefit from complete compile-time type safety.

## Conclusion: The Elegance of Typed Concurrency

Gleam's approach to typed actors delivers a compelling developer experience by building a sophisticated type-safe layer on proven BEAM primitives. This approach achieves:

- **Complete type safety** at compile time
- **Zero-cost abstractions** that don't sacrifice BEAM performance
- **Seamless interop** with existing Erlang/Elixir systems
- **Familiar actor patterns** for BEAM developers
- **Composable message handling** through Selectors

The implementation reveals several key insights:

1. **Unique references** provide the foundation for type-safe channels
2. **Message tagging** maintains type information at runtime
3. **Map-based selectors** enable efficient, type-safe message routing
4. **Transformation functions** unify different message types
5. **OTP compliance** ensures actors work within the broader BEAM ecosystem

This design proves that you don't need to sacrifice the power and performance of the actor model to gain type safety. Instead, Gleam shows how thoughtful language design can enhance the developer experience while preserving the characteristics that make BEAM systems so robust and scalable.

Whether you're building microservices, distributed systems, or real-time applications, Gleam's typed actors provide the safety and expressiveness needed for modern concurrent programming - all while running on the battle-tested BEAM virtual machine.

*Ready to dive deeper? Try building your actor-based system in Gleam and experience the power of typed concurrency firsthand.*
