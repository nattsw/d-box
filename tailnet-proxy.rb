#!/usr/bin/env ruby
# frozen_string_literal: true

require "socket"

listen_port, target_host, target_port = ARGV
abort "usage: tailnet-proxy.rb LISTEN_PORT TARGET_HOST TARGET_PORT" unless target_port

server = TCPServer.new("127.0.0.1", Integer(listen_port))
stopping = false

shutdown = proc do
  stopping = true
  server.close unless server.closed?
end
Signal.trap("INT", &shutdown)
Signal.trap("TERM", &shutdown)

begin
  loop do
    client = server.accept
    Thread.new(client) do |downstream|
      upstream = TCPSocket.new(target_host, Integer(target_port))
      writers = [
        Thread.new { IO.copy_stream(downstream, upstream); upstream.close_write },
        Thread.new { IO.copy_stream(upstream, downstream); downstream.close_write },
      ]
      writers.each(&:join)
    rescue SystemCallError, IOError
      # A request can arrive while the dev server is starting or stopping.
    ensure
      upstream&.close
      downstream.close unless downstream.closed?
    end
  end
rescue IOError
  raise unless stopping
end
