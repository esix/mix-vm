const vm_mod = @import("mix_vm.zig");
const Vm          = vm_mod.Vm;
const MixWordLayout = vm_mod.MixWordLayout;
const MixIndexReg   = vm_mod.MixIndexReg;
const CompareFlag   = vm_mod.CompareFlag;
const MEMORY_SIZE   = vm_mod.MEMORY_SIZE;

/// Maximum magnitude of a MIX word: 63*64^4 + ... + 63 = 2^30 - 1
const MAX_WORD: i32 = (1 << 30) - 1; // 1 073 741 823

// ── Field helpers ─────────────────────────────────────────────────────────

/// Read field (L:R) from a word, right-justified into result.
/// If L > 0, result sign is always +.
fn readField(word: MixWordLayout, F: u8) MixWordLayout {
    const L: u8 = F / 8;
    const R: u8 = F % 8;
    var result = MixWordLayout{ .bytes = .{ 0, 0, 0, 0, 0 }, .sign = 0 };
    if (L > R) return result;

    // Copy positions R, R-1, ... L  →  dest positions 5, 4, ...
    var k: u8 = 0;
    while (k <= R - L) : (k += 1) {
        const src: u8 = R - k;
        const dst: u8 = 5 - k;
        if (src == 0) {
            result.sign = word.sign;
        } else {
            result.bytes[dst - 1] = word.bytes[src - 1];
        }
    }
    if (L > 0) result.sign = 0;
    return result;
}

/// Write the rightmost (R-L+1) positions of src into positions L..R of dest.
/// Positions outside L..R in dest are unchanged.
fn writeField(dest: *MixWordLayout, src: MixWordLayout, F: u8) void {
    const L: u8 = F / 8;
    const R: u8 = F % 8;
    if (L > R) return;

    var k: u8 = 0;
    while (k <= R - L) : (k += 1) {
        const dst_pos: u8 = R - k;
        const src_pos: u8 = 5 - k;
        if (dst_pos == 0) {
            dest.sign = src.sign;
        } else {
            dest.bytes[dst_pos - 1] = if (src_pos == 0) src.sign else src.bytes[src_pos - 1];
        }
    }
}

/// Clamp M to a valid memory address.
inline fn addr(M: i32) u32 {
    if (M < 0 or M >= MEMORY_SIZE) return 0; // undefined behaviour in MIX; clamp
    return @intCast(M);
}

/// Expand an index register to a full word (zeros in high bytes) for comparison.
fn indexToWord(r: MixIndexReg) MixWordLayout {
    return .{ .bytes = .{ 0, 0, 0, r.bytes[0], r.bytes[1] }, .sign = r.sign };
}

// ── Arithmetic helpers ────────────────────────────────────────────────────

fn storeArith(vm: *Vm, reg: *MixWordLayout, result: i32) void {
    if (result == 0) {
        reg.bytes = .{ 0, 0, 0, 0, 0 };
        // sign unchanged per Knuth: "if result is zero the sign of rA is unchanged"
    } else if (result > MAX_WORD or result < -MAX_WORD) {
        vm.overflow = true;
        const mag: i32 = @intCast(@as(u32, @intCast(@abs(result))) & @as(u32, MAX_WORD));
        reg.setValueFromInt(if (result < 0) -mag else mag);
    } else {
        reg.setValueFromInt(result);
    }
}

// ── Opcode implementations ────────────────────────────────────────────────

fn opADD(vm: *Vm, M: i32, F: u8) void {
    const v = readField(vm.memory.readWord(addr(M)), F).getValueAsInt();
    storeArith(vm, &vm.rA, vm.rA.getValueAsInt() + v);
}

fn opSUB(vm: *Vm, M: i32, F: u8) void {
    const v = readField(vm.memory.readWord(addr(M)), F).getValueAsInt();
    storeArith(vm, &vm.rA, vm.rA.getValueAsInt() - v);
}

