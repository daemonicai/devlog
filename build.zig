// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_override = b.option([]const u8, "version", "devlog version string");
    const version = version_override orelse manifest.version;
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    // Lets the "version is embedded via the build option, not duplicated"
    // test in src/main.zig tell a legitimate `-Dversion=X` override apart
    // from the default path, without weakening what it actually protects
    // against: a hardcoded version literal in src/. See that test.
    options.addOption(bool, "version_overridden", version_override != null);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", options);
    // Exists solely so the "version is embedded via the build option, not
    // duplicated" test in src/main.zig can reach build.zig.zon directly —
    // no production code consumes "manifest".
    root_module.addAnonymousImport("manifest", .{ .root_source_file = b.path("build.zig.zon") });

    const exe = b.addExecutable(.{
        .name = "devlog",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run devlog");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    // Block 9A's e2e tests (src/e2e_test.zig) drive `zig-out/bin/devlog`
    // as a real child process, on purpose — that is the point of an
    // end-to-end test, and the one thing it must never do is validate a
    // stale binary while the unit tests beside it check current source.
    // `run_exe_tests` only depends on `exe_tests` (the test binary
    // itself), which says nothing about `exe`, so without this the
    // installed `devlog` could predate the source the tests just
    // compiled against and the suite would still print green. Depending
    // on the install step (not just `exe`) means "installed and up to
    // date at zig-out/bin/devlog", which is exactly what the e2e tests
    // read. This must hold for `zig build test` on its own — no target
    // ordering in the Makefile substitutes for it.
    run_exe_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // `zig build release` — cross-compiles the three tarball targets and
    // installs each to `zig-out/release/<triple>/devlog`. Deliberately not a
    // dependency of the default install step (`make build` stays host-only
    // and fast) and not added to `b.getInstallStep()`. The `Makefile`'s
    // `release` target owns packaging (tar, sha256) once these exist; this
    // step owns only compilation and where the binaries land — the triple
    // directory names below are the Makefile's `TRIPLES` list and must match
    // exactly, since it loops over that literal list.
    //
    // R9: always `ReleaseSafe`, never the host's `-Doptimize` and never
    // `ReleaseFast` — the only state this tool touches is a permanent
    // append-only log, and a corrupt log is unrecoverable.
    //
    // R10: the two Linux triples target musl with static linkage, so `ldd`
    // reports "not a dynamic executable". macOS cannot be fully static
    // (Apple does not support statically linking libSystem); the release
    // step does not attempt it, and `otool -L` listing only
    // `/usr/lib/libSystem.B.dylib` is the correct, expected result there.
    const release_step = b.step("release", "Cross-compile static release binaries");
    const release_targets = [_]struct {
        dir_name: []const u8,
        query: []const u8,
        static: bool,
    }{
        .{ .dir_name = "aarch64-macos", .query = "aarch64-macos", .static = false },
        .{ .dir_name = "x86_64-linux-musl", .query = "x86_64-linux-musl", .static = true },
        .{ .dir_name = "aarch64-linux-musl", .query = "aarch64-linux-musl", .static = true },
    };
    for (release_targets) |rt| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = rt.query }) catch unreachable;
        const resolved = b.resolveTargetQuery(query);

        const release_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseSafe,
        });
        release_module.addOptions("build_options", options);

        const release_exe = b.addExecutable(.{
            .name = "devlog",
            .root_module = release_module,
            .linkage = if (rt.static) .static else null,
        });

        const install_release = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{rt.dir_name}) } },
        });
        release_step.dependOn(&install_release.step);
    }
}
