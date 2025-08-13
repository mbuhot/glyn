import gleam/list
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom

import gleam/string

import gleam/json

// FFI to convert any Gleam value to Dynamic
@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: a) -> Dynamic

////
//// GLEAM DYNAMIC DECODING PATTERNS
////
//// This test file demonstrates the key differences between decoding JSON-like data
//// and decoding native Gleam data structures from Dynamic values.
////
//// KEY INSIGHT: Gleam data structures are encoded as tuples (Arrays), not objects
//// with named fields. This means we use `decode.at(index, decoder)` instead of
//// `decode.field(name, decoder)` to access structure elements.
////
//// ENCODING PATTERNS:
////
//// 1. RECORDS: Encoded as tuples with constructor tag at index 0
////    SimpleRecord("Alice", 30) -> {simple_record, "Alice", 30}
////    Access: decode.field(1, decode.string) for first field
////            decode.field(2, decode.int) for second field
////    Note: Constructor names are converted PascalCase -> snake_case
////
//// 2. TUPLES: Direct tuple encoding, 0-based indexing (no constructor tag)
////    #("hello", 42, True) -> {"hello", 42, true}
////    Access: decode.field(0, decode.string), decode.field(1, decode.int), etc.
////
//// 3. SIMPLE VARIANTS: Encoded as atoms
////    Red -> red (atom)
////    Classification: "Atom"
////
//// 4. COMPLEX VARIANTS: Encoded as tuples with constructor tag
////    Custom("purple") -> {custom, "purple"}
////    Access: decode.field(1, decode.string) for the data
////    Note: Constructor names are converted PascalCase -> snake_case
////
//// 5. RESULT TYPES: Encoded as tuples
////    Ok("success") -> {ok, "success"}
////    Error("fail") -> {error, "fail"}
////    Access: decode.field(1, decoder) for the wrapped value
////
//// 6. LISTS: Encoded as proper lists, use decode.list(element_decoder)
////    [1, 2, 3] -> [1, 2, 3]
////    Classification: "List"
////
//// CLASSIFICATION MAPPING:
//// - Records, complex variants, Result types, tuples -> "Array"
//// - Simple variants without data -> "Atom"
//// - Lists -> "List"
//// - Primitives -> "String", "Int", "Bool", "Float"
////
//// This is fundamentally different from JSON decoding where you would use
//// field names: decode.field("name", decode.string)
////
//// For Gleam data, there are two approaches:
//// - decode.at([1], decode.string) for direct tuple access in decode.run()
//// - decode.field(1, decode.string) with use syntax when building decoders


fn expect_value(value, decoder) {
  use decoded <- decode.then(decoder)
  case decoded == value {
    True -> decode.success(decoded)
    False -> decode.failure(decoded, "Exactly: " <> string.inspect(value))
  }
}

// Test data types
pub type SimpleRecord {
  SimpleRecord(name: String, age: Int)
}

fn simple_record_to_json(simple_record: SimpleRecord) -> json.Json {
  let SimpleRecord(name:, age:) = simple_record
  json.object([
    #("name", json.string(name)),
    #("age", json.int(age)),
  ])
}

fn simple_record_decoder() -> decode.Decoder(SimpleRecord) {
  decode.one_of(simple_record_dynamic_decoder(), or: [simple_record_json_decoder()])
}

fn simple_record_json_decoder() -> decode.Decoder(SimpleRecord) {
  use name <- decode.field("name", decode.string)
  use age <- decode.field("age", decode.int)
  decode.success(SimpleRecord(name:, age:))
}

fn simple_record_dynamic_decoder() -> decode.Decoder(SimpleRecord) {
  use _tag <- decode.field(0, expect_value(atom.create("simple_record"), atom.decoder()))
  use name <- decode.field(1, decode.string)
  use age <- decode.field(2, decode.int)
  decode.success(SimpleRecord(name:, age:))
}

pub type Color {
  Red
  Green
  Blue
  Custom(name: String)
}

fn decode_color() -> decode.Decoder(Color) {
  decode.one_of(
    decode.map(expect_value(atom.create("red"), atom.decoder()), fn(_) { Red }),
    or: [
      decode.map(expect_value(atom.create("green"), atom.decoder()), fn(_) { Green }),
      decode.map(expect_value(atom.create("blue"), atom.decoder()), fn(_) { Blue }),
      {
        use _ <- decode.field(0, expect_value(atom.create("custom"), atom.decoder()))
        use name <- decode.field(1, decode.string)
        decode.success(Custom(name))
      }
    ]
  )
}

pub type ComplexRecord {
  ComplexRecord(id: Int, colors: List(Color), record: SimpleRecord)
}

fn decode_complex_record() -> decode.Decoder(ComplexRecord) {
  {
    use _ <- decode.field(0, expect_value(atom.create("complex_record"), atom.decoder()))
    use id <- decode.field(1, decode.int)
    use colors <- decode.field(2, decode.list(decode_color()))
    use record <- decode.field(3, simple_record_decoder())
    decode.success(ComplexRecord(id, colors, record))
  }
}

// Basic decoding tests
pub fn simple_record_decoding_test() {
  let simple_record = SimpleRecord("Alice", 30)
  let simple_dynamic = to_dynamic(simple_record)
  let simple_record_json = simple_record |> simple_record_to_json() |> json.to_string()

  assert Ok(simple_record) == decode.run(simple_dynamic, simple_record_decoder())
  assert Ok(simple_record) == json.parse(simple_record_json, simple_record_decoder())
}

pub fn simple_record_decoding_failure_test() {
  let simple_record = #(atom.create("wrong_tag"), "Bob", 25)
  let simple_dynamic = to_dynamic(simple_record)
  let assert Error(decode_errors) = decode.run(simple_dynamic, simple_record_decoder())
  let assert Ok(error) =  decode_errors |> list.first()
  assert error.expected == "Exactly: SimpleRecord"
  assert error.found == "Atom"
  assert error.path == ["0"]
}

pub fn color_decoder_test() {
  assert Ok(Red) == decode.run(to_dynamic(Red), decode_color())
  assert Ok(Green) == decode.run(to_dynamic(Green), decode_color())
  assert Ok(Blue) == decode.run(to_dynamic(Blue), decode_color())

  // Test Custom variant (tuple)
  let custom = Custom("orange")
  assert Ok(Custom("orange")) == decode.run(to_dynamic(custom), decode_color())

  // Test that invalid color fails
  let invalid_atom = to_dynamic(atom.create("yellow"))
  let assert Error(_) = decode.run(invalid_atom, decode_color())
}

pub fn complex_record_decode_successfully_test() {
  let complex = ComplexRecord(
    id: 42,
    colors: [Red, Custom("blue")],
    record: SimpleRecord("test", 25)
  )
  let complex_dynamic = to_dynamic(complex)
  assert Ok(complex) == decode.run(complex_dynamic, decode_complex_record())
}

pub fn complex_record_decode_failure_test() {
  // Test what happens when we try to decode wrong record type
  let complex = ComplexRecord(42, [Red], SimpleRecord("nested", 25))
  let complex_dynamic = to_dynamic(complex)
  let assert Error(errors) = decode.run(complex_dynamic, simple_record_decoder())
  assert errors != []
}