fn opMUL(vm: *Vm, M: i32, F: u8) void {
    const v: i64 = readField(vm.memory.readWord(addr(M)), F).getValueAsInt();
    const product: i64 = @as(i64, vm.rA.getValueAsInt()) * v;
    const sign: u8 = if (product < 0) 1 else 0;
    var mag: u64 = @intCast(@abs(product));

    // Pack 60 bits into 10 MIX bytes (6 bits each)
    var bytes: [10]u8 = undefined;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        bytes[i] = @truncate(mag & 0x3F);
        mag >>= 6;
    }
    vm.rA = .{ .bytes = bytes[0..5].*, .sign = sign };
    vm.rX = .{ .bytes = bytes[5..10].*, .sign = sign };
}

fn opDIV(vm: *Vm, M: i32, F: u8) void {
    const divisor: i64 = readField(vm.memory.readWord(addr(M)), F).getValueAsInt();
    if (divisor == 0) { vm.overflow = true; return; }

    // Reconstruct rA:rX as a 60-bit signed value
    var mag: i64 = 0;
    for (vm.rA.bytes) |b| mag = mag * 64 + b;
    for (vm.rX.bytes) |b| mag = mag * 64 + b;
    const dividend: i64 = if (vm.rA.sign != 0) -mag else mag;

    if (@abs(@divTrunc(dividend, divisor)) > MAX_WORD) {
        vm.overflow = true;
        return;
    }

    const orig_sign = vm.rA.sign;
    const q: i32 = @intCast(@divTrunc(dividend, divisor));
    const r: i32 = @intCast(@abs(@rem(dividend, divisor)));

    vm.rA.setValueFromInt(q);
    vm.rX.setValueFromInt(r);
    vm.rX.sign = orig_sign; // remainder takes sign of dividend
}

fn opLDA(vm: *Vm, M: i32, F: u8) void { vm.rA = readField(vm.memory.readWord(addr(M)), F); }
fn opLDX(vm: *Vm, M: i32, F: u8) void { vm.rX = readField(vm.memory.readWord(addr(M)), F); }
fn opLDAN(vm: *Vm, M: i32, F: u8) void { opLDA(vm, M, F); vm.rA.sign ^= 1; }
fn opLDXN(vm: *Vm, M: i32, F: u8) void { opLDX(vm, M, F); vm.rX.sign ^= 1; }

fn opLDi(vm: *Vm, M: i32, F: u8, i: u8) void {
    const loaded = readField(vm.memory.readWord(addr(M)), F);
    vm.rI[i].sign     = loaded.sign;
    vm.rI[i].bytes[0] = loaded.bytes[3];
    vm.rI[i].bytes[1] = loaded.bytes[4];
}

fn opLDiN(vm: *Vm, M: i32, F: u8, i: u8) void {
    opLDi(vm, M, F, i);
    vm.rI[i].sign ^= 1;
}

fn opSTA(vm: *Vm, M: i32, F: u8) void {
    var w = vm.memory.readWord(addr(M));
    writeField(&w, vm.rA, F);
    vm.memory.writeWord(addr(M), w);
}

fn opSTX(vm: *Vm, M: i32, F: u8) void {
    var w = vm.memory.readWord(addr(M));
    writeField(&w, vm.rX, F);
    vm.memory.writeWord(addr(M), w);
}

fn opSTi(vm: *Vm, M: i32, F: u8, i: u8) void {
    var w = vm.memory.readWord(addr(M));
    const full = indexToWord(vm.rI[i]);
    writeField(&w, full, F);
    vm.memory.writeWord(addr(M), w);
}

fn opSTJ(vm: *Vm, M: i32, F: u8) void {
    var w = vm.memory.readWord(addr(M));
    const j_word = MixWordLayout{
        .bytes = .{ 0, 0, 0, @truncate(vm.rJ >> 6), @truncate(vm.rJ & 0x3F) },
        .sign  = 0,
    };
    writeField(&w, j_word, F);
    vm.memory.writeWord(addr(M), w);
}

fn opSTZ(vm: *Vm, M: i32, F: u8) void {
    var w = vm.memory.readWord(addr(M));
    writeField(&w, .{ .bytes = .{ 0, 0, 0, 0, 0 }, .sign = 0 }, F);
    vm.memory.writeWord(addr(M), w);
}

