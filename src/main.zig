const std = @import("std");
const mix_asm = @import("mix_asm.zig");
const vm_mod  = @import("mix_vm.zig");
const mix_cpu = @import("mix_cpu.zig");

const Vm           = vm_mod.Vm;
const MixWordLayout = vm_mod.MixWordLayout;

const usage =
    \\Usage: mix-vm [options] <file>
    \\
    \\  <file>           Run a .mixal source file or a .mix binary
    \\  -c <file.mixal>  Compile .mixal to <file>.mix (no execution)
    \\  -d <file>        Interactive debugger
    \\  -h               Show this help
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.len < 2) {
        try stderr.writeAll(usage);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        try stdout.writeAll(usage);
        return;
    }

    if (std.mem.eql(u8, args[1], "-c")) {
        if (args.len < 3) {
            try stderr.writeAll("mix-vm: -c requires a filename\n");
            std.process.exit(1);
        }
        try compileOnly(args[2], allocator, stderr.any());
        return;
    }

    if (std.mem.eql(u8, args[1], "-d")) {
        if (args.len < 3) {
            try stderr.writeAll("mix-vm: -d requires a filename\n");
            std.process.exit(1);
        }
        try debugMode(args[2], allocator, stderr.any());
        return;
    }

    try runMode(args[1], allocator, stderr.any());
}

// ── file loading ──────────────────────────────────────────────────────────────

fn loadSource(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return f.readToEndAlloc(allocator, 8 * 1024 * 1024);
}

/// Assemble .mixal source or parse .mix binary into a VM. Returns start address.
fn loadIntoVm(
    path:       []const u8,
    vm:         *Vm,
    allocator:  std.mem.Allocator,
    err_writer: std.io.AnyWriter,
) !u32 {
    if (std.mem.endsWith(u8, path, ".mix")) {
        return parseMix(path, vm, allocator);
    }
    const source = try loadSource(path, allocator);
    defer allocator.free(source);

    var result = try mix_asm.assemble(source, allocator, err_writer);
    defer result.deinit();

    for (result.words) |w| {
        var word: MixWordLayout = .{ .bytes = .{ 0, 0, 0, 0, 0 }, .sign = 0 };
        word.setValueFromInt(w.value);
        vm.memory.writeWord(w.addr, word);
    }
    return result.start_addr;
}

/// Parse MDK .mix binary (little-endian) into VM, return start address.
/// Format: 4-byte magic, 4-byte version, 4-byte ?, 4-byte start_addr,
///         8 bytes of header data, then symbol string ending with ';',
///         then 4-byte word records + 2-byte line numbers (all little-endian).
fn parseMix(path: []const u8, vm: *Vm, allocator: std.mem.Allocator) !u32 {
    const data = try loadSource(path, allocator);
    defer allocator.free(data);

    if (data.len < 16) return error.InvalidFormat;
    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic != 0xBEEFDEAD) return error.InvalidFormat;

    // Start address is in the header at offset 12
    const start_addr: u32 = std.mem.readInt(u32, data[12..16], .little);

    var cur_addr: u32 = start_addr;

    // Skip string section: scan forward from byte 16 for ';' (0x3B)
    var pos: usize = 16;
    while (pos < data.len and data[pos] != 0x3B) pos += 1;
    pos += 1; // skip ';'

    while (pos + 4 <= data.len) {
        const raw = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (raw & 0x80000000 != 0) {
            cur_addr = raw & 0x7FFFFFFF;
            continue;
        }
        if (pos + 2 > data.len) break;
        pos += 2; // skip line number
        var word: MixWordLayout = .{ .bytes = .{ 0, 0, 0, 0, 0 }, .sign = 0 };
        word.setValueFromInt(@bitCast(raw));
        if (cur_addr < 4000) vm.memory.writeWord(cur_addr, word);
        cur_addr += 1;
    }
    return start_addr;
}

