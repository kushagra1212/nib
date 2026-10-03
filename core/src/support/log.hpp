#pragma once
#include <string>
#include <string_view>
#include <vector>

// Port of Log.swift, with the split the control panel design called for: a
// bounded in-memory ring that is always fed, and a file write that stays
// gated. The panel reads the ring, so logging can be looked at after the thing
// worth seeing has already started going wrong.
//
// No field text is ever written, only lengths and counts. The log is one click
// from the clipboard in Diagnostics, and it would otherwise record what
// someone typed into a password manager or a private channel.

namespace nib::log {

void write(std::string_view message);

// File output: on when NIB_LOG is set at launch, or turned on from the panel.
bool file_enabled();
void set_file_enabled(bool enabled);

// The most recent lines, oldest first. Bounded at 500.
std::vector<std::string> recent();

void reset();

}  // namespace nib::log