/// F=0 INC, F=1 DEC, F=2 ENT, F=3 ENN  — for rA
fn opREGA(vm: *Vm, M: i32, F: u8) void {
    switch (F) {
        0 => storeArith(vm, &vm.rA, vm.rA.getValueAsInt() + M),
        1 => storeArith(vm, &vm.rA, vm.rA.getValueAsInt() - M),
        2 => vm.rA.setValueFromInt(M),
        3 => vm.rA.setValueFromInt(-M),
        else => {},
    }
}

/// F=0 INC, F=1 DEC, F=2 ENT, F=3 ENN  — for rX
fn opREGX(vm: *Vm, M: i32, F: u8) void {
    switch (F) {
        0 => storeArith(vm, &vm.rX, vm.rX.getValueAsInt() + M),
        1 => storeArith(vm, &vm.rX, vm.rX.getValueAsInt() - M),
        2 => vm.rX.setValueFromInt(M),
        3 => vm.rX.setValueFromInt(-M),
        else => {},
    }
}

/// F=0 INC, F=1 DEC, F=2 ENT, F=3 ENN  — for rI[i]
fn opREGi(vm: *Vm, M: i32, F: u8, i: u8) void {
    const MAX_IDX: i32 = 64 * 64 - 1; // 4095
    const cur = vm.rI[i].toInt();
    const result: i32 = switch (F) {
        0 => cur + M,
        1 => cur - M,
        2 => M,
        3 => -M,
        else => return,
    };
    if (result > MAX_IDX or result < -MAX_IDX) vm.overflow = true;
    vm.rI[i].fromInt(@min(@max(result, -MAX_IDX), MAX_IDX));
}

fn opJMP(vm: *Vm, M: i32, F: u8) void {
    const target = addr(M);
    switch (F) {
        0 => { vm.rJ = vm.pc; vm.pc = target; },                          // JMP
        1 => { vm.pc = target; },                                           // JSJ (don't save rJ)
        2 => { if (vm.overflow)  { vm.overflow = false; vm.rJ = vm.pc; vm.pc = target; } else { vm.overflow = false; } }, // JOV
        3 => { if (!vm.overflow) { vm.rJ = vm.pc; vm.pc = target; } else { vm.overflow = false; } },                     // JNOV
        4 => { if (vm.cmp == .less)    { vm.rJ = vm.pc; vm.pc = target; } }, // JL
        5 => { if (vm.cmp == .equal)   { vm.rJ = vm.pc; vm.pc = target; } }, // JE
        6 => { if (vm.cmp == .greater) { vm.rJ = vm.pc; vm.pc = target; } }, // JG
        7 => { if (vm.cmp != .less)    { vm.rJ = vm.pc; vm.pc = target; } }, // JGE
        8 => { if (vm.cmp != .equal)   { vm.rJ = vm.pc; vm.pc = target; } }, // JNE
        9 => { if (vm.cmp != .greater) { vm.rJ = vm.pc; vm.pc = target; } }, // JLE
        else => {},
    }
}

fn jumpIf(vm: *Vm, target: u32, cond: bool) void {
    if (cond) { vm.rJ = vm.pc; vm.pc = target; }
}

fn opJA(vm: *Vm, M: i32, F: u8) void {
    const v = vm.rA.getValueAsInt();
    const t = addr(M);
    switch (F) {
        0 => jumpIf(vm, t, v < 0),
        1 => jumpIf(vm, t, v == 0),
        2 => jumpIf(vm, t, v > 0),
        3 => jumpIf(vm, t, v >= 0),
        4 => jumpIf(vm, t, v != 0),
        5 => jumpIf(vm, t, v <= 0),
        else => {},
    }
}

fn opJX(vm: *Vm, M: i32, F: u8) void {
    const v = vm.rX.getValueAsInt();
    const t = addr(M);
    switch (F) {
        0 => jumpIf(vm, t, v < 0),
        1 => jumpIf(vm, t, v == 0),
        2 => jumpIf(vm, t, v > 0),
        3 => jumpIf(vm, t, v >= 0),
        4 => jumpIf(vm, t, v != 0),
        5 => jumpIf(vm, t, v <= 0),
        else => {},
    }
}

