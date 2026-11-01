// Client-side parameter binding: '?' placeholders are replaced with SQL
// literals before the statement is sent (the protocol has no server-side
// binding), with the same rules as Frostlake's other drivers.
package frostlake

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

// Replaces '?' placeholders with SQL literals, leaving placeholders inside
// string literals (both '' and \' escape), dollar-quoted $$…$$ strings,
// quoted identifiers and --,//,/* */ comments untouched. Errs when the bind
// count does not match the placeholder count, in either direction.
substitute :: proc(sql: string, binds: []Value, allocator := context.allocator) -> (out: string, err: Error) {
	builder := strings.builder_make(allocator)
	plain := 0
	next := 0
	i := 0
	for i < len(sql) {
		c := sql[i]
		if c == '\'' {
			i = skip_sql_string(sql, i)
		} else if c == '"' {
			i = skip_quoted_ident(sql, i)
		} else if c == '-' && i + 1 < len(sql) && sql[i + 1] == '-' {
			i = skip_line(sql, i)
		} else if c == '/' && i + 1 < len(sql) && sql[i + 1] == '*' {
			i = skip_block_comment(sql, i + 2)
		} else if c == '/' && i + 1 < len(sql) && sql[i + 1] == '/' {
			i = skip_line(sql, i)
		} else if is_name_start(c) {
			// A name is read whole, as the lexer reads one: the $$ in a$$b opens no body.
			i = skip_name(sql, i)
		} else if c == '$' && i + 1 < len(sql) && sql[i + 1] == '$' {
			i = skip_dollar_quoted(sql, i + 2)
		} else if c == '?' {
			strings.write_string(&builder, sql[plain:i])
			if next >= len(binds) {
				strings.builder_destroy(&builder)
				return "", make_error(.Usage, "not enough bind values for placeholders", allocator)
			}
			literal, literal_err := format_literal(binds[next], allocator)
			if literal_err != nil {
				strings.builder_destroy(&builder)
				return "", literal_err
			}
			strings.write_string(&builder, literal)
			delete(literal, allocator)
			next += 1
			i += 1
			plain = i
		} else {
			i += 1
		}
	}
	strings.write_string(&builder, sql[plain:])
	if next < len(binds) {
		strings.builder_destroy(&builder)
		plural := "" if next == 1 else "s"
		return "", make_errorf(.Usage, allocator, "too many bind values: %d given, %d placeholder%s", len(binds), next, plural)
	}
	return strings.to_string(builder), nil
}

// Renders one bind value as a SQL literal.
format_literal :: proc(value: Value, allocator := context.allocator) -> (out: string, err: Error) {
	switch v in value {
	case nil:
		return strings.clone("NULL", allocator), nil
	case bool:
		return strings.clone("TRUE" if v else "FALSE", allocator), nil
	case i128:
		return signed(fmt.aprintf("%d", v, allocator = allocator), allocator), nil
	case f64:
		if math.is_nan(v) || math.is_inf(v, 0) {
			return "", make_errorf(.Usage, allocator, "non-finite number %v", v)
		}
		return signed(fmt.aprintf("%v", v, allocator = allocator), allocator), nil
	case string:
		return encode_sql_string(v, allocator), nil
	case Bytes:
		hex := "0123456789ABCDEF"
		builder := strings.builder_make(allocator)
		strings.write_string(&builder, "X'")
		for b in v {
			strings.write_byte(&builder, hex[b >> 4])
			strings.write_byte(&builder, hex[b & 0xF])
		}
		strings.write_byte(&builder, '\'')
		return strings.to_string(builder), nil
	case Date:
		quoted := encode_sql_string(v.text, allocator)
		defer delete(quoted, allocator)
		return fmt.aprintf("%s::DATE", quoted, allocator = allocator), nil
	case Timestamp:
		quoted := encode_sql_string(v.text, allocator)
		defer delete(quoted, allocator)
		return fmt.aprintf("%s::TIMESTAMP_NTZ", quoted, allocator = allocator), nil
	case Array:
		builder := strings.builder_make(allocator)
		strings.write_byte(&builder, '[')
		for item, index in v {
			if index > 0 {
				strings.write_string(&builder, ", ")
			}
			part, part_err := format_literal(item, allocator)
			if part_err != nil {
				strings.builder_destroy(&builder)
				return "", part_err
			}
			strings.write_string(&builder, part)
			delete(part, allocator)
		}
		strings.write_byte(&builder, ']')
		return strings.to_string(builder), nil
	case Object:
		return "", make_error(.Usage, "unsupported bind type object", allocator)
	}
	return strings.clone("NULL", allocator), nil
}

