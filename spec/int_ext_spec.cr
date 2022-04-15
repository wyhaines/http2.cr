describe Int do
  it "has a bunch of byte size helpers that all do what one would expect" do
    1.byte.should eq 1
    1_u32.byte.should be_a UInt32
    1.kilobyte.should eq 1024
    4_u16.kilobytes.should be_a UInt16
    4_u16.kilobytes.should eq 4096
    8.megabytes.should eq 8_388_608
    16_u64.gigabytes.should be_a UInt64
    16_u64.gigabytes.should eq 17_179_869_184
    (16_u64.gigabytes + 8.kilobytes).should eq 17_179_877_376
  end
end
