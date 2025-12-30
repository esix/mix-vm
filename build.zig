const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Executable for the terminal
    const exe_module = b.addModule("mix-vm-module", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mix-vm",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Define the WASM target for the browser
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const main_helper = b.addModule("main", .{
        .root_source_file = b.path("src/main_wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm = b.addExecutable(.{
        .name = "mix-vm",
        .root_module = main_helper,
    });

    // <https://github.com/ziglang/zig/issues/8633  >
    wasm.global_base = 6560;
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = true;  // ENABLED IMPORT MEMORY AGAIN
    wasm.stack_size = std.wasm.page_size;

    const number_of_pages = 2;
    wasm.initial_memory = std.wasm.page_size * number_of_pages;
    wasm.max_memory = std.wasm.page_size * number_of_pages;

    const wasm_install = b.addInstallArtifact(wasm, .{});

    // Command to copy WASM to frontend
    const copy_step = b.step("copy-wasm", "Copy WASM to frontend");
    const copy_cmd = b.addSystemCommand(&.{ "cp", "zig-out/bin/mix-vm.wasm", "frontend/mix-vm.wasm" });
    copy_cmd.step.dependOn(&wasm_install.step);
    copy_step.dependOn(&copy_cmd.step);

    // Command to run the exe
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    b.getInstallStep().dependOn(&copy_cmd.step);
}
