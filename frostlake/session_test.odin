// How a connection keeps its idea of the engine session in step with the
// engine's, against a scripted loopback server: requireSession once the engine
// is known to honour it, recovery from a session the engine no longer holds,
// and the session released on close. Each test ends its server with
// loopback_stop, so a request the driver failed to send shows up as a missing
// one rather than as a test that never finishes.
package frostlake

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// Answers from an engine that reports newSession (0.1.0 and later).
@(private = "file")
S1_NEW :: `{"success":true,"sessionId":"s1","newSession":true,"resultSets":[]}`
@(private = "file")
S1 :: `{"success":true,"sessionId":"s1","newSession":false,"resultSets":[]}`
@(private = "file")
S2_NEW :: `{"success":true,"sessionId":"s2","newSession":true,"resultSets":[]}`
@(private = "file")
S2 :: `{"success":true,"sessionId":"s2","newSession":false,"resultSets":[]}`
@(private = "file")
S2_SEVEN :: `{"success":true,"sessionId":"s2","newSession":false,"resultSets":[{"columns":[{"name":"N","dataType":"NUMBER"}],"rows":[[7]]}]}`
@(private = "file")
S3_NEW :: `{"success":true,"sessionId":"s3","newSession":true,"resultSets":[]}`
@(private = "file")
S3 :: `{"success":true,"sessionId":"s3","newSession":false,"resultSets":[]}`

// The 404 a request that requires its session gets once the engine no longer
// holds it: nothing ran.
@(private = "file")
GONE_S1 :: `{"success":false,"errorMessage":"Session 's1' does not exist or has expired.","sessionId":null,"newSession":false,"resultSets":[]}`
@(private = "file")
GONE_S2 :: `{"success":false,"errorMessage":"Session 's2' does not exist or has expired.","sessionId":null,"newSession":false,"resultSets":[]}`

// What DELETE /api/sessions/{id} answers for a session the engine held.
@(private = "file")
RELEASED :: `{"success":true,"sessionId":null,"newSession":false,"resultSets":[]}`

// An answer from an engine that predates newSession (0.0.7).
@(private = "file")
LEGACY :: `{"success":true,"sessionId":"s1","resultSets":[]}`

@(private = "file")
USE_APP :: `"sql":"USE DATABASE APP"`

@(test)
test_require_session_waits_for_the_engine :: proc(t: ^testing.T) {
	exchanges := []Canned_Exchange{{200, S1_NEW}, {200, S1}, {200, RELEASED}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)
	defer destroy_connection(&conn)

	run_ok(t, &conn, "SELECT 1")
	close(&conn)

	seen := loopback_stop(server)
	if !testing.expect_value(t, len(seen), 3) {
		return
	}
	// Nothing is known before the first answer, so the request that starts the
	// session carries neither an id nor the flag.
	testing.expectf(t, strings.contains(seen[0], USE_APP), "request was: %s", seen[0])
	testing.expectf(t, !strings.contains(seen[0], "sessionId"), "request was: %s", seen[0])
	testing.expectf(t, !strings.contains(seen[0], "requireSession"), "request was: %s", seen[0])
	// That answer carried newSession, so every request naming the session
	// requires it from then on.
	testing.expectf(t, strings.contains(seen[1], "\"sessionId\":\"s1\""), "request was: %s", seen[1])
	testing.expectf(t, strings.contains(seen[1], "\"requireSession\":true"), "request was: %s", seen[1])
	testing.expectf(t, strings.has_prefix(seen[2], "DELETE /api/sessions/s1 HTTP/1.1\r\n"), "request was: %s", seen[2])
}

@(test)
test_an_older_engine_is_sent_no_session_flag_and_no_release :: proc(t: ^testing.T) {
	// Engines before 0.1.0 answer no newSession and know neither requireSession
	// nor DELETE /api/sessions: their parser may refuse a field it does not
	// know. The third exchange is what a stray DELETE would get.
	exchanges := []Canned_Exchange{{200, LEGACY}, {200, LEGACY}, {200, LEGACY}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)
	defer destroy_connection(&conn)

	run_ok(t, &conn, "SELECT 1")
	close(&conn)

	seen := loopback_stop(server)
	if !testing.expect_value(t, len(seen), 2) {
		return
	}
	testing.expectf(t, strings.contains(seen[1], "\"sessionId\":\"s1\""), "request was: %s", seen[1])
	testing.expectf(t, !strings.contains(seen[1], "requireSession"), "request was: %s", seen[1])
}

