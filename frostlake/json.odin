// A minimal JSON parser and string escaper — just enough for the Frostlake
// HTTP protocol, so the package stays dependency-free (core only). Integral
// numbers parse into i128, which holds every NUMBER(38,0) exactly; the core
// json package would not keep them exact past f64.
package frostlake

import "core:mem"
import "core:strconv"
import "core:strings"

@(private = "file")
Json_Parser :: struct {
	data:      string,
	pos:       int,
	allocator: mem.Allocator,
}

// Parses one JSON document into a Value tree owned by the allocator; free it
// with destroy_value.
@(private)
parse_json :: proc(text: string, allocator := context.allocator) -> (value: Value, err: Error) {
	parser := Json_Parser{text, 0, allocator}
	skip_whitespace(&parser)
	value, err = parse_value(&parser)
	if err != nil {
		return nil, err
	}
	skip_whitespace(&parser)
	if parser.pos != len(parser.data) {
		destroy_value(value, allocator)
		return nil, make_errorf(.Json, allocator, "trailing content at byte %d", parser.pos)
	}
	return value, nil
}

// Appends text escaped for embedding in a JSON document (no surrounding quotes).
@(private)
escape_json :: proc(builder: ^strings.Builder, text: string) {
	for i in 0 ..< len(text) {
		c := text[i]
		switch {
		case c == '"':
			strings.write_string(builder, "\\\"")
		case c == '\\':
			strings.write_string(builder, "\\\\")
		case c == '\n':
			strings.write_string(builder, "\\n")
		case c == '\r':
			strings.write_string(builder, "\\r")
		case c == '\t':
			strings.write_string(builder, "\\t")
		case c < 0x20:
			hex := "0123456789abcdef"
			strings.write_string(builder, "\\u00")
			strings.write_byte(builder, hex[c >> 4])
			strings.write_byte(builder, hex[c & 0xF])
		case:
			strings.write_byte(builder, c)
		}
	}
}

// Object member lookup on a parsed tree; nil when absent or not an object.
@(private)
json_get :: proc(value: Value, key: string) -> Value {
	object, ok := value.(Object)
	if !ok {
		return nil
	}
	for member in object {
		if member.key == key {
			return member.value
		}
	}
	return nil
}

@(private = "file")
skip_whitespace :: proc(parser: ^Json_Parser) {
	for parser.pos < len(parser.data) {
		c := parser.data[parser.pos]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			parser.pos += 1
		} else {
			break
		}
	}
}

@(private = "file")
peek :: proc(parser: ^Json_Parser) -> (c: u8, ok: bool) {
	if parser.pos < len(parser.data) {
		return parser.data[parser.pos], true
	}
	return 0, false
}

@(private = "file")
parse_value :: proc(parser: ^Json_Parser) -> (value: Value, err: Error) {
	c, ok := peek(parser)
	if !ok {
		return nil, make_errorf(.Json, parser.allocator, "unexpected end of document at byte %d", parser.pos)
	}
	switch {
	case c == '{':
		return parse_object(parser)
	case c == '[':
		return parse_array(parser)
	case c == '"':
		text, serr := parse_string(parser)
		if serr != nil {
			return nil, serr
		}
		return text, nil
	case c == 't':
		return parse_keyword(parser, "true", true)
	case c == 'f':
		return parse_keyword(parser, "false", false)
	case c == 'n':
		return parse_keyword(parser, "null", nil)
	case c == '-' || (c >= '0' && c <= '9'):
		return parse_number(parser)
	}
	return nil, make_errorf(.Json, parser.allocator, "unexpected '%c' at byte %d", rune(c), parser.pos)
}

@(private = "file")
parse_keyword :: proc(parser: ^Json_Parser, keyword: string, value: Value) -> (Value, Error) {
	if strings.has_prefix(parser.data[parser.pos:], keyword) {
		parser.pos += len(keyword)
		return value, nil
	}
	return nil, make_errorf(.Json, parser.allocator, "invalid token at byte %d", parser.pos)
}

@(private = "file")
parse_object :: proc(parser: ^Json_Parser) -> (value: Value, err: Error) {
	parser.pos += 1 // '{'
	members := make([dynamic]Member, parser.allocator)
	skip_whitespace(parser)
	if c, ok := peek(parser); ok && c == '}' {
		parser.pos += 1
		return Object(members), nil
	}
	for {
		skip_whitespace(parser)
		key, key_err := parse_string(parser)
		if key_err != nil {
			destroy_value(Object(members), parser.allocator)
			return nil, key_err
		}
		skip_whitespace(parser)
		if c, ok := peek(parser); !ok || c != ':' {
			delete(key, parser.allocator)
			destroy_value(Object(members), parser.allocator)
			return nil, make_errorf(.Json, parser.allocator, "expected ':' at byte %d", parser.pos)
		}
		parser.pos += 1
		skip_whitespace(parser)
		member_value, value_err := parse_value(parser)
		if value_err != nil {
			delete(key, parser.allocator)
			destroy_value(Object(members), parser.allocator)
			return nil, value_err
		}
		append(&members, Member{key, member_value})
		skip_whitespace(parser)
		c, ok := peek(parser)
		if ok && c == ',' {
			parser.pos += 1
			continue
		}
		if ok && c == '}' {
			parser.pos += 1
			return Object(members), nil
		}
		destroy_value(Object(members), parser.allocator)
		return nil, make_errorf(.Json, parser.allocator, "expected ',' or '}' at byte %d", parser.pos)
	}
}

