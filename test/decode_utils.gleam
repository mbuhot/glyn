import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}

/// Test message types for Registry testing
pub type ServiceMessage {
  GetStatus(reply_with: Subject(String))
  ProcessRequest(id: String, reply_with: Subject(Bool))
  UpdateConfig(key: String, value: String)
  Shutdown
}

pub type SystemCommand {
  StartSystem(reply_with: Subject(Bool))
  StopSystem
  RestartSystem
  GetSystemInfo(reply_with: Subject(String))
  SetLogLevel(level: String)
}

pub type UserEvent {
  UserCreated(id: String, name: String, email: String)
  UserUpdated(id: String, field: String, value: String)
  UserDeleted(id: String)
  UserLogin(id: String, timestamp: Int)
  UserLogout(id: String, timestamp: Int)
}

/// Test message types for PubSub testing
pub type ChatMessage {
  UserJoined(username: String)
  UserLeft(username: String)
  Message(username: String, content: String)
  AdminMessage(content: String)
}

pub type MetricEvent {
  CounterIncrement(name: String, value: Int)
  GaugeUpdate(name: String, value: Float)
  TimerRecord(name: String, duration_ms: Int)
  HistogramUpdate(name: String, value: Float)
}

/// Integration test types
pub type Command {
  ProcessOrder(id: String, reply_with: Subject(Bool))
  GetCommandStatus(reply_with: Subject(String))
  GetProcessedOrders(reply_with: Subject(Int))
  CommandShutdown
}

pub type Event {
  OrderCreated(id: String, amount: Int)
  PaymentProcessed(id: String)
  SystemAlert(message: String)
}

/// Utility function to expect a specific atom value in decoders
pub fn expect_atom(expected: String) -> decode.Decoder(atom.Atom) {
  use value <- decode.then(atom.decoder())
  case atom.to_string(value) == expected {
    True -> decode.success(value)
    False -> decode.failure(value, "Expected atom: " <> expected)
  }
}

/// ServiceMessage decoder
pub fn service_message_decoder() -> decode.Decoder(ServiceMessage) {
  decode.one_of(
    // GetStatus variant
    {
      use _ <- decode.field(0, expect_atom("get_status"))
      use reply_with <- decode.field(1, subject_decoder())
      decode.success(GetStatus(reply_with))
    },
    or: [
      // ProcessRequest variant
      {
        use _ <- decode.field(0, expect_atom("process_request"))
        use id <- decode.field(1, decode.string)
        use reply_with <- decode.field(2, subject_decoder())
        decode.success(ProcessRequest(id, reply_with))
      },
      // UpdateConfig variant
      {
        use _ <- decode.field(0, expect_atom("update_config"))
        use key <- decode.field(1, decode.string)
        use value <- decode.field(2, decode.string)
        decode.success(UpdateConfig(key, value))
      },
      // Shutdown variant
      {
        use _ <- decode.field(0, expect_atom("shutdown"))
        decode.success(Shutdown)
      },
    ],
  )
}

/// SystemCommand decoder
pub fn system_command_decoder() -> decode.Decoder(SystemCommand) {
  let start_system = {
    use _ <- decode.field(0, expect_atom("start_system"))
    use reply_with <- decode.field(1, subject_decoder())
    decode.success(StartSystem(reply_with))
  }

  let stop_system = {
    use _ <- decode.field(0, expect_atom("stop_system"))
    decode.success(StopSystem)
  }

  let restart_system = {
    use _ <- decode.field(0, expect_atom("restart_system"))
    decode.success(RestartSystem)
  }

  let get_system_info = {
    use _ <- decode.field(0, expect_atom("get_system_info"))
    use reply_with <- decode.field(1, subject_decoder())
    decode.success(GetSystemInfo(reply_with))
  }

  let set_log_level = {
    use _ <- decode.field(0, expect_atom("set_log_level"))
    use level <- decode.field(1, decode.string)
    decode.success(SetLogLevel(level))
  }

  decode.one_of(start_system, or: [
    stop_system,
    restart_system,
    get_system_info,
    set_log_level,
  ])
}

/// ChatMessage decoder
pub fn chat_message_decoder() -> decode.Decoder(ChatMessage) {
  decode.one_of(
    // UserJoined variant
    {
      use _ <- decode.field(0, expect_atom("user_joined"))
      use username <- decode.field(1, decode.string)
      decode.success(UserJoined(username))
    },
    or: [
      // UserLeft variant
      {
        use _ <- decode.field(0, expect_atom("user_left"))
        use username <- decode.field(1, decode.string)
        decode.success(UserLeft(username))
      },
      // Message variant
      {
        use _ <- decode.field(0, expect_atom("message"))
        use username <- decode.field(1, decode.string)
        use content <- decode.field(2, decode.string)
        decode.success(Message(username, content))
      },
      // AdminMessage variant
      {
        use _ <- decode.field(0, expect_atom("admin_message"))
        use content <- decode.field(1, decode.string)
        decode.success(AdminMessage(content))
      },
    ],
  )
}

