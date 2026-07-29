require "./spec_helper"

# Regression coverage for the writer batching in `src/connection.cr`
# (`writer_loop`/`flush_batch`, added to fix a WINDOW_UPDATE starvation
# valve): every other flow-control spec in this suite uses a
# `UNIXSocket.pair` left at its default `sync = true`, where every
# `IO#write` is its own `send(2)` regardless of whether `#flush` is ever
# called — so a bug that only manifests once writes accumulate in a
# genuinely *buffered* transport was invisible to the rest of the suite,
# including its own 10x concurrency gate. `sync = false` plus a sized
# `buffer_size` is exactly what `Connection.connect_prior_knowledge` /
# `.start_tls` configure in production (see the buffer-sizing rationale
# there); this spec configures the client transport the same way
# directly, over a `UNIXSocket.pair`, to exercise that real code path.
describe HTTP2::Connection do
  it "flushes a WINDOW_UPDATE-only batch promptly over a buffered transport" do
    UNIXSocket.pair do |client, peer|
      client.sync = false
      client.buffer_size = 8192

      stream_id = Channel(UInt32).new(1)
      credit_received = Channel(Nil).new(1)

      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        # A padded DATA frame's pad-length byte and padding bytes are
        # credited back to the peer as soon as they're observed
        # (`#handle_inbound_data`'s `overhead`/`#release_receive_credit`
        # path) -- no application-level body read is required to
        # trigger it. The writer stages this as a WINDOW_UPDATE-only
        # batch: nothing owns these frames as a `WriteCommand`, and
        # staging them changes no pool capacity, so `completions` stays
        # empty and `capacity_changed` stays `false` for this entire
        # batch. Before the fix, `#flush_batch`'s guard treated that
        # combination as "nothing to flush" and returned without ever
        # calling `@transport.flush`, leaving this credit stuck in the
        # buffered transport indefinitely once the writer went idle and
        # parked -- reproduced below by asserting the peer actually
        # receives it within a bounded timeout instead of hanging the
        # whole example.
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::PADDED,
          id,
          Bytes[1, 0x61, 0x62, 0x63, 0]
        ).write(io)
        io.flush

        connection_update = HTTP2::Frame.read(io)
          .as(HTTP2::Frame::WindowUpdate)
        connection_update.stream_id.should eq(0_u32)
        connection_update.window_size_increment.should eq(2_u32)
        stream_update = HTTP2::Frame.read(io)
          .as(HTTP2::Frame::WindowUpdate)
        stream_update.stream_id.should eq(id)
        stream_update.window_size_increment.should eq(2_u32)
        credit_received.send(nil)

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          id,
          Bytes.empty
        ).write(io)
        io.flush
      end

      # `max_buffered_body_bytes: 5` (below `SettingsState::DEFAULT_INITIAL_WINDOW_SIZE`)
      # makes `Configuration` advertise `SETTINGS_INITIAL_WINDOW_SIZE = 5`
      # to the peer, so this stream's replenishment watermark
      # (half that, `#replenishment_due_unlocked?`) is 2 -- exactly the
      # padded frame's overhead below, so the credit crosses it and wakes
      # the writer immediately without needing a separate body read.
      configuration = HTTP2::Connection::Configuration.new(
        max_buffered_body_bytes: 5
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream)
        stream_id.send(stream.id)

        select
        when credit_received.receive
        when timeout(2.seconds)
          fail(
            "peer never received the WINDOW_UPDATE credit -- it is " \
            "stuck in the writer's buffered transport"
          )
        end

        stream.body.gets_to_end.should eq("abc")
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end
end
