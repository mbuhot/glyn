import gleeunit
import glyn
import gleam/erlang/process.{type Subject}


pub fn main() -> Nil {
  gleeunit.main()
}

// Test message types for Registry
pub type ServiceMessage {
  GetStatus(reply_with: Subject(String))
  ProcessRequest(id: String, reply_with: Subject(Bool))
  Shutdown
}

pub type UserInfo {
  UserInfo(name: String, age: Int)
}

// Test basic registration and lookup functionality
pub fn basic_registration_and_lookup_test() {
  // Arrange: Create registry and subject with metadata
  let registry = glyn.new_registry(scope: "test_scope")
  let subject = process.new_subject()
  let test_metadata = "service_v1"

  // Act: Register the subject
  let registration_result = glyn.register(registry, "test_service", subject, test_metadata)

  // Assert: Registration should succeed
  let assert Ok(registration) = registration_result
  assert registration.name == "test_service"
  assert registration.metadata == test_metadata

  // Act: Look up the registered subject
  let lookup_result = glyn.lookup(registry, "test_service")

  // Assert: Lookup should return the same subject and metadata
  let assert Ok(#(found_subject, found_metadata)) = lookup_result
  assert found_subject == subject
  assert found_metadata == test_metadata
}

// Test error handling when looking up non-existent process
pub fn lookup_non_existent_process_test() {
  // Arrange: Create registry (no registrations)
  let registry = glyn.new_registry(scope: "error_test_scope")

  // Act: Try to lookup a process that doesn't exist
  let lookup_result = glyn.lookup(registry, "non_existent_service")

  // Assert: Should return an error
  let assert Error(error_message) = lookup_result
  assert error_message == "Process not found: non_existent_service"
}

// Test unregister functionality
pub fn unregister_process_test() {
  // Arrange: Create registry and register a process
  let registry = glyn.new_registry(scope: "unregister_test_scope")
  let subject = process.new_subject()
  let test_metadata = "unregister_service_v1"

  let assert Ok(registration) = glyn.register(registry, "temp_service", subject, test_metadata)

  // Verify it exists first
  let assert Ok(_) = glyn.lookup(registry, "temp_service")

  // Act: Unregister the process
  let unregister_result = glyn.unregister(registration)

  // Assert: Unregistration should succeed
  let assert Ok(_) = unregister_result

  // Act: Try to lookup the unregistered process
  let lookup_result = glyn.lookup(registry, "temp_service")

  // Assert: Should no longer be found
  let assert Error(error_message) = lookup_result
  assert error_message == "Process not found: temp_service"
}

// Test send_to_registered convenience function with actual message handling
pub fn send_to_registered_test() {
  // Arrange: Create registry
  let registry = glyn.new_registry(scope: "send_test_scope")

  // Create a simple service that handles GetStatus messages
  let service_subject = process.new_subject()
  let test_metadata = "send_service_v1"

  // Register the service subject in the registry
  let assert Ok(_registration) = glyn.register(registry, "message_service", service_subject, test_metadata)

  // Create a reply subject for the message
  let reply_subject = process.new_subject()

  // Act: Send a message to the registered process
  let send_result = glyn.send_to_registered(registry, "message_service", GetStatus(reply_subject))

  // Assert: Send should succeed
  let assert Ok(_) = send_result

  // Simulate a service handling the message by receiving it and sending a reply
  let assert Ok(received_message) = process.receive(service_subject, 100)
  let assert GetStatus(received_reply_subject) = received_message

  // Service sends a reply back
  process.send(received_reply_subject, "service_active")

  // Now receive the reply that was sent back
  let assert Ok(status_reply) = process.receive(reply_subject, 100)
  assert status_reply == "service_active"

  // Test error case: send to non-existent process
  let error_result = glyn.send_to_registered(registry, "non_existent_service", Shutdown)

  // Assert: Should return an error
  let assert Error(error_message) = error_result
  assert error_message == "Process not found: non_existent_service"
}
