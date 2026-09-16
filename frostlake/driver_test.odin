package frostlake

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_round_trips_learn_and_echo_the_session_id :: proc(t: ^testing.T) {
	ok := "{\"success\":true,\"sessionId\":\"s-1\",\"resultSets\":[]}"
	exchanges := []Canned_Exchange{{200, ok}, {200, ok}, {200, ok}, {200, ok}, {200, ok}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)

	dsn := fmt.aprintf("frostlake://127.0.0.1:%d", server.port)
	defer delete(dsn)
	conn, open_err := open(dsn)
	testing.expect(t, open_err == nil)
	defer destroy_connection(&conn)

	exec_discard(t, &conn, "SELECT 1")
	begin_err := begin(&conn)
	testing.expect(t, begin_err == nil)
	exec_discard(t, &conn, "SELECT 2")
	commit_err := commit(&conn)
	testing.expect(t, commit_err == nil)
	exec_discard(t, &conn, "SELECT 3")

	seen := loopback_finish(server)
	testing.expect_value(t, len(seen), 5)
	// The first request carries no session yet; every later one echoes the
	// id the server issued.
	testing.expectf(t, !strings.contains(seen[0], "sessionId"), "request was: %s", seen[0])
	testing.expectf(t, strings.contains(seen[1], "\"sessionId\":\"s-1\""), "request was: %s", seen[1])
	testing.expectf(t, strings.contains(seen[4], "\"sessionId\":\"s-1\""), "request was: %s", seen[4])
	// BEGIN flips autoCommit off for the whole transaction (the COMMIT
	// statement included); COMMIT restores it for what follows.
	testing.expectf(t, strings.contains(seen[0], "\"autoCommit\":true"), "request was: %s", seen[0])
	testing.expectf(t, strings.contains(seen[1], "BEGIN") && strings.contains(seen[1], "\"autoCommit\":false"), "request was: %s", seen[1])
	testing.expectf(t, strings.contains(seen[2], "\"autoCommit\":false"), "request was: %s", seen[2])
	testing.expectf(t, strings.contains(seen[3], "COMMIT") && strings.contains(seen[3], "\"autoCommit\":false"), "request was: %s", seen[3])
	testing.expectf(t, strings.contains(seen[4], "\"autoCommit\":true"), "request was: %s", seen[4])
}

@(test)
test_a_request_declares_a_statement_count_only_when_one_is_asked_for :: proc(t: ^testing.T) {
	ok := "{\"success\":true,\"sessionId\":\"s-1\",\"resultSets\":[]}"
	exchanges := []Canned_Exchange{{200, ok}, {200, ok}, {200, ok}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)

	dsn := fmt.aprintf("frostlake://127.0.0.1:%d", server.port)
	defer delete(dsn)
	conn, open_err := open(dsn)
	testing.expect(t, open_err == nil)
	defer destroy_connection(&conn)

	exec_discard(t, &conn, "SELECT 1")
	exec_counted_discard(t, &conn, "SELECT 1; SELECT 2", 2)
	exec_counted_discard(t, &conn, "SELECT 1; SELECT 2; SELECT 3", 0)

	seen := loopback_finish(server)
	testing.expect_value(t, len(seen), 3)
	// Nothing asked for a count, so the body carries no such field at all — not
	// null, not zero — and the session answers for the request as it always has.
	testing.expectf(t, !strings.contains(seen[0], "multiStatementCount"), "request was: %s", seen[0])
	testing.expectf(t, strings.contains(seen[1], "\"multiStatementCount\":2"), "request was: %s", seen[1])
	// Zero is a count like any other — any number of statements — not an absent one.
	testing.expectf(t, strings.contains(seen[2], "\"multiStatementCount\":0"), "request was: %s", seen[2])
}

