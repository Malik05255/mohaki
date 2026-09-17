#pragma once

namespace jawal {

// Fast, non-blocking-ish readiness probe used only by the host boot overlay.
// It performs one localhost connection attempt to Jawal's private guest-control
// port and uses short socket timeouts so stopping the VM never waits on it.
bool GuestReadyFast() noexcept;

} // namespace jawal
