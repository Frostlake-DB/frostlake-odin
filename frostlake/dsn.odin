// DSN parsing. frostlake://host[:port][/database][?schema=name] — URL
// conventions: %XX escapes decode (with '+' as space in the query only),
// IPv6 literals are bracketed, and http:// without a port means port 80
// while frostlake:// means the server default, 18082.
package frostlake

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

@(private)
Dsn :: struct {
	host:        string, // owned
	port:        int,
	pending_use: [dynamic]string, // owned USE statements, applied on first execute
}

@(private)
parse_dsn :: proc(dsn: string, allocator: mem.Allocator) -> (out: Dsn, err: Error) {
	scheme_end := strings.index(dsn, "://")
	if scheme_end < 0 {
		return {}, make_error(.Dsn, "DSN must start with frostlake:// or http://", allocator)
	}
	scheme := dsn[:scheme_end]
	rest := dsn[scheme_end + 3:]
	default_port := 0
	if strings.equal_fold(scheme, "frostlake") {
		default_port = 18082
	} else if strings.equal_fold(scheme, "http") {
		default_port = 80
	} else {
		return {}, make_error(.Dsn, "DSN must start with frostlake:// or http://", allocator)
	}

	// The query starts at the first '?' wherever it appears, so a DSN
	// without a path can still carry one: frostlake://host?schema=PUBLIC.
	location := rest
	query := ""
	if q := strings.index_byte(rest, '?'); q >= 0 {
		location = rest[:q]
		query = rest[q + 1:]
	}
	authority := location
	database_part := ""
	if slash := strings.index_byte(location, '/'); slash >= 0 {
		authority = location[:slash]
		database_part = location[slash + 1:]
	}
	if len(authority) == 0 {
		return {}, make_error(.Dsn, "DSN is missing host[:port]", allocator)
	}

	// IPv6 literals are bracketed, URL-style: frostlake://[::1]:18082/db.
	host_text := ""
	port := default_port
	if authority[0] == '[' {
		bracketed := authority[1:]
		closing := strings.index_byte(bracketed, ']')
		if closing < 0 {
			return {}, make_error(.Dsn, "unclosed '[' in DSN host", allocator)
		}
		host_text = bracketed[:closing]
		after := bracketed[closing + 1:]
		if len(after) > 0 {
			if after[0] != ':' {
				return {}, make_errorf(.Dsn, allocator, "unexpected '%s' after IPv6 host", after)
			}
			parsed, ok := parse_port(after[1:])
			if !ok {
				return {}, make_errorf(.Dsn, allocator, "invalid port '%s'", after[1:])
			}
			port = parsed
		}
	} else if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
		host_text = authority[:colon]
		parsed, ok := parse_port(authority[colon + 1:])
		if !ok {
			return {}, make_errorf(.Dsn, allocator, "invalid port '%s'", authority[colon + 1:])
		}
		port = parsed
	} else {
		host_text = authority
	}

	database, database_err := percent_decode(strings.trim(database_part, "/"), false, allocator)
	if database_err != nil {
		return {}, database_err
	}
	defer delete(database, allocator)

	schema := ""
	schema_set := false
	remaining := query
	for pair in strings.split_iterator(&remaining, "&") {
		eq := strings.index_byte(pair, '=')
		if eq < 0 {
			continue
		}
		key := pair[:eq]
		value := pair[eq + 1:]
		if strings.equal_fold(key, "schema") && len(value) > 0 {
			decoded, schema_err := percent_decode(value, true, allocator)
			if schema_err != nil {
				return {}, schema_err
			}
			schema = decoded
			schema_set = true
			break
		}
	}
	defer if schema_set {
		delete(schema, allocator)
	}

	out.pending_use = make([dynamic]string, allocator)
	if len(database) > 0 {
		quoted := quote_ident(database, allocator)
		defer delete(quoted, allocator)
		append(&out.pending_use, fmt.aprintf("USE DATABASE %s", quoted, allocator = allocator))
	}
	if schema_set {
		quoted := quote_ident(schema, allocator)
		defer delete(quoted, allocator)
		append(&out.pending_use, fmt.aprintf("USE SCHEMA %s", quoted, allocator = allocator))
	}
	out.host = strings.clone(host_text, allocator)
	out.port = port
	return out, nil
}

@(private = "file")
parse_port :: proc(text: string) -> (port: int, ok: bool) {
	if len(text) == 0 {
		return 0, false
	}
	value := 0
	for i in 0 ..< len(text) {
		c := text[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		value = value*10 + int(c - '0')
		if value > 65535 {
			return 0, false
		}
	}
	return value, true
}

// Decodes URL %XX escapes (and, in query values, '+' as space), so a DSN can
// name a database or schema containing spaces, slashes or '?'.
@(private)
percent_decode :: proc(text: string, form_encoded: bool, allocator: mem.Allocator) -> (out: string, err: Error) {
	builder := strings.builder_make(allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		if c == '%' {
			if i + 3 > len(text) {
				strings.builder_destroy(&builder)
				return "", make_errorf(.Dsn, allocator, "invalid %%-escape in '%s'", text)
			}
			high, high_ok := hex_digit(text[i + 1])
			low, low_ok := hex_digit(text[i + 2])
			if !high_ok || !low_ok {
				strings.builder_destroy(&builder)
				return "", make_errorf(.Dsn, allocator, "invalid %%-escape in '%s'", text)
			}
			strings.write_byte(&builder, high << 4 | low)
			i += 3
		} else if c == '+' && form_encoded {
			strings.write_byte(&builder, ' ')
			i += 1
		} else {
			strings.write_byte(&builder, c)
			i += 1
		}
	}
	decoded := strings.to_string(builder)
	if !utf8.valid_string(decoded) {
		strings.builder_destroy(&builder)
		return "", make_errorf(.Dsn, allocator, "invalid UTF-8 after %%-decoding '%s'", text)
	}
	return decoded, nil
}

@(private = "file")
hex_digit :: proc(c: u8) -> (value: u8, ok: bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// A valid unquoted identifier passes through bare in either case — the engine
// uppercases it, like Snowflake and like the JDBC driver's URL handling.
// Anything else is quoted, preserving exact case.
@(private)
quote_ident :: proc(name: string, allocator: mem.Allocator) -> string {
	plain := len(name) > 0
	if plain {
		first := name[0]
		plain =
			(first >= 'a' && first <= 'z') ||
			(first >= 'A' && first <= 'Z') ||
			first == '_'
		for i in 1 ..< len(name) {
			if !plain {
				break
			}
			c := name[i]
			plain =
				(c >= 'a' && c <= 'z') ||
				(c >= 'A' && c <= 'Z') ||
				(c >= '0' && c <= '9') ||
				c == '_' ||
				c == '$'
		}
	}
	if plain {
		return strings.clone(name, allocator)
	}
	builder := strings.builder_make(allocator)
	strings.write_byte(&builder, '"')
	for i in 0 ..< len(name) {
		if name[i] == '"' {
			strings.write_string(&builder, "\"\"")
		} else {
			strings.write_byte(&builder, name[i])
		}
	}
	strings.write_byte(&builder, '"')
	return strings.to_string(builder)
}
