// The connection: one POST /api/execute per statement with
// { sql, sessionId, autoCommit, multiStatementCount }; the server issues the
// sessionId on first contact and the driver echoes it back, so session state
// (current database/schema, transactions) persists across statements. Failed
// statements answer with a non-2xx status and the error JSON in the body,
// which the driver reads regardless of status.
package frostlake

import "core:mem"
import "core:strings"

Connection :: struct {
	host:        string,
	port:        int,
	session_id:  string, // "" until the server issues one
	auto_commit: bool,
	closed:      bool,
	pending_use: [dynamic]string,
	allocator:   mem.Allocator,
}

// Parses the DSN and verifies the server is reachable via GET /api/health.
// Free with destroy_connection. The allocator owns the connection's internals
// and any error this or a later call on the connection returns.
connect :: proc(dsn: string, allocator := context.allocator) -> (conn: Connection, err: Error) {
	conn, err = open(dsn, allocator)
	if err != nil {
		return {}, err
	}
	ping_err := ping(&conn)
	if ping_err != nil {
		destroy_connection(&conn)
		return {}, ping_err
	}
	return conn, nil
}

// Parses the DSN without contacting the server (connect = open + health check).
@(private)
open :: proc(dsn: string, allocator := context.allocator) -> (conn: Connection, err: Error) {
	parsed, parse_err := parse_dsn(dsn, allocator)
	if parse_err != nil {
		return {}, parse_err
	}
	return Connection{
		host = parsed.host,
		port = parsed.port,
		auto_commit = true,
		pending_use = parsed.pending_use,
		allocator = allocator,
	}, nil
}

@(private)
ping :: proc(conn: ^Connection) -> Error {
	response, request_err := http_request(conn.host, conn.port, "GET", "/api/health", nil, conn.allocator)
	if request_err != nil {
		detail := request_err.(Error_Detail)
		out := make_errorf(.Connect, conn.allocator, "cannot reach %s:%d: %s", conn.host, conn.port, detail.message)
		destroy_error(request_err, conn.allocator)
		return out
	}
	defer delete(response.body, conn.allocator)
	if response.status != 200 {
		return make_errorf(.Connect, conn.allocator, "server unhealthy: HTTP %d", response.status)
	}
	return nil
}

// Executes one statement, inlining '?' placeholders from binds in order (no
// substitution scan happens when binds is empty). The result and any error
// are owned by the given allocator.
//
// multi_statement_count says how many statements this one request carries,
// for a caller sending a semicolon-separated pack:
//
//	execute(&conn, "SELECT 1; SELECT 2", multi_statement_count = 2)
//
// It outranks the session's MULTI_STATEMENT_COUNT for this request alone and
// leaves the session where it was, so nothing has to be put back afterwards;
// 0 accepts any number. Left nil — as it is by default — the request carries
// no such field and the session's value decides.
execute :: proc(
	conn: ^Connection,
	sql: string,
	binds: []Value = nil,
	allocator := context.allocator,
	multi_statement_count: Maybe(int) = nil,
) -> (
	result: Query_Result,
	err: Error,
) {
	if conn.closed {
		return {}, make_error(.Usage, "connection is closed", allocator)
	}
	// A failed USE stays queued, so every later statement keeps failing
	// instead of silently running against the server's default database.
	for len(conn.pending_use) > 0 {
		statement := conn.pending_use[0]
		// Each USE is one statement of its own, so the caller's count is none
		// of its business.
		out, use_err := round_trip(conn, statement, allocator, nil)
		if use_err != nil {
			return {}, use_err
		}
		destroy_value(out, allocator)
		delete(statement, conn.allocator)
		ordered_remove(&conn.pending_use, 0)
	}
	rendered := sql
	rendered_owned := false
	if len(binds) > 0 {
		substituted, bind_err := substitute(sql, binds, allocator)
		if bind_err != nil {
			return {}, bind_err
		}
		rendered = substituted
		rendered_owned = true
	}
	out, trip_err := round_trip(conn, rendered, allocator, multi_statement_count)
	if rendered_owned {
		delete(rendered, allocator)
	}
	if trip_err != nil {
		return {}, trip_err
	}
	result = shape_result(out, allocator)
	destroy_value(out, allocator)
	return result, nil
}

