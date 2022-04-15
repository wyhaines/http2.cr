abstract struct Int
  def gigabytes
    megabytes * 1024
  end

  def megabytes
    kilobytes * 1024
  end

  def megabyte
    megabytes
  end

  def kilobytes
    bytes * 1024
  end

  def kilobyte
    kilobytes
  end

  def bytes
    self
  end

  def byte
    bytes
  end
end
