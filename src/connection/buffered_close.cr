# :nodoc:
#
# `IO::Buffered#close` flushes any bytes still sitting in the write buffer
# before closing (`flush if @out_count > 0`). That is exactly right for an
# ordinary close, but it is unsafe as the *only* way to close a transport
# once write buffering is enabled (P1.8 — see
# `Connection.connect_prior_knowledge`): if a peer stops reading, the
# writer fiber can be parked indefinitely inside its own `#flush` (holding
# the socket's internal write lock, `Crystal::FdLock`, for as long as that
# write is in flight). A second, close-triggered flush attempt (from a
# different fiber) then blocks *acquiring that same write lock* — and
# since it never reaches `#unbuffered_close`, it never fires the one
# mechanism (`Crystal::FdLock#try_close?`'s forced wake of parked
# readers/writers) that would unblock the original writer. The result is a
# genuine deadlock: `Connection#close` hangs forever against a stalled
# peer, even though it used to return promptly (pre-buffering, every write
# was already synced, so `@out_count` was always 0 and `#close` went
# straight to `#unbuffered_close`). See the P1.8 task report for the full
# trace.
#
# `#close_discarding_buffer` restores that "always go straight to
# `#unbuffered_close`" behavior explicitly, regardless of `@out_count`: any
# bytes still buffered here were already handed to the writer fiber's own
# in-flight `#flush` attempt (this does not cancel that attempt — it only
# skips a redundant, deadlock-prone second send of the same bytes), or
# were never going to reach a peer that has stopped reading in the first
# place. For the common case (`@out_count` already 0 — no write in
# flight) this is behaviorally identical to `#close`.
#
# **This alone does not make TLS closes safe** — `OpenSSL::SSL::Socket` is
# also `IO::Buffered` (has never set `sync = true`, so it has always been
# exposed to the deadlock above too), and this method does fix that same
# frame-buffer-flush deadlock for it. But `OpenSSL::SSL::Socket#unbuffered_close`
# *itself* unconditionally performs an independent write (`SSL_shutdown`
# sending a close_notify alert through the underlying socket), which
# `@out_count = 0` has no effect on and which can equally block forever
# against a stalled peer. `Connection#close_transport` does not rely on
# this method alone for TLS — see its own comment in src/connection.cr for
# how it closes the underlying raw socket directly instead.
module IO::Buffered
  def close_discarding_buffer : Nil
    @out_count = 0
    unbuffered_close
  end
end
