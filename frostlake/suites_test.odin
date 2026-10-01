// Runs the engine-owned, language-neutral JSON test suites through THIS driver.
//
// The definitions live in the frostlake repo (engine/src/test/resources/testkit/suites/*.json,
// spec in SCHEMA.md beside them); every statement travels this driver -> HTTP ->
// DatabaseHttpServer. The engine owns the definitions and this file is only the Odin runner —
// a port of the Java reference runner's JsonSuiteTest/Compare/HttpBackend — so suites added on
// the engine side are picked up here with no driver change.
//
//	export FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit
//	FROSTLAKE_CLASSPATH="<engine jar + deps>" odin test frostlake -define:ODIN_TEST_NAMES=frostlake.test_testkit_suites
//	FROSTLAKE_URL=frostlake://localhost:18082 odin test frostlake -define:ODIN_TEST_NAMES=frostlake.test_testkit_suites
//
// FL_CORPUS names the testkit directory whose suites/*.json replay (a relative path resolves
// against the working directory). Without it the test logs that it skipped the corpus and
// returns, as core:testing has no skipped state; one holding no suites fails the test. The
// first command boots a fresh engine (with a private user.home, so stage files stay out of the
// shared default); the second attaches to a running one. TESTKIT_SUITES=a,b keeps only the
// suites whose name contains a listed word, as in the reference. With no engine named the
// whole thing skips, so a checkout without one is never falsely green. The per-test report
// lands in FROSTLAKE_TESTKIT_REPORT, or testkit-odin.tsv in the temp directory.
//
// Semantics (mirroring SCHEMA.md and the reference):
//   - backend names for a suite's skip clause: `odin`, and `http` — the transport it speaks.
//   - per-test isolation: the reference's reset sequence, then the steps on ONE connection,
//     which keeps USE, variables and transactions on a single session.
//   - capabilities: SESSION, COLUMN_NAMES, UPDATE_COUNT (derived from the count grid, as the
//     reference does). No ERROR_CODE — the protocol carries a message only, so an expected
//     error's code/sqlState is counted as a missing API rather than as a failure.
//   - values compare after the reference's normalisation: NULL and booleans folded, anything
//     numeric rounded to 10 significant digits, everything else trimmed text.
package frostlake

import "core:fmt"
import "core:log"
import "core:math"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
TESTKIT_MAX_REPORTED_FAILURES :: 20

@(private = "file")
Testkit_Status :: enum {
	Pass,
	Fail,
	Error,
	Skip,
}

@(private = "file")
Testkit_Engine :: struct {
	dsn:     string,
	process: os.Process,
	booted:  bool,
	home:    string,
}

