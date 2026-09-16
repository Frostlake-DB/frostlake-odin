// A zero-dependency Odin driver for Frostlake, speaking the engine's HTTP
// protocol against a running DatabaseHttpServer.
//
//	conn, cerr := frostlake.connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
//	defer frostlake.destroy_connection(&conn)
//
//	result, qerr := frostlake.execute(&conn, "SELECT id, name FROM people WHERE id = ?", {i128(1)})
//	defer frostlake.destroy_result(&result)
//	cell, _ := frostlake.get(result, 0, "ID")
//
// Parameters are inlined client-side (the protocol has no server-side
// binding), with the same rules as Frostlake's other drivers. Integral NUMBER
// cells arrive as i128 — exact through NUMBER(38,0) — and DATE/TIMESTAMP*/
// BINARY cells as Date/Timestamp/Bytes.
//
// Everything a call returns is allocated on the allocator you pass it
// (context.allocator by default) and owned by you: free results with
// destroy_result, errors with destroy_error, and the connection with
// destroy_connection.
package frostlake

import "core:fmt"
import "core:mem"
import "core:strings"

// A SQL cell, bind value, or JSON value. The nil variant is SQL NULL.
// Integral numbers are i128, which holds every NUMBER(38,0) exactly;
// Date/Timestamp/Bytes are produced by the driver's typed conversion (and
// render as typed literals when used as binds).
Value :: union {
	bool,
	i128,
	f64,
	string,
	Bytes,
	Date,
	Timestamp,
	Array,
	Object,
}

Bytes :: distinct []u8

Date :: struct {
	text: string,
}

Timestamp :: struct {
	text: string,
}

Array :: distinct [dynamic]Value

Object :: distinct [dynamic]Member

// One member of an Object. A dynamic array of members (not a map) preserves
// duplicate keys and their order, both observable in JSON.
Member :: struct {
	key:   string,
	value: Value,
}

Error_Kind :: enum {
	Dsn,      // malformed DSN
	Connect,  // server unreachable or unhealthy
	Http,     // transport failure or malformed HTTP response
	Protocol, // response body is not the protocol's JSON
	Sql,      // the engine answered success=false
	Usage,    // driver misuse: bad binds, closed connection, unsupported bind type
	Json,     // malformed JSON document
}

Error_Detail :: struct {
	kind:    Error_Kind,
	message: string, // owned by the allocator given to the failing call
}

// nil means success; compare with `err != nil` and free with destroy_error.
Error :: union {
	Error_Detail,
}

Column :: struct {
	name:      string,
	data_type: string, // the wire's bare type name (e.g. "TIMESTAMP_NTZ"); "" when absent
	// The declared width of a text or binary column: characters for VARCHAR,
	// bytes for BINARY, and the most it could hold for an unbounded one. nil
	// for every other type, which has no width, and for a server that predates
	// the field -- never 0, which the wire does not send.
	length:    Maybe(i64),
}

// One statement's outcome: rows are indexed positionally and read by column
// name via get. A DML statement keeps its Snowflake-shaped result — one row
// holding a "number of rows …" column per action — and reports update_count,
// the affected-row count; update_count is nil for anything that is not DML,
// never 0. row_count is update_count for DML and the row total otherwise.
Query_Result :: struct {
	columns:      []Column,
	rows:         [][]Value,
	row_count:    i64,
	update_count: Maybe(i64),
}

error_message :: proc(err: Error) -> string {
	if detail, ok := err.(Error_Detail); ok {
		return detail.message
	}
	return ""
}

destroy_error :: proc(err: Error, allocator := context.allocator) {
	if detail, ok := err.(Error_Detail); ok {
		delete(detail.message, allocator)
	}
}

@(private)
make_error :: proc(kind: Error_Kind, message: string, allocator: mem.Allocator) -> Error {
	return Error_Detail{kind, strings.clone(message, allocator)}
}

@(private)
make_errorf :: proc(kind: Error_Kind, allocator: mem.Allocator, format: string, args: ..any) -> Error {
	return Error_Detail{kind, fmt.aprintf(format, ..args, allocator = allocator)}
}

