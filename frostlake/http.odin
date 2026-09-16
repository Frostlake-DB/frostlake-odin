// A minimal HTTP/1.1 client over core:net TCP — the Frostlake protocol is
// plaintext HTTP against a local server, so the package stays dependency-free.
// One connection per request (Connection: close); bodies by Content-Length,
// chunked transfer coding, or read-to-EOF.
package frostlake

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

@(private)
Http_Response :: struct {
	status: int,
	body:   string, // owned by the allocator given to http_request
}

@(private)
http_request :: proc(
	host: string,
	port: int,
	method: string,
	path: string,
	json_body: Maybe(string),
	allocator: mem.Allocator,
) -> (
	response: Http_Response,
	err: Error,
) {
	socket, dial_err := net.dial_tcp(host, port)
	if dial_err != nil {
		return {}, make_errorf(.Http, allocator, "request failed: %v", dial_err)
	}
	defer net.close(socket)
	_ = net.set_option(socket, .Receive_Timeout, time.Duration(300 * time.Second))
	_ = net.set_option(socket, .Send_Timeout, time.Duration(30 * time.Second))

	head := strings.builder_make(allocator)
	defer strings.builder_destroy(&head)
	// An IPv6 literal is bracketed in the Host header, URL-style.
	if strings.contains(host, ":") {
		fmt.sbprintf(&head, "%s %s HTTP/1.1\r\nHost: [%s]:%d\r\nConnection: close\r\n", method, path, host, port)
	} else {
		fmt.sbprintf(&head, "%s %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\n", method, path, host, port)
	}
	payload, has_payload := json_body.?
	if has_payload {
		strings.write_string(&head, "Content-Type: application/json\r\n")
		fmt.sbprintf(&head, "Content-Length: %d\r\n", len(payload))
	}
	strings.write_string(&head, "\r\n")

	if send_err := send_all(socket, strings.to_string(head)); send_err != nil {
		return {}, send_err_to_error(send_err, allocator)
	}
	if has_payload {
		if send_err := send_all(socket, payload); send_err != nil {
			return {}, send_err_to_error(send_err, allocator)
		}
	}

	reader := Http_Reader {
		socket    = socket,
		data      = make([dynamic]u8, allocator),
		allocator = allocator,
	}
	defer delete(reader.data)

	status_line, status_line_err := reader_line(&reader)
	if status_line_err != nil {
		return {}, status_line_err
	}
	status, status_ok := parse_status_line(status_line)
	if !status_ok {
		return {}, make_errorf(.Http, allocator, "bad status line: '%s'", strings.trim_right(status_line, "\r\n"))
	}

	content_length := -1
	chunked := false
	for {
		line, line_err := reader_line(&reader)
		if line_err != nil {
			return {}, line_err
		}
		trimmed := strings.trim_right(line, "\r\n")
		if len(trimmed) == 0 {
			break
		}
		colon := strings.index_byte(trimmed, ':')
		if colon < 0 {
			continue
		}
		name := strings.trim_space(trimmed[:colon])
		value := strings.trim_space(trimmed[colon + 1:])
		if strings.equal_fold(name, "content-length") {
			consumed := 0
			length, length_ok := strconv.parse_int(value, 10, &consumed)
			if length_ok && consumed == len(value) && length >= 0 {
				content_length = length
			}
		} else if strings.equal_fold(name, "transfer-encoding") && strings.equal_fold(value, "chunked") {
			chunked = true
		}
	}

	body := strings.builder_make(allocator)
	if chunked {
		for {
			size_line, size_line_err := reader_line(&reader)
			if size_line_err != nil {
				strings.builder_destroy(&body)
				return {}, size_line_err
			}
			// The size may carry a ";ext=..." chunk extension — parse up to it.
			digits := strings.trim_space(size_line)
			if semicolon := strings.index_byte(digits, ';'); semicolon >= 0 {
				digits = strings.trim_space(digits[:semicolon])
			}
			consumed := 0
			size, size_ok := strconv.parse_int(digits, 16, &consumed)
			if !size_ok || consumed != len(digits) || size < 0 {
				strings.builder_destroy(&body)
				return {}, make_errorf(.Http, allocator, "bad chunk size: '%s'", strings.trim_right(size_line, "\r\n"))
			}
			if size == 0 {
				_, _ = reader_line(&reader) // trailer / final CRLF
				break
			}
			chunk, chunk_err := reader_exact(&reader, size)
			if chunk_err != nil {
				strings.builder_destroy(&body)
				return {}, chunk_err
			}
			strings.write_string(&body, string(chunk))
			crlf, crlf_err := reader_exact(&reader, 2)
			if crlf_err != nil {
				strings.builder_destroy(&body)
				return {}, crlf_err
			}
			_ = crlf
		}
	} else if content_length >= 0 {
		content, content_err := reader_exact(&reader, content_length)
		if content_err != nil {
			strings.builder_destroy(&body)
			return {}, content_err
		}
		strings.write_string(&body, string(content))
	} else {
		rest, rest_err := reader_to_eof(&reader)
		if rest_err != nil {
			strings.builder_destroy(&body)
			return {}, rest_err
		}
		strings.write_string(&body, string(rest))
	}
	return Http_Response{status, strings.to_string(body)}, nil
}

