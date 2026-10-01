// The connection: one POST /api/execute per statement with
// { sql, sessionId, requireSession, autoCommit, multiStatementCount }; the
// server issues the sessionId on first contact and the driver echoes it back,
// so session state (current database/schema, transactions) persists across
// statements. Failed statements answer with a non-2xx status and the error
// JSON in the body, which the driver reads regardless of status.
package frostlake

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

Connection :: struct {
	host:            string,
	port:            int,
	session_id:      string, // "" until the server issues one
	auto_commit:     bool,
	closed:          bool,
	pending_use:     [dynamic]string,
	allocator:       mem.Allocator,
	// The DSN's USE statements, kept so that a fresh session standing in for a
	// lost one can be put back on them.
	scope:           [dynamic]string,
	session_support: Session_Support,
	// Set once a statement left state behind that a fresh session would not
	// have: a USE, SET/UNSET, ALTER SESSION, a temporary object, a CREATE/DROP
	// of a database or schema. Putting the DSN's scope back on clears it.
	dirty:           bool,
	// A transaction is open: from BEGIN (or START TRANSACTION), however it was
	// sent, until COMMIT or ROLLBACK.
	in_transaction:  bool,
}

// What the engine is known to do with the session id a request names. An engine
// that answers newSession also honours requireSession and DELETE
// /api/sessions/{id}; one that predates the field knows neither, and its parser
// may refuse a field it does not know. Nothing is known until the first answer
// that names a session.
Session_Support :: enum {
	Unknown,
	Tracked,   // the engine answers newSession
	Untracked, // the engine predates newSession
}

// How long closing waits for the engine to release the session.
@(private)
RELEASE_TIMEOUT :: 5 * time.Second

