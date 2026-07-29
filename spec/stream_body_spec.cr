require "./spec_helper"

describe HTTP2::StreamBody do
  it "preserves chunk order and returns credit only as bytes are read" do
    consumed = 0
    canceled = false
    body = HTTP2::StreamBody.new(
      6,
      ->(amount : Int32) { consumed += amount; nil },
      -> { canceled = true; nil }
    )

    body.enqueue("abc".to_slice).should be_true
    body.enqueue("def".to_slice).should be_true
    body.enqueue("x".to_slice).should be_false
    body.buffered_bytes.should eq(6)
    consumed.should eq(0)

    first = Bytes.new(2)
    body.read(first).should eq(2)
    first.should eq("ab".to_slice)
    consumed.should eq(2)

    body.finish
    body.gets_to_end.should eq("cdef")
    consumed.should eq(6)
    body.read(Bytes.new(1)).should eq(0)
    canceled.should be_false
  end

  it "discards and credits buffered bytes when an unfinished body closes" do
    consumed = 0
    canceled = false
    body = HTTP2::StreamBody.new(
      8,
      ->(amount : Int32) { consumed += amount; nil },
      -> { canceled = true; nil }
    )
    body.enqueue("body".to_slice).should be_true

    body.close

    body.closed?.should be_true
    body.buffered_bytes.should eq(0)
    consumed.should eq(4)
    canceled.should be_true
  end

  it "raises IO::Error instead of returning 0 when read after the " \
     "caller closes the body" do
    body = HTTP2::StreamBody.new(
      8,
      ->(_amount : Int32) { },
      -> { }
    )

    body.close

    expect_raises(IO::Error, /Closed stream/) do
      body.read(Bytes.new(1))
    end
  end

  it "still raises the stream's own terminal error, not the generic " \
     "closed-stream error, when a terminated body is also closed" do
    body = HTTP2::StreamBody.new(
      8,
      ->(_amount : Int32) { },
      -> { }
    )
    error = IO::Error.new("stream reset")

    body.terminate(error)
    body.close

    exception = expect_raises(IO::Error) { body.read(Bytes.new(1)) }
    exception.same?(error).should be_true
  end

  it "wakes a blocked reader with a terminal error" do
    body = HTTP2::StreamBody.new(
      8,
      ->(_amount : Int32) { },
      -> { }
    )
    result = Channel(Exception?).new(1)
    spawn do
      begin
        body.read(Bytes.new(1))
        result.send(nil)
      rescue error
        result.send(error)
      end
    end

    error = IO::Error.new("reset")
    body.terminate(error).should eq(0)
    select
    when observed = result.receive
      observed.should be(error)
    when timeout(1.second)
      fail("body reader was not woken")
    end
  end

  it "does not discard unread bytes when a finished body later becomes terminal" do
    body = HTTP2::StreamBody.new(
      8,
      ->(_amount : Int32) { },
      -> { }
    )
    body.enqueue("body".to_slice).should be_true
    body.finish

    error = IO::Error.new("late reset")
    body.terminate(error).should eq(0)
    body.buffered_bytes.should eq(4)
    buffer = Bytes.new(8)
    body.read(buffer).should eq(4)
    buffer[0, 4].should eq("body".to_slice)
  end

  it "terminate after finish preserves buffered data through to EOF" do
    body = HTTP2::StreamBody.new(
      6,
      ->(_amount : Int32) { },
      -> { }
    )
    body.enqueue("hello".to_slice).should be_true
    body.finish
    body.terminate(IO::Error.new("late reset")).should eq(0)
    buffer = Bytes.new(16)
    body.read(buffer).should eq(5)
    body.read(buffer).should eq(0)
  end

  it "drains multiple buffered chunks in a single read" do
    consumed = 0
    body = HTTP2::StreamBody.new(
      8,
      ->(amount : Int32) { consumed += amount; nil },
      -> { }
    )
    body.enqueue("aaaa".to_slice).should be_true
    body.enqueue("bbbb".to_slice).should be_true
    buffer = Bytes.new(8)
    body.read(buffer).should eq(8)
    String.new(buffer).should eq("aaaabbbb")
    consumed.should eq(8)
  end
end