@(test)
test_testkit_suites :: proc(t: ^testing.T) {
	corpus, _ := os.lookup_env("FL_CORPUS", context.allocator)
	defer delete(corpus)
	if corpus == "" {
		log.info(
			"skipping testkit: set FL_CORPUS to frostlake's engine/src/test/resources/testkit to replay the testkit corpus",
		)
		return
	}
	suites_dir := strings.concatenate({corpus, "/suites"})
	defer delete(suites_dir)
	files := testkit_suite_files(suites_dir)
	defer {
		for file in files {
			delete(file)
		}
		delete(files)
	}
	if !testing.expectf(t, len(files) > 0, "FL_CORPUS=%s: no *.json suites in %s", corpus, suites_dir) {
		return
	}
	engine, engine_named, engine_err := testkit_engine()
	if !engine_named {
		log.info("skipping testkit: set FROSTLAKE_URL, or FROSTLAKE_CLASSPATH to boot an engine")
		return
	}
	defer testkit_engine_stop(&engine)
	if !testing.expectf(t, engine_err == "", "cannot start the engine: %s", engine_err) {
		return
	}
	testing.set_fail_timeout(t, 60 * time.Minute)

	wanted := testkit_wanted_suites()
	defer {
		for word in wanted {
			delete(word)
		}
		delete(wanted)
	}

	conn: Connection
	connected := false
	for _ in 0 ..< 150 {
		candidate, connect_err := connect(engine.dsn)
		if connect_err == nil {
			conn = candidate
			connected = true
			break
		}
		destroy_error(connect_err)
		time.sleep(200 * time.Millisecond)
	}
	if !testing.expect(t, connected, "the engine did not become healthy") {
		return
	}
	defer destroy_connection(&conn)

	started := time.tick_now()
	tsv := strings.builder_make()
	defer strings.builder_destroy(&tsv)
	strings.write_string(&tsv, "suite\ttest\tstatus\tfailedStep\tdetail\tms\n")
	passed, failed, skipped, missing_api, suite_count := 0, 0, 0, 0, 0
	first_failures := make([dynamic]string)
	defer {
		for line in first_failures {
			delete(line)
		}
		delete(first_failures)
	}

	for file in files {
		data, read_err := os.read_entire_file_from_path(file, context.allocator)
		if !testing.expectf(t, read_err == nil, "%s: %v", file, read_err) {
			continue
		}
		suite, parse_err := parse_json(string(data))
		delete(data)
		if parse_err != nil {
			testing.expectf(t, false, "%s: %s", file, error_message(parse_err))
			destroy_error(parse_err)
			continue
		}
		defer destroy_value(suite)

		suite_name, has_name := testkit_member_string(suite, "suite")
		if !has_name {
			suite_name = testkit_file_stem(file)
		}
		if !testkit_is_wanted(wanted[:], suite_name) {
			continue
		}
		suite_count += 1
		tests, _ := testkit_member_array(suite, "tests")
		for test in tests {
			name, _ := testkit_member_string(test, "name")
			tick := time.tick_now()
			status: Testkit_Status
			step := 0
			detail := ""
			if reason, skip := testkit_skip_reason(test); skip {
				status, detail = .Skip, reason
			} else {
				status, step, detail = testkit_run_case(&conn, test, &missing_api)
			}
			switch status {
			case .Pass:
				passed += 1
			case .Skip:
				skipped += 1
			case .Fail, .Error:
				failed += 1
				if len(first_failures) < TESTKIT_MAX_REPORTED_FAILURES {
					line := fmt.tprintf("%s / %s: %v %s", suite_name, name, status, detail)
					append(&first_failures, strings.clone(testkit_truncate(line, 300)))
				}
			}
			ms := 0 if status == .Skip else int(time.duration_milliseconds(time.tick_since(tick)))
			step_text := fmt.tprintf("%d", step) if step > 0 else ""
			fmt.sbprintf(
				&tsv,
				"%s\t%s\t%s\t%s\t%s\t%d\n",
				suite_name,
				name,
				testkit_status_text(status),
				step_text,
				testkit_single_line(detail),
				ms,
			)
			free_all(context.temp_allocator)
		}
	}

	report := testkit_report_path()
	defer delete(report)
	write_err := os.write_entire_file(report, strings.to_string(tsv))
	testing.expectf(t, write_err == nil, "cannot write %s: %v", report, write_err)

	log.infof(
		"testkit [odin]: %d passed, %d failed, %d skipped, %d check(s) needing an API the HTTP transport lacks — %d suite files in %.1f s, report %s",
		passed,
		failed,
		skipped,
		missing_api,
		suite_count,
		time.duration_seconds(time.tick_since(started)),
		report,
	)
	for line in first_failures {
		log.infof("  %s", line)
	}
	testing.expectf(t, failed == 0, "testkit cases failed; see %s", report)
}

// The engine to run against: FROSTLAKE_URL attaches, FROSTLAKE_CLASSPATH boots one. engine_err
// is non-empty when an engine was named but could not be started.
@(private = "file")
testkit_engine :: proc() -> (engine: Testkit_Engine, named: bool, engine_err: string) {
	if url, has_url := os.lookup_env("FROSTLAKE_URL", context.allocator); has_url {
		return Testkit_Engine{dsn = url}, true, ""
	}
	classpath, has_classpath := os.lookup_env("FROSTLAKE_CLASSPATH", context.allocator)
	if !has_classpath {
		return {}, false, ""
	}
	defer delete(classpath)
	java := strings.clone("java")
	if java_home, has_java_home := os.lookup_env("JAVA_HOME", context.allocator); has_java_home {
		delete(java)
		java = fmt.aprintf("%s/bin/java", java_home)
		delete(java_home)
	}
	defer delete(java)

	probe, probe_err := net.listen_tcp(net.Endpoint{net.IP4_Loopback, 0})
	if probe_err != nil {
		return {}, true, "cannot probe for a free port"
	}
	endpoint, _ := net.bound_endpoint(probe)
	net.close(probe)

	home, home_err := os.make_directory_temp("", "frostlake-odin-testkit-*", context.allocator)
	if home_err != nil {
		return {}, true, "cannot create a private user.home"
	}
	user_home := fmt.aprintf("-Duser.home=%s", home)
	defer delete(user_home)
	port := fmt.aprintf("%d", endpoint.port)
	defer delete(port)
	command := []string{java, user_home, "-cp", classpath, "dev.frostlake.http.DatabaseHttpServer", port}
	process, start_err := os.process_start({working_dir = home, command = command})
	if start_err != nil {
		os.remove_all(home)
		delete(home)
		return {}, true, "failed to spawn the Frostlake server"
	}
	dsn := fmt.aprintf("frostlake://127.0.0.1:%d", endpoint.port)
	return Testkit_Engine{dsn = dsn, process = process, booted = true, home = home}, true, ""
}

