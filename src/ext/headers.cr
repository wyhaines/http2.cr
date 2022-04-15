require "http/headers"

struct HTTP::Headers
  def serialize(io)
    self.each do |name, values|
      values.each do |value|
        io << name << ": " << value << "\r\n"
      end
    end
    io << "\r\n"

    io
  end
end