/// Write MDK .mix binary for -c mode.
fn writeMix(path: []const u8, result: *const mix_asm.AssembleResult) !void {
    var out_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = std.fs.path.stem(path);
    const dir  = std.fs.path.dirname(path) orelse ".";
    const out_path = try std.fmt.bufPrint(&out_path_buf, "{s}/{s}.mix", .{ dir, base });

    const f = try std.fs.cwd().createFile(out_path, .{});
    defer f.close();
    const w = f.deprecatedWriter();

    // MDK-compatible header (little-endian)
    try w.writeInt(u32, 0xBEEFDEAD,        .little); // magic
    try w.writeInt(u32, 1,                 .little); // version
    try w.writeInt(u32, 0,                 .little); // num symbols
    try w.writeInt(u32, result.start_addr, .little); // start address
    try w.writeInt(u32, 0,                 .little); // path length (0 = no path prefix)
    try w.writeInt(u32, 0,                 .little); // padding
    try w.writeByte(0x3B);                            // end of symbol table

    // Words are already sorted by address from the assembler.
    // Emit a block-start record whenever the address is non-consecutive.
    var prev_addr: ?u32 = null;
    for (result.words) |wr| {
        if (prev_addr == null or wr.addr != prev_addr.? + 1) {
            // new contiguous block
            try w.writeInt(u32, 0x80000000 | wr.addr, .little);
        }
        try w.writeInt(u32, @bitCast(wr.value), .little);
        try w.writeInt(u16, 0,                  .little); // line number
        prev_addr = wr.addr;

    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("Wrote {s}\n", .{out_path});
}

// ── modes ─────────────────────────────────────────────────────────────────────

fn compileOnly(path: []const u8, allocator: std.mem.Allocator, err_writer: std.io.AnyWriter) !void {
    if (!std.mem.endsWith(u8, path, ".mixal")) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("mix-vm: -c expects a .mixal file, got: {s}\n", .{path});
        std.process.exit(1);
    }
    const source = try loadSource(path, allocator);
    defer allocator.free(source);

    var result = try mix_asm.assemble(source, allocator, err_writer);
    defer result.deinit();

    try writeMix(path, &result);
}

