const mem = @import("mix_memory.zig");

pub const Memory        = mem.Memory;
pub const MixWordLayout = mem.MixWordLayout;
pub const MixByteValue  = mem.MixByteValue;
pub const MixSignValue  = mem.MixSignValue;
pub const MEMORY_SIZE   = mem.MEMORY_SIZE;

pub const CompareFlag = enum(u8) {
    less    = 0,
    equal   = 1,
    greater = 2,
};

/// MIX index register: 2 bytes + sign, range −4095..+4095
pub const MixIndexReg = struct {
    bytes: [2]MixByteValue,
    sign:  MixSignValue,

    pub fn toInt(self: MixIndexReg) i32 {
        const mag: i32 = @as(i32, self.bytes[0]) * 64 + @as(i32, self.bytes[1]);
        return if (self.sign != 0) -mag else mag;
    }

    pub fn fromInt(self: *MixIndexReg, val: i32) void {
        const abs: u32 = @intCast(@abs(val));
        self.sign     = if (val < 0) 1 else 0;
        self.bytes[0] = @truncate(abs >> 6);
        self.bytes[1] = @truncate(abs & 0x3F);
    }
};

/// Full MIX machine state
pub const Vm = struct {
    memory:   Memory,
    rA:       MixWordLayout,  // accumulator
    rX:       MixWordLayout,  // extension
    rI:       [6]MixIndexReg, // index registers I1..I6
    rJ:       u32,            // jump address, always positive (0..3999)
    pc:       u32,            // program counter (0..3999)
    cycle:    u32,            // executed instruction count
    overflow: bool,
    cmp:      CompareFlag,    // result of last comparison
    halted:   bool,

    // Elapsed time in Knuth's "time units" (u), per TAOCP §1.3.1.
    time_units: u32,

    // Pending I/O: set by mix_cpu.step(), cleared by host after handling.
    // io_kind: 0=none, 1=OUT, 2=IN, 3=IOC
    io_kind:   u8,
    io_device: u8,
    io_addr:   u32,
    io_m:      i32,

    pub fn init(self: *Vm) void {
        self.memory.init();
        self.rA       = .{ .bytes = .{ 0, 0, 0, 0, 0 }, .sign = 0 };
        self.rX       = .{ .bytes = .{ 0, 0, 0, 0, 0 }, .sign = 0 };
        for (&self.rI) |*r| r.* = .{ .bytes = .{ 0, 0 }, .sign = 0 };
        self.rJ       = 0;
        self.pc       = 0;
        self.cycle    = 0;
        self.overflow = false;
        self.cmp      = .equal;
        self.halted   = false;
        self.time_units = 0;
        self.io_kind   = 0;
        self.io_device = 0;
        self.io_addr   = 0;
        self.io_m      = 0;
    }
};
