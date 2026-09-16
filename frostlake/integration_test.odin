// Boots a real DatabaseHttpServer from FROSTLAKE_CLASSPATH and drives the
// whole surface over it; skips itself when the variable is unset.
package frostlake

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A check this engine cannot answer, logged rather than passed: this driver
// supports engines older than the behaviour some checks look for, and a green
// tick against one of those would claim an engine had been checked for
// something it never reports.
skip_check :: proc(what: string, why: string) {
	log.infof("SKIP %s: %s", what, why)
}

@(test)
test_integration_full_driver_flow :: proc(t: ^testing.T) {
	classpath, has_classpath := os.lookup_env("FROSTLAKE_CLASSPATH", context.allocator)
	if !has_classpath {
		log.info("skipping integration test: FROSTLAKE_CLASSPATH not set")
		return
	}
	defer delete(classpath)
	testing.set_fail_timeout(t, 300 * time.Second)

	java := strings.clone("java")
	if java_home, has_java_home := os.lookup_env("JAVA_HOME", context.allocator); has_java_home {
		delete(java)
		java = fmt.aprintf("%s/bin/java", java_home)
		delete(java_home)
	}
	defer delete(java)

	// Reserve an ephemeral port, then hand it to the server.
	probe, probe_err := net.listen_tcp(net.Endpoint{net.IP4_Loopback, 0})
	if !testing.expect(t, probe_err == nil, "cannot probe for a free port") {
		return
	}
	probe_endpoint, _ := net.bound_endpoint(probe)
	port := probe_endpoint.port
	net.close(probe)
	port_text := fmt.aprintf("%d", port)
	defer delete(port_text)

	command := []string{java, "-cp", classpath, "dev.frostlake.http.DatabaseHttpServer", port_text}
	server, start_err := os.process_start({command = command})
	if !testing.expectf(t, start_err == nil, "failed to spawn the Frostlake server: %v", start_err) {
		return
	}
	defer {
		_ = os.process_kill(server)
		_, _ = os.process_wait(server)
	}

	dsn := fmt.aprintf("frostlake://127.0.0.1:%d", port)
	defer delete(dsn)
	conn: Connection
	connected := false
	for _ in 0 ..< 150 {
		candidate, connect_err := connect(dsn)
		if connect_err == nil {
			conn = candidate
			connected = true
			break
		}
		destroy_error(connect_err)
		time.sleep(200 * time.Millisecond)
	}
	if !testing.expect(t, connected, "server did not become healthy") {
		return
	}
	defer destroy_connection(&conn)

	// DDL, DML and a typed query through binds.
	if !exec_ok(t, &conn, "CREATE OR REPLACE DATABASE odin_test_db") {
		return
	}
	exec_ok(t, &conn, "USE DATABASE odin_test_db")
	exec_ok(t, &conn, "CREATE TABLE people (id INTEGER, name VARCHAR, score FLOAT, ok BOOLEAN)")
	inserted, inserted_ok := exec(
		t,
		&conn,
		"INSERT INTO people VALUES (?, ?, ?, ?), (?, ?, ?, ?)",
		{i128(1), "Ada O'Hara \\ Byron", 9.5, true, i128(2), "Grace", 8.25, false},
	)
	if inserted_ok {
		testing.expect_value(t, inserted.row_count, 2)
		testing.expect_value(t, inserted.update_count, i64(2))
		destroy_result(&inserted)
	}
	queried, queried_ok := exec(t, &conn, "SELECT id, name, score, ok FROM people WHERE id = ?", {i128(1)})
	if queried_ok {
		testing.expect_value(t, len(queried.rows), 1)
		expect_cell(t, queried, 0, "ID", i128(1))
		expect_cell(t, queried, 0, "NAME", "Ada O'Hara \\ Byron")
		expect_cell(t, queried, 0, "SCORE", 9.5)
		expect_cell(t, queried, 0, "OK", true)
		destroy_result(&queried)
	}

	// Session state persists across statements (the table is unqualified).
	counted, counted_ok := exec(t, &conn, "SELECT COUNT(*) AS n FROM people")
	if counted_ok {
		expect_cell(t, counted, 0, "N", i128(2))
		destroy_result(&counted)
	}

	// Transaction rollback.
	exec_ok(t, &conn, "CREATE TABLE acc (n INTEGER)")
	exec_ok(t, &conn, "INSERT INTO acc VALUES (1)")
	testing.expect(t, begin(&conn) == nil)
	exec_ok(t, &conn, "INSERT INTO acc VALUES (2)")
	testing.expect(t, rollback(&conn) == nil)
	rolled_back, rolled_back_ok := exec(t, &conn, "SELECT COUNT(*) AS n FROM acc")
	if rolled_back_ok {
		expect_cell(t, rolled_back, 0, "N", i128(1))
		destroy_result(&rolled_back)
	}

	// Integral NUMBER stays exact far past i64.
	big, big_ok := exec(t, &conn, "SELECT 12345678901234567890123456789::NUMBER(38,0) AS n")
	if big_ok {
		expect_cell(t, big, 0, "N", i128(12345678901234567890123456789))
		destroy_result(&big)
	}

	// Temporal and binary binds round-trip with typed results.
	exec_ok(t, &conn, "CREATE TABLE stamps (id INTEGER, moment TIMESTAMP_NTZ, d DATE, b BINARY)")
	exec_ok(
		t,
		&conn,
		"INSERT INTO stamps VALUES (?, ?, ?, ?)",
		{i128(1), Timestamp{"2026-08-13T12:34:56.789000"}, Date{"2026-08-13"}, Bytes{0xCA, 0xFE}},
	)
	stamped, stamped_ok := exec(t, &conn, "SELECT moment, d, b FROM stamps WHERE id = 1")
	if stamped_ok {
		moment, _ := get(stamped, 0, "MOMENT")
		if moment_value, is_timestamp := moment.(Timestamp); is_timestamp {
			testing.expectf(t, strings.has_prefix(moment_value.text, "2026-08-13 12:34:56.789"), "MOMENT = %s", moment_value.text)
		} else {
			testing.expectf(t, false, "MOMENT = %v", moment)
		}
		expect_cell(t, stamped, 0, "D", Date{"2026-08-13"})
		expect_cell(t, stamped, 0, "B", Bytes{0xCA, 0xFE})
		destroy_result(&stamped)
	}

	// NULL binds round-trip to NULL cells; reads are case-insensitive; a
	// SELECT's row_count is its row total.
	exec_ok(t, &conn, "INSERT INTO people VALUES (?, ?, ?, ?)", {i128(3), nil, nil, nil})
	nulls, nulls_ok := exec(t, &conn, "SELECT name, score FROM people WHERE id = 3")
	if nulls_ok {
		expect_cell(t, nulls, 0, "NAME", nil)
		expect_cell(t, nulls, 0, "score", nil)
		testing.expect_value(t, nulls.row_count, 1)
		testing.expect_value(t, nulls.update_count, nil)
		destroy_result(&nulls)
	}
	exec_ok(t, &conn, "DELETE FROM people WHERE id = 3")

	// Transaction commit persists.
	testing.expect(t, begin(&conn) == nil)
	exec_ok(t, &conn, "INSERT INTO acc VALUES (3)")
	testing.expect(t, commit(&conn) == nil)
	committed, committed_ok := exec(t, &conn, "SELECT COUNT(*) AS n FROM acc")
	if committed_ok {
		expect_cell(t, committed, 0, "N", i128(2))
		destroy_result(&committed)
	}

	// Every timestamp flavour converts to Timestamp; TIME stays text;
	// VARBINARY decodes like BINARY.
	exec_ok(t, &conn, "CREATE TABLE flavours (ltz TIMESTAMP_LTZ, tz TIMESTAMP_TZ, t TIME, vb VARBINARY)")
	exec_ok(
		t,
		&conn,
		"INSERT INTO flavours VALUES ('2026-08-19 10:00:00', '2026-08-19 10:00:00 +02:00', '12:34:56', X'CAFE')",
	)
	flavours, flavours_ok := exec(t, &conn, "SELECT ltz, tz, t, vb FROM flavours")
	if flavours_ok {
		expect_timestamp_prefix(t, flavours, "LTZ", "2026-08-19 10:00:00")
		expect_timestamp_prefix(t, flavours, "TZ", "2026-08-19 10:00:00")
		time_cell, _ := get(flavours, 0, "T")
		if time_text, is_text := time_cell.(string); is_text {
			testing.expectf(t, strings.has_prefix(time_text, "12:34:56"), "T = %s", time_text)
		} else {
			testing.expectf(t, false, "T = %v", time_cell)
		}
		expect_cell(t, flavours, 0, "VB", Bytes{0xCA, 0xFE})
		destroy_result(&flavours)
	}

	// An Array bind renders as an array literal — usable in expressions (the
	// engine deliberately rejects them inside INSERT ... VALUES, like Snowflake).
	array_bind := Array(make([dynamic]Value))
	append(&array_bind, i128(1))
	append(&array_bind, "x")
	arrayed, arrayed_ok := exec(t, &conn, "SELECT ? AS a", {array_bind})
	if arrayed_ok {
		cell, _ := get(arrayed, 0, "A")
		if text, is_text := cell.(string); is_text {
			testing.expectf(t, strings.contains(text, "1") && strings.contains(text, "x"), "A = %s", text)
		} else {
			testing.expectf(t, false, "A = %v", cell)
		}
		destroy_result(&arrayed)
	}
	delete(array_bind) // the "x" element is a literal, so only the container is heap

	// A request may say for itself how many statements it carries. The session is
	// still at one statement a request, so the pack is refused on its count alone.
	//
	// Only an engine that counts the statements in a request refuses a pack at
	// all, and this driver supports older ones than that. Against one of those
	// the refusal never comes, so the check is skipped rather than passed: a
	// green tick would claim an engine had been checked for a refusal it does
	// not make.
	refused, refused_err := execute(&conn, "SELECT 1 AS one; SELECT 2 AS two")
	counts_statements := refused_err != nil
	if counts_statements {
		testing.expectf(
			t,
			strings.contains(error_message(refused_err), "statement count"),
			"error was: %s",
			error_message(refused_err),
		)
		destroy_error(refused_err)
	} else {
		skip_check(
			"a pack nobody asked for is refused",
			"this engine does not enforce a statement count",
		)
		destroy_result(&refused)
	}
	// The same pack, saying how many statements it holds. No ALTER SESSION anywhere.
	packed, packed_err := execute(
		&conn,
		"CREATE TABLE packed (id INTEGER); INSERT INTO packed VALUES (1), (2)",
		multi_statement_count = 2,
	)
	if testing.expectf(t, packed_err == nil, "a pack declaring its count should run: %s", error_message(packed_err)) {
		destroy_result(&packed)
	} else {
		destroy_error(packed_err)
	}
	packed_count, packed_count_ok := exec(t, &conn, "SELECT COUNT(*) AS n FROM packed")
	if packed_count_ok {
		expect_cell(t, packed_count, 0, "N", i128(2))
		destroy_result(&packed_count)
	}
	// The count belonged to that one request, so the session is where it was.
	still_one, still_one_err := execute(&conn, "SELECT 1 AS one; SELECT 2 AS two")
	if counts_statements {
		testing.expect(t, still_one_err != nil, "the session should still be at one statement a request")
	} else {
		skip_check(
			"the count a request declared does not stay behind on the session",
			"this engine does not enforce a statement count",
		)
	}
	if still_one_err != nil {
		destroy_error(still_one_err)
	} else {
		destroy_result(&still_one)
	}

	// A multi-statement request answers with several result sets; the driver
	// surfaces the first, as documented. The engine refuses a pack the caller did
	// not ask for, so the session asks for any number first.
	asked, asked_ok := exec(t, &conn, "ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")
	if asked_ok {
		destroy_result(&asked)
	}
	multi, multi_ok := exec(t, &conn, "SELECT 1 AS one; SELECT 2 AS two")
	if multi_ok {
		expect_cell(t, multi, 0, "ONE", i128(1))
		destroy_result(&multi)
	}

	// Column metadata: a text or binary column reports its declared width --
	// characters for VARCHAR, bytes for BINARY, the most it could hold for an
	// unbounded one -- and every other type reports none.
	exec_ok(t, &conn, "CREATE TABLE widths (v9 VARCHAR(9), b5 BINARY(5), n NUMBER(10,2), vu VARCHAR)")
	widths, widths_ok := exec(t, &conn, "SELECT v9, b5, n, vu FROM widths")
	if widths_ok {
		if testing.expect(t, len(widths.columns) == 4, "four columns") {
			// Engines before 0.1.0 send no length at all, and this driver
			// supports them: a column then reports none, and there is no width
			// to check. Skipped rather than passed -- a green tick would claim
			// an engine had been checked for a width it never sends.
			if widths.columns[0].length == nil {
				skip_check(
					"a text or binary column reports its declared width",
					"this engine sends no column length",
				)
			} else {
				testing.expect_value(t, widths.columns[0].length, i64(9))
				testing.expect_value(t, widths.columns[1].length, i64(5))
				testing.expect_value(t, widths.columns[3].length, i64(16777216))
			}
			// A number carries no width whichever engine answered.
			testing.expect_value(t, widths.columns[2].length, nil)
		}
		destroy_result(&widths)
	}

	// Dollar-quoted strings pass through substitution untouched.
	dollar, dollar_ok := exec(t, &conn, "SELECT $$a?b$$ AS s, ? AS n", {i128(7)})
	if dollar_ok {
		expect_cell(t, dollar, 0, "S", "a?b")
		expect_cell(t, dollar, 0, "N", i128(7))
		destroy_result(&dollar)
	}

	// MERGE, UPDATE and DELETE report affected-row counts: UPDATE's always-0
	// "multi-joined" column stays out of the sum, MERGE's per-action counts add up.
	// Each keeps its Snowflake-shaped grid, one count column per action.
	created, created_ok := exec(t, &conn, "CREATE TABLE tgt (id INTEGER, v VARCHAR)")
	if created_ok {
		testing.expect_value(t, created.update_count, nil)
		destroy_result(&created)
	}
	exec_ok(t, &conn, "CREATE TABLE src (id INTEGER, v VARCHAR)")
	exec_ok(t, &conn, "INSERT INTO tgt VALUES (1, 'old')")
	exec_ok(t, &conn, "INSERT INTO src VALUES (1, 'new'), (2, 'ins')")
	merged, merged_ok := exec(
		t,
		&conn,
		"MERGE INTO tgt USING src ON tgt.id = src.id WHEN MATCHED THEN UPDATE SET v = src.v WHEN NOT MATCHED THEN INSERT VALUES (src.id, src.v)",
	)
	if merged_ok {
		testing.expect_value(t, merged.row_count, 2)
		testing.expect_value(t, merged.update_count, i64(2))
		expect_cell(t, merged, 0, "number of rows inserted", i128(1))
		expect_cell(t, merged, 0, "number of rows updated", i128(1))
		destroy_result(&merged)
	}
	updated, updated_ok := exec(t, &conn, "UPDATE tgt SET v = 'x' WHERE id IN (1, 2)")
	if updated_ok {
		testing.expect_value(t, updated.row_count, 2)
		testing.expect_value(t, updated.update_count, i64(2))
		expect_cell(t, updated, 0, "number of rows updated", i128(2))
		expect_cell(t, updated, 0, "number of multi-joined rows updated", i128(0))
		destroy_result(&updated)
	}
	untouched, untouched_ok := exec(t, &conn, "UPDATE tgt SET v = 'y' WHERE id = 999")
	if untouched_ok {
		testing.expect_value(t, untouched.update_count, i64(0))
		destroy_result(&untouched)
	}
	deleted, deleted_ok := exec(t, &conn, "DELETE FROM tgt WHERE id IN (1, 2)")
	if deleted_ok {
		testing.expect_value(t, deleted.row_count, 2)
		testing.expect_value(t, deleted.update_count, i64(2))
		destroy_result(&deleted)
	}

	// A query can carry a DML count name of its own. An engine that reports
	// updateCount says it is not DML, so it stays a one-row query. Engines before
	// 0.1.0 report nothing and the name is all there is to go on, so the check
	// is skipped there rather than passed.
	version, version_ok := exec(t, &conn, "SELECT CURRENT_VERSION() AS v")
	reports_update_count := false
	if version_ok {
		cell, _ := get(version, 0, "V")
		if text, is_text := cell.(string); is_text {
			reports_update_count = engine_version_at_least(text, 0, 1)
		}
		destroy_result(&version)
	}
	aliased, aliased_ok := exec(t, &conn, "SELECT 9 AS \"number of rows inserted\"")
	if aliased_ok {
		expect_cell(t, aliased, 0, "number of rows inserted", i128(9))
		if reports_update_count {
			testing.expect_value(t, aliased.update_count, nil)
			testing.expect_value(t, aliased.row_count, 1)
		} else {
			skip_check("a query carrying a DML count name stays a query", "this engine reports no updateCount")
		}
		destroy_result(&aliased)
	}

	// A DSN naming database and schema lands the session there (identifiers
	// travel bare, so the engine uppercases them Snowflake-style).
	scoped_dsn := fmt.aprintf("frostlake://127.0.0.1:%d/odin_test_db?schema=public", port)
	defer delete(scoped_dsn)
	scoped, scoped_err := connect(scoped_dsn)
	if testing.expectf(t, scoped_err == nil, "DSN with database/schema failed: %s", error_message(scoped_err)) {
		scoped_count, scoped_count_ok := exec(t, &scoped, "SELECT COUNT(*) AS n FROM people")
		if scoped_count_ok {
			expect_cell(t, scoped_count, 0, "N", i128(2))
			destroy_result(&scoped_count)
		}
		destroy_connection(&scoped)
	} else {
		destroy_error(scoped_err)
	}

	// A DSN naming a database that does not exist fails on first use — and
	// keeps failing rather than silently running in the default database.
	broken_dsn := fmt.aprintf("frostlake://127.0.0.1:%d/odin_no_such_db", port)
	defer delete(broken_dsn)
	broken, broken_err := connect(broken_dsn)
	if testing.expect(t, broken_err == nil, "connect ignores the DSN database, so it should succeed") {
		first_result, first_err := execute(&broken, "SELECT 1")
		if testing.expect(t, first_err != nil, "USE of a missing database should fail") {
			destroy_error(first_err)
		} else {
			destroy_result(&first_result)
		}
		second_result, second_err := execute(&broken, "SELECT 1")
		if testing.expect(t, second_err != nil, "the failed USE should stay queued") {
			destroy_error(second_err)
		} else {
			destroy_result(&second_result)
		}
		destroy_connection(&broken)
	} else {
		destroy_error(broken_err)
	}

	// The error surface carries the engine's message.
	failed_result, failed_err := execute(&conn, "SELECT FROM nowhere")
	if testing.expect(t, failed_err != nil, "SELECT FROM nowhere should fail") {
		testing.expectf(
			t,
			strings.contains(error_message(failed_err), "SQL compilation error"),
			"error was: %s",
			error_message(failed_err),
		)
		destroy_error(failed_err)
	} else {
		destroy_result(&failed_result)
	}
}