@(private = "file")
testkit_engine_stop :: proc(engine: ^Testkit_Engine) {
	if engine.booted {
		_ = os.process_kill(engine.process)
		_, _ = os.process_wait(engine.process)
		os.remove_all(engine.home)
	}
	delete(engine.home)
	delete(engine.dsn)
	engine^ = {}
}

@(private = "file")
testkit_suite_files :: proc(dir: string) -> []string {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return nil
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	files := make([dynamic]string)
	for info in infos {
		if strings.has_suffix(info.name, ".json") {
			append(&files, strings.clone(info.fullpath))
		}
	}
	slice.sort(files[:])
	return files[:]
}

@(private = "file")
testkit_wanted_suites :: proc() -> [dynamic]string {
	wanted := make([dynamic]string)
	listed, has_listed := os.lookup_env("TESTKIT_SUITES", context.allocator)
	if !has_listed {
		return wanted
	}
	defer delete(listed)
	remaining := listed
	for word in strings.split_iterator(&remaining, ",") {
		trimmed := strings.trim_space(word)
		if len(trimmed) > 0 {
			append(&wanted, strings.to_lower(trimmed))
		}
	}
	return wanted
}

@(private = "file")
testkit_is_wanted :: proc(wanted: []string, suite_name: string) -> bool {
	if len(wanted) == 0 {
		return true
	}
	name := strings.to_lower(suite_name, context.temp_allocator)
	for word in wanted {
		if strings.contains(name, word) {
			return true
		}
	}
	return false
}

@(private = "file")
testkit_report_path :: proc() -> string {
	if explicit, has_explicit := os.lookup_env("FROSTLAKE_TESTKIT_REPORT", context.allocator); has_explicit {
		return explicit
	}
	dir, err := os.temp_directory(context.allocator)
	if err != nil {
		return strings.clone("testkit-odin.tsv")
	}
	defer delete(dir)
	return strings.concatenate({dir, "/testkit-odin.tsv"})
}

// The skip clause names this runner: `odin`, or `http` — the transport it speaks.
@(private = "file")
testkit_skip_reason :: proc(test: Value) -> (reason: string, skip: bool) {
	clause, _ := testkit_member(test, "skip")
	backends, _ := testkit_member_array(clause, "backends")
	for backend in backends {
		name, is_string := backend.(string)
		if is_string && (strings.equal_fold(name, "odin") || strings.equal_fold(name, "http")) {
			if text, has_reason := testkit_member_string(clause, "reason"); has_reason {
				return text, true
			}
			return fmt.tprintf("skipped for %s", name), true
		}
	}
	return "", false
}