@(test)
test_failed_statements_surface_the_engine_message :: proc(t: ^testing.T) {
	exchanges := []Canned_Exchange{
		{400, "{\"success\":false,\"errorMessage\":\"boom table missing\"}"},
		{200, "{\"success\":false}"},
		{500, "not json at all"},
	}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)

	dsn := fmt.aprintf("frostlake://127.0.0.1:%d", server.port)
	defer delete(dsn)
	conn, open_err := open(dsn)
	testing.expect(t, open_err == nil)
	defer destroy_connection(&conn)

	expect_execute_error(t, &conn, "SELECT 1", "boom table missing")
	expect_execute_error(t, &conn, "SELECT 2", "statement failed")
	expect_execute_error(t, &conn, "SELECT 3", "HTTP 500 with unreadable body")
}

@(test)
test_connect_rejects_an_unhealthy_server :: proc(t: ^testing.T) {
	exchanges := []Canned_Exchange{{503, "down"}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	dsn := fmt.aprintf("frostlake://127.0.0.1:%d", server.port)
	defer delete(dsn)
	conn, err := connect(dsn)
	if !testing.expect(t, err != nil, "connect unexpectedly succeeded") {
		destroy_connection(&conn)
		return
	}
	testing.expectf(t, strings.contains(error_message(err), "server unhealthy: HTTP 503"), "error was: %s", error_message(err))
	destroy_error(err)
}

@(test)
test_a_closed_connection_refuses_statements :: proc(t: ^testing.T) {
	conn, open_err := open("frostlake://localhost:1")
	testing.expect(t, open_err == nil)
	defer destroy_connection(&conn)
	close(&conn)
	result, err := execute(&conn, "SELECT 1")
	if !testing.expect(t, err != nil, "execute on a closed connection succeeded") {
		destroy_result(&result)
	}
	testing.expect_value(t, error_message(err), "connection is closed")
	destroy_error(err)

	unreachable_conn, unreachable_err := connect("frostlake://127.0.0.1:1")
	if !testing.expect(t, unreachable_err != nil, "connect to port 1 succeeded") {
		destroy_connection(&unreachable_conn)
		return
	}
	testing.expectf(
		t,
		strings.contains(error_message(unreachable_err), "cannot reach 127.0.0.1:1"),
		"error was: %s",
		error_message(unreachable_err),
	)
	destroy_error(unreachable_err)
}

@(test)
test_dml_counts_sum_like_the_jdbc_driver :: proc(t: ^testing.T) {
	// An engine that reports no updateCount is read from the count grid.
	// UPDATE: two columns, the always-0 multi-joined one excluded from the count.
	update := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[{\"name\":\"number of rows updated\"},{\"name\":\"number of multi-joined rows updated\"}],\"rows\":[[5,0]]}]}",
	)
	testing.expect_value(t, update.row_count, 5)
	testing.expect_value(t, update.update_count, i64(5))
	// The grid itself stays readable, as Snowflake shapes it.
	testing.expect_value(t, len(update.columns), 2)
	updated, _ := get(update, 0, "number of rows updated")
	testing.expect(t, values_equal(updated, i128(5)))
	multi_joined, _ := get(update, 0, "number of multi-joined rows updated")
	testing.expect(t, values_equal(multi_joined, i128(0)))
	destroy_result(&update)

	// MERGE: one column per action, summed.
	merge := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[{\"name\":\"number of rows inserted\"},{\"name\":\"number of rows updated\"}],\"rows\":[[2,3]]}]}",
	)
	testing.expect_value(t, merge.row_count, 5)
	testing.expect_value(t, merge.update_count, i64(5))
	testing.expect_value(t, len(merge.rows), 1)
	destroy_result(&merge)

	// An aliased look-alike stays an ordinary one-row query result.
	alias := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[{\"name\":\"number of rows once\"}],\"rows\":[[7]]}]}",
	)
	testing.expect_value(t, alias.row_count, 1)
	testing.expect_value(t, alias.update_count, nil)
	cell, _ := get(alias, 0, "number of rows once")
	testing.expect(t, values_equal(cell, i128(7)))
	destroy_result(&alias)
}

@(test)
test_a_reported_update_count_decides_what_is_dml :: proc(t: ^testing.T) {
	// A query can carry an exact count name — a column alias, or a DML result
	// piped into a SELECT. The engine reports -1 for it, and that outranks the
	// name: it stays a one-row query.
	piped := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[{\"name\":\"number of rows inserted\"}],\"rows\":[[2]],\"updateCount\":-1}]}",
	)
	testing.expect_value(t, piped.update_count, nil)
	testing.expect_value(t, piped.row_count, 1)
	inserted, _ := get(piped, 0, "number of rows inserted")
	testing.expect(t, values_equal(inserted, i128(2)))
	destroy_result(&piped)

	// A reported count is the count, whatever the grid holds.
	merge := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[{\"name\":\"number of rows inserted\"},{\"name\":\"number of rows updated\"}],\"rows\":[[1,1]],\"updateCount\":7}]}",
	)
	testing.expect_value(t, merge.update_count, i64(7))
	testing.expect_value(t, merge.row_count, 7)
	destroy_result(&merge)

	// DML that touched nothing is still DML: a count of 0, not nil.
	nothing := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[{\"name\":\"number of rows updated\"},{\"name\":\"number of multi-joined rows updated\"}],\"rows\":[[0,0]],\"updateCount\":0}]}",
	)
	testing.expect_value(t, nothing.update_count, i64(0))
	testing.expect_value(t, nothing.row_count, 0)
	destroy_result(&nothing)

	// DDL answers a status grid and no count.
	ddl := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[{\"name\":\"status\"}],\"rows\":[[\"Table T successfully created.\"]],\"updateCount\":-1}]}",
	)
	testing.expect_value(t, ddl.update_count, nil)
	testing.expect_value(t, ddl.row_count, 1)
	destroy_result(&ddl)
}

@(test)
test_shaping_tolerates_absent_and_ragged_result_sets :: proc(t: ^testing.T) {
	no_sets := expect_shaped(t, "{\"success\":true}")
	testing.expect_value(t, no_sets.row_count, 0)
	testing.expect_value(t, no_sets.update_count, nil)
	destroy_result(&no_sets)

	empty_sets := expect_shaped(t, "{\"resultSets\":[]}")
	testing.expect_value(t, empty_sets.row_count, 0)
	destroy_result(&empty_sets)

	// A short row pads with NULLs instead of crashing.
	ragged := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[{\"name\":\"A\"},{\"name\":\"B\"}],\"rows\":[[1]]}]}",
	)
	testing.expect_value(t, ragged.row_count, 1)
	a, _ := get(ragged, 0, "A")
	testing.expect(t, values_equal(a, i128(1)))
	b, b_found := get(ragged, 0, "B")
	testing.expect(t, b_found && b == nil)
	destroy_result(&ragged)
}

@(test)
test_text_and_binary_columns_carry_their_declared_width :: proc(t: ^testing.T) {
	// The wire sends `length` for VARCHAR and BINARY only -- characters for
	// one, bytes for the other -- and an unbounded column carries the most it
	// could hold, so nothing has to be invented.
	widths := expect_shaped(
		t,
		"{\"resultSets\":[{\"columns\":[" +
		"{\"name\":\"V9\",\"dataType\":\"VARCHAR\",\"precision\":0,\"scale\":0,\"length\":9}," +
		"{\"name\":\"B5\",\"dataType\":\"BINARY\",\"precision\":0,\"scale\":0,\"length\":5}," +
		"{\"name\":\"N\",\"dataType\":\"NUMBER\",\"precision\":10,\"scale\":2}," +
		"{\"name\":\"VU\",\"dataType\":\"VARCHAR\",\"precision\":0,\"scale\":0,\"length\":16777216}]," +
		"\"rows\":[]}]}",
	)
	defer destroy_result(&widths)
	testing.expect_value(t, widths.columns[0].length, i64(9))
	testing.expect_value(t, widths.columns[1].length, i64(5))
	// A number has a precision and a scale and no width at all: nil, not 0.
	testing.expect_value(t, widths.columns[2].length, nil)
	testing.expect_value(t, widths.columns[3].length, i64(16777216))

	// A column a server predating the field sent reports nothing either.
	older := expect_shaped(t, "{\"resultSets\":[{\"columns\":[{\"name\":\"S\",\"dataType\":\"VARCHAR\"}],\"rows\":[[\"x\"]]}]}")
	defer destroy_result(&older)
	testing.expect_value(t, older.columns[0].length, nil)
}

@(test)
test_column_lookup_prefers_exact_then_falls_back_case_insensitively :: proc(t: ^testing.T) {
	columns := []Column{{name = "n"}, {name = "N"}}
	rows := [][]Value{{i128(1), i128(2)}}
	ambiguous := Query_Result{columns = columns, rows = rows, row_count = 1}
	upper, _ := get(ambiguous, 0, "N")
	testing.expect(t, values_equal(upper, i128(2)))
	lower, _ := get(ambiguous, 0, "n")
	testing.expect(t, values_equal(lower, i128(1)))
	_, missing_found := get(ambiguous, 0, "missing")
	testing.expect(t, !missing_found)
	_, out_of_range := get(ambiguous, 9, "n")
	testing.expect(t, !out_of_range)

	single_columns := []Column{{name = "NAME"}}
	single_rows := [][]Value{{"Ada"}}
	single := Query_Result{columns = single_columns, rows = single_rows, row_count = 1}
	name, _ := get(single, 0, "name")
	testing.expect(t, values_equal(name, "Ada"))
}

@(test)
test_binary_conversion_requires_clean_hex :: proc(t: ^testing.T) {
	expect_converted(t, "CAFE", "BINARY", Bytes{0xCA, 0xFE})
	expect_converted(t, "", "BINARY", Bytes{})
	expect_converted(t, "CAF", "BINARY", "CAF")
	expect_converted(t, "ZZ", "BINARY", "ZZ")
	expect_converted(t, "CAFE", "VARBINARY", Bytes{0xCA, 0xFE})
	expect_converted(t, "x", "TIMESTAMP_LTZ", Timestamp{"x"})
	expect_converted(t, "2026-08-19", "DATE", Date{"2026-08-19"})
	expect_converted(t, "t", "", "t")
	converted := convert_cell(nil, "BINARY", context.allocator)
	testing.expect(t, converted == nil)
}

@(private = "file")
exec_discard :: proc(t: ^testing.T, conn: ^Connection, sql: string, loc := #caller_location) {
	result, err := execute(conn, sql)
	if !testing.expectf(t, err == nil, "execute(%s) failed: %s", sql, error_message(err), loc = loc) {
		destroy_error(err)
		return
	}
	destroy_result(&result)
}

@(private = "file")
exec_counted_discard :: proc(t: ^testing.T, conn: ^Connection, sql: string, count: int, loc := #caller_location) {
	result, err := execute(conn, sql, multi_statement_count = count)
	if !testing.expectf(t, err == nil, "execute(%s) failed: %s", sql, error_message(err), loc = loc) {
		destroy_error(err)
		return
	}
	destroy_result(&result)
}

@(private = "file")
expect_execute_error :: proc(t: ^testing.T, conn: ^Connection, sql: string, expected: string, loc := #caller_location) {
	result, err := execute(conn, sql)
	if !testing.expectf(t, err != nil, "execute(%s) unexpectedly succeeded", sql, loc = loc) {
		destroy_result(&result)
		return
	}
	testing.expectf(t, error_message(err) == expected, "execute(%s) error = '%s', want '%s'", sql, error_message(err), expected, loc = loc)
	destroy_error(err)
}

@(private = "file")
expect_shaped :: proc(t: ^testing.T, body: string, loc := #caller_location) -> Query_Result {
	tree, err := parse_json(body)
	if !testing.expectf(t, err == nil, "parse_json failed: %s", error_message(err), loc = loc) {
		destroy_error(err)
		return {}
	}
	result := shape_result(tree, context.allocator)
	destroy_value(tree)
	return result
}

@(private = "file")
expect_converted :: proc(t: ^testing.T, text: string, data_type: string, expected: Value, loc := #caller_location) {
	converted := convert_cell(text, data_type, context.allocator)
	testing.expectf(t, values_equal(converted, expected), "convert_cell(%s, %s) = %v, want %v", text, data_type, converted, expected, loc = loc)
	destroy_value(converted)
}
