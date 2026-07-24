require "./spec_helper"

describe HTTP2 do
  it "exposes the shard version in its namespace" do
    HTTP2::VERSION.should eq "0.1.0"
  end
end