@(private = "file")
testkit_run_case :: proc(
	conn: ^Connection,
	test: Value,
	missing_api: ^int,
) -> (
	status: Testkit_Status,
	failed_step: int,
	detail: string,
) {
	reset := [?]string {
		"ALTER SESSION SET MULTI_STATEMENT_COUNT = 0",
		"CREATE OR REPLACE DATABASE test_db",
		"USE DATABASE test_db",
		"CREATE OR REPLACE SCHEMA test_schema",
		"USE SCHEMA test_schema",
	}
	for sql in reset {
		result, err := execute(conn, sql)
		if err != nil {
			detail = fmt.tprintf("resetContext failed on '%s': %s", sql, error_message(err))
			destroy_error(err)
			return .Error, 0, detail
		}
		destroy_result(&result)
	}
	steps, _ := testkit_member_array(test, "steps")
	for step, index in steps {
		sql, _ := testkit_member_string(step, "sql")
		result, err := execute(conn, sql)
		if err != nil {
			// A transport failure is an ERROR, as in the reference — never an "expected error".
			kind := err.(Error_Detail).kind
			if kind == .Http || kind == .Protocol {
				detail = fmt.tprintf("%s  [sql: %s]", error_message(err), sql)
				destroy_error(err)
				return .Error, index + 1, detail
			}
		}
		expect, _ := testkit_member(step, "expect")
		mismatch, mismatched := testkit_check(expect, result, err)
		if err != nil {
			if error_expect, has_error := testkit_member(expect, "error"); has_error {
				if !mismatched && (testkit_has(error_expect, "code") || testkit_has(error_expect, "sqlState")) {
					missing_api^ += 1
				}
			}
			destroy_error(err)
		} else {
			destroy_result(&result)
		}
		if mismatched {
			return .Fail, index + 1, fmt.tprintf("%s  [sql: %s]", mismatch, sql)
		}
	}
	return .Pass, 0, ""
}

// The reference's Compare.check: one step's expect block against the driver's outcome. Every
// detail is built on the temp allocator, so it outlives the result and error it describes.
@(private = "file")
testkit_check :: proc(expect: Value, result: Query_Result, err: Error) -> (detail: string, mismatched: bool) {
	if error_expect, has_error := testkit_member(expect, "error"); has_error {
		if _, is_object := error_expect.(Object); is_object {
			if err == nil {
				return "expected an error, statement succeeded", true
			}
			message := error_message(err)
			if want, has_want := testkit_member_string(error_expect, "messageContains"); has_want {
				haystack := strings.to_lower(message, context.temp_allocator)
				needle := strings.to_lower(want, context.temp_allocator)
				if !strings.contains(haystack, needle) {
					return fmt.tprintf("error message [%s] does not contain [%s]", message, want), true
				}
			}
			return "", false
		}
	}
	if err != nil {
		return fmt.tprintf("unexpected error: %s", error_message(err)), true
	}
	if _, is_object := expect.(Object); !is_object {
		return "", false
	}

	if want, has_value := testkit_member(expect, "value"); has_value {
		want_text, want_null := testkit_text(want)
		got_text, got_null := testkit_first_cell(result)
		if testkit_norm(want_text, want_null) != testkit_norm(got_text, got_null) {
			return fmt.tprintf(
				"value [%s] != expected [%s]",
				"null" if got_null else got_text,
				"null" if want_null else want_text,
			), true
		}
	}

	if want_rows, has_rows := testkit_member_array(expect, "rows"); has_rows {
		want := make([dynamic]string, context.temp_allocator)
		for row in want_rows {
			line := strings.builder_make(context.temp_allocator)
			if cells, is_row := row.(Array); is_row {
				for cell in cells {
					text, null := testkit_text(cell)
					strings.write_string(&line, testkit_norm(text, null))
					strings.write_byte(&line, 0x1f)
				}
			}
			append(&want, strings.to_string(line))
		}
		got := make([dynamic]string, context.temp_allocator)
		for row in result.rows {
			line := strings.builder_make(context.temp_allocator)
			for cell, column in row {
				text, null := testkit_cell_text(cell, result.columns[column])
				strings.write_string(&line, testkit_norm(text, null))
				strings.write_byte(&line, 0x1f)
			}
			append(&got, strings.to_string(line))
		}
		ordered, _ := testkit_member(expect, "ordered")
		if flag, is_bool := ordered.(bool); !is_bool || !flag {
			slice.sort(want[:])
			slice.sort(got[:])
		}
		if !slice.equal(want[:], got[:]) {
			return fmt.tprintf("rows differ: expected %v got %v", want[:], got[:]), true
		}
	}

	if raw, has_row_count := testkit_member(expect, "rowCount"); has_row_count {
		if want, is_number := testkit_int(raw); is_number && len(result.rows) != want {
			return fmt.tprintf("rowCount %d != expected %d", len(result.rows), want), true
		}
	}

	if want_columns, has_columns := testkit_member_array(expect, "columns"); has_columns {
		if len(result.columns) != len(want_columns) {
			names := make([dynamic]string, context.temp_allocator)
			for column in result.columns {
				append(&names, column.name)
			}
			return fmt.tprintf(
				"column count %d != expected %d %v",
				len(result.columns),
				len(want_columns),
				names[:],
			), true
		}
		for want, index in want_columns {
			want_text, _ := testkit_text(want)
			if !strings.equal_fold(want_text, result.columns[index].name) {
				return fmt.tprintf(
					"column[%d] [%s] != expected [%s]",
					index,
					result.columns[index].name,
					want_text,
				), true
			}
		}
	}

	if raw, has_update_count := testkit_member(expect, "updateCount"); has_update_count {
		if want, is_number := testkit_int(raw); is_number {
			got := testkit_update_count(result)
			if got != i64(want) {
				return fmt.tprintf("updateCount %d != expected %d", got, want), true
			}
		}
	}
	return "", false
}