// Exact match wins; a case-insensitive match is the fallback.
column_index :: proc(result: Query_Result, name: string) -> (index: int, found: bool) {
	for column, i in result.columns {
		if column.name == name {
			return i, true
		}
	}
	for column, i in result.columns {
		if strings.equal_fold(column.name, name) {
			return i, true
		}
	}
	return 0, false
}

// Returns the cell by row index and column name. The value is borrowed from
// the result — do not destroy it separately.
get :: proc(result: Query_Result, row: int, column: string) -> (cell: Value, found: bool) {
	index, ok := column_index(result, column)
	if !ok || row < 0 || row >= len(result.rows) {
		return nil, false
	}
	cells := result.rows[row]
	if index >= len(cells) {
		return nil, false
	}
	return cells[index], true
}

destroy_value :: proc(value: Value, allocator := context.allocator) {
	switch v in value {
	case nil, bool, i128, f64:
	// no heap storage
	case string:
		delete(v, allocator)
	case Bytes:
		delete(([]u8)(v), allocator)
	case Date:
		delete(v.text, allocator)
	case Timestamp:
		delete(v.text, allocator)
	case Array:
		arr := v
		for item in arr {
			destroy_value(item, allocator)
		}
		delete(arr)
	case Object:
		object := v
		for member in object {
			delete(member.key, allocator)
			destroy_value(member.value, allocator)
		}
		delete(object)
	}
}

destroy_result :: proc(result: ^Query_Result, allocator := context.allocator) {
	for column in result.columns {
		delete(column.name, allocator)
		delete(column.data_type, allocator)
	}
	delete(result.columns, allocator)
	for row in result.rows {
		for cell in row {
			destroy_value(cell, allocator)
		}
		delete(row, allocator)
	}
	delete(result.rows, allocator)
	result^ = {}
}

destroy :: proc {
	destroy_connection,
	destroy_result,
	destroy_value,
	destroy_error,
}

// Deep structural equality, since a union holding slices is not comparable
// with ==. NaN never equals anything, like f64 comparison itself.
values_equal :: proc(a, b: Value) -> bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	switch av in a {
	case nil:
		return b == nil
	case bool:
		bv, ok := b.(bool)
		return ok && av == bv
	case i128:
		bv, ok := b.(i128)
		return ok && av == bv
	case f64:
		bv, ok := b.(f64)
		return ok && av == bv
	case string:
		bv, ok := b.(string)
		return ok && av == bv
	case Bytes:
		bv, ok := b.(Bytes)
		if !ok || len(av) != len(bv) {
			return false
		}
		for x, i in av {
			if x != bv[i] {
				return false
			}
		}
		return true
	case Date:
		bv, ok := b.(Date)
		return ok && av.text == bv.text
	case Timestamp:
		bv, ok := b.(Timestamp)
		return ok && av.text == bv.text
	case Array:
		bv, ok := b.(Array)
		if !ok || len(av) != len(bv) {
			return false
		}
		for item, i in av {
			if !values_equal(item, bv[i]) {
				return false
			}
		}
		return true
	case Object:
		bv, ok := b.(Object)
		if !ok || len(av) != len(bv) {
			return false
		}
		for member, i in av {
			if member.key != bv[i].key || !values_equal(member.value, bv[i].value) {
				return false
			}
		}
		return true
	}
	return false
}

// Deep copy onto the given allocator.
clone_value :: proc(value: Value, allocator := context.allocator) -> Value {
	switch v in value {
	case nil:
		return nil
	case bool:
		return v
	case i128:
		return v
	case f64:
		return v
	case string:
		return strings.clone(v, allocator)
	case Bytes:
		cloned := make([]u8, len(v), allocator)
		copy(cloned, ([]u8)(v))
		return Bytes(cloned)
	case Date:
		return Date{strings.clone(v.text, allocator)}
	case Timestamp:
		return Timestamp{strings.clone(v.text, allocator)}
	case Array:
		items := make([dynamic]Value, 0, len(v), allocator)
		for item in v {
			append(&items, clone_value(item, allocator))
		}
		return Array(items)
	case Object:
		members := make([dynamic]Member, 0, len(v), allocator)
		for member in v {
			append(&members, Member{strings.clone(member.key, allocator), clone_value(member.value, allocator)})
		}
		return Object(members)
	}
	return nil
}
