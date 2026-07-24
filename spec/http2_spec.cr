require "./spec_helper"

describe HTTP2 do
  it "exposes the shard version in its namespace" do
    HTTP2::VERSION.should eq "1.0.0-rc.1"
  end
end
