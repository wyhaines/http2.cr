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

    expect_raises(IO::Error, /closed stream/) do
      body.read(Bytes.new(1))
    end
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

  it "discards unread bytes when a finished body later becomes terminal" do
    body = HTTP2::StreamBody.new(
      8,
      ->(_amount : Int32) { },
      -> { }
    )
    body.enqueue("body".to_slice).should be_true
    body.finish

    error = IO::Error.new("late reset")
    body.terminate(error).should eq(4)
    body.buffered_bytes.should eq(0)
    expect_raises(IO::Error, /late reset/) do
      body.read(Bytes.new(1))
    end
  end
end
