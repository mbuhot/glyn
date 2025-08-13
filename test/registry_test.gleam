import decode_utils
import gleam/erlang/process.{type Subject}
import gleeunit
import glyn/registry

pub fn main() -> Nil {
  gleeunit.main()
}

// Actor message types for testing multi-channel composition
pub type TestActorMessage {
  DirectCommand(DirectMessage)
  RegistryMessage(decode_utils.ServiceMessage)
  SystemCommand(decode_utils.SystemCommand)
  Shutdown
}

pub type DirectMessage {
  Ping(reply_with: Subject(String))
  SetState(state: String)
  GetState(reply_with: Subject(String))
}

pub type TestActorState {
  TestActorState(message_count: Int, last_message: String, state: String)
}

// Test basic registry registration with selector composition
pub fn basic_registration_with_selector_test() {
  // Arrange: Create registry with service message decoder
  let registry =
    registry.new(
      scope: "test_basic_selector",
      decoder: decode_utils.service_message_decoder(),
      error_default: decode_utils.Shutdown,
    )

  // Create base selector for direct commands
  let command_subject = process.new_subject()
  let base_selector =
    process.new_selector()
    |> process.select_map(command_subject, DirectCommand)

  // Act: Register and compose selectors
  let assert Ok(registry_selector) =
    registry.register(registry, "test_service", "test_metadata_v1")
  let enhanced_selector =
    base_selector
    |> process.merge_selector(process.map_selector(
      registry_selector,
      RegistryMessage,
    ))

  // Assert: Selector should be enhanced (this is implicit - if register succeeded, selector is enhanced)
  // We can verify by checking that whereis works
  let assert Ok(#(_pid, metadata)) = registry.whereis(registry, "test_service")
  assert metadata == "test_metadata_v1"

  // Test sending a message and receiving it through the selector
  let reply_subject = process.new_subject()
  let message = decode_utils.GetStatus(reply_subject)

  // Send message to registered process
  let assert Ok(_) = registry.send(registry, "test_service", message)

  // Use selector to receive the message (with timeout)
  case process.selector_receive(enhanced_selector, 100) {
    Ok(RegistryMessage(decode_utils.GetStatus(received_reply_subject))) -> {
      // Message decoded successfully
      assert received_reply_subject == reply_subject
    }
    Ok(DirectCommand(_)) -> {
      panic as "Received direct command instead of registry message"
    }
    Ok(_) -> {
      panic as "Received unexpected message type"
    }
    Error(_) -> {
      panic as "Message not received within timeout"
    }
  }
}

// Test multi-channel actor composition
pub fn multi_channel_actor_composition_test() {
  // Arrange: Create registries for different message types
  let service_registry =
    registry.new(
      scope: "test_multi_channel_service",
      decoder: decode_utils.service_message_decoder(),
      error_default: decode_utils.Shutdown,
    )

  let system_registry =
    registry.new(
      scope: "test_multi_channel_system",
      decoder: decode_utils.system_command_decoder(),
      error_default: decode_utils.StopSystem,
    )

  // Create actor with multi-channel selector
  let command_subject = process.new_subject()

  // Start with direct command channel
  let base_selector =
    process.new_selector()
    |> process.select_map(command_subject, DirectCommand)

  // Add service registry channel
  let assert Ok(service_registry_selector) =
    registry.register(service_registry, "multi_service", "service_meta")
  let with_service =
    base_selector
    |> process.merge_selector(process.map_selector(
      service_registry_selector,
      RegistryMessage,
    ))

  // Add system registry channel
  let assert Ok(system_registry_selector) =
    registry.register(system_registry, "multi_system", "system_meta")
  let final_selector =
    with_service
    |> process.merge_selector(process.map_selector(
      system_registry_selector,
      SystemCommand,
    ))

  // Act & Assert: Test that all three channels work

  // Test direct command
  process.send(command_subject, Ping(process.new_subject()))
  case process.selector_receive(final_selector, 100) {
    Ok(DirectCommand(Ping(_))) -> Nil
    _ -> panic as "Direct command channel failed"
  }

  // Test service registry message
  let assert Ok(_) =
    registry.send(
      service_registry,
      "multi_service",
      decode_utils.GetStatus(process.new_subject()),
    )
  case process.selector_receive(final_selector, 100) {
    Ok(RegistryMessage(decode_utils.GetStatus(_))) -> Nil
    _ -> panic as "Service registry channel failed"
  }

  // Test system registry message
  let assert Ok(_) =
    registry.send(system_registry, "multi_system", decode_utils.StopSystem)
  case process.selector_receive(final_selector, 100) {
    Ok(SystemCommand(decode_utils.StopSystem)) -> Nil
    _ -> panic as "System registry channel failed"
  }
}

// Test type safety through different scopes and decoders
pub fn type_safety_through_scopes_test() {
  // Arrange: Create two registries with different decoders in same scope
  // This tests that processes can be registered under same name but different scopes
  let service_registry =
    registry.new(
      scope: "type_safety_service",
      decoder: decode_utils.service_message_decoder(),
      error_default: decode_utils.Shutdown,
    )

  let system_registry =
    registry.new(
      scope: "type_safety_system",
      // Different scope
      decoder: decode_utils.system_command_decoder(),
      error_default: decode_utils.StopSystem,
    )

  let command_subject = process.new_subject()
  let _base_selector =
    process.new_selector() |> process.select_map(command_subject, DirectCommand)

  // Register same name in both registries
  let assert Ok(_) =
    registry.register(service_registry, "shared_name", "service_meta")

  let assert Ok(_) =
    registry.register(
      system_registry,
      "shared_name",
      // Same name, different scope
      "system_meta",
    )

  // Act & Assert: Both should work independently
  let assert Ok(#(_pid1, meta1)) =
    registry.whereis(service_registry, "shared_name")
  let assert Ok(#(_pid2, meta2)) =
    registry.whereis(system_registry, "shared_name")

  assert meta1 == "service_meta"
  assert meta2 == "system_meta"

  // Send different message types to same name in different scopes
  let assert Ok(_) =
    registry.send(service_registry, "shared_name", decode_utils.Shutdown)

  let assert Ok(_) =
    registry.send(system_registry, "shared_name", decode_utils.StopSystem)
  // Test passes if both sends succeed, proving scope isolation works
}

// Test registry operations (send, call, whereis, unregister)
pub fn registry_operations_test() {
  // Arrange: Create registry and register a service
  let registry =
    registry.new(
      scope: "test_operations",
      decoder: decode_utils.service_message_decoder(),
      error_default: decode_utils.Shutdown,
    )

  let command_subject = process.new_subject()
  let _base_selector =
    process.new_selector() |> process.select_map(command_subject, DirectCommand)

  let assert Ok(_registry_selector) =
    registry.register(registry, "operations_service", "ops_meta")

  // Test whereis
  let assert Ok(#(_pid, metadata)) =
    registry.whereis(registry, "operations_service")
  assert metadata == "ops_meta"

  // Test send
  let assert Ok(_) =
    registry.send(
      registry,
      "operations_service",
      decode_utils.UpdateConfig("key1", "value1"),
    )

  // Test unregister
  let assert Ok(_) = registry.unregister(registry, "operations_service")

  // After unregister, whereis should fail
  let assert Error(registry.ProcessNotFound("operations_service")) =
    registry.whereis(registry, "operations_service")

  // Send should also fail
  let assert Error(registry.ProcessNotFound("operations_service")) =
    registry.send(registry, "operations_service", decode_utils.Shutdown)
}

// Test distributed behavior simulation
pub fn distributed_behavior_simulation_test() {
  // Arrange: Create two registries with same scope and decoder (simulating different nodes)
  let registry1 =
    registry.new(
      scope: "distributed_test",
      decoder: decode_utils.service_message_decoder(),
      error_default: decode_utils.Shutdown,
    )

  let registry2 =
    registry.new(
      scope: "distributed_test",
      // Same scope = distributed behavior
      decoder: decode_utils.service_message_decoder(),
      error_default: decode_utils.Shutdown,
    )

  let command_subject = process.new_subject()
  let _base_selector =
    process.new_selector() |> process.select_map(command_subject, DirectCommand)

  // Register in first "node"
  let assert Ok(_) =
    registry.register(registry1, "distributed_service", "node1_meta")

  // Act: Lookup from second "node"
  let assert Ok(#(_pid, metadata)) =
    registry.whereis(registry2, "distributed_service")

  // Assert: Should find the service registered in the first "node"
  assert metadata == "node1_meta"

  // Send message from second "node" to service in first "node"
  let assert Ok(_) =
    registry.send(
      registry2,
      "distributed_service",
      decode_utils.GetStatus(process.new_subject()),
    )
  // Test passes if cross-node send succeeds, proving distributed behavior
}

// Test error handling for non-existent processes
pub fn error_handling_test() {
  let registry =
    registry.new(
      scope: "test_errors",
      decoder: decode_utils.service_message_decoder(),
      error_default: decode_utils.Shutdown,
    )

  // Test whereis for non-existent process
  let assert Error(registry.ProcessNotFound("nonexistent")) =
    registry.whereis(registry, "nonexistent")

  // Test send to non-existent process
  let assert Error(registry.ProcessNotFound("nonexistent")) =
    registry.send(registry, "nonexistent", decode_utils.Shutdown)

  // Test unregister non-existent process
  case registry.unregister(registry, "nonexistent") {
    Error(registry.UnregistrationFailed(_)) -> Nil
    _ -> panic as "Should have failed to unregister non-existent process"
  }
}
// TODO: Add FFI helper for testing decode errors once registry exposes scope access
// This would require either exposing the scope or adding a test helper to registry module
