const std = @import("std");

// Constant for memory size, declared outside the struct
pub const MEMORY_SIZE = 4000;

// MixByte will be represented as u8 in WASM memory, but with a check that the top 2 bits are 0
pub const MixByteValue = u8;

// Sign: 0 - positive, 1 - negative.
// Also represented as u8 (0 or 1), occupies one byte in the struct.
pub const MixSignValue = u8; // or bool, but u8 for clarity and alignment

// MIX Word: 5 bytes of data + 1 sign byte = 6 bytes in WASM memory.
// This is convenient for JS: 6 consecutive bytes per word.
pub const MixWordLayout = extern struct { // extern struct ensures C ABI layout, bytes are consecutive without padding
    bytes: [5]MixByteValue,
    sign: MixSignValue,

    // Helper functions for convenient work with the word in Zig

    // Sets the word value from an integer (for initialization/loading)
    // Checks that byte values fit into 6 bits (0-63).
    pub fn setValueFromInt(self: *MixWordLayout, value: i32) !void {
        const abs_val = @abs(value);
        self.sign = if (value < 0) 1 else 0;

        var temp = abs_val;
        for (0..5) |i| {
            // Use @as to cast the result of temp & 0x3F to u8 type
            const byte_val = @as(u8, @truncate(temp & 0x3F)); // Take lower 6 bits and cast to u8
            // Inline check (alternative: check in the calling code)
            if (byte_val > 63) @panic("Byte value exceeds 6 bits");
            self.bytes[4 - i] = byte_val;
            temp >>= 6;
        }
    }

    // Gets the word value as an integer
    pub fn getValueAsInt(self: MixWordLayout) i32 {
        var result: i32 = 0;
        for (0..5) |i| {
            result <<= 6;
            result |= self.bytes[i];
        }
        if (self.sign == 1) {
            result = -result;
        }
        return result;
    }

    // Checks if all bytes in the word have valid values (0-63)
    pub fn validate(self: MixWordLayout) bool {
        for (self.bytes) |b| {
            if (b > 63) {
                return false;
            }
        }
        // Check the sign (0 or 1)
        if (self.sign > 1) {
            return false;
        }
        return true;
    }
};

// VM Memory: 4000 words, indexed from 0 to 3999
// Each word occupies 6 bytes (5 data bytes + 1 sign byte)
pub const Memory = struct {
    // const memory_size = 4000; // Moved outside the struct as MEMORY_SIZE
    data: [MEMORY_SIZE * 6]u8 = undefined, // Use the external constant

    pub fn init(self: *Memory) void {
        @memset(&self.data, 0); // Fill with zeros
    }

    // Gets a pointer to the start of the word at the given address
    fn getWordPtr(self: *const Memory, address: u32) *const MixWordLayout {
        if (address >= MEMORY_SIZE) { // Use the external constant
            @panic("Memory access out of bounds");
        }
        // Calculate the offset: address * 6 bytes per word
        const offset = address * 6;
        // Cast the byte pointer to a MixWordLayout pointer
        return @ptrCast(@alignCast(self.data[offset..].ptr));
    }

    // Gets a pointer to the start of the word at the given address (for writing)
    fn getWordPtrMut(self: *Memory, address: u32) *MixWordLayout {
        if (address >= MEMORY_SIZE) { // Use the external constant
            @panic("Memory access out of bounds");
        }
        const offset = address * 6;
        return @ptrCast(@alignCast(&self.data[offset]));
    }

    pub fn readWord(self: *const Memory, address: u32) MixWordLayout {
        return self.getWordPtr(address).*; // Dereference the pointer, get a copy of the word
    }

    pub fn writeWord(self: *Memory, address: u32, word: MixWordLayout) void {
        // Validate before writing
        if (!word.validate()) {
             @panic("Invalid MixWord value");
        }
        self.getWordPtrMut(address).* = word; // Dereference the pointer, assign the word
    }

    // Convenient function to read a byte from a word
    pub fn readByte(self: *const Memory, address: u32, byte_index: u32) MixByteValue {
        if (byte_index >= 5) {
            @panic("Byte index out of bounds for word");
        }
        const word = self.readWord(address);
        return word.bytes[byte_index];
    }

    // Convenient function to write a byte to a word
    pub fn writeByte(self: *Memory, address: u32, byte_index: u32, byte_val: MixByteValue) void {
        if (byte_val > 63) {
             @panic("Value too large for MixByte (must be 0-63)");
        }
        if (byte_index >= 5) {
            @panic("Byte index out of bounds for word");
        }
        var word = self.readWord(address);
        word.bytes[byte_index] = byte_val;
        self.writeWord(address, word);
    }

    // Function to get a pointer to the internal memory data (for WASM export)
    pub fn getMemorySlice(self: *Memory) []u8 {
        return &self.data;
    }

    // Function to get a pointer to the start of the memory buffer (for WASM export)
    pub fn getMemoryPtr(self: *Memory) [*]u8 {
        return self.data[0..].ptr;
    }

    // Function to get the memory size in bytes
    pub fn getMemorySizeInBytes(self: *Memory) usize {
        return self.data.len;
    }
};