// What one POST /api/execute came back with.
@(private)
Outcome :: enum {
	Answered,     // an answer, in the session the request named or a new one
	Replaced,     // an answer, from a fresh session started in place of the one named
	Session_Gone, // a refusal: the engine no longer holds the session named; nothing ran
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
	scope := make([dynamic]string, 0, len(parsed.pending_use), allocator)
	for statement in parsed.pending_use {
		append(&scope, strings.clone(statement, allocator))
	}
	return Connection{
		host = parsed.host,
		port = parsed.port,
		auto_commit = true,
		pending_use = parsed.pending_use,
		allocator = allocator,
		scope = scope,
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
	return run(conn, sql, binds, allocator, multi_statement_count, conn.auto_commit)
}

// execute, sending auto_commit as the request's autoCommit: the connection's
// own flag for every statement but begin's BEGIN.
@(private)
run :: proc(
	conn: ^Connection,
	sql: string,
	binds: []Value,
	allocator: mem.Allocator,
	multi_statement_count: Maybe(int),
	auto_commit: bool,
) -> (
	result: Query_Result,
	err: Error,
) {
	if conn.closed {
		return {}, make_error(.Usage, "connection is closed", allocator)
	}
	if use_err := apply_pending_use(conn, allocator); use_err != nil {
		return {}, use_err
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
	out, trip_err := exchange(conn, rendered, allocator, multi_statement_count, auto_commit)
	if rendered_owned {
		delete(rendered, allocator)
	}
	if trip_err != nil {
		return {}, trip_err
	}
	track_statements(conn, sql)
	result = shape_result(out, allocator)
	destroy_value(out, allocator)
	return result, nil
}

// BEGIN turns autoCommit off for the whole transaction (the COMMIT statement
// included); COMMIT/ROLLBACK restore it for what follows. The BEGIN itself goes
// out with autoCommit off, but the connection turns it off only once BEGIN has
// run: a begin that failed -- the transport broke, a queued USE was refused --
// leaves the connection autocommitting, rather than running what follows in an
// implicit transaction nobody opened and nobody will commit.
begin :: proc(conn: ^Connection, allocator := context.allocator) -> Error {
	result, err := run(conn, "BEGIN", nil, allocator, nil, false)
	if err != nil {
		return err
	}
	destroy_result(&result, allocator)
	conn.auto_commit = false
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

// Marks the connection closed, so later executes fail, and gives the engine
// its session back with DELETE /api/sessions/{id}, which also rolls back a
// transaction left open on it rather than leaving it to the engine's idle
// expiry. Releasing is a courtesy: it waits at most five seconds for the
// answer, and whatever goes wrong with it is ignored, since closing cannot
// fail. An engine that predates the endpoint (it answers no newSession) is sent
// nothing, and its session lingers until that expiry as before. Only the first
// close sends anything.
close :: proc(conn: ^Connection) {
	if conn.closed {
		return
	}
	conn.closed = true
	if len(conn.session_id) == 0 || conn.session_support != .Tracked {
		return
	}
	id := escape_path_segment(conn.session_id, conn.allocator)
	defer delete(id, conn.allocator)
	path := fmt.aprintf("/api/sessions/%s", id, allocator = conn.allocator)
	defer delete(path, conn.allocator)
	response, err := http_request(conn.host, conn.port, "DELETE", path, nil, conn.allocator, RELEASE_TIMEOUT)
	if err != nil {
		destroy_error(err, conn.allocator)
	} else {
		delete(response.body, conn.allocator)
	}
}

// Frees the connection's internals, closing it first when it is still open, so
// that its session is released either way.
destroy_connection :: proc(conn: ^Connection) {
	close(conn)
	delete(conn.host, conn.allocator)
	delete(conn.session_id, conn.allocator)
	for statement in conn.pending_use {
		delete(statement, conn.allocator)
	}
	delete(conn.pending_use)
	for statement in conn.scope {
		delete(statement, conn.allocator)
	}
	delete(conn.scope)
	conn.host = ""
	conn.session_id = ""
	conn.pending_use = nil
	conn.scope = nil
	conn.closed = true
}

// Puts the owed USE statements on the session, each leaving the queue only
// once it has succeeded: a failed USE stays queued, so every later statement
// keeps failing instead of silently running against the server's default
// database. A session lost part way through takes the USEs already run with
// it, so the whole scope starts over in a fresh session -- once. With the whole
// scope on, the session holds nothing the caller put there.
@(private)
apply_pending_use :: proc(conn: ^Connection, allocator: mem.Allocator) -> Error {
	if len(conn.pending_use) == 0 {
		return nil
	}
	restarted := false
	for len(conn.pending_use) > 0 {
		// Each USE is one statement of its own, so the caller's count is none
		// of its business.
		out, outcome, use_err := round_trip(conn, conn.pending_use[0], allocator, nil, conn.auto_commit)
		switch outcome {
		case .Session_Gone:
			if restarted {
				return refused_again(conn, allocator)
			}
			restarted = true
			if lost := lose_session(conn, allocator); lost != nil {
				return lost
			}
			continue
		case .Replaced:
			// The engine ran this USE in a fresh session in place of ours, so
			// what the ones before it selected is gone: the scope starts over.
			if !restarted {
				restarted = true
				forget_session(conn)
				if use_err != nil {
					return use_err
				}
				destroy_value(out, allocator)
				continue
			}
		case .Answered:
		}
		if use_err != nil {
			return use_err
		}
		destroy_value(out, allocator)
		delete(conn.pending_use[0], conn.allocator)
		ordered_remove(&conn.pending_use, 0)
	}
	conn.dirty = false
	return nil
}

// One statement, recovering from a session the engine no longer holds. Nothing
// ran then: when the session held nothing a fresh one lacks, the DSN's scope
// goes onto a fresh session and the statement is sent once more, exactly as it
// was first sent; when it held an open transaction or context, lose_session
// refuses instead.
@(private)
exchange :: proc(
	conn: ^Connection,
	sql: string,
	allocator: mem.Allocator,
	multi_statement_count: Maybe(int),
	auto_commit: bool,
) -> (
	out: Value,
	err: Error,
) {
	for attempt in 0 ..< 2 {
		outcome: Outcome
		out, outcome, err = round_trip(conn, sql, allocator, multi_statement_count, auto_commit)
		switch outcome {
		case .Answered:
			return out, err
		case .Replaced:
			// It ran, but in a fresh session: the scope goes back on before the
			// next statement.
			forget_session(conn)
			return out, err
		case .Session_Gone:
			if attempt > 0 {
				return nil, refused_again(conn, allocator)
			}
			if lost := lose_session(conn, allocator); lost != nil {
				return nil, lost
			}
			if use_err := apply_pending_use(conn, allocator); use_err != nil {
				return nil, use_err
			}
		}
	}
	return nil, refused_again(conn, allocator)
}

// The engine no longer holds this connection's session -- it expired, was
// released, or the server restarted -- and nothing ran. The id is dropped and
// the DSN's scope queued for a fresh session. When the lost session held an
// open transaction, or context set up on it, re-running the statement would
// put it somewhere its author did not intend, so a Session_Lost error says so
// instead. Either way the connection stays usable, and its next statement
// starts on the DSN's scope.
@(private)
lose_session :: proc(conn: ^Connection, allocator: mem.Allocator) -> Error {
	had_transaction := conn.in_transaction
	had_context := conn.dirty
	drop_session(conn)
	if had_transaction {
		return make_error(
			.Session_Lost,
			"the engine no longer holds this connection's session (it expired, was released, or the server restarted), so its open transaction is gone; the statement did not run",
			allocator,
		)
	}
	if had_context {
		return make_error(
			.Session_Lost,
			"the engine no longer holds this connection's session (it expired, was released, or the server restarted), and the context set up on it (USE, SET, ALTER SESSION or a temporary object) went with it, so the statement was not re-run; the next statement starts a fresh session on the connection's scope",
			allocator,
		)
	}
	return nil
}

// A session the engine started for this connection was refused at once. It is
// dropped as well, so the next statement starts over.
@(private)
refused_again :: proc(conn: ^Connection, allocator: mem.Allocator) -> Error {
	drop_session(conn)
	return make_error(
		.Session_Lost,
		"the engine refused a session it had just started for this connection; the statement did not run",
		allocator,
	)
}

@(private)
drop_session :: proc(conn: ^Connection) {
	delete(conn.session_id, conn.allocator)
	conn.session_id = ""
	forget_session(conn)
}

// Nothing is left of what the session held -- it was lost, or the engine ran a
// request in a fresh session in place of it -- so the DSN's scope goes back on
// before the next statement, and the transaction is over.
@(private)
forget_session :: proc(conn: ^Connection) {
	conn.auto_commit = true
	conn.in_transaction = false
	conn.dirty = false
	for statement in conn.pending_use {
		delete(statement, conn.allocator)
	}
	clear(&conn.pending_use)
	for statement in conn.scope {
		append(&conn.pending_use, strings.clone(statement, conn.allocator))
	}
}

// A session id as one path segment: anything but an unreserved character is
// percent-encoded.
@(private = "file")
escape_path_segment :: proc(text: string, allocator: mem.Allocator) -> string {
	hex := "0123456789ABCDEF"
	builder := strings.builder_make(allocator)
	for i in 0 ..< len(text) {
		c := text[i]
		unreserved :=
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '-' ||
			c == '_' ||
			c == '.' ||
			c == '~'
		if unreserved {
			strings.write_byte(&builder, c)
		} else {
			strings.write_byte(&builder, '%')
			strings.write_byte(&builder, hex[c >> 4])
			strings.write_byte(&builder, hex[c & 0xF])
		}
	}
	return strings.to_string(builder)
}

// One POST /api/execute, without any recovery, carrying auto_commit as its
// autoCommit. Returns the parsed response tree (owned by allocator) after
// learning the sessionId and checking success; outcome says what became of the
// session.
@(private)
round_trip :: proc(
	conn: ^Connection,
	sql: string,
	allocator: mem.Allocator,
	multi_statement_count: Maybe(int),
	auto_commit: bool,
) -> (
	out: Value,
	outcome: Outcome,
	err: Error,
) {
	named_session := len(conn.session_id) > 0
	// Resume the session or refuse: without this, an engine that no longer
	// holds it starts a fresh one under the same id and the statement runs in
	// the wrong context. Sent only once the engine is known to honour it: an
	// older one's parser may refuse a field it does not know.
	require_session := named_session && conn.session_support == .Tracked

	payload := strings.builder_make(allocator)
	defer strings.builder_destroy(&payload)
	strings.write_string(&payload, "{\"sql\":\"")
	escape_json(&payload, sql)
	strings.write_string(&payload, "\",\"autoCommit\":")
	strings.write_string(&payload, "true" if auto_commit else "false")
	if named_session {
		strings.write_string(&payload, ",\"sessionId\":\"")
		escape_json(&payload, conn.session_id)
		strings.write_string(&payload, "\"")
	}
	if require_session {
		strings.write_string(&payload, ",\"requireSession\":true")
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
		return nil, .Answered, request_err
	}
	defer delete(response.body, allocator)
	parsed, parse_err := parse_json(response.body, allocator)
	if parse_err != nil {
		destroy_error(parse_err, allocator)
		return nil, .Answered, make_errorf(.Protocol, allocator, "HTTP %d with unreadable body", response.status)
	}
	session, session_ok := json_get(parsed, "sessionId").(string)
	success, success_ok := json_get(parsed, "success").(bool)
	if require_session && response.status == 404 && !(success_ok && success) && !session_ok {
		destroy_value(parsed, allocator)
		return nil, .Session_Gone, nil
	}
	outcome = .Answered
	if session_ok {
		if conn.session_id != session {
			delete(conn.session_id, conn.allocator)
			conn.session_id = strings.clone(session, conn.allocator)
		}
		// The first answer that names a session says whether the engine keeps
		// sessions to their id: one that does answers newSession.
		if started, started_ok := json_get(parsed, "newSession").(bool); started_ok {
			conn.session_support = .Tracked
			if started && named_session {
				outcome = .Replaced
			}
		} else if conn.session_support == .Unknown {
			conn.session_support = .Untracked
		}
	}
	if !success_ok || !success {
		message := "statement failed"
		if engine_message, message_ok := json_get(parsed, "errorMessage").(string); message_ok {
			message = engine_message
		}
		sql_err := make_error(.Sql, message, allocator)
		destroy_value(parsed, allocator)
		return nil, outcome, sql_err
	}
	return parsed, outcome, nil
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