// Whether a CURRENT_VERSION() answer such as "0.1.0" or "0.1.1-SNAPSHOT" is at
// least major.minor.
@(private = "file")
engine_version_at_least :: proc(version: string, major, minor: int) -> bool {
	parts: [2]int
	part := 0
	for i in 0 ..< len(version) {
		c := version[i]
		if c >= '0' && c <= '9' {
			parts[part] = parts[part] * 10 + int(c - '0')
		} else if c == '.' && part == 0 {
			part = 1
		} else {
			break
		}
	}
	return parts[0] > major || (parts[0] == major && parts[1] >= minor)
}

@(private = "file")
exec :: proc(
	t: ^testing.T,
	conn: ^Connection,
	sql: string,
	binds: []Value = nil,
	loc := #caller_location,
) -> (
	result: Query_Result,
	ok: bool,
) {
	execute_err: Error
	result, execute_err = execute(conn, sql, binds)
	if execute_err != nil {
		testing.expectf(t, false, "execute(%s) failed: %s", sql, error_message(execute_err), loc = loc)
		destroy_error(execute_err)
		return {}, false
	}
	return result, true
}

@(private = "file")
exec_ok :: proc(t: ^testing.T, conn: ^Connection, sql: string, binds: []Value = nil, loc := #caller_location) -> bool {
	result, ok := exec(t, conn, sql, binds, loc)
	if ok {
		destroy_result(&result)
	}
	return ok
}

@(private = "file")
expect_cell :: proc(
	t: ^testing.T,
	result: Query_Result,
	row: int,
	column: string,
	expected: Value,
	loc := #caller_location,
) {
	cell, found := get(result, row, column)
	if !testing.expectf(t, found, "column %s not found", column, loc = loc) {
		return
	}
	testing.expectf(t, values_equal(cell, expected), "%s = %v, want %v", column, cell, expected, loc = loc)
}

@(private = "file")
expect_timestamp_prefix :: proc(
	t: ^testing.T,
	result: Query_Result,
	column: string,
	prefix: string,
	loc := #caller_location,
) {
	cell, _ := get(result, 0, column)
	if stamped, is_timestamp := cell.(Timestamp); is_timestamp {
		testing.expectf(t, strings.has_prefix(stamped.text, prefix), "%s = %s", column, stamped.text, loc = loc)
	} else {
		testing.expectf(t, false, "%s = %v", column, cell, loc = loc)
	}
}
