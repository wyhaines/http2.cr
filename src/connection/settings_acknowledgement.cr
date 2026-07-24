module HTTP2
  class Connection
    # :nodoc:
    class SettingsAcknowledgement
      getter settings : SettingsState
      getter sent_at : Time::Instant?

      def initialize(@settings : SettingsState)
      end

      def mark_sent(at : Time::Instant) : Nil
        @sent_at ||= at
      end
    end
  end
end