@(test)
test_a_lost_session_is_replaced_and_the_statement_sent_once_more :: proc(t: ^testing.T) {
	exchanges := []Canned_Exchange{
		{200, S1_NEW},   // USE DATABASE
		{200, S1},       // CREATE TABLE, which is no context
		{404, GONE_S1},  // SELECT 7: the session is gone
		{200, S2_NEW},   // USE DATABASE, in a fresh session
		{200, S2_SEVEN}, // SELECT 7, once more
		{200, RELEASED},
	}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)
	defer destroy_connection(&conn)

	run_ok(t, &conn, "CREATE TABLE t (a INT)")
	result, err := execute(&conn, "SELECT 7 AS n")
	if testing.expectf(t, err == nil, "the statement should have been sent again: %s", error_message(err)) {
		cell, _ := get(result, 0, "N")
		testing.expect(t, values_equal(cell, i128(7)))
		destroy_result(&result)
	} else {
		destroy_error(err)
	}
	testing.expect_value(t, conn.session_id, "s2")
	close(&conn)

	seen := loopback_stop(server)
	if !testing.expect_value(t, len(seen), 6) {
		return
	}
	// The scope went onto a fresh session, named by no id, and the statement
	// followed it there.
	testing.expectf(t, strings.contains(seen[3], USE_APP) && !strings.contains(seen[3], "sessionId"), "request was: %s", seen[3])
	testing.expectf(t, strings.contains(seen[4], "SELECT 7 AS n"), "request was: %s", seen[4])
	testing.expectf(t, strings.contains(seen[4], "\"sessionId\":\"s2\",\"requireSession\":true"), "request was: %s", seen[4])
	testing.expectf(t, strings.has_prefix(seen[5], "DELETE /api/sessions/s2 "), "request was: %s", seen[5])
}

@(test)
test_a_session_refused_twice_raises_and_the_connection_carries_on :: proc(t: ^testing.T) {
	exchanges := []Canned_Exchange{
		{200, S1_NEW},  // USE DATABASE
		{404, GONE_S1}, // SELECT 1
		{200, S2_NEW},  // USE DATABASE, in a fresh session
		{404, GONE_S2}, // SELECT 1, refused again
		{200, S3_NEW},  // the next statement starts over
		{200, S3},      // SELECT 2
		{200, RELEASED},
	}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)
	defer destroy_connection(&conn)

	expect_session_lost(t, &conn, "SELECT 1", "just started")
	testing.expect(t, !conn.closed)
	// The connection carries on: the next statement starts a fresh session on
	// the DSN's scope.
	run_ok(t, &conn, "SELECT 2")
	close(&conn)

	seen := loopback_stop(server)
	if !testing.expect_value(t, len(seen), 7) {
		return
	}
	testing.expectf(t, strings.contains(seen[4], USE_APP) && !strings.contains(seen[4], "sessionId"), "request was: %s", seen[4])
	testing.expectf(t, strings.contains(seen[5], "SELECT 2"), "request was: %s", seen[5])
}

@(test)
test_a_lost_transaction_raises_and_nothing_is_sent_again :: proc(t: ^testing.T) {
	exchanges := []Canned_Exchange{
		{200, S1_NEW},  // USE DATABASE
		{200, S1},      // BEGIN
		{404, GONE_S1}, // INSERT: the session is gone
		{200, S2_NEW},  // the next statement starts over
		{200, S2},      // SELECT 1
		{200, RELEASED},
	}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)
	defer destroy_connection(&conn)

	testing.expect(t, begin(&conn) == nil)
	testing.expect(t, conn.in_transaction)
	expect_session_lost(t, &conn, "INSERT INTO t VALUES (1)", "transaction")
	testing.expect(t, !conn.in_transaction)
	testing.expect(t, conn.auto_commit)
	run_ok(t, &conn, "SELECT 1")
	close(&conn)

	seen := loopback_stop(server)
	if !testing.expect_value(t, len(seen), 6) {
		return
	}
	// The INSERT was not sent again, and the next statement started over on
	// the DSN's scope with autocommit back on.
	testing.expectf(t, strings.contains(seen[2], "INSERT INTO t VALUES (1)"), "request was: %s", seen[2])
	testing.expectf(t, strings.contains(seen[3], USE_APP) && !strings.contains(seen[3], "sessionId"), "request was: %s", seen[3])
	testing.expectf(t, strings.contains(seen[3], "\"autoCommit\":true"), "request was: %s", seen[3])
	testing.expectf(t, strings.contains(seen[4], "SELECT 1") && strings.contains(seen[4], "\"autoCommit\":true"), "request was: %s", seen[4])
}

