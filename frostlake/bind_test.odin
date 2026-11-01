package frostlake

import "core:strings"
import "core:testing"

@(test)
test_substitution_skips_literals_identifiers_and_comments :: proc(t: ^testing.T) {
	expect_substituted(
		t,
		"SELECT 'a?b', \"c?d\", ? -- e?f\n, ? /* g?h */",
		{"x", i128(2)},
		"SELECT 'a?b', \"c?d\", 'x' -- e?f\n, 2 /* g?h */",
	)
}

@(test)
test_substitution_string_encoding_doubles_backslashes_then_quotes :: proc(t: ^testing.T) {
	expect_substituted(t, "SELECT ?", {"Ada O'Hara \\ Byron"}, "SELECT 'Ada O''Hara \\\\ Byron'")
}

@(test)
test_substitution_skips_slash_slash_comments :: proc(t: ^testing.T) {
	expect_substituted(t, "SELECT ? // c?d\n, ?", {i128(1), i128(2)}, "SELECT 1 // c?d\n, 2")
}

@(test)
test_substitution_skips_dollar_quoted_strings :: proc(t: ^testing.T) {
	expect_substituted(t, "SELECT $$a?b$$ AS s, ? AS n", {i128(7)}, "SELECT $$a?b$$ AS s, 7 AS n")
	// An unterminated $$ swallows the rest, like the grammar's non-greedy lexer rule.
	expect_substituted(t, "SELECT $$a?b", {}, "SELECT $$a?b")
}

@(test)
test_substitution_reads_a_name_whole_so_its_dollars_open_no_body :: proc(t: ^testing.T) {
	expect_substituted(t, "SELECT 1 AS a$$b, ?", {i128(7)}, "SELECT 1 AS a$$b, 7")
	expect_substituted(t, "SELECT a$$b, $$c?d$$, ?", {i128(7)}, "SELECT a$$b, $$c?d$$, 7")
}

@(test)
test_substitution_ends_a_line_comment_at_a_carriage_return :: proc(t: ^testing.T) {
	expect_substituted(t, "SELECT 1 -- c\r, ?", {i128(7)}, "SELECT 1 -- c\r, 7")
	expect_substituted(t, "SELECT 1 // c\r, ?", {i128(7)}, "SELECT 1 // c\r, 7")
	expect_substituted(t, "SELECT 1 -- c?\r\n, ?", {i128(7)}, "SELECT 1 -- c?\r\n, 7")
}

@(test)
test_negative_numbers_are_parenthesised :: proc(t: ^testing.T) {
	expect_substituted(t, "SELECT 3-?", {i128(-5)}, "SELECT 3-(-5)")
	expect_substituted(t, "SELECT ?::VARCHAR", {i128(-5)}, "SELECT (-5)::VARCHAR")
	expect_substituted(t, "SELECT 3-?", {f64(-2.5)}, "SELECT 3-(-2.5)")
	expect_substituted(t, "SELECT ?::VARCHAR", {f64(-2.5)}, "SELECT (-2.5)::VARCHAR")
	expect_substituted(
		t,
		"SELECT 3-?",
		{i128(-170141183460469231731687303715884105728)},
		"SELECT 3-(-170141183460469231731687303715884105728)",
	)
	expect_substituted(t, "SELECT 3-?", {i128(5)}, "SELECT 3-5")
	// Negative zero is not below zero, but it renders with a minus all the same.
	negative_zero := f64(0)
	negative_zero = -negative_zero
	expect_substituted(t, "SELECT 3-?", {negative_zero}, "SELECT 3-(-0)")
	expect_substituted(t, "SELECT ?::VARCHAR", {negative_zero}, "SELECT (-0)::VARCHAR")
}

@(test)
test_substitution_rejects_bind_count_mismatch :: proc(t: ^testing.T) {
	_, not_enough := substitute("SELECT ?, ?", {i128(1)})
	testing.expect(t, strings.contains(error_message(not_enough), "not enough bind values"))
	destroy_error(not_enough)

	_, too_many := substitute("SELECT ?", {i128(1), i128(2)})
	testing.expect_value(t, error_message(too_many), "too many bind values: 2 given, 1 placeholder")
	destroy_error(too_many)
}

@(test)
test_typed_literal_formatting :: proc(t: ^testing.T) {
	expect_literal(t, nil, "NULL")
	expect_literal(t, true, "TRUE")
	expect_literal(t, 9.5, "9.5")
	expect_literal(t, Bytes{0xCA, 0xFE}, "X'CAFE'")
	expect_literal(t, Timestamp{"2026-01-02T03:04:05"}, "'2026-01-02T03:04:05'::TIMESTAMP_NTZ")

	items := Array(make([dynamic]Value))
	append(&items, i128(1))
	append(&items, "a")
	expect_literal(t, items, "[1, 'a']")
	delete(items) // the "a" element is a literal, so only the container is heap

}

@(test)
test_typed_literal_formatting_edges :: proc(t: ^testing.T) {
	expect_literal(t, i128(-7), "(-7)")
	expect_literal(t, Date{"2026-08-19"}, "'2026-08-19'::DATE")
	expect_literal(t, Bytes{}, "X''")

	nested_inner := Array(make([dynamic]Value))
	append(&nested_inner, nil)
	nested := Array(make([dynamic]Value))
	append(&nested, nested_inner)
	expect_literal(t, nested, "[[NULL]]")
	destroy_value(nested)

	nan := f64(0)
	nan = nan / nan
	expect_literal_error(t, nan)
	infinity := f64(1e308) * 10
	expect_literal_error(t, infinity)
	empty_object: Object
	expect_literal_error(t, empty_object)
}

@(private = "file")
expect_substituted :: proc(t: ^testing.T, sql: string, binds: []Value, expected: string, loc := #caller_location) {
	rendered, err := substitute(sql, binds)
	if !testing.expectf(t, err == nil, "substitute(%s) failed: %s", sql, error_message(err), loc = loc) {
		destroy_error(err)
		return
	}
	testing.expectf(t, rendered == expected, "substitute(%s) = %s, want %s", sql, rendered, expected, loc = loc)
	delete(rendered)
}

@(private = "file")
expect_literal :: proc(t: ^testing.T, value: Value, expected: string, loc := #caller_location) {
	literal, err := format_literal(value)
	if !testing.expectf(t, err == nil, "format_literal(%v) failed: %s", value, error_message(err), loc = loc) {
		destroy_error(err)
		return
	}
	testing.expectf(t, literal == expected, "format_literal(%v) = %s, want %s", value, literal, expected, loc = loc)
	delete(literal)
}

@(private = "file")
expect_literal_error :: proc(t: ^testing.T, value: Value, loc := #caller_location) {
	literal, err := format_literal(value)
	if !testing.expectf(t, err != nil, "format_literal(%v) unexpectedly succeeded: %s", value, literal, loc = loc) {
		delete(literal)
		return
	}
	destroy_error(err)
}
