# frostlake-odin

A zero-dependency Odin driver for [Frostlake](https://frostlake.dev), speaking the
engine's HTTP protocol against a running `DatabaseHttpServer`. Core library only — the
driver carries its own minimal HTTP/1.1 client over `core:net` (the protocol is
plaintext HTTP) and a small recursive-descent JSON parser, because Odin's core JSON
package would not keep 38-digit integers exact.

## Engine version

Requires a Frostlake engine **0.0.7 or newer** (verified against 0.0.7 and the
0.1.0 release). Ask a running server which one it is with `SELECT CURRENT_VERSION()`.
The driver versions independently of the engine: it speaks the HTTP protocol, not the
jar, so this is a floor rather than a lockstep pin.

Built and tested with an Odin `dev-2026-05` nightly.

## Installing

Odin has no package registry; vendor the package the usual way — either copy the
`frostlake/` directory into your project and import it by relative path, or map this
repository as a collection:

```sh
odin build . -collection:frostlake=path/to/frostlake-odin
```

```odin
import frostlake "frostlake:frostlake"
```

## Usage

```odin
import frostlake "frostlake:frostlake"

conn, cerr := frostlake.connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
if cerr != nil { /* frostlake.error_message(cerr) */ }
defer frostlake.destroy_connection(&conn)

created, _ := frostlake.execute(&conn, "CREATE TABLE people (id INTEGER, name VARCHAR)")
frostlake.destroy_result(&created)

inserted, _ := frostlake.execute(
	&conn,
	"INSERT INTO people VALUES (?, ?), (?, ?)",
	{i128(1), "Ada", i128(2), "Grace"},
)
assert(inserted.row_count == 2)
frostlake.destroy_result(&inserted)

people, _ := frostlake.execute(&conn, "SELECT id, name FROM people WHERE id = ?", {i128(1)})
defer frostlake.destroy_result(&people)
id, _ := frostlake.get(people, 0, "ID")     // i128(1)
name, _ := frostlake.get(people, 0, "NAME") // "Ada"
```

`execute(&conn, sql, binds)` returns a `Query_Result` with `columns`, positional `rows`
(read cells by name via `get(result, row, "NAME")`), `row_count` and `update_count`. A
`Column` carries its `name`, its `data_type`, and — for a text or binary column — its
declared `length`: characters for `VARCHAR`, bytes for `BINARY`, and `16777216` for an
unbounded one, the most it could hold. Every other type has no width, so `length` is
`nil` there rather than `0`, as it is for a server that predates the field. A failed
statement returns a non-nil `Error` carrying the engine's message.
`begin`/`commit`/`rollback` drive transactions.

DML keeps the result Snowflake gives it: one row holding a `number of rows …` column per
action — `number of rows inserted` for an INSERT, one per action for a MERGE, and for an
UPDATE an always-0 `number of multi-joined rows updated` beside the count. `update_count`
is the affected-row count, summed the way the engine's JDBC driver sums it: MERGE's
per-action counts add up and UPDATE's always-0 companion stays out. It is `nil` for
anything that is not DML — a query, DDL — rather than `0`, which is a real count: an
UPDATE that matched nothing. From 0.1.0 on the engine reports the count itself, so a
query whose column merely carries a count name (`SELECT 9 AS "number of rows inserted"`)
stays a query; against an older engine the column names are all there is to go on.
`row_count` is `update_count` for DML and the number of rows otherwise.

A multi-statement request answers with several result sets; the driver surfaces the
first — after the session asks for a pack (`ALTER SESSION SET MULTI_STATEMENT_COUNT = n`,
or `0` for any number), which the engine requires as the account does. `examples/basic`
is the runnable version of the above.

One call can ask for itself instead, with the optional `multi_statement_count`:

```odin
packed, err := frostlake.execute(
	&conn,
	"CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1), (2)",
	multi_statement_count = 2,
)
```

The count applies to that one request and outranks the session's
`MULTI_STATEMENT_COUNT` for it; `0` accepts any number. It moves no session state, so
there is nothing to save and put back, and two connections cannot disturb each other's
packing. Left out — as it is by default — the request carries no such field at all and
the session's value decides, exactly as before.

The database and schema named in the DSN are applied as `USE` statements on first
execute. Valid identifiers travel bare — the engine uppercases them, Snowflake-style —
and anything else (spaces, hyphens, a leading digit) is double-quoted with its exact
case. The DSN follows URL conventions: `%XX` escapes decode (with `+` as space in the
query), IPv6 literals are bracketed (`frostlake://[::1]:18082/db`), and `http://`
without a port means port 80 while `frostlake://` means 18082.

## Memory

Everything a call returns is allocated on the allocator you pass it
(`context.allocator` by default) and owned by you:

- `destroy_result(&result)` frees a `Query_Result` (cells included),
- `destroy_error(err)` frees an error's message,
- `destroy_connection(&conn)` frees the connection's internals,
- `destroy_value(value)` frees a `Value` tree you built from allocated parts.

`get` borrows a cell out of its result — read it, don't destroy it. The test suite runs
under `core:testing`'s tracking allocator; a leak or bad free in the driver fails loud.

## Bind values

Parameters are inlined client-side (`?` placeholders); placeholders inside string
literals, dollar-quoted `$$…$$` strings, quoted identifiers and comments are left
alone. Passing binds that don't match the placeholder count errs in either direction —
except that an empty bind slice skips the substitution scan entirely, like the sibling
drivers. `Value` is a union; the nil variant is SQL NULL:

| `Value` variant | SQL literal |
| --- | --- |
| nil | `NULL` |
| `bool` | `TRUE` / `FALSE` |
| `i128` / `f64` | as written |
| `string` | `'…'` (backslashes and quotes escaped) |
| `Bytes` | `X'hex'` |
| `Date{"2026-08-13"}` | `'…'::DATE` |
| `Timestamp{"2026-08-13T12:34:56"}` | `'…'::TIMESTAMP_NTZ` |
| `Array` | `[…]` (elements formatted recursively) |

Untyped literals pick their variant where it's unambiguous (`"Ada"`, `9.5`, `true`);
integers must say `i128(1)` because both numeric variants could hold them.

## Result types

Integral `NUMBER` cells arrive as `i128` — exact through the full `NUMBER(38,0)` range,
no floating-point degradation. Scaled `NUMBER(p,s)` cells cross the wire as JSON
decimals and land in `f64` — exact only to ~15 significant digits. `FLOAT` → `f64`,
`BOOLEAN` → `bool`, `DATE` → `Date`, `TIMESTAMP*` → `Timestamp` (the wire text; parse
with `core:time` in your application if you want calendar types), `BINARY` → `Bytes`;
everything else stays `string`, semi-structured cells included (they cross the wire as
Snowflake's text rendering).

## Running the tests

```sh
odin test frostlake -out:frostlake_tests
```

The unit half (JSON, DSN, binds, HTTP against a canned loopback server, protocol flows)
always runs. The integration test boots a real server from the engine's compiled
classes and drives the whole surface over it; it skips itself unless the classpath is
set:

```sh
export FROSTLAKE_CLASSPATH="path/to/frostlake-db.jar:<engine deps>"
odin test frostlake -out:frostlake_tests
```

`JAVA_HOME` is honored when set (plain `java` otherwise; Java 17+).

## Protocol

One `POST /api/execute` per statement with `{ sql, sessionId, autoCommit }`, plus
`multiStatementCount` when a call asks for one; the server issues the `sessionId` on
first contact and the driver echoes it back, so session state (current
database/schema, transactions) persists across statements. Failed statements
answer with a non-2xx status and the error JSON in the body, which the driver reads
regardless of status. A result set's `updateCount`, when the server sends one, is what
marks it as DML (`-1` for anything else). `GET /api/health` backs `connect`'s
reachability check. Each
round trip uses a fresh TCP connection (`Connection: close`).
