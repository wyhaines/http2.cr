require "./spec_helper"

describe HTTP2 do
  it "exposes the shard version in its namespace" do
    HTTP2::VERSION.should eq "0.1.0"
  end
end

describe HTTP2::Connection do
  it "writes the client preface to a supplied IO" do
    io = IO::Memory.new
    connection = HTTP2::Connection.new(io)

    connection.send_preface

    io.to_slice.should eq HTTP2::Connection::Preface
  end
end