fn runMode(path: []const u8, allocator: std.mem.Allocator, err_writer: std.io.AnyWriter) !void {
    var vm: Vm = undefined;
    vm.init();

    const start = loadIntoVm(path, &vm, allocator, err_writer) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("mix-vm: failed to load '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    vm.pc = @intCast(start);

    runToHalt(&vm);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("Halted at PC={d}  cycles={d}\n", .{ vm.pc, vm.cycle });
    try printRegs(&vm, stdout);
}

fn runToHalt(vm: *Vm) void {
    var limit: u32 = 10_000_000;
    while (!vm.halted and limit > 0) : (limit -= 1) {
        mix_cpu.step(vm);
    }
}

fn debugMode(path: []const u8, allocator: std.mem.Allocator, err_writer: std.io.AnyWriter) !void {
    var vm: Vm = undefined;
    vm.init();

    const start = loadIntoVm(path, &vm, allocator, err_writer) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("mix-vm: failed to load '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    vm.pc = @intCast(start);

    try runDebugger(&vm, allocator);
}

// ── debugger REPL ─────────────────────────────────────────────────────────────

fn runDebugger(vm: *Vm, allocator: std.mem.Allocator) !void {
    const stdin  = std.fs.File.stdin().deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    var breakpoints = std.AutoHashMap(u32, void).init(allocator);
    defer breakpoints.deinit();

    var buf: [256]u8 = undefined;

    try stdout.writeAll("MIX Debugger  (h for help)\n");
    try printRegs(vm, stdout);
    try printMem(vm, vm.pc, 5, stdout);

    while (true) {
        try stdout.print("(mix) ", .{});
        const line = stdin.readUntilDelimiter(&buf, '\n') catch break;
        const cmd  = std.mem.trim(u8, line, " \t\r");
        if (cmd.len == 0) continue;

        const sp   = std.mem.indexOfScalar(u8, cmd, ' ');
        const verb = if (sp) |i| cmd[0..i] else cmd;
        const rest = if (sp) |i| std.mem.trim(u8, cmd[i..], " \t") else "";

        if (std.mem.eql(u8, verb, "q") or std.mem.eql(u8, verb, "quit")) {
            break;
        } else if (std.mem.eql(u8, verb, "h") or std.mem.eql(u8, verb, "help")) {
            try stdout.writeAll(
                \\  s / step            step one instruction
                \\  r / run / c / cont  run until halt or breakpoint
                \\  p / regs            print registers
                \\  pc                  print program counter
                \\  b  <addr>           toggle breakpoint at addr
                \\  bl                  list breakpoints
                \\  m  <addr> [n]       show n words of memory (default 10)
                \\  q / quit            exit
                \\
            );
        } else if (std.mem.eql(u8, verb, "s") or std.mem.eql(u8, verb, "step")) {
            if (vm.halted) {
                try stdout.writeAll("VM is halted\n");
            } else {
                mix_cpu.step(vm);
                try stdout.print("PC={d}  cycles={d}\n", .{ vm.pc, vm.cycle });
                try printMem(vm, vm.pc, 1, stdout);
            }
        } else if (std.mem.eql(u8, verb, "r")    or std.mem.eql(u8, verb, "run") or
                   std.mem.eql(u8, verb, "c")    or std.mem.eql(u8, verb, "cont"))
        {
            var limit: u32 = 10_000_000;
            while (!vm.halted and limit > 0) : (limit -= 1) {
                mix_cpu.step(vm);
                if (breakpoints.contains(vm.pc)) {
                    try stdout.print("Break @ {d}\n", .{vm.pc});
                    break;
                }
            }
            if (vm.halted) try stdout.writeAll("Halted\n");
            try printRegs(vm, stdout);
        } else if (std.mem.eql(u8, verb, "p") or std.mem.eql(u8, verb, "regs")) {
            try printRegs(vm, stdout);
        } else if (std.mem.eql(u8, verb, "pc")) {
            try stdout.print("PC = {d}\n", .{vm.pc});
        } else if (std.mem.eql(u8, verb, "b") or std.mem.eql(u8, verb, "break")) {
            const addr = std.fmt.parseInt(u32, rest, 10) catch {
                try stdout.writeAll("b <addr>\n");
                continue;
            };
            if (breakpoints.contains(addr)) {
                _ = breakpoints.remove(addr);
                try stdout.print("Breakpoint removed at {d}\n", .{addr});
            } else {
                try breakpoints.put(addr, {});
                try stdout.print("Breakpoint set at {d}\n", .{addr});
            }
        } else if (std.mem.eql(u8, verb, "bl")) {
            var it  = breakpoints.keyIterator();
            var any = false;
            while (it.next()) |k| {
                try stdout.print("  {d}\n", .{k.*});
                any = true;
            }
            if (!any) try stdout.writeAll("  (none)\n");
        } else if (std.mem.eql(u8, verb, "m") or std.mem.eql(u8, verb, "mem")) {
            var addr:  u32 = vm.pc;
            var count: u32 = 10;
            var parts = std.mem.splitScalar(u8, rest, ' ');
            if (parts.next()) |a| {
                if (a.len > 0) addr = std.fmt.parseInt(u32, a, 10) catch vm.pc;
            }
            if (parts.next()) |n| {
                if (n.len > 0) count = std.fmt.parseInt(u32, n, 10) catch 10;
            }
            try printMem(vm, addr, count, stdout);
        } else {
            try stdout.print("Unknown command: {s}  (h for help)\n", .{verb});
        }
    }
}

// ── display helpers ───────────────────────────────────────────────────────────

fn fmtWord(w: MixWordLayout, buf: []u8) []const u8 {
    const sign: u8 = if (w.sign == 1) '-' else '+';
    return std.fmt.bufPrint(buf, "{c} {:0>2} {:0>2} {:0>2} {:0>2} {:0>2}", .{
        sign, w.bytes[0], w.bytes[1], w.bytes[2], w.bytes[3], w.bytes[4],
    }) catch buf[0..0];
}

fn printRegs(vm: *const Vm, writer: anytype) !void {
    var buf: [64]u8 = undefined;
    try writer.print("rA  = {s}\n", .{fmtWord(vm.rA, &buf)});
    try writer.print("rX  = {s}\n", .{fmtWord(vm.rX, &buf)});
    for (vm.rI, 0..) |ri, i| {
        try writer.print("rI{d} = {d}\n", .{ i + 1, ri.toInt() });
    }
    try writer.print("rJ  = {d}\n", .{vm.rJ});
    try writer.print("PC  = {d}  cycles={d}  halted={}\n", .{ vm.pc, vm.cycle, vm.halted });
    const cmp_str: []const u8 = switch (vm.cmp) {
        .less    => "L",
        .equal   => "E",
        .greater => "G",
    };
    try writer.print("OV  = {}  CMP = {s}\n", .{ vm.overflow, cmp_str });
}

fn printMem(vm: *const Vm, addr: u32, count: u32, writer: anytype) !void {
    var buf: [64]u8 = undefined;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const a = addr + i;
        if (a >= 4000) break;
        const w          = vm.memory.readWord(a);
        const pc_marker: []const u8 = if (a == vm.pc) ">" else " ";
        try writer.print("{s}{d:0>4}  {s}\n", .{ pc_marker, a, fmtWord(w, &buf) });
    }
}
