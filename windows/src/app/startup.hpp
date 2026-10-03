#pragma once

namespace nib::app::startup {

// Start at Login, through the per-user Run key: no admin prompt, and the same
// switch Task Manager's Startup tab shows and can turn off.
enum class State { on, off, disabled_by_user };

State state();
// Returns false when the registry refused.
bool set(bool enabled);

}  // namespace nib::app::startup
