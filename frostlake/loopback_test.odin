// A canned-response loopback HTTP server for the tests: serves the scripted
// (status, body) exchanges — one TCP connection each, the way the driver's
// Connection: close protocol works — and records the request payloads it saw.
//
// Every test that starts a server must consume ALL its exchanges before
// calling loopback_finish, or the join would wait on an accept that never
// comes.
package frostlake

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:thread"

Canned_Exchange :: struct {
	status: int,
	body:   string,
}

Loopback_Server :: struct {
	listener:        net.TCP_Socket,
	listener_closed: bool,
	port:            int,
	exchanges:       []Canned_Exchange,
	seen:            [dynamic]string,
	allocator:       mem.Allocator,
	worker:          ^thread.Thread,
}

loopback_start :: proc(exchanges: []Canned_Exchange) -> ^Loopback_Server {
	server := new(Loopback_Server)
	server.allocator = context.allocator
	server.exchanges = exchanges
	server.seen = make([dynamic]string, server.allocator)
	listener, listen_err := net.listen_tcp(net.Endpoint{net.IP4_Loopback, 0})
	assert(listen_err == nil, "cannot bind a loopback listener")
	endpoint, _ := net.bound_endpoint(listener)
	server.listener = listener
	server.port = endpoint.port
	server.worker = thread.create_and_start_with_poly_data(server, loopback_serve)
	return server
}

// Joins the worker (all exchanges must have been consumed) and returns the
// request payloads seen, in order. The slices stay owned by the server.
loopback_finish :: proc(server: ^Loopback_Server) -> []string {
	if server.worker != nil {
		thread.join(server.worker)
		thread.destroy(server.worker)
		server.worker = nil
	}
	if !server.listener_closed {
		net.close(server.listener)
		server.listener_closed = true
	}
	return server.seen[:]
}

loopback_destroy :: proc(server: ^Loopback_Server) {
	_ = loopback_finish(server)
	for request in server.seen {
		delete(request, server.allocator)
	}
	delete(server.seen)
	free(server, server.allocator)
}

@(private = "file")
loopback_serve :: proc(server: ^Loopback_Server) {
	for exchange in server.exchanges {
		client, _, accept_err := net.accept_tcp(server.listener)
		if accept_err != .None {
			return
		}
		request := loopback_read_request(client, server.allocator)
		append(&server.seen, request)
		response := fmt.aprintf(
			"HTTP/1.1 %d X\r\nContent-Length: %d\r\n\r\n%s",
			exchange.status,
			len(exchange.body),
			exchange.body,
			allocator = server.allocator,
		)
		loopback_send(client, response)
		delete(response, server.allocator)
		net.close(client)
	}
}

@(private = "file")
loopback_send :: proc(client: net.TCP_Socket, data: string) {
	raw := transmute([]u8)data
	sent := 0
	for sent < len(raw) {
		n, send_err := net.send_tcp(client, raw[sent:])
		if send_err != .None {
			return
		}
		sent += n
	}
}

// Reads one full HTTP request (head + Content-Length body) off the socket.
@(private)
loopback_read_request :: proc(client: net.TCP_Socket, allocator: mem.Allocator) -> string {
	data := make([dynamic]u8, allocator)
	defer delete(data)
	buffer: [4096]u8
	for {
		if text, complete := loopback_complete_request(data[:]); complete {
			return strings.clone(text, allocator)
		}
		n, recv_err := net.recv_tcp(client, buffer[:])
		if recv_err != .None || n == 0 {
			return strings.clone(string(data[:]), allocator)
		}
		append(&data, ..buffer[:n])
	}
}

@(private = "file")
loopback_complete_request :: proc(data: []u8) -> (text: string, complete: bool) {
	text = string(data)
	head_end := strings.index(text, "\r\n\r\n")
	if head_end < 0 {
		return "", false
	}
	content_length := 0
	remaining := text[:head_end]
	for line in strings.split_iterator(&remaining, "\r\n") {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		if strings.equal_fold(strings.trim_space(line[:colon]), "content-length") {
			value := strings.trim_space(line[colon + 1:])
			consumed := 0
			length, ok := strconv.parse_int(value, 10, &consumed)
			if ok && consumed == len(value) && length >= 0 {
				content_length = length
			}
		}
	}
	if len(data) >= head_end + 4 + content_length {
		return text, true
	}
	return "", false
}
