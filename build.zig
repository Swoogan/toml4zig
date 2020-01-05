const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const cflags = [_][]const u8{
        "-std=c99",
        "-Wall",
        "-Wextra",
        "-fpic",
    };

    const partial = b.addObject("toml.zig", "toml.zig");

    const lib = b.addStaticLibrary("toml4zig", null);
    lib.setBuildMode(mode);
    lib.addObject(partial);
    // lib.setTarget(.wasm32, .freestanding, .musl);
    lib.addCSourceFile("toml.c", &cflags);
    lib.linkSystemLibrary("c");

    b.default_step.dependOn(&lib.step);
    b.installArtifact(lib);

    const json = b.addExecutable("toml_json", null);
    json.setBuildMode(mode);
    json.addCSourceFile("toml_json.c", &cflags);
    json.linkSystemLibrary("c");
    json.linkLibrary(lib);

    b.default_step.dependOn(&json.step);
    b.installArtifact(json);

    // const cat = b.addExecutable("toml_cat", null);
    // cat.setBuildMode(mode);
    // cat.addCSourceFile("toml.c", &cflags);
    // cat.addCSourceFile("toml_cat.c", &cflags);
    // cat.addObject(object);
    // cat.linkSystemLibrary("c");
    // cat.linkLibrary(lib);

    // b.default_step.dependOn(&cat.step);
    // b.installArtifact(cat);
    // var main_tests = b.addTest("src/main.zig");
    // main_tests.setBuildMode(mode);

    // const test_step = b.step("test", "Run library tests");
    // test_step.dependOn(&main_tests.step);
}
