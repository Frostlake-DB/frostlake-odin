// What a request does to its session, read from its SQL text. The scanner is
// binding's own (string literals, quoted identifiers, $$…$$ bodies and comments
// are stepped over), so the two cannot disagree about what is code.
package frostlake

import "core:strings"

// What a statement does to the session's transaction.
@(private)
Transaction_Effect :: enum {
	None,
	Begins, // BEGIN on its own or with TRANSACTION, WORK or NAME; START TRANSACTION
	Ends,   // COMMIT, ROLLBACK
}

// The words that may sit between CREATE/DROP/ALTER and the kind of object named.
@(private = "file")
OBJECT_MODIFIERS := [?]string {
	"OR", "REPLACE", "TRANSIENT", "TEMPORARY", "TEMP", "VOLATILE", "LOCAL", "GLOBAL",
	"SECURE", "IF", "NOT", "EXISTS", "PUBLIC", "PRIVATE", "ICEBERG", "DYNAMIC", "HYBRID",
	"EVENT", "RECURSIVE", "MATERIALIZED", "EXTERNAL",
}

// Records what each top-level statement of a request left on the session. A ';'
// inside a literal, a quoted identifier, a $$ body or a comment does not split,
// and a scripting block is split along with everything else, which only makes
// the checks more willing to flag a request -- the safe direction.
@(private)
track_statements :: proc(conn: ^Connection, sql: string) {
	start := 0
	i := 0
	for i < len(sql) {
		if past := skip_non_code(sql, i); past >= 0 {
			i = past
		} else if sql[i] == ';' {
			track_statement(conn, sql[start:i])
			i += 1
			start = i
		} else {
			i += 1
		}
	}
	track_statement(conn, sql[start:])
}

@(private = "file")
track_statement :: proc(conn: ^Connection, statement: string) {
	if touches_session(statement) {
		conn.dirty = true
	}
	switch transaction_effect(statement) {
	case .Begins:
		conn.in_transaction = true
	case .Ends:
		conn.in_transaction = false
	case .None:
	}
}

// Whether a statement leaves behind state a fresh session would not have: a
// moved scope (USE, or CREATE/DROP of a DATABASE or SCHEMA), a session variable
// or setting (SET, UNSET, ALTER SESSION), or a temporary object. CREATE TABLE and
// its kind leave the session as it was.
@(private)
touches_session :: proc(statement: string) -> bool {
	buffer: [16]string
	words := buffer[:leading_words(statement, buffer[:])]
	if len(words) == 0 {
		return false
	}
	verb := words[0]
	if is_keyword(verb, "USE") || is_keyword(verb, "SET") || is_keyword(verb, "UNSET") {
		return true
	}
	modifiers := 1
	for modifiers < len(words) && is_modifier(words[modifiers]) {
		modifiers += 1
	}
	object := words[modifiers] if modifiers < len(words) else ""
	if is_keyword(verb, "ALTER") {
		return is_keyword(object, "SESSION")
	}
	if !is_keyword(verb, "CREATE") && !is_keyword(verb, "DROP") {
		return false
	}
	if is_keyword(object, "DATABASE") || is_keyword(object, "SCHEMA") {
		return true
	}
	if is_keyword(verb, "CREATE") {
		for word in words[1:modifiers] {
			if is_keyword(word, "TEMPORARY") || is_keyword(word, "TEMP") || is_keyword(word, "VOLATILE") {
				return true
			}
		}
	}
	return false
}

// Whether a statement opens or ends a transaction. BEGIN followed by a statement
// opens a scripting block instead.
@(private)
transaction_effect :: proc(statement: string) -> Transaction_Effect {
	buffer: [2]string
	words := buffer[:leading_words(statement, buffer[:])]
	if len(words) == 0 {
		return .None
	}
	if is_keyword(words[0], "BEGIN") {
		if len(words) == 1 ||
		   is_keyword(words[1], "TRANSACTION") ||
		   is_keyword(words[1], "WORK") ||
		   is_keyword(words[1], "NAME") {
			return .Begins
		}
		return .None
	}
	if is_keyword(words[0], "START") && len(words) == 2 && is_keyword(words[1], "TRANSACTION") {
		return .Begins
	}
	if is_keyword(words[0], "COMMIT") || is_keyword(words[0], "ROLLBACK") {
		return .Ends
	}
	return .None
}

// Fills words with the statement's leading words -- slices of it -- stepping
// over whitespace and comments and stopping at the first thing that is not a
// word. Returns how many it found.
@(private = "file")
leading_words :: proc(statement: string, words: []string) -> int {
	count := 0
	i := 0
	for i < len(statement) && count < len(words) {
		c := statement[i]
		next: u8 = statement[i + 1] if i + 1 < len(statement) else 0
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v' {
			i += 1
		} else if (c == '-' && next == '-') || (c == '/' && next == '/') {
			i = skip_line(statement, i)
		} else if c == '/' && next == '*' {
			i = skip_block_comment(statement, i + 2)
		} else if is_word_byte(c) {
			start := i
			for i < len(statement) && is_word_byte(statement[i]) {
				i += 1
			}
			words[count] = statement[start:i]
			count += 1
		} else {
			break
		}
	}
	return count
}

// Just past the literal, quoted identifier, $$ body or comment opening at i, or
// -1 when i is code.
@(private = "file")
skip_non_code :: proc(sql: string, i: int) -> int {
	c := sql[i]
	next: u8 = sql[i + 1] if i + 1 < len(sql) else 0
	switch {
	case c == '\'':
		return skip_sql_string(sql, i)
	case c == '"':
		return skip_quoted_ident(sql, i)
	case c == '-' && next == '-':
		return skip_line(sql, i)
	case c == '/' && next == '/':
		return skip_line(sql, i)
	case c == '/' && next == '*':
		return skip_block_comment(sql, i + 2)
	case is_name_start(c):
		// A name holds no separator, and the $$ inside one opens no body.
		return skip_name(sql, i)
	case c == '$' && next == '$':
		return skip_dollar_quoted(sql, i + 2)
	}
	return -1
}

// A byte of an unquoted identifier: a letter, a digit, '_', '$', or any byte of
// a multi-byte UTF-8 character.
@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '_' ||
		c == '$' ||
		c >= 0x80
}

@(private = "file")
is_modifier :: proc(word: string) -> bool {
	for modifier in OBJECT_MODIFIERS {
		if is_keyword(word, modifier) {
			return true
		}
	}
	return false
}

@(private = "file")
is_keyword :: proc(word: string, keyword: string) -> bool {
	return strings.equal_fold(word, keyword)
}
