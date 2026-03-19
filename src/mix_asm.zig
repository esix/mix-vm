/// Two-pass MIXAL assembler.
/// Mirrors the logic in frontend/assembler.js.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// ── Public API ────────────────────────────────────────────────────────────────

pub const WordEntry = struct { addr: u32, value: i32 };

pub const AssembleResult = struct {
    words:      []WordEntry,
    start_addr: u32,
    allocator:  Allocator,

    pub fn deinit(self: AssembleResult) void {
        self.allocator.free(self.words);
    }
};

/// Assemble MIXAL source.  Errors are written to `err_writer`.
/// Returns `error.AssemblyFailed` if any error was encountered.
pub fn assemble(
    source:     []const u8,
    allocator:  Allocator,
    err_writer: std.io.AnyWriter,
) (Allocator.Error || error{AssemblyFailed})!AssembleResult {
    var a = Assembler.init(allocator, err_writer);
    defer a.deinit();
    return a.run(source);
}

// ── Opcode table (sorted for binary search) ───────────────────────────────────

const Op = struct { name: []const u8, c: u8, f: u8 };

const OPS = [_]Op{
    .{ .name = "ADD",  .c = 1,  .f = 5 },
    .{ .name = "CHAR", .c = 5,  .f = 1 },
    .{ .name = "CMP1", .c = 57, .f = 5 }, .{ .name = "CMP2", .c = 58, .f = 5 },
    .{ .name = "CMP3", .c = 59, .f = 5 }, .{ .name = "CMP4", .c = 60, .f = 5 },
    .{ .name = "CMP5", .c = 61, .f = 5 }, .{ .name = "CMP6", .c = 62, .f = 5 },
    .{ .name = "CMPA", .c = 56, .f = 5 }, .{ .name = "CMPX", .c = 63, .f = 5 },
    .{ .name = "DEC1", .c = 49, .f = 1 }, .{ .name = "DEC2", .c = 50, .f = 1 },
    .{ .name = "DEC3", .c = 51, .f = 1 }, .{ .name = "DEC4", .c = 52, .f = 1 },
    .{ .name = "DEC5", .c = 53, .f = 1 }, .{ .name = "DEC6", .c = 54, .f = 1 },
    .{ .name = "DECA", .c = 48, .f = 1 }, .{ .name = "DECX", .c = 55, .f = 1 },
    .{ .name = "DIV",  .c = 4,  .f = 5 },
    .{ .name = "ENN1", .c = 49, .f = 3 }, .{ .name = "ENN2", .c = 50, .f = 3 },
    .{ .name = "ENN3", .c = 51, .f = 3 }, .{ .name = "ENN4", .c = 52, .f = 3 },
    .{ .name = "ENN5", .c = 53, .f = 3 }, .{ .name = "ENN6", .c = 54, .f = 3 },
    .{ .name = "ENNA", .c = 48, .f = 3 }, .{ .name = "ENNX", .c = 55, .f = 3 },
    .{ .name = "ENT1", .c = 49, .f = 2 }, .{ .name = "ENT2", .c = 50, .f = 2 },
    .{ .name = "ENT3", .c = 51, .f = 2 }, .{ .name = "ENT4", .c = 52, .f = 2 },
    .{ .name = "ENT5", .c = 53, .f = 2 }, .{ .name = "ENT6", .c = 54, .f = 2 },
    .{ .name = "ENTA", .c = 48, .f = 2 }, .{ .name = "ENTX", .c = 55, .f = 2 },
    .{ .name = "HLT",  .c = 5,  .f = 2 },
    .{ .name = "IN",   .c = 36, .f = 0 },
    .{ .name = "INC1", .c = 49, .f = 0 }, .{ .name = "INC2", .c = 50, .f = 0 },
    .{ .name = "INC3", .c = 51, .f = 0 }, .{ .name = "INC4", .c = 52, .f = 0 },
    .{ .name = "INC5", .c = 53, .f = 0 }, .{ .name = "INC6", .c = 54, .f = 0 },
    .{ .name = "INCA", .c = 48, .f = 0 }, .{ .name = "INCX", .c = 55, .f = 0 },
    .{ .name = "IOC",  .c = 35, .f = 0 },
    .{ .name = "J1N",  .c = 41, .f = 0 }, .{ .name = "J1NN", .c = 41, .f = 3 },
    .{ .name = "J1NP", .c = 41, .f = 5 }, .{ .name = "J1NZ", .c = 41, .f = 4 },
    .{ .name = "J1P",  .c = 41, .f = 2 }, .{ .name = "J1Z",  .c = 41, .f = 1 },
    .{ .name = "J2N",  .c = 42, .f = 0 }, .{ .name = "J2NN", .c = 42, .f = 3 },
    .{ .name = "J2NP", .c = 42, .f = 5 }, .{ .name = "J2NZ", .c = 42, .f = 4 },
    .{ .name = "J2P",  .c = 42, .f = 2 }, .{ .name = "J2Z",  .c = 42, .f = 1 },
    .{ .name = "J3N",  .c = 43, .f = 0 }, .{ .name = "J3NN", .c = 43, .f = 3 },
    .{ .name = "J3NP", .c = 43, .f = 5 }, .{ .name = "J3NZ", .c = 43, .f = 4 },
    .{ .name = "J3P",  .c = 43, .f = 2 }, .{ .name = "J3Z",  .c = 43, .f = 1 },
    .{ .name = "J4N",  .c = 44, .f = 0 }, .{ .name = "J4NN", .c = 44, .f = 3 },
    .{ .name = "J4NP", .c = 44, .f = 5 }, .{ .name = "J4NZ", .c = 44, .f = 4 },
    .{ .name = "J4P",  .c = 44, .f = 2 }, .{ .name = "J4Z",  .c = 44, .f = 1 },
    .{ .name = "J5N",  .c = 45, .f = 0 }, .{ .name = "J5NN", .c = 45, .f = 3 },
    .{ .name = "J5NP", .c = 45, .f = 5 }, .{ .name = "J5NZ", .c = 45, .f = 4 },
    .{ .name = "J5P",  .c = 45, .f = 2 }, .{ .name = "J5Z",  .c = 45, .f = 1 },
    .{ .name = "J6N",  .c = 46, .f = 0 }, .{ .name = "J6NN", .c = 46, .f = 3 },
    .{ .name = "J6NP", .c = 46, .f = 5 }, .{ .name = "J6NZ", .c = 46, .f = 4 },
    .{ .name = "J6P",  .c = 46, .f = 2 }, .{ .name = "J6Z",  .c = 46, .f = 1 },
    .{ .name = "JAN",  .c = 40, .f = 0 }, .{ .name = "JANN", .c = 40, .f = 3 },
    .{ .name = "JANP", .c = 40, .f = 5 }, .{ .name = "JANZ", .c = 40, .f = 4 },
    .{ .name = "JAP",  .c = 40, .f = 2 }, .{ .name = "JAZ",  .c = 40, .f = 1 },
    .{ .name = "JBUS", .c = 34, .f = 0 },
    .{ .name = "JE",   .c = 39, .f = 5 }, .{ .name = "JG",   .c = 39, .f = 6 },
    .{ .name = "JGE",  .c = 39, .f = 7 }, .{ .name = "JL",   .c = 39, .f = 4 },
    .{ .name = "JLE",  .c = 39, .f = 9 }, .{ .name = "JMP",  .c = 39, .f = 0 },
    .{ .name = "JNE",  .c = 39, .f = 8 }, .{ .name = "JNOV", .c = 39, .f = 3 },
    .{ .name = "JOV",  .c = 39, .f = 2 }, .{ .name = "JRED", .c = 38, .f = 0 },
    .{ .name = "JSJ",  .c = 39, .f = 1 },
    .{ .name = "JXN",  .c = 47, .f = 0 }, .{ .name = "JXNN", .c = 47, .f = 3 },
    .{ .name = "JXNP", .c = 47, .f = 5 }, .{ .name = "JXNZ", .c = 47, .f = 4 },
    .{ .name = "JXP",  .c = 47, .f = 2 }, .{ .name = "JXZ",  .c = 47, .f = 1 },
    .{ .name = "LD1",  .c = 9,  .f = 5 }, .{ .name = "LD1N", .c = 17, .f = 5 },
    .{ .name = "LD2",  .c = 10, .f = 5 }, .{ .name = "LD2N", .c = 18, .f = 5 },
    .{ .name = "LD3",  .c = 11, .f = 5 }, .{ .name = "LD3N", .c = 19, .f = 5 },
    .{ .name = "LD4",  .c = 12, .f = 5 }, .{ .name = "LD4N", .c = 20, .f = 5 },
    .{ .name = "LD5",  .c = 13, .f = 5 }, .{ .name = "LD5N", .c = 21, .f = 5 },
    .{ .name = "LD6",  .c = 14, .f = 5 }, .{ .name = "LD6N", .c = 22, .f = 5 },
    .{ .name = "LDA",  .c = 8,  .f = 5 }, .{ .name = "LDAN", .c = 16, .f = 5 },
    .{ .name = "LDX",  .c = 15, .f = 5 }, .{ .name = "LDXN", .c = 23, .f = 5 },
    .{ .name = "MOVE", .c = 7,  .f = 1 }, .{ .name = "MUL",  .c = 3,  .f = 5 },
    .{ .name = "NOP",  .c = 0,  .f = 0 }, .{ .name = "NUM",  .c = 5,  .f = 0 },
    .{ .name = "OUT",  .c = 37, .f = 0 },
    .{ .name = "SLA",  .c = 6,  .f = 0 }, .{ .name = "SLAX", .c = 6,  .f = 2 },
    .{ .name = "SLC",  .c = 6,  .f = 4 },
    .{ .name = "SRA",  .c = 6,  .f = 1 }, .{ .name = "SRAX", .c = 6,  .f = 3 },
    .{ .name = "SRC",  .c = 6,  .f = 5 },
    .{ .name = "ST1",  .c = 25, .f = 5 }, .{ .name = "ST2",  .c = 26, .f = 5 },
    .{ .name = "ST3",  .c = 27, .f = 5 }, .{ .name = "ST4",  .c = 28, .f = 5 },
    .{ .name = "ST5",  .c = 29, .f = 5 }, .{ .name = "ST6",  .c = 30, .f = 5 },
    .{ .name = "STA",  .c = 24, .f = 5 }, .{ .name = "STJ",  .c = 32, .f = 2 },
    .{ .name = "STX",  .c = 31, .f = 5 }, .{ .name = "STZ",  .c = 33, .f = 5 },
    .{ .name = "SUB",  .c = 2,  .f = 5 },
};

