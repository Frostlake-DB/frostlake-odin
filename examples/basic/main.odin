// The canonical usage example: connect to a running DatabaseHttpServer,
// create a table, insert through binds, read typed cells back.
//
// Start a server (data/start-http-server.sh in the engine repo, default port
// 18082), then:
//
//	odin run examples/basic
package main

import frostlake "../../frostlake"

import "core:fmt"

main :: proc() {
	conn, connect_err := frostlake.connect("frostlake://localhost:18082")
	if connect_err != nil {
		fmt.eprintfln("connect failed: %s", frostlake.error_message(connect_err))
		frostlake.destroy_error(connect_err)
		return
	}
	defer frostlake.destroy_connection(&conn)

	statements := []string{
		"CREATE OR REPLACE DATABASE odin_example_db",
		"USE DATABASE odin_example_db",
		"CREATE TABLE people (id INTEGER, name VARCHAR, score FLOAT, ok BOOLEAN)",
	}
	for statement in statements {
		result, err := frostlake.execute(&conn, statement)
		if err != nil {
			fmt.eprintfln("%s failed: %s", statement, frostlake.error_message(err))
			frostlake.destroy_error(err)
			return
		}
		frostlake.destroy_result(&result)
	}

	inserted, insert_err := frostlake.execute(
		&conn,
		"INSERT INTO people VALUES (?, ?, ?, ?), (?, ?, ?, ?)",
		{i128(1), "Ada", 9.5, true, i128(2), "Grace", 8.25, false},
	)
	if insert_err != nil {
		fmt.eprintfln("insert failed: %s", frostlake.error_message(insert_err))
		frostlake.destroy_error(insert_err)
		return
	}
	fmt.printfln("inserted %d rows", inserted.row_count)
	frostlake.destroy_result(&inserted)

	people, query_err := frostlake.execute(&conn, "SELECT id, name, score, ok FROM people WHERE score > ?", {f64(9)})
	if query_err != nil {
		fmt.eprintfln("query failed: %s", frostlake.error_message(query_err))
		frostlake.destroy_error(query_err)
		return
	}
	defer frostlake.destroy_result(&people)

	for _, row in people.rows {
		id, _ := frostlake.get(people, row, "ID")
		name, _ := frostlake.get(people, row, "NAME")
		score, _ := frostlake.get(people, row, "SCORE")
		fmt.printfln("id=%v name=%v score=%v", id, name, score)
	}
}
