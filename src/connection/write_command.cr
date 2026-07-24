module HTTP2
  class Connection
    # :nodoc:
    class WriteCommand
      getter frames : Array(Frames)
      getter? preface : Bool
      getter encoder_table_size : Int32?
      getter header_block : HeaderBlock?

      @completion = Channel(Exception?).new(1)

      record HeaderBlock,
        stream_id : UInt32,
        fields : Array(HeaderField),
        end_stream : Bool

      def initialize(
        @frames : Array(Frames),
        @preface : Bool = false,
        @encoder_table_size : Int32? = nil,
        @header_block : HeaderBlock? = nil,
      )
      end

      def self.settings_ack(encoder_table_size : Int32?) : self
        new(
          [Frame::Settings.ack] of Frames,
          encoder_table_size: encoder_table_size
        )
      end

      def self.headers(
        stream_id : UInt32,
        fields : Array(HeaderField),
        end_stream : Bool,
      ) : self
        new(
          [] of Frames,
          header_block: HeaderBlock.new(stream_id, fields, end_stream)
        )
      end

      def complete(error : Exception? = nil) : Nil
        @completion.send(error)
      end

      def wait : Nil
        if error = @completion.receive
          raise error
        end
      end
    end
  end
end