fn opJi(vm: *Vm, M: i32, F: u8, i: u8) void {
    const v = vm.rI[i].toInt();
    const t = addr(M);
    switch (F) {
        0 => jumpIf(vm, t, v < 0),
        1 => jumpIf(vm, t, v == 0),
        2 => jumpIf(vm, t, v > 0),
        3 => jumpIf(vm, t, v >= 0),
        4 => jumpIf(vm, t, v != 0),
        5 => jumpIf(vm, t, v <= 0),
        else => {},
    }
}

fn opCMP(vm: *Vm, reg: MixWordLayout, M: i32, F: u8) void {
    const rv = readField(reg, F).getValueAsInt();
    const mv = readField(vm.memory.readWord(addr(M)), F).getValueAsInt();
    vm.cmp = if (rv < mv) .less else if (rv > mv) .greater else .equal;
}

fn opSHIFT(vm: *Vm, M: i32, F: u8) void {
    const n: usize = @intCast(@min(@max(M, 0), 10));

    var buf: [10]u8 = undefined;
    for (0..5) |i| buf[i]     = vm.rA.bytes[i];
    for (0..5) |i| buf[i + 5] = vm.rX.bytes[i];

    var out: [10]u8 = .{0} ** 10;
    switch (F) {
        0 => { // SLA — rA only, shift left, fill right with 0
            const s = @min(n, 5);
            for (0..5) |i| out[i] = if (i + s < 5) buf[i + s] else 0;
            @memcpy(buf[0..5], out[0..5]);
        },
        1 => { // SRA — rA only, shift right, fill left with 0
            const s = @min(n, 5);
            for (0..5) |i| out[i] = if (i >= s) buf[i - s] else 0;
            @memcpy(buf[0..5], out[0..5]);
        },
        2 => { // SLAX — rA:rX left shift
            const s = @min(n, 10);
            for (0..10) |i| out[i] = if (i + s < 10) buf[i + s] else 0;
            @memcpy(&buf, &out);
        },
        3 => { // SRAX — rA:rX right shift
            const s = @min(n, 10);
            for (0..10) |i| out[i] = if (i >= s) buf[i - s] else 0;
            @memcpy(&buf, &out);
        },
        4 => { // SLC — rA:rX rotate left
            const s = n % 10;
            for (0..10) |i| out[i] = buf[(i + s) % 10];
            @memcpy(&buf, &out);
        },
        5 => { // SRC — rA:rX rotate right
            const s = n % 10;
            for (0..10) |i| out[i] = buf[(i + 10 - s) % 10];
            @memcpy(&buf, &out);
        },
        else => return,
    }
    @memcpy(&vm.rA.bytes, buf[0..5]);
    @memcpy(&vm.rX.bytes, buf[5..10]);
}

fn opMOVE(vm: *Vm, M: i32, F: u8) void {
    const src: u32 = addr(M);
    const dst: u32 = @intCast(@max(vm.rI[0].toInt(), 0));
    for (0..F) |k| {
        const s = (src + @as(u32, @intCast(k))) % MEMORY_SIZE;
        const d = (dst + @as(u32, @intCast(k))) % MEMORY_SIZE;
        vm.memory.writeWord(d, vm.memory.readWord(s));
    }
    vm.rI[0].fromInt(vm.rI[0].toInt() + @as(i32, F));
}

fn opNUM(vm: *Vm) void {
    var result: i64 = 0;
    for (vm.rA.bytes) |b| result = result * 10 + (b % 10);
    for (vm.rX.bytes) |b| result = result * 10 + (b % 10);
    const sign = vm.rA.sign;
    if (result > MAX_WORD) {
        vm.overflow = true;
        result = result & MAX_WORD;
    }
    vm.rA.setValueFromInt(if (sign != 0) -@as(i32, @intCast(result)) else @as(i32, @intCast(result)));
}

fn opCHAR(vm: *Vm) void {
    var n: u32 = @intCast(@abs(vm.rA.getValueAsInt()));
    for (0..5) |i| { vm.rX.bytes[4 - i] = @intCast(30 + n % 10); n /= 10; }
    for (0..5) |i| { vm.rA.bytes[4 - i] = @intCast(30 + n % 10); n /= 10; }
}