// Parenthesises a numeral that starts with '-', which is then one value wherever
// it lands: bare, 3-? bound to -5 would read 3--5, a line comment, and ?::VARCHAR
// would cast before it negates. The rendered text decides, not a < 0 test, so
// negative zero (rendered -0) is wrapped too. Takes ownership of numeral.
@(private = "file")
signed :: proc(numeral: string, allocator: mem.Allocator) -> string {
	if !strings.has_prefix(numeral, "-") {
		return numeral
	}
	wrapped := fmt.aprintf("(%s)", numeral, allocator = allocator)
	delete(numeral, allocator)
	return wrapped
}

@(private = "file")
encode_sql_string :: proc(text: string, allocator: mem.Allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_byte(&builder, '\'')
	for i in 0 ..< len(text) {
		switch text[i] {
		case '\\':
			strings.write_string(&builder, "\\\\")
		case '\'':
			strings.write_string(&builder, "''")
		case:
			strings.write_byte(&builder, text[i])
		}
	}
	strings.write_byte(&builder, '\'')
	return strings.to_string(builder)
}

@(private)
skip_sql_string :: proc(sql: string, start: int) -> int {
	j := start + 1
	for j < len(sql) {
		if sql[j] == '\\' {
			j += 2 // backslash always escapes
		} else if sql[j] == '\'' {
			if j + 1 < len(sql) && sql[j + 1] == '\'' {
				j += 2
			} else {
				return j + 1
			}
		} else {
			j += 1
		}
	}
	return min(j, len(sql))
}

@(private)
skip_quoted_ident :: proc(sql: string, start: int) -> int {
	j := start + 1
	for j < len(sql) {
		if sql[j] == '"' {
			if j + 1 < len(sql) && sql[j + 1] == '"' {
				j += 2
				continue
			}
			return j + 1
		}
		j += 1
	}
	return j
}

// A line comment ends at a line feed or a carriage return, whichever comes
// first, as the lexer's LINE_COMMENT does: ('--' | '//') ~[\r\n]*.
@(private)
skip_line :: proc(sql: string, start: int) -> int {
	for j in start ..< len(sql) {
		if sql[j] == '\n' || sql[j] == '\r' {
			return j + 1
		}
	}
	return len(sql)
}

@(private)
is_name_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

@(private = "file")
is_name_part :: proc(c: u8) -> bool {
	return is_name_start(c) || (c >= '0' && c <= '9') || c == '$'
}

// The end of the name that starts at start, read as the lexer reads an
// IDENTIFIER: [a-zA-Z_][a-zA-Z0-9_$]*.
@(private)
skip_name :: proc(sql: string, start: int) -> int {
	j := start + 1
	for j < len(sql) && is_name_part(sql[j]) {
		j += 1
	}
	return j
}

@(private)
skip_block_comment :: proc(sql: string, start: int) -> int {
	j := start
	for j + 1 < len(sql) {
		if sql[j] == '*' && sql[j + 1] == '/' {
			return j + 2
		}
		j += 1
	}
	return len(sql)
}

// Non-greedy to the next $$, like the grammar's DOLLAR_QUOTED_STRING: '$$' .*? '$$'.
@(private)
skip_dollar_quoted :: proc(sql: string, start: int) -> int {
	j := start
	for j + 1 < len(sql) {
		if sql[j] == '$' && sql[j + 1] == '$' {
			return j + 2
		}
		j += 1
	}
	return len(sql)
}
