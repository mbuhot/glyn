// Message type identifier for deterministic and type-safe PubSub and Registry identification
//
// Example usage:
// ```gleam
// // Define your message type
// pub type ChatMessage {
//   UserJoined(username: String)
//   Message(username: String, content: String)
// }
//
// // Create MessageType constant for compile-time type safety
// pub const chat_message_type: MessageType(ChatMessage) = MessageType("ChatMessage_v1")
//
// // Use with PubSub
// import glyn/pubsub
// let pubsub = pubsub.new(scope: "chat_app", message_type: chat_message_type)
// let subscription = pubsub.subscribe(pubsub, "general", process.self())
// let reached = pubsub.publish(pubsub, "general", UserJoined("Alice"))
//
// // Use with Registry
// import glyn/registry
// let registry = registry.new(scope: "chat_services", message_type: chat_message_type)
// let registration = registry.register(registry, "chat_handler", subject, metadata)
// let result = registry.send(registry, "chat_handler", UserJoined("Bob"))
// let reply = registry.call(registry, "chat_handler", waiting: 1000, sending: GetStatus)
// ```
pub type MessageType(message) {
  MessageType(id: String)
}