/// MetricEvent decoder
pub fn metric_event_decoder() -> decode.Decoder(MetricEvent) {
  decode.one_of(
    // CounterIncrement variant
    {
      use _ <- decode.field(0, expect_atom("counter_increment"))
      use name <- decode.field(1, decode.string)
      use value <- decode.field(2, decode.int)
      decode.success(CounterIncrement(name, value))
    },
    or: [
      // GaugeUpdate variant
      {
        use _ <- decode.field(0, expect_atom("gauge_update"))
        use name <- decode.field(1, decode.string)
        use value <- decode.field(2, decode.float)
        decode.success(GaugeUpdate(name, value))
      },
      // TimerRecord variant
      {
        use _ <- decode.field(0, expect_atom("timer_record"))
        use name <- decode.field(1, decode.string)
        use duration_ms <- decode.field(2, decode.int)
        decode.success(TimerRecord(name, duration_ms))
      },
      // HistogramUpdate variant
      {
        use _ <- decode.field(0, expect_atom("histogram_update"))
        use name <- decode.field(1, decode.string)
        use value <- decode.field(2, decode.float)
        decode.success(HistogramUpdate(name, value))
      },
    ],
  )
}

/// UserEvent decoder
pub fn user_event_decoder() -> decode.Decoder(UserEvent) {
  decode.one_of(
    // UserCreated variant
    {
      use _ <- decode.field(0, expect_atom("user_created"))
      use id <- decode.field(1, decode.string)
      use name <- decode.field(2, decode.string)
      use email <- decode.field(3, decode.string)
      decode.success(UserCreated(id, name, email))
    },
    or: [
      // UserUpdated variant
      {
        use _ <- decode.field(0, expect_atom("user_updated"))
        use id <- decode.field(1, decode.string)
        use field <- decode.field(2, decode.string)
        use value <- decode.field(3, decode.string)
        decode.success(UserUpdated(id, field, value))
      },
      // UserDeleted variant
      {
        use _ <- decode.field(0, expect_atom("user_deleted"))
        use id <- decode.field(1, decode.string)
        decode.success(UserDeleted(id))
      },
      // UserLogin variant
      {
        use _ <- decode.field(0, expect_atom("user_login"))
        use id <- decode.field(1, decode.string)
        use timestamp <- decode.field(2, decode.int)
        decode.success(UserLogin(id, timestamp))
      },
      // UserLogout variant
      {
        use _ <- decode.field(0, expect_atom("user_logout"))
        use id <- decode.field(1, decode.string)
        use timestamp <- decode.field(2, decode.int)
        decode.success(UserLogout(id, timestamp))
      },
    ],
  )
}

/// Command decoder for integration tests
pub fn command_decoder() -> decode.Decoder(Command) {
  decode.one_of(
    // ProcessOrder variant
    {
      use _ <- decode.field(0, expect_atom("process_order"))
      use id <- decode.field(1, decode.string)
      use reply_with <- decode.field(2, subject_decoder())
      decode.success(ProcessOrder(id, reply_with))
    },
    or: [
      // GetCommandStatus variant
      {
        use _ <- decode.field(0, expect_atom("get_command_status"))
        use reply_with <- decode.field(1, subject_decoder())
        decode.success(GetCommandStatus(reply_with))
      },
      // GetProcessedOrders variant
      {
        use _ <- decode.field(0, expect_atom("get_processed_orders"))
        use reply_with <- decode.field(1, subject_decoder())
        decode.success(GetProcessedOrders(reply_with))
      },
      // CommandShutdown variant
      {
        use _ <- decode.field(0, expect_atom("command_shutdown"))
        decode.success(CommandShutdown)
      },
    ],
  )
}

/// Event decoder for integration tests
pub fn event_decoder() -> decode.Decoder(Event) {
  decode.one_of(
    // OrderCreated variant
    {
      use _ <- decode.field(0, expect_atom("order_created"))
      use id <- decode.field(1, decode.string)
      use amount <- decode.field(2, decode.int)
      decode.success(OrderCreated(id, amount))
    },
    or: [
      // PaymentProcessed variant
      {
        use _ <- decode.field(0, expect_atom("payment_processed"))
        use id <- decode.field(1, decode.string)
        decode.success(PaymentProcessed(id))
      },
      // SystemAlert variant
      {
        use _ <- decode.field(0, expect_atom("system_alert"))
        use message <- decode.field(1, decode.string)
        decode.success(SystemAlert(message))
      },
    ],
  )
}

@external(erlang, "gleam_erlang_ffi", "identity")
fn dynamic_to_pid(d: Dynamic) -> process.Pid

fn subject_decoder() -> decode.Decoder(Subject(message)) {
  use _ <- decode.field(0, expect_atom("subject"))
  use pid <- decode.field(1, decode.dynamic)
  use tag <- decode.field(2, decode.dynamic)
  decode.success(process.unsafely_create_subject(dynamic_to_pid(pid), tag))
}
