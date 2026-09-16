package frostlake

import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"

@(test)
test_http_reads_content_length_bodies :: proc(t: ^testing.T) {
	server := loopback_raw_start("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
	defer loopback_raw_destroy(server)
	response, err := http_request("127.0.0.1", server.port, "GET", "/api/health", nil, context.allocator)
	testing.expectf(t, err == nil, "request failed: %s", error_message(err))
	destroy_error(err)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, response.body, "hello")
	delete(response.body)
	seen := loopback_raw_finish(server)
	testing.expectf(t, strings.has_prefix(seen, "GET /api/health HTTP/1.1\r\n"), "request was: %s", seen)
	testing.expectf(t, strings.contains(seen, "\r\nHost: 127.0.0.1:"), "request was: %s", seen)
	testing.expectf(t, strings.contains(seen, "\r\nConnection: close\r\n"), "request was: %s", seen)
}

@(test)
test_http_reads_chunked_bodies_with_extensions :: proc(t: ^testing.T) {
	server := loopback_raw_start(
		"HTTP/1.1 500 Server Error\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nab\r\n\r\n3\r\ncde\r\n0\r\n\r\n",
	)
	defer loopback_raw_destroy(server)
	response, err := http_request("127.0.0.1", server.port, "POST", "/api/execute", "{}", context.allocator)
	testing.expectf(t, err == nil, "request failed: %s", error_message(err))
	destroy_error(err)
	testing.expect_value(t, response.status, 500)
	testing.expect_value(t, response.body, "ab\r\ncde")
	delete(response.body)
	seen := loopback_raw_finish(server)
	testing.expectf(t, strings.contains(seen, "\r\nContent-Length: 2\r\n"), "request was: %s", seen)
	testing.expectf(t, strings.contains(seen, "\r\nContent-Type: application/json\r\n"), "request was: %s", seen)
	testing.expectf(t, strings.has_suffix(seen, "\r\n\r\n{}"), "request was: %s", seen)
}

@(test)
test_http_reads_to_eof_without_length :: proc(t: ^testing.T) {
	server := loopback_raw_start("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nrest of stream")
	defer loopback_raw_destroy(server)
	response, err := http_request("127.0.0.1", server.port, "GET", "/", nil, context.allocator)
	testing.expectf(t, err == nil, "request failed: %s", error_message(err))
	destroy_error(err)
	testing.expect_value(t, response.body, "rest of stream")
	delete(response.body)
	_ = loopback_raw_finish(server)
}

@(test)
test_http_rejects_a_bad_status_line :: proc(t: ^testing.T) {
	server := loopback_raw_start("garbage\r\n\r\n")
	defer loopback_raw_destroy(server)
	response, err := http_request("127.0.0.1", server.port, "GET", "/", nil, context.allocator)
	testing.expectf(t, err != nil, "request unexpectedly succeeded: %v", response)
	testing.expect(t, strings.contains(error_message(err), "bad status line"))
	destroy_error(err)
	if err == nil {
		delete(response.body)
	}
	_ = loopback_raw_finish(server)
}

@(test)
test_http_brackets_ipv6_hosts_in_the_host_header :: proc(t: ^testing.T) {
	// Self-skips where the loopback has no IPv6.
	listener, listen_err := net.listen_tcp(net.Endpoint{net.IP6_Loopback, 0})
	if listen_err != nil {
		log.info("skipping IPv6 test: cannot bind [::1]")
		return
	}
	endpoint, _ := net.bound_endpoint(listener)
	server := new(Loopback_Raw_Server)
	server.allocator = context.allocator
	server.listener = listener
	server.port = endpoint.port
	server.response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
	server.worker = thread.create_and_start_with_poly_data(server, loopback_raw_serve)

	response, err := http_request("::1", server.port, "GET", "/api/health", nil, context.allocator)
	testing.expectf(t, err == nil, "request failed: %s", error_message(err))
	destroy_error(err)
	if err == nil {
		testing.expect_value(t, response.body, "ok")
		delete(response.body)
	}
	seen := loopback_raw_finish(server)
	testing.expectf(t, strings.contains(seen, "\r\nHost: [::1]:"), "request was: %s", seen)
	loopback_raw_destroy(server)
}

// A single-response raw server: reads once (up to 4KB), answers with the
// canned bytes verbatim, closes. Distinct from Loopback_Server, which speaks
// well-formed HTTP — this one can serve garbage.
Loopback_Raw_Server :: struct {
	listener:        net.TCP_Socket,
	listener_closed: bool,
	port:            int,
	response:        string,
	seen:            string,
	allocator:       mem.Allocator,
	worker:          ^thread.Thread,
	finished:        bool,
}

loopback_raw_start :: proc(response: string) -> ^Loopback_Raw_Server {
	server := new(Loopback_Raw_Server)
	server.allocator = context.allocator
	server.response = response
	listener, listen_err := net.listen_tcp(net.Endpoint{net.IP4_Loopback, 0})
	assert(listen_err == nil, "cannot bind a loopback listener")
	endpoint, _ := net.bound_endpoint(listener)
	server.listener = listener
	server.port = endpoint.port
	server.worker = thread.create_and_start_with_poly_data(server, loopback_raw_serve)
	return server
}

loopback_raw_serve :: proc(server: ^Loopback_Raw_Server) {
	client, _, accept_err := net.accept_tcp(server.listener)
	if accept_err != .None {
		return
	}
	server.seen = loopback_read_request(client, server.allocator)
	raw := transmute([]u8)server.response
	sent := 0
	for sent < len(raw) {
		written, send_err := net.send_tcp(client, raw[sent:])
		if send_err != .None {
			break
		}
		sent += written
	}
	net.close(client)
}

loopback_raw_finish :: proc(server: ^Loopback_Raw_Server) -> string {
	if server.worker != nil {
		thread.join(server.worker)
		thread.destroy(server.worker)
		server.worker = nil
	}
	if !server.listener_closed {
		net.close(server.listener)
		server.listener_closed = true
	}
	server.finished = true
	return server.seen
}

loopback_raw_destroy :: proc(server: ^Loopback_Raw_Server) {
	if !server.finished {
		_ = loopback_raw_finish(server)
	}
	delete(server.seen, server.allocator)
	free(server, server.allocator)
}
