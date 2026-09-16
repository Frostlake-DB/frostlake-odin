package frostlake

import "core:testing"

@(test)
test_dsn_extracts_database_and_schema :: proc(t: ^testing.T) {
	// Valid identifiers travel bare in either case (the engine uppercases
	// them, Snowflake-style); anything else is quoted with its exact case.
	conn, err := open("frostlake://localhost:1234/My_DB?schema=public")
	testing.expect(t, err == nil)
	testing.expect_value(t, conn.host, "localhost")
	testing.expect_value(t, conn.port, 1234)
	testing.expect_value(t, len(conn.pending_use), 2)
	testing.expect_value(t, conn.pending_use[0], "USE DATABASE My_DB")
	testing.expect_value(t, conn.pending_use[1], "USE SCHEMA public")
	destroy_connection(&conn)

	quoted, quoted_err := open("frostlake://localhost/my-db?schema=2fast")
	testing.expect(t, quoted_err == nil)
	testing.expect_value(t, quoted.port, 18082)
	testing.expect_value(t, quoted.pending_use[0], "USE DATABASE \"my-db\"")
	testing.expect_value(t, quoted.pending_use[1], "USE SCHEMA \"2fast\"")
	destroy_connection(&quoted)
}

@(test)
test_dsn_handles_url_shapes :: proc(t: ^testing.T) {
	// A query without a path.
	no_path, no_path_err := open("frostlake://localhost?schema=PUBLIC")
	testing.expect(t, no_path_err == nil)
	testing.expect_value(t, no_path.host, "localhost")
	testing.expect_value(t, len(no_path.pending_use), 1)
	testing.expect_value(t, no_path.pending_use[0], "USE SCHEMA PUBLIC")
	destroy_connection(&no_path)

	// http:// keeps URL semantics: default port 80, like the other drivers.
	expect_dsn_port(t, "http://localhost/db", 80)
	expect_dsn_port(t, "frostlake://localhost", 18082)

	// Bracketed IPv6 literals, with and without a port.
	v6, v6_err := open("frostlake://[::1]:9999/db")
	testing.expect(t, v6_err == nil)
	testing.expect_value(t, v6.host, "::1")
	testing.expect_value(t, v6.port, 9999)
	destroy_connection(&v6)
	expect_dsn_port(t, "frostlake://[::1]/db", 18082)

	// %-escapes decode in path and query; '+' means space only in the query.
	decoded, decoded_err := open("frostlake://h/my%20db?schema=a+b%3F")
	testing.expect(t, decoded_err == nil)
	testing.expect_value(t, decoded.pending_use[0], "USE DATABASE \"my db\"")
	testing.expect_value(t, decoded.pending_use[1], "USE SCHEMA \"a b?\"")
	destroy_connection(&decoded)

	plus_in_path, plus_err := open("frostlake://h/a+b")
	testing.expect(t, plus_err == nil)
	testing.expect_value(t, plus_in_path.pending_use[0], "USE DATABASE \"a+b\"")
	destroy_connection(&plus_in_path)

	unicode, unicode_err := open("frostlake://h/caf%C3%A9")
	testing.expect(t, unicode_err == nil)
	testing.expect_value(t, unicode.pending_use[0], "USE DATABASE \"café\"")
	destroy_connection(&unicode)

	expect_dsn_error(t, "frostlake://h/bad%zz")
	expect_dsn_error(t, "ftp://h/db")
	expect_dsn_error(t, "frostlake://[::1/db")
	expect_dsn_error(t, "frostlake:///db")
	expect_dsn_error(t, "frostlake://h:not_a_port/db")
	expect_dsn_error(t, "localhost:18082")
}

@(test)
test_quote_ident_doubles_embedded_quotes :: proc(t: ^testing.T) {
	expect_quoted(t, "we\"ird", "\"we\"\"ird\"")
	expect_quoted(t, "_ok$2", "_ok$2")
	expect_quoted(t, "$lead", "\"$lead\"")
	expect_quoted(t, "", "\"\"")
}

@(private = "file")
expect_dsn_port :: proc(t: ^testing.T, dsn: string, port: int, loc := #caller_location) {
	conn, err := open(dsn)
	if !testing.expectf(t, err == nil, "open(%s) failed: %s", dsn, error_message(err), loc = loc) {
		destroy_error(err)
		return
	}
	testing.expectf(t, conn.port == port, "open(%s) port = %d, want %d", dsn, conn.port, port, loc = loc)
	destroy_connection(&conn)
}

@(private = "file")
expect_dsn_error :: proc(t: ^testing.T, dsn: string, loc := #caller_location) {
	conn, err := open(dsn)
	if !testing.expectf(t, err != nil, "open(%s) unexpectedly succeeded", dsn, loc = loc) {
		destroy_connection(&conn)
		return
	}
	destroy_error(err)
}

@(private = "file")
expect_quoted :: proc(t: ^testing.T, name: string, expected: string, loc := #caller_location) {
	quoted := quote_ident(name, context.allocator)
	testing.expectf(t, quoted == expected, "quote_ident(%s) = %s, want %s", name, quoted, expected, loc = loc)
	delete(quoted)
}
