const MixMemory = @import("mix_memory.zig");
const Memory = MixMemory.Memory;
const MixWordLayout = MixMemory.MixWordLayout;

// Global VM state
var vm_memory: Memory = undefined; // Initialized in vm_init
var vm_state: i32 = 0; // Your previous variable

// Function to initialize the VM, called from JS on load
export fn vm_init() void {
    vm_memory = Memory{}; // Create the struct
    vm_memory.init();     // Initialize its data
    vm_state = 0; // Reset state
}

export fn vm_step() void {
    vm_state += 1; // Simple step logic
    // Here will be the logic to execute one instruction
    // and modify vm_memory
}

export fn vm_get_state() i32 {
    return vm_state;
}

export fn vm_reset() void {
    vm_memory.init(); // Reset memory
    vm_state = 0;
}

// Function to read a word from memory, called from JS
// Use u32 for address, as WASM does not support u12
export fn vm_read_word(address: u32) i32 {
    // Check bounds in JS or within the readWord function itself
    const word = vm_memory.readWord(address);
    // Return the value as i32.
    return word.getValueAsInt();
}

// Function to write a word to memory, called from JS
// Use u32 for address, as WASM does not support u12
export fn vm_write_word(address: u32, value: i32) void {
    // Check bounds in JS or within the writeWord function itself
    var word: MixWordLayout = .{ .bytes = [_]u8{0} ** 5, .sign = 0 };
    word.setValueFromInt(value) catch {
        @panic("Failed to set word value from int");
    };
    vm_memory.writeWord(address, word);
}

// Function to get a pointer to the start of the WASM memory region
// This is needed so JS can access the memory buffer directly
export fn vm_memory_ptr() [*]u8 {
    return vm_memory.getMemoryPtr();
}

// Export the memory size in bytes (for JS, if direct buffer access is needed)
export fn vm_memory_size_bytes() usize {
    return vm_memory.getMemorySizeInBytes();
}

// Empty function so the compiler doesn't remove other functions
export fn __keep_alive__() void {}

// --- Additional: Debugging functions ---

// Function to read a specific byte from a word
// Use u32 for address and byte_index, as WASM does not support u12, u3
export fn vm_read_byte(address: u32, byte_index: u32) u8 {
    // Check bounds in JS or within the readByte function itself
    const byte_val = vm_memory.readByte(address, byte_index);
    return byte_val; // MixByteValue (u8) returned as u8
}

// Function to write a specific byte to a word
// Use u32 for address and byte_index, as WASM does not support u12, u3
export fn vm_write_byte(address: u32, byte_index: u32, byte_val: u8) void {
    // Check that byte_val fits into 6 bits
    if (byte_val > 63) {
        @panic("Value too large for MixByte (must be 0-63)");
    }
    // Check bounds in JS or within the writeByte function itself
    vm_memory.writeByte(address, byte_index, byte_val);
}
