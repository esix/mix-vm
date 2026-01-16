
// frontend/main.js

async function loadWasm() {
  const wasmBytes = await fetch("mix-vm.wasm").then((response) =>
      response.arrayBuffer(),
  );

  const imports = {
    env: {
      abort: () => {
        throw new Error(
            "Abort called from WASM (likely from a panic). Check console for Zig panic message.",
        );
      },
    },
  };

  try {
    const wasmModule = await WebAssembly.instantiate(wasmBytes, imports);

    console.log(
        "WASM loaded and instantiated (exported memory):",
        wasmModule.instance.exports,
    );

    const exports = wasmModule.instance.exports;
    console.assert(exports.vm_init, "No exports.vm_init");
    console.assert(exports.vm_get_state, "No exports.vm_get_state");

    // Initialize the VM
    exports.vm_init();
    console.log("VM initialized.");
    console.log("Current VM state:", exports.vm_get_state());

    if (
        exports.vm_get_full_memory_view &&
        exports.vm_get_memory_required_size
    ) {
      // 1. We need to get the exported WASM memory
      // const wasmMemory = exports.memory; // WASM exports memory
      // // 2. Create a DataView or Uint8Array on top of the exported memory
      // const wasmMemoryView = new Uint8Array(wasmMemory.buffer);
      // // 3. Create a JS buffer of the required size
      // const jsMemoryBuffer = new Uint8Array(requiredSize);
      // 4. Call the Zig function, passing it the offset in the exported memory,
      //    where our JS buffer is located (after we "placed" it there).
      //    BUT! We cannot simply pass a JS Uint8Array to Zig.
      //    We need to place the buffer *inside* WASM memory, so that Zig can get a pointer to it.
      //    This is done by allocating space in WASM memory and copying the data into it from JS,
      //    or by using special mechanisms (e.g., WASI, although this is not directly suitable for freestanding).
      //    The simplest way is to use a `toWasm` buffer, but this is not a standard JS API.
      //    Instead, Zig should copy *into* the offset passed to it in *its* memory.

      // Get WASM exported memory
      const wasmMemory = exports.memory; // This is WebAssembly.Memory
      const wasmMemoryBuffer = wasmMemory.buffer; // This is ArrayBuffer
      const wasmMemoryView = new Uint8Array(wasmMemoryBuffer); // This is Uint8Array over WASM memory

      // Get the required size
      const requiredSize = exports.vm_get_memory_required_size();

      // Reserve space in WASM memory for the result.
      // This could be static space or dynamically allocated (if there is an allocator).
      // For simplicity, let's assume we know that there is enough memory and use the beginning
      // (in practice, you need to consider global variables and the stack).
      // Let's assume we will copy the result to the beginning of WASM memory.
      // This is NOT safe in reality, but works as a demonstration.
      const destination_offset = 0; // DO NOT USE 0 IN PRACTICE!

      // Call Zig to copy the VM memory into WASM memory at the specified offset
      exports.vm_get_full_memory_view(destination_offset, requiredSize);

      // Now copy from WASM memory to JS Uint8Array
      const jsMemoryBuffer = wasmMemoryView.subarray(
          destination_offset,
          destination_offset + requiredSize,
      );

      console.log("Copied VM memory to JS buffer:", jsMemoryBuffer);
      document.getElementById("output").innerHTML =
          `<p>WASM loaded. VM memory copied to JS buffer (${jsMemoryBuffer.length} bytes).</p>`;
    } else {
      document.getElementById("output").innerHTML =
          "<p>WASM loaded, but vm_get_full_memory_view or vm_get_memory_required_size not found.</p>";
    }
  } catch (error) {
    console.error("Error instantiating WASM:", error);
    document.getElementById("output").innerHTML =
        `<p>Error loading WASM: ${error.message}</p>`;
  }
}

document.getElementById("run").addEventListener("click", loadWasm);
