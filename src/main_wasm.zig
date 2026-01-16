// src/main_wasm.zig
const MixMemory = @import("mix_memory.zig");
const Memory = MixMemory.Memory;
const MixWordLayout = MixMemory.MixWordLayout;
const MEMORY_SIZE = MixMemory.MEMORY_SIZE; // Import the constant

const BYTES_PER_WORD = 6;

var vm_memory: Memory = undefined;
var vm_state: i32 = 0;

// Function to initialize the VM, called from JS on load
export fn vm_init() void {
    vm_memory = Memory{}; // Create the structure
    vm_memory.init();     // Initialize its data
    vm_state = 0; // Reset the state
}

export fn vm_step() void {
    vm_state += 1; // Simple step logic
    // Here will be the logic to execute a single instruction
    // and modify the vm_memory
    // THEN THERE WILL BE LOGIC TO SAVE A SNAPSHOT
}

export fn vm_get_state() i32 {
    return vm_state;
}

export fn vm_reset() void {
    vm_memory.init(); // Reset the memory
    vm_state = 0;
}

// Function to read a word from memory from JS
// Use u32 for address, as WASM does not support u12
export fn vm_read_word(address: u32) i32 {
    // Check boundaries in JS or in the readWord function itself
    const word = vm_memory.readWord(address);
    // Return the value as i32.
    return word.getValueAsInt();
}

// Function to write a word to memory from JS
// Use u32 for address, as WASM does not support u12
export fn vm_write_word(address: u32, value: i32) void {
    // Check boundaries in JS or in the writeWord function itself
    var word: MixWordLayout = .{ .bytes = [_]u8{0} ** 5, .sign = 0 };
    word.setValueFromInt(value) catch {
        @panic("Failed to set word value from int");
    };
    vm_memory.writeWord(address, word);
}

// Export the size of the required memory (for JS, to know the buffer size)
export fn vm_get_memory_required_size() u32 {
    return MEMORY_SIZE * BYTES_PER_WORD;
}

// Export a function to get the current state of the VM memory
// buffer_ptr: pointer to the beginning of the Uint8Array buffer in WASM memory, provided from JS
// buffer_size: size of the buffer in bytes
export fn vm_get_full_memory_view(buffer_ptr: [*]u8, buffer_size: u32) void {
    const required_size = MEMORY_SIZE * BYTES_PER_WORD; // Use the constant

    // Check if the buffer is large enough
    if (buffer_size < required_size) {
        @panic("Buffer provided to vm_get_full_memory_view is too small");
    }

    // Get a slice of our internal VM memory
    const vm_memory_slice = vm_memory.getMemorySlice(); // This is [24000]u8

    // Copy the data from the internal VM memory to the provided buffer
    @memcpy(buffer_ptr[0..required_size], vm_memory_slice);
}

// --- Additionally: Functions for debugging ---

// Function to read a specific byte from a word
// Use u32 for address and byte_index, as WASM does not support u12, u3
export fn vm_read_byte(address: u32, byte_index: u32) u8 {
    // Check boundaries in JS or in the readByte function itself
    const byte_val = vm_memory.readByte(address, byte_index);
    return byte_val; // MixByteValue (u8) is returned as u8
}

// Function to write a specific byte to a word
// Use u32 for address and byte_index, as WASM does not support u12, u3
export fn vm_write_byte(address: u32, byte_index: u32, byte_val: u8) void {
    // Check that byte_val fits in 6 bits
    if (byte_val > 63) {
        @panic("Value too large for MixByte (must be 0-63)");
    }
    // Check boundaries in JS or in the writeByte function itself
    vm_memory.writeByte(address, byte_index, byte_val);
}

// Empty function, so the compiler doesn't remove other functions
export fn __keep_alive__() void {}