@(test)
test_a_transaction_begun_as_a_statement_is_tracked :: proc(t: ^testing.T) {
	exchanges := []Canned_Exchange{
		{200, S1_NEW},  // USE DATABASE
		{200, S1},      // BEGIN TRANSACTION
		{200, S1},      // COMMIT
		{200, S1},      // START TRANSACTION
		{404, GONE_S1}, // INSERT: the session is gone
	}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)
	defer destroy_connection(&conn)

	run_ok(t, &conn, "BEGIN TRANSACTION")
	testing.expect(t, conn.in_transaction)
	run_ok(t, &conn, "COMMIT")
	testing.expect(t, !conn.in_transaction)
	run_ok(t, &conn, "START TRANSACTION")
	testing.expect(t, conn.in_transaction)
	expect_session_lost(t, &conn, "INSERT INTO t VALUES (1)", "transaction")
	testing.expect(t, !conn.in_transaction)
	// The session is gone, so closing has nothing to release.
	close(&conn)
	seen := loopback_stop(server)
	testing.expect_value(t, len(seen), 5)
}

@(test)
test_a_session_lost_after_context_was_set_up_raises :: proc(t: ^testing.T) {
	// Each of these leaves something behind that a fresh session would not
	// have, so re-running the next statement in one would run it elsewhere.
	contexts := []string{
		"USE SCHEMA OTHER",
		"SET v = 1",
		"ALTER SESSION SET TIMEZONE = 'UTC'",
		"CREATE TEMPORARY TABLE scratch (a INT)",
	}
	for context_sql in contexts {
		exchanges := []Canned_Exchange{
			{200, S1_NEW},  // USE DATABASE
			{200, S1},      // the context
			{404, GONE_S1}, // SELECT: the session is gone
			{200, S2_NEW},  // the next statement starts over
			{200, S2},      // SELECT 1
			{200, RELEASED},
		}
		server := loopback_start(exchanges)
		conn := open_app(server)

		run_ok(t, &conn, context_sql)
		expect_session_lost(t, &conn, "SELECT * FROM t", "context")
		run_ok(t, &conn, "SELECT 1")
		close(&conn)

		seen := loopback_stop(server)
		if testing.expectf(t, len(seen) == 6, "after %s: %d requests", context_sql, len(seen)) {
			testing.expectf(t, strings.contains(seen[2], "SELECT * FROM t"), "request was: %s", seen[2])
			testing.expectf(t, strings.contains(seen[3], USE_APP) && !strings.contains(seen[3], "sessionId"), "request was: %s", seen[3])
		}
		destroy_connection(&conn)
		loopback_destroy(server)
	}
}

@(test)
test_a_replaced_session_gets_the_scope_back_first :: proc(t: ^testing.T) {
	// An engine that ran a request in a fresh session in place of the one it
	// named says so with newSession: true; what the old one held is gone.
	exchanges := []Canned_Exchange{
		{200, S1_NEW}, // USE DATABASE
		{200, S1_NEW}, // SELECT 1, in a fresh session
		{200, S1},     // USE DATABASE, again
		{200, S1},     // SELECT 2
		{200, RELEASED},
	}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)
	defer destroy_connection(&conn)

	run_ok(t, &conn, "SELECT 1")
	run_ok(t, &conn, "SELECT 2")
	close(&conn)

	seen := loopback_stop(server)
	if !testing.expect_value(t, len(seen), 5) {
		return
	}
	testing.expectf(t, strings.contains(seen[2], USE_APP), "request was: %s", seen[2])
	testing.expectf(t, strings.contains(seen[3], "SELECT 2"), "request was: %s", seen[3])
}

@(test)
test_closing_releases_the_session_once :: proc(t: ^testing.T) {
	// The fourth exchange is what a second DELETE would get.
	exchanges := []Canned_Exchange{{200, S1_NEW}, {200, S1}, {200, RELEASED}, {200, RELEASED}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)

	testing.expect(t, begin(&conn) == nil)
	close(&conn)
	close(&conn)
	destroy_connection(&conn)

	seen := loopback_stop(server)
	if !testing.expect_value(t, len(seen), 3) {
		return
	}
	// Releasing the session rolls its open transaction back too.
	testing.expectf(t, strings.has_prefix(seen[2], "DELETE /api/sessions/s1 HTTP/1.1\r\n"), "request was: %s", seen[2])
}