// A growing receive buffer over the socket. Slices and strings returned by
// reader_line / reader_exact / reader_to_eof borrow the buffer and stay valid
// only until the next reader_* call.
@(private = "file")
Http_Reader :: struct {
	socket:    net.TCP_Socket,
	data:      [dynamic]u8,
	pos:       int,
	eof:       bool,
	allocator: mem.Allocator,
}

@(private = "file")
reader_fill :: proc(reader: ^Http_Reader) -> Error {
	if reader.eof {
		return make_error(.Http, "request failed: unexpected end of response", reader.allocator)
	}
	chunk: [4096]u8
	n, recv_err := net.recv_tcp(reader.socket, chunk[:])
	if recv_err != .None {
		return make_errorf(.Http, reader.allocator, "request failed: %v", recv_err)
	}
	if n == 0 {
		reader.eof = true
		return nil
	}
	append(&reader.data, ..chunk[:n])
	return nil
}

@(private = "file")
reader_line :: proc(reader: ^Http_Reader) -> (line: string, err: Error) {
	for {
		for j in reader.pos ..< len(reader.data) {
			if reader.data[j] == '\n' {
				line = string(reader.data[reader.pos:j + 1])
				reader.pos = j + 1
				return line, nil
			}
		}
		if reader.eof {
			return "", make_error(.Http, "request failed: unexpected end of response", reader.allocator)
		}
		fill_err := reader_fill(reader)
		if fill_err != nil {
			return "", fill_err
		}
	}
}

@(private = "file")
reader_exact :: proc(reader: ^Http_Reader, count: int) -> (data: []u8, err: Error) {
	for len(reader.data) - reader.pos < count {
		if reader.eof {
			return nil, make_error(.Http, "request failed: unexpected end of response", reader.allocator)
		}
		fill_err := reader_fill(reader)
		if fill_err != nil {
			return nil, fill_err
		}
	}
	data = reader.data[reader.pos:reader.pos + count]
	reader.pos += count
	return data, nil
}

@(private = "file")
reader_to_eof :: proc(reader: ^Http_Reader) -> (data: []u8, err: Error) {
	for !reader.eof {
		fill_err := reader_fill(reader)
		if fill_err != nil {
			return nil, fill_err
		}
	}
	data = reader.data[reader.pos:]
	reader.pos = len(reader.data)
	return data, nil
}

@(private = "file")
parse_status_line :: proc(line: string) -> (status: int, ok: bool) {
	i := 0
	for i < len(line) && line[i] != ' ' && line[i] != '\t' {
		i += 1
	}
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	start := i
	value := 0
	for i < len(line) && line[i] >= '0' && line[i] <= '9' {
		value = value*10 + int(line[i] - '0')
		if value > 999 {
			return 0, false
		}
		i += 1
	}
	if i == start {
		return 0, false
	}
	if i < len(line) && line[i] != ' ' && line[i] != '\t' && line[i] != '\r' && line[i] != '\n' {
		return 0, false
	}
	return value, true
}

@(private = "file")
send_all :: proc(socket: net.TCP_Socket, data: string) -> net.TCP_Send_Error {
	raw := transmute([]u8)data
	sent := 0
	for sent < len(raw) {
		n, send_err := net.send_tcp(socket, raw[sent:])
		if send_err != .None {
			return send_err
		}
		sent += n
	}
	return .None
}

@(private = "file")
send_err_to_error :: proc(send_err: net.TCP_Send_Error, allocator: mem.Allocator) -> Error {
	return make_errorf(.Http, allocator, "request failed: %v", send_err)
}
