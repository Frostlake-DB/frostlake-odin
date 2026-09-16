package frostlake

import "core:strings"
import "core:testing"

@(test)
test_json_parses_numbers_in_every_shape :: proc(t: ^testing.T) {
	expect_parsed(t, "0", i128(0))
	expect_parsed(t, "-42", i128(-42))
	expect_parsed(t, "9.5", 9.5)
	expect_parsed(t, "-2.5e-2", -0.025)
	expect_parsed(t, "1E3", f64(1000))
	// A decimal that happens to be integral still stays f64 — the wire's
	// "9.0" is a scaled NUMBER or FLOAT, not an integer.
	expect_parsed(t, "9.0", f64(9))
	expect_parse_error(t, "1-2")
	// Integral NUMBER stays exact far past i64.
	expect_parsed(t, "12345678901234567890123456789", i128(12345678901234567890123456789))
}

@(test)
test_json_parses_keywords_and_empty_containers :: proc(t: ^testing.T) {
	expect_parsed(t, "null", nil)
	expect_parsed(t, "false", false)

	empty_array, array_err := parse_json("[]")
	testing.expect(t, array_err == nil)
	items, is_array := empty_array.(Array)
	testing.expect(t, is_array && len(items) == 0)
	destroy_value(empty_array)

	empty_object, object_err := parse_json("{}")
	testing.expect(t, object_err == nil)
	members, is_object := empty_object.(Object)
	testing.expect(t, is_object && len(members) == 0)
	destroy_value(empty_object)

	mixed, mixed_err := parse_json(" [ null , {\"a\" : 1} ] ")
	testing.expect(t, mixed_err == nil)
	mixed_items, _ := mixed.(Array)
	testing.expect(t, len(mixed_items) == 2)
	testing.expect(t, mixed_items[0] == nil)
	testing.expect(t, values_equal(json_get(mixed_items[1], "a"), i128(1)))
	destroy_value(mixed)
}

@(test)
test_json_rejects_malformed_documents :: proc(t: ^testing.T) {
	expect_parse_error(t, "")
	expect_parse_error(t, "{\"a\":1} extra")
	expect_parse_error(t, "\"unterminated")
	expect_parse_error(t, "{\"a\"}")
	expect_parse_error(t, "[1,]")
	expect_parse_error(t, "nulL")
	expect_parse_error(t, "\"bad \\x escape\"")
}

@(test)
test_json_unescapes_strings :: proc(t: ^testing.T) {
	value, err := parse_json("\"a\\n\\\"b\\\\c\\u00e9\\ud83d\\ude00\"")
	testing.expect(t, err == nil)
	testing.expect(t, values_equal(value, "a\n\"b\\cé😀"))
	destroy_value(value)
	// A malformed pair is an error, not a crash: high surrogate followed by
	// a non-surrogate escape, and a lone high surrogate at end of string.
	expect_parse_error(t, "\"\\ud83d\\u0041\"")
	expect_parse_error(t, "\"\\ud83dx\"")
}

@(test)
test_json_escape_survives_a_parse_round_trip :: proc(t: ^testing.T) {
	original := "a\"b\\c\nd\re\tf\u0001g é😀"
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_byte(&builder, '"')
	escape_json(&builder, original)
	strings.write_byte(&builder, '"')
	value, err := parse_json(strings.to_string(builder))
	testing.expect(t, err == nil)
	testing.expect(t, values_equal(value, original))
	destroy_value(value)
}

@(test)
test_json_parses_the_protocol_shapes :: proc(t: ^testing.T) {
	value, err := parse_json(
		"{\"success\":true,\"resultSets\":[{\"columns\":[{\"name\":\"N\"}],\"rows\":[[12345678901234567890123456789]]}]}",
	)
	testing.expect(t, err == nil)
	testing.expect(t, values_equal(json_get(value, "success"), true))
	sets, _ := json_get(value, "resultSets").(Array)
	rows, _ := json_get(sets[0], "rows").(Array)
	first_row, _ := rows[0].(Array)
	testing.expect(t, values_equal(first_row[0], i128(12345678901234567890123456789)))
	destroy_value(value)
}

@(private = "file")
expect_parsed :: proc(t: ^testing.T, text: string, expected: Value, loc := #caller_location) {
	value, err := parse_json(text)
	if !testing.expectf(t, err == nil, "parse_json(%s) failed: %s", text, error_message(err), loc = loc) {
		destroy_error(err)
		return
	}
	testing.expectf(t, values_equal(value, expected), "parse_json(%s) = %v, want %v", text, value, expected, loc = loc)
	destroy_value(value)
}

@(private = "file")
expect_parse_error :: proc(t: ^testing.T, text: string, loc := #caller_location) {
	value, err := parse_json(text)
	if !testing.expectf(t, err != nil, "parse_json(%s) unexpectedly succeeded: %v", text, value, loc = loc) {
		destroy_value(value)
		return
	}
	destroy_error(err)
}