@(test)
test_destroying_an_open_connection_releases_its_session :: proc(t: ^testing.T) {
	exchanges := []Canned_Exchange{{200, S1_NEW}, {200, RELEASED}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_bare(server)

	run_ok(t, &conn, "SELECT 1")
	destroy_connection(&conn)

	seen := loopback_stop(server)
	if testing.expect_value(t, len(seen), 2) {
		testing.expectf(t, strings.has_prefix(seen[1], "DELETE /api/sessions/s1 "), "request was: %s", seen[1])
	}
}

@(test)
test_a_refused_scope_still_releases_its_session :: proc(t: ^testing.T) {
	// The engine refused the USE, but in a session it started for it.
	refused := `{"success":false,"errorMessage":"Database 'APP' does not exist or not authorized.","sessionId":"s9","newSession":true,"resultSets":[]}`
	exchanges := []Canned_Exchange{{200, refused}, {200, RELEASED}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_app(server)

	result, err := execute(&conn, "SELECT 1")
	if testing.expect(t, err != nil, "a refused scope should fail the statement") {
		testing.expectf(t, strings.contains(error_message(err), "APP"), "error was: %s", error_message(err))
		destroy_error(err)
	} else {
		destroy_result(&result)
	}
	destroy_connection(&conn)

	seen := loopback_stop(server)
	if testing.expect_value(t, len(seen), 2) {
		testing.expectf(t, strings.has_prefix(seen[1], "DELETE /api/sessions/s9 "), "request was: %s", seen[1])
	}
}

@(test)
test_closing_never_fails_whatever_the_release_meets :: proc(t: ^testing.T) {
	// A 404, a 405, a hang-up, silence, and nothing listening at all: close has
	// no error to return, and it waits no longer than its five seconds.
	gone := `{"success":false,"errorMessage":"Session 's1' does not exist or has expired.","sessionId":null,"resultSets":[]}`
	replies := []Canned_Exchange{{404, gone}, {405, ""}, {LOOPBACK_HANG_UP, ""}, {LOOPBACK_HOLD, ""}}
	for reply, index in replies {
		exchanges := []Canned_Exchange{{200, S1_NEW}, reply}
		server := loopback_start(exchanges)
		conn := open_bare(server)
		run_ok(t, &conn, "SELECT 1")

		started := time.tick_now()
		close(&conn)
		took := time.tick_since(started)
		testing.expectf(t, took < 8 * time.Second, "case %d: closing took %v", index, took)
		testing.expect(t, conn.closed)

		seen := loopback_stop(server)
		if testing.expectf(t, len(seen) == 2, "case %d: %d requests", index, len(seen)) {
			testing.expectf(t, strings.has_prefix(seen[1], "DELETE /api/sessions/s1 "), "case %d: request was: %s", index, seen[1])
		}
		destroy_connection(&conn)
		loopback_destroy(server)
	}

	// Nothing listening: the release cannot even connect.
	exchanges := []Canned_Exchange{{200, S1_NEW}}
	server := loopback_start(exchanges)
	defer loopback_destroy(server)
	conn := open_bare(server)
	defer destroy_connection(&conn)
	run_ok(t, &conn, "SELECT 1")
	_ = loopback_stop(server)
	close(&conn)
	testing.expect(t, conn.closed)
}

@(test)
test_session_statements_are_recognised :: proc(t: ^testing.T) {
	// What a fresh session would not have: a moved scope, a setting, a
	// variable, or a temporary object.
	for statement in ([]string{
			"USE SCHEMA other",
			"set v = 1",
			"UNSET v",
			"ALTER SESSION SET TIMEZONE = 'UTC'",
			"CREATE DATABASE d",
			"CREATE OR REPLACE SCHEMA s",
			"DROP DATABASE IF EXISTS d",
			"CREATE TEMPORARY TABLE t (a INT)",
			"create temp table t (a int)",
			"CREATE OR REPLACE LOCAL TEMPORARY TABLE t (a INT)",
			"CREATE VOLATILE TABLE t (a INT)",
			"/* note */ -- more\n USE WAREHOUSE w",
		}) {
		testing.expectf(t, touches_session(statement), "%s should touch the session", statement)
	}
	// A permanent object, or a word that merely looks like a modifier later on,
	// leaves the session as it was.
	for statement in ([]string{
			"SELECT 1",
			"CREATE TABLE t (a INT)",
			"CREATE TRANSIENT TABLE t (a INT)",
			"CREATE TABLE temporary (a INT)",
			"DROP TABLE temp",
			"ALTER TABLE t ADD COLUMN c INT",
			"INSERT INTO t VALUES (1)",
			"'USE DATABASE d'",
		}) {
		testing.expectf(t, !touches_session(statement), "%s should leave the session alone", statement)
	}

	testing.expect_value(t, transaction_effect("BEGIN"), Transaction_Effect.Begins)
	testing.expect_value(t, transaction_effect("begin transaction"), Transaction_Effect.Begins)
	testing.expect_value(t, transaction_effect("BEGIN WORK"), Transaction_Effect.Begins)
	testing.expect_value(t, transaction_effect("BEGIN NAME t1"), Transaction_Effect.Begins)
	testing.expect_value(t, transaction_effect("START TRANSACTION"), Transaction_Effect.Begins)
	testing.expect_value(t, transaction_effect("COMMIT"), Transaction_Effect.Ends)
	testing.expect_value(t, transaction_effect("rollback work"), Transaction_Effect.Ends)
	// BEGIN followed by a statement opens a scripting block, not a transaction.
	testing.expect_value(t, transaction_effect("BEGIN\n  SELECT 1"), Transaction_Effect.None)
	testing.expect_value(t, transaction_effect("START TASK t"), Transaction_Effect.None)
	testing.expect_value(t, transaction_effect(""), Transaction_Effect.None)
}

@(test)
test_every_statement_of_a_request_is_tracked :: proc(t: ^testing.T) {
	conn: Connection
	// A USE riding behind a SELECT moves the session just as surely...
	track_statements(&conn, "SELECT 1; USE SCHEMA other")
	testing.expect(t, conn.dirty)
	// ...but the same words inside a literal, a comment or a $$ body do not.
	quiet: Connection
	track_statements(&quiet, "SELECT 'x; USE SCHEMA other' -- ; SET v = 1\n; SELECT $$ ; BEGIN $$")
	testing.expect(t, !quiet.dirty)
	testing.expect(t, !quiet.in_transaction)
	// A transaction opened and closed within one request is closed.
	packed: Connection
	track_statements(&packed, "BEGIN; INSERT INTO t VALUES (1); COMMIT")
	testing.expect(t, !packed.in_transaction)
	track_statements(&packed, "BEGIN; INSERT INTO t VALUES (1)")
	testing.expect(t, packed.in_transaction)
}

// A connection on the scripted server whose DSN names database APP.
@(private = "file")
open_app :: proc(server: ^Loopback_Server) -> Connection {
	dsn := fmt.aprintf("frostlake://127.0.0.1:%d/APP", server.port)
	defer delete(dsn)
	conn, _ := open(dsn)
	return conn
}

// A connection on the scripted server whose DSN names no scope.
@(private = "file")
open_bare :: proc(server: ^Loopback_Server) -> Connection {
	dsn := fmt.aprintf("frostlake://127.0.0.1:%d", server.port)
	defer delete(dsn)
	conn, _ := open(dsn)
	return conn
}

@(private = "file")
run_ok :: proc(t: ^testing.T, conn: ^Connection, sql: string, loc := #caller_location) {
	result, err := execute(conn, sql)
	if !testing.expectf(t, err == nil, "execute(%s) failed: %s", sql, error_message(err), loc = loc) {
		destroy_error(err)
		return
	}
	destroy_result(&result)
}

@(private = "file")
expect_session_lost :: proc(t: ^testing.T, conn: ^Connection, sql: string, reason: string, loc := #caller_location) {
	result, err := execute(conn, sql)
	if !testing.expectf(t, err != nil, "execute(%s) should have failed", sql, loc = loc) {
		destroy_result(&result)
		return
	}
	testing.expectf(t, error_kind(err) == .Session_Lost, "execute(%s) failed as %v: %s", sql, error_kind(err), error_message(err), loc = loc)
	testing.expectf(t, strings.contains(error_message(err), reason), "execute(%s) error was: %s", sql, error_message(err), loc = loc)
	destroy_error(err)
}