// BEGIN flips autoCommit off for the whole transaction (the COMMIT statement
// included); COMMIT/ROLLBACK restore it for what follows.
begin :: proc(conn: ^Connection, allocator := context.allocator) -> Error {
	conn.auto_commit = false
	result, err := execute(conn, "BEGIN", nil, allocator)
	if err != nil {
		return err
	}
	destroy_result(&result, allocator)
	return nil
}

commit :: proc(conn: ^Connection, allocator := context.allocator) -> Error {
	result, err := execute(conn, "COMMIT", nil, allocator)
	if err != nil {
		return err
	}
	destroy_result(&result, allocator)
	conn.auto_commit = true
	return nil
}

rollback :: proc(conn: ^Connection, allocator := context.allocator) -> Error {
	result, err := execute(conn, "ROLLBACK", nil, allocator)
	if err != nil {
		return err
	}
	destroy_result(&result, allocator)
	conn.auto_commit = true
	return nil
}

// Marks the connection closed; later executes fail. The protocol has no
// session-close endpoint, so nothing is sent.
close :: proc(conn: ^Connection) {
	conn.closed = true
}

destroy_connection :: proc(conn: ^Connection) {
	delete(conn.host, conn.allocator)
	delete(conn.session_id, conn.allocator)
	for statement in conn.pending_use {
		delete(statement, conn.allocator)
	}
	delete(conn.pending_use)
	conn.host = ""
	conn.session_id = ""
	conn.pending_use = nil
	conn.closed = true
}

// One POST /api/execute. Returns the parsed response tree (owned by
// allocator) after learning the sessionId and checking success.
@(private)
round_trip :: proc(
	conn: ^Connection,
	sql: string,
	allocator: mem.Allocator,
	multi_statement_count: Maybe(int),
) -> (
	out: Value,
	err: Error,
) {
	payload := strings.builder_make(allocator)
	defer strings.builder_destroy(&payload)
	strings.write_string(&payload, "{\"sql\":\"")
	escape_json(&payload, sql)
	strings.write_string(&payload, "\",\"autoCommit\":")
	strings.write_string(&payload, "true" if conn.auto_commit else "false")
	if len(conn.session_id) > 0 {
		strings.write_string(&payload, ",\"sessionId\":\"")
		escape_json(&payload, conn.session_id)
		strings.write_string(&payload, "\"")
	}
	if count, has_count := multi_statement_count.?; has_count {
		strings.write_string(&payload, ",\"multiStatementCount\":")
		strings.write_int(&payload, count)
	}
	strings.write_byte(&payload, '}')

	// Failed statements answer with a non-2xx status AND the error payload in
	// the body, so the body is parsed regardless of status.
	response, request_err := http_request(conn.host, conn.port, "POST", "/api/execute", strings.to_string(payload), allocator)
	if request_err != nil {
		return nil, request_err
	}
	defer delete(response.body, allocator)
	parsed, parse_err := parse_json(response.body, allocator)
	if parse_err != nil {
		destroy_error(parse_err, allocator)
		return nil, make_errorf(.Protocol, allocator, "HTTP %d with unreadable body", response.status)
	}
	if session, session_ok := json_get(parsed, "sessionId").(string); session_ok {
		if conn.session_id != session {
			delete(conn.session_id, conn.allocator)
			conn.session_id = strings.clone(session, conn.allocator)
		}
	}
	success, success_ok := json_get(parsed, "success").(bool)
	if !success_ok || !success {
		message := "statement failed"
		if engine_message, message_ok := json_get(parsed, "errorMessage").(string); message_ok {
			message = engine_message
		}
		sql_err := make_error(.Sql, message, allocator)
		destroy_value(parsed, allocator)
		return nil, sql_err
	}
	return parsed, nil
}

