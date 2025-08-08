import gleeunit
import glyn
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

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