// The reference's HttpBackend count: the DML count the driver reports, or else
// ExecResult.deriveUpdateCountFromGrid — a single row whose every column is a "number of …"
// count answers its first cell.
@(private = "file")
testkit_update_count :: proc(result: Query_Result) -> i64 {
	if count, reported := result.update_count.?; reported {
		return count
	}
	if len(result.columns) == 0 || len(result.rows) != 1 {
		return -1
	}
	for column in result.columns {
		if !strings.has_prefix(strings.to_lower(column.name, context.temp_allocator), "number of") {
			return -1
		}
	}
	if len(result.rows[0]) == 0 {
		return -1
	}
	#partial switch first in result.rows[0][0] {
	case i128:
		return i64(first)
	case string:
		if count, ok := testkit_parse_i64(strings.trim_space(first)); ok {
			return count
		}
	}
	return -1
}

@(private = "file")
testkit_parse_i64 :: proc(text: string) -> (value: i64, ok: bool) {
	if len(text) == 0 {
		return 0, false
	}
	i := 0
	negative := text[0] == '-'
	if text[0] == '-' || text[0] == '+' {
		i = 1
	}
	if i == len(text) {
		return 0, false
	}
	for ; i < len(text); i += 1 {
		c := text[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		value = value * 10 + i64(c - '0')
	}
	return -value if negative else value, true
}

@(private = "file")
testkit_first_cell :: proc(result: Query_Result) -> (text: string, null: bool) {
	if len(result.rows) == 0 || len(result.rows[0]) == 0 {
		return "", true
	}
	return testkit_cell_text(result.rows[0][0], result.columns[0])
}

// A driver cell as text, decoded once when its column carries semi-structured values: such a
// cell reaches a client as its JSON text, while the suites record the value — a JSON string
// becomes its content, and anything else (a number, an object, text that is not JSON) stays
// exactly as it came.
@(private = "file")
testkit_cell_text :: proc(cell: Value, column: Column) -> (text: string, null: bool) {
	text, null = testkit_text(cell)
	if null {
		return
	}
	data_type := column.data_type
	if !(strings.equal_fold(data_type, "VARIANT") ||
		   strings.equal_fold(data_type, "OBJECT") ||
		   strings.equal_fold(data_type, "ARRAY")) {
		return
	}
	decoded, parse_err := parse_json(text, context.temp_allocator)
	if parse_err != nil {
		return
	}
	if content, is_string := decoded.(string); is_string {
		return content, false
	}
	return
}

// A value as the reference stringifies it: plain text for scalars, Java's collection
// toString for arrays and objects. Allocations are temporary.
@(private = "file")
testkit_text :: proc(value: Value) -> (text: string, null: bool) {
	switch v in value {
	case nil:
		return "", true
	case bool:
		return "true" if v else "false", false
	case i128:
		return fmt.tprintf("%d", v), false
	case f64:
		switch {
		case math.is_nan(v):
			return "NaN", false
		case math.is_inf(v, 1):
			return "Infinity", false
		case math.is_inf(v, -1):
			return "-Infinity", false
		}
		return fmt.tprintf("%v", v), false
	case string:
		return v, false
	case Bytes:
		hex := "0123456789ABCDEF"
		builder := strings.builder_make(context.temp_allocator)
		for b in v {
			strings.write_byte(&builder, hex[b >> 4])
			strings.write_byte(&builder, hex[b & 0xF])
		}
		return strings.to_string(builder), false
	case Date:
		return v.text, false
	case Timestamp:
		return v.text, false
	case Array:
		builder := strings.builder_make(context.temp_allocator)
		strings.write_byte(&builder, '[')
		for item, index in v {
			if index > 0 {
				strings.write_string(&builder, ", ")
			}
			item_text, item_null := testkit_text(item)
			strings.write_string(&builder, "null" if item_null else item_text)
		}
		strings.write_byte(&builder, ']')
		return strings.to_string(builder), false
	case Object:
		builder := strings.builder_make(context.temp_allocator)
		strings.write_byte(&builder, '{')
		for member, index in v {
			if index > 0 {
				strings.write_string(&builder, ", ")
			}
			member_text, member_null := testkit_text(member.value)
			fmt.sbprintf(&builder, "%s=%s", member.key, "null" if member_null else member_text)
		}
		strings.write_byte(&builder, '}')
		return strings.to_string(builder), false
	}
	return "", true
}

// The reference's Compare.norm: NULL and booleans folded, anything BigDecimal can read rounded
// to 10 significant digits (HALF_UP) and printed plain, everything else trimmed text.
@(private = "file")
testkit_norm :: proc(raw: string, null: bool) -> string {
	if null {
		return "NULL"
	}
	value := raw
	for len(value) > 0 && value[0] <= ' ' {
		value = value[1:]
	}
	for len(value) > 0 && value[len(value) - 1] <= ' ' {
		value = value[:len(value) - 1]
	}
	if len(value) == 0 || strings.equal_fold(value, "null") {
		return "NULL"
	}
	if strings.equal_fold(value, "true") {
		return "TRUE"
	}
	if strings.equal_fold(value, "false") {
		return "FALSE"
	}
	if number, is_number := testkit_decimal_norm(value); is_number {
		return number
	}
	return value
}

@(private = "file")
testkit_decimal_norm :: proc(text: string) -> (out: string, ok: bool) {
	i := 0
	negative := false
	if i < len(text) && (text[i] == '-' || text[i] == '+') {
		negative = text[i] == '-'
		i += 1
	}
	digits := make([dynamic]u8, 0, len(text), context.temp_allocator)
	fraction_digits := 0
	seen_point := false
	scan: for i < len(text) {
		c := text[i]
		switch {
		case c >= '0' && c <= '9':
			append(&digits, c - '0')
			if seen_point {
				fraction_digits += 1
			}
		case c == '.' && !seen_point:
			seen_point = true
		case:
			break scan
		}
		i += 1
	}
	if len(digits) == 0 {
		return "", false
	}
	exponent := 0
	if i < len(text) {
		if text[i] != 'e' && text[i] != 'E' {
			return "", false
		}
		i += 1
		exponent_negative := false
		if i < len(text) && (text[i] == '+' || text[i] == '-') {
			exponent_negative = text[i] == '-'
			i += 1
		}
		if i == len(text) {
			return "", false
		}
		for ; i < len(text); i += 1 {
			c := text[i]
			if c < '0' || c > '9' {
				return "", false
			}
			exponent = exponent * 10 + int(c - '0')
			if exponent > 100_000 {
				return "", false
			}
		}
		if exponent_negative {
			exponent = -exponent
		}
	}

	scale := exponent - fraction_digits
	first := -1
	for d, k in digits {
		if d != 0 {
			first = k
			break
		}
	}
	if first < 0 {
		return "0", true
	}
	significant := make([dynamic]u8, 0, len(digits) + 1, context.temp_allocator)
	append(&significant, ..digits[first:])
	if len(significant) > 10 {
		round_up := significant[10] >= 5
		scale += len(significant) - 10
		resize(&significant, 10)
		if round_up {
			k := len(significant)
			for {
				if k == 0 {
					inject_at(&significant, 0, 1)
					pop(&significant)
					scale += 1
					break
				}
				k -= 1
				if significant[k] == 9 {
					significant[k] = 0
				} else {
					significant[k] += 1
					break
				}
			}
		}
	}
	for len(significant) > 1 && significant[len(significant) - 1] == 0 {
		pop(&significant)
		scale += 1
	}

	builder := strings.builder_make(context.temp_allocator)
	if negative {
		strings.write_byte(&builder, '-')
	}
	if scale >= 0 {
		for d in significant {
			strings.write_byte(&builder, '0' + d)
		}
		for _ in 0 ..< scale {
			strings.write_byte(&builder, '0')
		}
	} else {
		point := len(significant) + scale
		if point > 0 {
			for d, k in significant {
				if k == point {
					strings.write_byte(&builder, '.')
				}
				strings.write_byte(&builder, '0' + d)
			}
		} else {
			strings.write_string(&builder, "0.")
			for _ in 0 ..< -point {
				strings.write_byte(&builder, '0')
			}
			for d in significant {
				strings.write_byte(&builder, '0' + d)
			}
		}
	}
	return strings.to_string(builder), true
}

// Object member lookup that tells a JSON null apart from an absent key; the last duplicate
// wins, as in the reference's LinkedHashMap.
@(private = "file")
testkit_member :: proc(value: Value, key: string) -> (member: Value, found: bool) {
	object, is_object := value.(Object)
	if !is_object {
		return nil, false
	}
	for entry in object {
		if entry.key == key {
			member, found = entry.value, true
		}
	}
	return
}

@(private = "file")
testkit_has :: proc(value: Value, key: string) -> bool {
	member, found := testkit_member(value, key)
	return found && member != nil
}

@(private = "file")
testkit_member_string :: proc(value: Value, key: string) -> (text: string, found: bool) {
	member, _ := testkit_member(value, key)
	text, found = member.(string)
	return
}

@(private = "file")
testkit_member_array :: proc(value: Value, key: string) -> (items: Array, found: bool) {
	member, _ := testkit_member(value, key)
	items, found = member.(Array)
	return
}

@(private = "file")
testkit_int :: proc(value: Value) -> (number: int, ok: bool) {
	#partial switch v in value {
	case i128:
		return int(v), true
	case f64:
		return int(v), true
	}
	return 0, false
}