// Shapes the response tree into a Query_Result, cloning everything kept. A DML
// statement's count grid is kept like any other result.
@(private)
shape_result :: proc(out: Value, allocator: mem.Allocator) -> Query_Result {
	sets, sets_ok := json_get(out, "resultSets").(Array)
	if !sets_ok || len(sets) == 0 {
		return Query_Result{}
	}
	set := sets[0]
	raw_columns, _ := json_get(set, "columns").(Array)
	raw_rows, _ := json_get(set, "rows").(Array)

	columns := make([]Column, len(raw_columns), allocator)
	for raw_column, i in raw_columns {
		name, _ := json_get(raw_column, "name").(string)
		columns[i].name = strings.clone(name, allocator)
		if data_type, data_type_ok := json_get(raw_column, "dataType").(string); data_type_ok {
			columns[i].data_type = strings.clone(data_type, allocator)
		}
		// Text and binary columns carry a width; everything else omits the
		// field, and so does a server that predates it.
		if length, length_ok := json_get(raw_column, "length").(i128); length_ok {
			columns[i].length = i64(length)
		}
	}
	rows := make([][]Value, len(raw_rows), allocator)
	for raw_row, r in raw_rows {
		cells := make([]Value, len(columns), allocator)
		if raw_cells, raw_cells_ok := raw_row.(Array); raw_cells_ok {
			for c in 0 ..< len(cells) {
				if c < len(raw_cells) {
					cells[c] = convert_cell(raw_cells[c], columns[c].data_type, allocator)
				}
			}
		}
		rows[r] = cells
	}
	result := Query_Result{columns = columns, rows = rows, row_count = i64(len(rows))}
	if count, is_dml := dml_count(set, raw_columns, raw_rows); is_dml {
		result.update_count = count
		result.row_count = count
	}
	return result
}

// The affected-row count, when the statement was DML. An engine that reports
// updateCount says so outright (-1 for anything else), so a query whose
// columns merely carry count names stays a query. An older engine is read from
// the count grid instead: a single row whose columns are all exactly DML count
// names, summed like the engine's JDBC driver sums them, with UPDATE's always-0
// "number of multi-joined rows updated" left out, per Snowflake semantics.
@(private = "file")
dml_count :: proc(set: Value, raw_columns: Array, raw_rows: Array) -> (count: i64, is_dml: bool) {
	if reported, has_reported := json_get(set, "updateCount").(i128); has_reported {
		return i64(reported), reported >= 0
	}
	if len(raw_rows) != 1 || len(raw_columns) == 0 {
		return 0, false
	}
	first_row, _ := raw_rows[0].(Array)
	total: i128 = 0
	any_summed := false
	for raw_column, i in raw_columns {
		name, _ := json_get(raw_column, "name").(string)
		if strings.equal_fold(name, "number of rows inserted") ||
		   strings.equal_fold(name, "number of rows updated") ||
		   strings.equal_fold(name, "number of rows deleted") {
			any_summed = true
			if i < len(first_row) {
				if cell, cell_ok := first_row[i].(i128); cell_ok {
					total += cell
				}
			}
		} else if !strings.equal_fold(name, "number of multi-joined rows updated") {
			return 0, false
		}
	}
	return i64(total), any_summed
}

// Applies the wire's declared type to a text cell: DATE/TIMESTAMP*/BINARY
// arrive as text and convert to Date/Timestamp/Bytes; everything else is
// cloned as-is. A short row's missing cells stay nil.
@(private)
convert_cell :: proc(raw: Value, data_type: string, allocator: mem.Allocator) -> Value {
	text, is_text := raw.(string)
	if !is_text {
		return clone_value(raw, allocator)
	}
	if strings.equal_fold(data_type, "DATE") {
		return Date{strings.clone(text, allocator)}
	}
	if strings.equal_fold(data_type, "TIMESTAMP") ||
	   strings.equal_fold(data_type, "TIMESTAMP_NTZ") ||
	   strings.equal_fold(data_type, "TIMESTAMP_LTZ") ||
	   strings.equal_fold(data_type, "TIMESTAMP_TZ") ||
	   strings.equal_fold(data_type, "DATETIME") {
		return Timestamp{strings.clone(text, allocator)}
	}
	if strings.equal_fold(data_type, "BINARY") || strings.equal_fold(data_type, "VARBINARY") {
		if decoded, decoded_ok := decode_hex(text, allocator); decoded_ok {
			return Bytes(decoded)
		}
	}
	return strings.clone(text, allocator)
}

@(private)
decode_hex :: proc(text: string, allocator: mem.Allocator) -> (bytes: []u8, ok: bool) {
	if len(text) % 2 != 0 {
		return nil, false
	}
	for i in 0 ..< len(text) {
		c := text[i]
		hex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !hex {
			return nil, false
		}
	}
	bytes = make([]u8, len(text) / 2, allocator)
	for i := 0; i < len(text); i += 2 {
		high, _ := hex_nibble(text[i])
		low, _ := hex_nibble(text[i + 1])
		bytes[i / 2] = high << 4 | low
	}
	return bytes, true
}

@(private = "file")
hex_nibble :: proc(c: u8) -> (value: u8, ok: bool) {
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
