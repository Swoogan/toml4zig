const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const cflags = [_][]const u8 {
        "-std=c99",
        "-Wall",
        "-Wextra",
        "-fpic"
    };

    const lib = b.addStaticLibrary("toml4zig", null);
    lib.linkSystemLibrary("c");
    lib.setBuildMode(mode);
    lib.addCSourceFile("toml.c", cflags);

    b.default_step.dependOn(&lib.step);
    b.installArtifact(lib);

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