@(private = "file")
testkit_file_stem :: proc(path: string) -> string {
	name := path
	if slash := strings.last_index_byte(name, '/'); slash >= 0 {
		name = name[slash + 1:]
	}
	return strings.trim_suffix(name, ".json")
}

@(private = "file")
testkit_status_text :: proc(status: Testkit_Status) -> string {
	switch status {
	case .Pass:
		return "PASS"
	case .Fail:
		return "FAIL"
	case .Error:
		return "ERROR"
	case .Skip:
		return "SKIP"
	}
	return ""
}

@(private = "file")
testkit_single_line :: proc(text: string) -> string {
	if strings.index_any(text, "\t\n\r\x1f") < 0 {
		return text
	}
	out, _ := strings.replace_all(text, "\t", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\r", " ", context.temp_allocator)
	out, _ = strings.replace_all(out, "\x1f", "|", context.temp_allocator)
	return out
}

@(private = "file")
testkit_truncate :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {
		return text
	}
	end := limit
	for end > 0 && (text[end] & 0xC0) == 0x80 {
		end -= 1
	}
	return text[:end]
}

@(test)
test_testkit_norm_matches_the_reference :: proc(t: ^testing.T) {
	Case :: struct {
		raw:  string,
		want: string,
	}
	cases := []Case {
		{"2", "2"},
		{"2.000000", "2"},
		{"3.500000", "3.5"},
		{" 42 ", "42"},
		{"-0", "0"},
		{"0.000", "0"},
		{"1e+21", "1000000000000000000000"},
		{"2.5e-05", "0.000025"},
		{"0.30000000000000004", "0.3"},
		{"12345678905", "12345678910"},
		{"9999999999.5", "10000000000"},
		{"-12345678901234567890123456789", "-12345678900000000000000000000"},
		{"1.", "1"},
		{".5", "0.5"},
		{"+7", "7"},
		{"1e", "1e"},
		{"0x10", "0x10"},
		{"NaN", "NaN"},
		{"true", "TRUE"},
		{"False", "FALSE"},
		{"null", "NULL"},
		{"", "NULL"},
		{"abc", "abc"},
	}
	for c in cases {
		got := testkit_norm(c.raw, false)
		testing.expectf(t, got == c.want, "norm(%q) = %q, want %q", c.raw, got, c.want)
	}
	testing.expect_value(t, testkit_norm("anything", true), "NULL")
	free_all(context.temp_allocator)
}
