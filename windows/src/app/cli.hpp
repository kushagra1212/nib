#pragma once

namespace nib::app {

// The command line, for seeing a feature fail with a reason: every probe
// prints each stage, so a failure names itself instead of being silence.
// Returns the exit code, or -1 when the arguments are not a CLI command and
// the app should start.
int run_cli(int argc, wchar_t** argv);

}  // namespace nib::app
