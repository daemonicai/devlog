// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const build_options = @import("build_options");

/// Placeholder entry point. Block 1.4 replaces this with real subcommand
/// dispatch; this block only establishes the build, the version option, and
/// the test harness.
pub fn main() !void {}

test "version is embedded via the build option, not duplicated" {
    try std.testing.expectEqualStrings("0.1.0", build_options.version);
}