@(private = "file")
parse_array :: proc(parser: ^Json_Parser) -> (value: Value, err: Error) {
	parser.pos += 1 // '['
	items := make([dynamic]Value, parser.allocator)
	skip_whitespace(parser)
	if c, ok := peek(parser); ok && c == ']' {
		parser.pos += 1
		return Array(items), nil
	}
	for {
		skip_whitespace(parser)
		item, item_err := parse_value(parser)
		if item_err != nil {
			destroy_value(Array(items), parser.allocator)
			return nil, item_err
		}
		append(&items, item)
		skip_whitespace(parser)
		c, ok := peek(parser)
		if ok && c == ',' {
			parser.pos += 1
			continue
		}
		if ok && c == ']' {
			parser.pos += 1
			return Array(items), nil
		}
		destroy_value(Array(items), parser.allocator)
		return nil, make_errorf(.Json, parser.allocator, "expected ',' or ']' at byte %d", parser.pos)
	}
}

@(private = "file")
parse_string :: proc(parser: ^Json_Parser) -> (text: string, err: Error) {
	if c, ok := peek(parser); !ok || c != '"' {
		return "", make_errorf(.Json, parser.allocator, "expected '\"' at byte %d", parser.pos)
	}
	parser.pos += 1
	builder := strings.builder_make(parser.allocator)
	for {
		start := parser.pos
		for parser.pos < len(parser.data) {
			b := parser.data[parser.pos]
			if b == '"' || b == '\\' {
				break
			}
			parser.pos += 1
		}
		strings.write_string(&builder, parser.data[start:parser.pos])
		c, ok := peek(parser)
		if ok && c == '"' {
			parser.pos += 1
			return strings.to_string(builder), nil
		}
		if ok && c == '\\' {
			parser.pos += 1
			escape_err := parse_escape(parser, &builder)
			if escape_err != nil {
				strings.builder_destroy(&builder)
				return "", escape_err
			}
			continue
		}
		strings.builder_destroy(&builder)
		return "", make_error(.Json, "unterminated string", parser.allocator)
	}
}

@(private = "file")
parse_escape :: proc(parser: ^Json_Parser, builder: ^strings.Builder) -> Error {
	c, ok := peek(parser)
	if !ok {
		return make_error(.Json, "unterminated escape", parser.allocator)
	}
	parser.pos += 1
	switch c {
	case '"':
		strings.write_byte(builder, '"')
	case '\\':
		strings.write_byte(builder, '\\')
	case '/':
		strings.write_byte(builder, '/')
	case 'b':
		strings.write_byte(builder, 0x08)
	case 'f':
		strings.write_byte(builder, 0x0C)
	case 'n':
		strings.write_byte(builder, '\n')
	case 'r':
		strings.write_byte(builder, '\r')
	case 't':
		strings.write_byte(builder, '\t')
	case 'u':
		high, high_err := parse_hex4(parser)
		if high_err != nil {
			return high_err
		}
		code := high
		if high >= 0xD800 && high < 0xDC00 {
			// surrogate pair — the second escape must be a low surrogate
			if !strings.has_prefix(parser.data[parser.pos:], "\\u") {
				return make_error(.Json, "unpaired surrogate", parser.allocator)
			}
			parser.pos += 2
			low, low_err := parse_hex4(parser)
			if low_err != nil {
				return low_err
			}
			if !(low >= 0xDC00 && low < 0xE000) {
				return make_error(.Json, "unpaired surrogate", parser.allocator)
			}
			code = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
		}
		if (code >= 0xD800 && code < 0xE000) || code > 0x10FFFF {
			return make_error(.Json, "invalid code point", parser.allocator)
		}
		strings.write_rune(builder, rune(code))
	case:
		return make_errorf(.Json, parser.allocator, "invalid escape '\\%c'", rune(c))
	}
	return nil
}

@(private = "file")
parse_hex4 :: proc(parser: ^Json_Parser) -> (code: u32, err: Error) {
	if parser.pos + 4 > len(parser.data) {
		return 0, make_error(.Json, "truncated \\u escape", parser.allocator)
	}
	value: u32 = 0
	for i in 0 ..< 4 {
		c := parser.data[parser.pos + i]
		digit: u32
		switch {
		case c >= '0' && c <= '9':
			digit = u32(c - '0')
		case c >= 'a' && c <= 'f':
			digit = u32(c - 'a' + 10)
		case c >= 'A' && c <= 'F':
			digit = u32(c - 'A' + 10)
		case:
			return 0, make_error(.Json, "invalid \\u escape", parser.allocator)
		}
		value = value << 4 | digit
	}
	parser.pos += 4
	return value, nil
}

@(private = "file")
parse_number :: proc(parser: ^Json_Parser) -> (value: Value, err: Error) {
	start := parser.pos
	fractional := false
	scan: for parser.pos < len(parser.data) {
		switch parser.data[parser.pos] {
		case '0' ..= '9', '-', '+':
			parser.pos += 1
		case '.', 'e', 'E':
			fractional = true
			parser.pos += 1
		case:
			break scan
		}
	}
	text := parser.data[start:parser.pos]
	if !fractional {
		consumed := 0
		integral, ok := strconv.parse_i128_of_base(text, 10, &consumed)
		if ok && consumed == len(text) {
			return integral, nil
		}
	}
	consumed := 0
	floating, ok := strconv.parse_f64(text, &consumed)
	if ok && consumed == len(text) {
		return floating, nil
	}
	return nil, make_errorf(.Json, parser.allocator, "invalid number '%s'", text)
}