// ── Main step ─────────────────────────────────────────────────────────────

pub fn step(vm: *Vm) void {
    if (vm.halted) return;

    const instr = vm.memory.readWord(vm.pc);
    const C: u8 = instr.bytes[4];
    const F: u8 = instr.bytes[3];
    const I: u8 = instr.bytes[2];

    // Signed address field
    const AA: i32 = @as(i32, instr.bytes[0]) * 64 + @as(i32, instr.bytes[1]);
    var M: i32 = if (instr.sign != 0) -AA else AA;
    if (I >= 1 and I <= 6) M += vm.rI[I - 1].toInt();

    // Advance PC before execution; jumps will override it
    vm.pc = (vm.pc + 1) % MEMORY_SIZE;
    vm.cycle += 1;

    switch (C) {
        0  => {},                                       // NOP
        1  => opADD(vm, M, F),
        2  => opSUB(vm, M, F),
        3  => opMUL(vm, M, F),
        4  => opDIV(vm, M, F),
        5  => switch (F) {                              // SPEC
                  0 => opNUM(vm),
                  1 => opCHAR(vm),
                  2 => vm.halted = true,               // HLT
                  else => {},
              },
        6  => opSHIFT(vm, M, F),
        7  => opMOVE(vm, M, F),
        8  => opLDA(vm, M, F),
        9  => opLDi(vm, M, F, 0),
        10 => opLDi(vm, M, F, 1),
        11 => opLDi(vm, M, F, 2),
        12 => opLDi(vm, M, F, 3),
        13 => opLDi(vm, M, F, 4),
        14 => opLDi(vm, M, F, 5),
        15 => opLDX(vm, M, F),
        16 => opLDAN(vm, M, F),
        17 => opLDiN(vm, M, F, 0),
        18 => opLDiN(vm, M, F, 1),
        19 => opLDiN(vm, M, F, 2),
        20 => opLDiN(vm, M, F, 3),
        21 => opLDiN(vm, M, F, 4),
        22 => opLDiN(vm, M, F, 5),
        23 => opLDXN(vm, M, F),
        24 => opSTA(vm, M, F),
        25 => opSTi(vm, M, F, 0),
        26 => opSTi(vm, M, F, 1),
        27 => opSTi(vm, M, F, 2),
        28 => opSTi(vm, M, F, 3),
        29 => opSTi(vm, M, F, 4),
        30 => opSTi(vm, M, F, 5),
        31 => opSTX(vm, M, F),
        32 => opSTJ(vm, M, F),
        33 => opSTZ(vm, M, F),
        34, 35, 36, 37, 38 => {}, // I/O stubs: JBUS, IOC, IN, OUT, JRED
        39 => opJMP(vm, M, F),
        40 => opJA(vm, M, F),
        41 => opJi(vm, M, F, 0),
        42 => opJi(vm, M, F, 1),
        43 => opJi(vm, M, F, 2),
        44 => opJi(vm, M, F, 3),
        45 => opJi(vm, M, F, 4),
        46 => opJi(vm, M, F, 5),
        47 => opJX(vm, M, F),
        48 => opREGA(vm, M, F),
        49 => opREGi(vm, M, F, 0),
        50 => opREGi(vm, M, F, 1),
        51 => opREGi(vm, M, F, 2),
        52 => opREGi(vm, M, F, 3),
        53 => opREGi(vm, M, F, 4),
        54 => opREGi(vm, M, F, 5),
        55 => opREGX(vm, M, F),
        56 => opCMP(vm, vm.rA,              M, F),
        57 => opCMP(vm, indexToWord(vm.rI[0]), M, F),
        58 => opCMP(vm, indexToWord(vm.rI[1]), M, F),
        59 => opCMP(vm, indexToWord(vm.rI[2]), M, F),
        60 => opCMP(vm, indexToWord(vm.rI[3]), M, F),
        61 => opCMP(vm, indexToWord(vm.rI[4]), M, F),
        62 => opCMP(vm, indexToWord(vm.rI[5]), M, F),
        63 => opCMP(vm, vm.rX,              M, F),
        else => {}, // unknown opcode → NOP
    }
}