fn lookupOp(name: []const u8) ?Op {
    var lo: usize = 0;
    var hi: usize = OPS.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, name, OPS[mid].name)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => return OPS[mid],
        }
    }
    return null;
}

// MIX character table (MDK convention): index = MIX byte value
const MIX_CHARS = " ABCDEFGHI~JKLMNOPQR`^STUVWXYZ0123456789.,()+-*/=$<>@;:'";

fn charToMix(ch: u8) u8 {
    const u = std.ascii.toUpper(ch);
    for (MIX_CHARS, 0..) |c, i| {
        if (u == c) return @intCast(i);
    }
    return 0;
}

// ── Parsed line ───────────────────────────────────────────────────────────────

const Line = struct {
    num:     u32,
    label:   []const u8,
    opcode:  []const u8,
    operand: []const u8,
};

fn parseLine(raw: []const u8, num: u32) Line {
    const s = std.mem.trimRight(u8, raw, " \t\r\n");
    if (s.len == 0 or s[0] == '*') return .{ .num = num, .label = "", .opcode = "", .operand = "" };

    var pos: usize = 0;
    var label: []const u8 = "";

    if (s[0] != ' ' and s[0] != '\t') {
        while (pos < s.len and s[pos] != ' ' and s[pos] != '\t') pos += 1;
        label = s[0..pos];
    }
    while (pos < s.len and (s[pos] == ' ' or s[pos] == '\t')) pos += 1;
    if (pos >= s.len or s[pos] == '*') return .{ .num = num, .label = label, .opcode = "", .operand = "" };

    const opc_start = pos;
    while (pos < s.len and s[pos] != ' ' and s[pos] != '\t') pos += 1;
    const opcode = s[opc_start..pos];

    while (pos < s.len and (s[pos] == ' ' or s[pos] == '\t')) pos += 1;
    if (pos >= s.len or s[pos] == '*') return .{ .num = num, .label = label, .opcode = opcode, .operand = "" };

    const opnd_start = pos;
    while (pos < s.len and s[pos] != ' ' and s[pos] != '\t') pos += 1;

    return .{ .num = num, .label = label, .opcode = opcode, .operand = s[opnd_start..pos] };
}

