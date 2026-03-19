const MixCpu        = @import("mix_cpu.zig");
const MixVm         = @import("mix_vm.zig");
const Vm            = MixVm.Vm;
const MixWordLayout = MixVm.MixWordLayout;
const MEMORY_SIZE   = MixVm.MEMORY_SIZE;

const BYTES_PER_WORD = 6;

var vm: Vm = undefined;

// ── Lifecycle ──────────────────────────────────────────────────────────────

export fn vm_init()  void { vm.init(); }
export fn vm_reset() void { vm.init(); }

export fn vm_step() void {
    MixCpu.step(&vm);
}

// ── VM state: read ─────────────────────────────────────────────────────────

export fn vm_get_pc()       u32 { return vm.pc; }
export fn vm_get_cycle()    u32 { return vm.cycle; }
export fn vm_get_halted()   u32 { return if (vm.halted)   1 else 0; }
export fn vm_get_overflow() u32 { return if (vm.overflow) 1 else 0; }
export fn vm_get_cmp()      u32 { return @intFromEnum(vm.cmp); }

// ── VM state: write (used by step-back restore) ────────────────────────────

export fn vm_set_pc(val: u32)       void { vm.pc    = @min(val, MEMORY_SIZE - 1); }
export fn vm_set_cycle(val: u32)    void { vm.cycle = val; }
export fn vm_set_halted(val: u32)   void { vm.halted   = val != 0; }
export fn vm_set_overflow(val: u32) void { vm.overflow = val != 0; }
export fn vm_set_cmp(val: u32)      void { vm.cmp = @enumFromInt(@min(val, 2)); }

// ── Registers: read ────────────────────────────────────────────────────────

export fn vm_get_reg_a() i32 { return vm.rA.getValueAsInt(); }
export fn vm_get_reg_x() i32 { return vm.rX.getValueAsInt(); }
export fn vm_get_reg_j() u32 { return vm.rJ; }

/// idx: 1–6
export fn vm_get_reg_i(idx: u32) i32 {
    if (idx < 1 or idx > 6) return 0;
    return vm.rI[idx - 1].toInt();
}

// ── Registers: write ───────────────────────────────────────────────────────

export fn vm_set_reg_a(val: i32) void { vm.rA.setValueFromInt(val); }
export fn vm_set_reg_x(val: i32) void { vm.rX.setValueFromInt(val); }
export fn vm_set_reg_j(val: u32) void { vm.rJ = @min(val, MEMORY_SIZE - 1); }

/// idx: 1–6
export fn vm_set_reg_i(idx: u32, val: i32) void {
    if (idx < 1 or idx > 6) return;
    vm.rI[idx - 1].fromInt(val);
}

// ── Memory ─────────────────────────────────────────────────────────────────

export fn vm_get_memory_required_size() u32 { return MEMORY_SIZE * BYTES_PER_WORD; }
export fn vm_get_memory_ptr()        [*]u8 { return vm.memory.getMemoryPtr(); }

export fn vm_read_word(address: u32) i32 {
    return vm.memory.readWord(address).getValueAsInt();
}

export fn vm_write_word(address: u32, value: i32) void {
    var word: MixWordLayout = .{ .bytes = .{ 0, 0, 0, 0, 0 }, .sign = 0 };
    word.setValueFromInt(value);
    vm.memory.writeWord(address, word);
}

export fn vm_read_byte(address: u32, byte_index: u32) u8 {
    return vm.memory.readByte(address, byte_index);
}

export fn vm_write_byte(address: u32, byte_index: u32, byte_val: u8) void {
    if (byte_val > 63) @panic("MixByte must be 0–63");
    vm.memory.writeByte(address, byte_index, byte_val);
}

// ── Pending I/O (set during step; host reads then clears) ──────────────────

export fn vm_get_io_kind()   u32 { return vm.io_kind; }
export fn vm_get_io_device() u32 { return vm.io_device; }
export fn vm_get_io_addr()   u32 { return vm.io_addr; }
export fn vm_get_io_m()      i32 { return vm.io_m; }
export fn vm_clear_io()     void { vm.io_kind = 0; }

export fn __keep_alive__() void {}