// ── Assembler state ───────────────────────────────────────────────────────────

const Assembler = struct {
    gpa:        Allocator,
    err_writer: std.io.AnyWriter,
    symbols:    std.StringHashMap(i32),
    words:      ArrayList(WordEntry),
    // Literal constants: =expr=  key → allocated string, value → assigned address
    lit_keys:   ArrayList([]u8),   // owns the strings
    lit_addrs:  ArrayList(u32),    // parallel: address assigned in pass 1
    had_error:  bool,

    fn init(gpa: Allocator, ew: std.io.AnyWriter) Assembler {
        return .{
            .gpa        = gpa,
            .err_writer = ew,
            .symbols    = std.StringHashMap(i32).init(gpa),
            .words      = .{},
            .lit_keys   = .{},
            .lit_addrs  = .{},
            .had_error  = false,
        };
    }

    fn deinit(self: *Assembler) void {
        var it = self.symbols.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.symbols.deinit();
        for (self.lit_keys.items) |k| self.gpa.free(k);
        self.lit_keys.deinit(self.gpa);
        self.lit_addrs.deinit(self.gpa);
        self.words.deinit(self.gpa); // no-op after toOwnedSlice
    }

    fn emitErr(self: *Assembler, line_num: u32, msg: []const u8) void {
        self.err_writer.print("line {d}: {s}\n", .{ line_num, msg }) catch {};
        self.had_error = true;
    }

    fn emitErrf(self: *Assembler, line_num: u32, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "error (message too long)";
        self.emitErr(line_num, msg);
    }

    // ── Expression evaluator ──────────────────────────────────────────────────

    fn evalExpr(self: *Assembler, raw_expr: []const u8, loc: u32, line_num: u32) ?i32 {
        const expr = std.mem.trim(u8, raw_expr, " \t");
        if (expr.len == 0) return 0;

        var acc: i32     = 0;
        var op:  u8      = '+';
        var prev_val     = false;
        var i:   usize   = 0;

        while (i < expr.len) {
            const ch = expr[i];
            if (ch == ' ' or ch == '\t') { i += 1; continue; }

            if (ch >= '0' and ch <= '9') {
                var n: i32 = 0;
                while (i < expr.len and expr[i] >= '0' and expr[i] <= '9') {
                    n = n * 10 + @as(i32, expr[i] - '0');
                    i += 1;
                }
                acc = applyOp(acc, op, n);
                op = '+'; prev_val = true;

            } else if (std.ascii.isAlphabetic(ch)) {
                var buf: [64]u8 = undefined;
                var len: usize = 0;
                while (i < expr.len and std.ascii.isAlphanumeric(expr[i])) {
                    if (len >= buf.len) {
                        self.emitErr(line_num, "symbol name too long");
                        return null;
                    }
                    buf[len] = std.ascii.toUpper(expr[i]);
                    len += 1;
                    i += 1;
                }
                const sym = buf[0..len];
                const val = self.symbols.get(sym) orelse {
                    self.emitErrf(line_num, "undefined symbol '{s}'", .{sym});
                    return null;
                };
                acc = applyOp(acc, op, val);
                op = '+'; prev_val = true;

            } else if (ch == '*') {
                if (prev_val) {
                    op = '*'; prev_val = false;
                } else {
                    acc = applyOp(acc, op, @intCast(loc));
                    op = '+'; prev_val = true;
                }
                i += 1;

            } else if (ch == '+') { op = '+'; prev_val = false; i += 1;
            } else if (ch == '-') { op = '-'; prev_val = false; i += 1;
            } else if (ch == '/') {
                if (i + 1 < expr.len and expr[i + 1] == '/') { op = 'f'; i += 2; }
                else { op = '/'; i += 1; }
                prev_val = false;
            } else if (ch == ':') { op = ':'; prev_val = false; i += 1;
            } else { i += 1; }
        }
        return acc;
    }

    fn applyOp(a: i32, op: u8, b: i32) i32 {
        return switch (op) {
            '+' => a + b,
            '-' => a - b,
            '*' => a *% b,
            '/', 'f' => if (b != 0) @divTrunc(a, b) else 0,
            ':' => a * 8 + b,
            else => b,
        };
    }

    // ── Literal constant helpers ──────────────────────────────────────────────

    fn litIndex(self: *Assembler, expr: []const u8) !usize {
        for (self.lit_keys.items, 0..) |k, idx| {
            if (std.mem.eql(u8, k, expr)) return idx;
        }
        const owned = try self.gpa.dupe(u8, expr);
        try self.lit_keys.append(self.gpa, owned);
        try self.lit_addrs.append(self.gpa, 0); // assigned later
        return self.lit_keys.items.len - 1;
    }

    fn litAddr(self: *const Assembler, expr: []const u8) ?u32 {
        for (self.lit_keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, expr)) return self.lit_addrs.items[i];
        }
        return null;
    }

    // ── Operand parser ────────────────────────────────────────────────────────

    const Opnd = struct {
        addr:  i32,
        index: u8,
        field: ?u8,   // null → use opcode default
    };

    fn parseOpnd(self: *Assembler, raw: []const u8, loc: u32, line_num: u32) ?Opnd {
        var s = raw;
        var addr_override: ?i32 = null;

        // Literal constant  =expr=
        if (s.len > 0 and s[0] == '=') {
            const close = std.mem.indexOfScalarPos(u8, s, 1, '=') orelse {
                self.emitErr(line_num, "unclosed literal '='");
                return null;
            };
            const lit_expr = s[1..close];
            const idx = self.litAddr(lit_expr) orelse {
                self.emitErr(line_num, "literal not found (pass 1 bug)");
                return null;
            };
            addr_override = @intCast(idx);
            s = s[close + 1..];
        }

        // Field spec  (L:R)  — suffix
        var field: ?u8 = null;
        if (std.mem.lastIndexOfScalar(u8, s, '(')) |fp| {
            if (s[s.len - 1] == ')') {
                const fspec = s[fp + 1 .. s.len - 1];
                if (std.mem.indexOfScalar(u8, fspec, ':')) |ci| {
                    const L = std.fmt.parseInt(u8, fspec[0..ci], 10) catch 255;
                    const R = std.fmt.parseInt(u8, fspec[ci + 1..], 10) catch 255;
                    if (L <= 5 and R <= 5) field = L * 8 + R;
                }
                s = s[0..fp];
            }
        }

        // Index  ,n  — suffix
        var index: u8 = 0;
        if (std.mem.lastIndexOfScalar(u8, s, ',')) |ci| {
            index = std.fmt.parseInt(u8, s[ci + 1..], 10) catch 0;
            s = s[0..ci];
        }

        // Address expression (or literal address already resolved)
        const a = addr_override orelse
            if (s.len == 0) @as(i32, 0)
            else (self.evalExpr(s, loc, line_num) orelse return null);

        return .{ .addr = a, .index = index, .field = field };
    }

    // ── Instruction encoder ───────────────────────────────────────────────────

    fn encodeInstr(signed_addr: i32, index: u8, field: u8, c: u8) i32 {
        const aa: u32 = @intCast(@abs(signed_addr) & 0xFFF);
        const a1: i32 = @intCast((aa >> 6) & 0x3F);
        const a2: i32 = @intCast(aa & 0x3F);
        const mag: i32 = a1 * 16777216 + a2 * 262144 +
                         @as(i32, index) * 4096 +
                         @as(i32, field) * 64 +
                         @as(i32, c);
        return if (signed_addr < 0) -mag else mag;
    }

    // ── Uppercase helper ──────────────────────────────────────────────────────

    fn toUpper(out: []u8, in: []const u8) []u8 {
        for (in, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
        return out[0..in.len];
    }

    // ── Symbol registration ───────────────────────────────────────────────────

    fn defineSymbol(self: *Assembler, raw_name: []const u8, value: i32, line_num: u32) !void {
        var buf: [64]u8 = undefined;
        if (raw_name.len > buf.len) {
            self.emitErr(line_num, "label too long");
            return;
        }
        const name = toUpper(buf[0..raw_name.len], raw_name);
        if (self.symbols.contains(name)) return; // first definition wins
        const owned = try self.gpa.dupe(u8, name);
        try self.symbols.put(owned, value);
    }

    // ── Pass 1: collect symbols + literal placeholders ────────────────────────

    fn pass1(self: *Assembler, lines: []const Line) !u32 {
        var loc: u32 = 0;
        var start_addr: u32 = 0;
        var buf: [64]u8 = undefined;

        for (lines) |line| {
            if (line.opcode.len == 0) continue;
            const op = if (line.opcode.len <= 64)
                toUpper(buf[0..line.opcode.len], line.opcode)
            else {
                self.emitErr(line.num, "opcode too long");
                continue;
            };

            if (std.mem.eql(u8, op, "EQU")) {
                if (line.label.len > 0) {
                    const v = self.evalExpr(line.operand, loc, line.num) orelse 0;
                    try self.defineSymbol(line.label, v, line.num);
                }
            } else if (std.mem.eql(u8, op, "ORIG")) {
                const v = self.evalExpr(line.operand, loc, line.num) orelse 0;
                if (v < 0 or v >= 4000) {
                    self.emitErrf(line.num, "ORIG address {d} out of range", .{v});
                } else {
                    loc = @intCast(v);
                }
            } else if (std.mem.eql(u8, op, "END")) {
                // Assign literal addresses starting at current loc
                for (self.lit_addrs.items) |*a| {
                    a.* = loc;
                    loc += 1;
                }
                start_addr = @intCast(self.evalExpr(line.operand, loc, line.num) orelse 0);
                break;
            } else if (std.mem.eql(u8, op, "CON") or std.mem.eql(u8, op, "ALF") or
                       lookupOp(op) != null)
            {
                if (line.label.len > 0) {
                    try self.defineSymbol(line.label, @intCast(loc), line.num);
                }
                // Collect literal constants from operand
                if (line.operand.len > 0 and line.operand[0] == '=') {
                    const close = std.mem.indexOfScalarPos(u8, line.operand, 1, '=') orelse 0;
                    if (close > 0) {
                        _ = try self.litIndex(line.operand[1..close]);
                    }
                }
                loc += 1;
            } else {
                self.emitErrf(line.num, "unknown opcode '{s}'", .{op});
            }
        }
        return start_addr;
    }

    // ── Pass 2: emit words ────────────────────────────────────────────────────

    fn pass2(self: *Assembler, lines: []const Line) !void {
        var loc: u32 = 0;
        var buf: [64]u8 = undefined;

        for (lines) |line| {
            if (line.opcode.len == 0) continue;
            const op = if (line.opcode.len <= 64)
                toUpper(buf[0..line.opcode.len], line.opcode)
            else continue;

            if (std.mem.eql(u8, op, "EQU")) {
                continue;
            } else if (std.mem.eql(u8, op, "ORIG")) {
                const v = self.evalExpr(line.operand, loc, line.num) orelse continue;
                if (v >= 0 and v < 4000) loc = @intCast(v);
                continue;
            } else if (std.mem.eql(u8, op, "END")) {
                break;
            } else if (std.mem.eql(u8, op, "CON")) {
                const v = self.evalExpr(line.operand, loc, line.num) orelse 0;
                try self.words.append(self.gpa,.{ .addr = loc, .value = v });
                loc += 1;
            } else if (std.mem.eql(u8, op, "ALF")) {
                var chars = line.operand;
                if (chars.len >= 2 and
                    ((chars[0] == '"' and chars[chars.len-1] == '"') or
                     (chars[0] == '\'' and chars[chars.len-1] == '\'')))
                    chars = chars[1 .. chars.len - 1];
                var b = [_]u8{0} ** 5;
                for (0..5) |k| b[k] = if (k < chars.len) charToMix(chars[k]) else 0;
                const mag: i32 = @as(i32, b[0]) * 16777216 + @as(i32, b[1]) * 262144 +
                                 @as(i32, b[2]) * 4096 + @as(i32, b[3]) * 64 + @as(i32, b[4]);
                try self.words.append(self.gpa,.{ .addr = loc, .value = mag });
                loc += 1;
            } else if (lookupOp(op)) |info| {
                const opnd = self.parseOpnd(line.operand, loc, line.num) orelse {
                    loc += 1;
                    continue;
                };
                const f = opnd.field orelse info.f;
                const w = encodeInstr(opnd.addr, opnd.index, f, info.c);
                try self.words.append(self.gpa,.{ .addr = loc, .value = w });
                loc += 1;
            }
        }

        // Emit literal constant words
        for (self.lit_keys.items, 0..) |expr, i| {
            const a = self.lit_addrs.items[i];
            const v = self.evalExpr(expr, a, 0) orelse 0;
            try self.words.append(self.gpa,.{ .addr = a, .value = v });
        }
    }

    // ── Orchestrator ──────────────────────────────────────────────────────────

    fn run(self: *Assembler, source: []const u8) (Allocator.Error || error{AssemblyFailed})!AssembleResult {
        // Parse all lines
        var lines: ArrayList(Line) = .{};
        defer lines.deinit(self.gpa);
        var it = std.mem.splitScalar(u8, source, '\n');
        var num: u32 = 1;
        while (it.next()) |raw| {
            try lines.append(self.gpa, parseLine(raw, num));
            num += 1;
        }

        const start_addr = try self.pass1(lines.items);
        if (!self.had_error) try self.pass2(lines.items);
        if (self.had_error) return error.AssemblyFailed;

        return .{
            .words      = try self.words.toOwnedSlice(self.gpa),
            .start_addr = start_addr,
            .allocator  = self.gpa,
        };
    }
};
