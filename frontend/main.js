// frontend/main.js

// Create the memory object that will be used by WASM.
// Size is specified in WASM pages (1 page = 65536 bytes).
// In build.zig, you specified max_memory as std.wasm.page_size * number_of_pages (2 pages).
// 'maximum' in JS must correspond to this value.
const wasmMemory = new WebAssembly.Memory({
  initial: 2, // Initial size in pages (should be >= initial_memory in build.zig)
  maximum: 2, // Maximum size in pages (should be >= max_memory in build.zig)
  // and correspond to the value specified in build.zig in bytes, divided by 65536
});

// Function to load and instantiate WASM
async function loadWasm() {
  // Fetch the WASM bytecode
  const wasmBytes = await fetch("mix-vm.wasm").then((response) =>
    response.arrayBuffer(),
  );

  // Prepare the imports object.
  const imports = {
    env: {
      memory: wasmMemory,
      // Add a simple abort stub, in case Zig generates it as an import
      // and code inside WASM calls panic.
      abort: () => {
        throw new Error(
          "Abort called from WASM (likely from a panic). Check console for Zig panic message.",
        );
      },
    },
  };

  try {
    // Instantiate WASM, passing the imports
    const wasmModule = await WebAssembly.instantiate(wasmBytes, imports);

    console.log(
      "WASM loaded and instantiated with imported memory:",
      wasmModule.instance.exports,
    );

    const exports = wasmModule.instance.exports;

    // Check if the required functions exist
    if (exports.vm_init) {
      // Initialize the VM
      exports.vm_init();
      console.log("VM initialized.");

      // Example of calling other functions
      if (exports.vm_get_state) {
        console.log("Current VM state:", exports.vm_get_state());
      }

      // Check access to memory via the exported pointer
      if (exports.vm_memory_ptr && exports.vm_memory_size_bytes) {
        const ptr = exports.vm_memory_ptr(); // Get the byte offset
        const size = exports.vm_memory_size_bytes(); // Get the memory size in bytes
        console.log(`WASM memory pointer offset: ${ptr}, size: ${size} bytes`);

        // Create a view of the WASM memory as a Uint8Array
        const memoryView = new Uint8Array(wasmMemory.buffer);

        // Now you can read/write directly to memoryView
        // or use the exported functions to interact with the VM
        // and debug its state.
        document.getElementById("output").innerHTML =
          `<p>WASM loaded. Memory accessible. Ptr offset: ${ptr}, Size: ${size}. Max WASM memory pages: ${wasmMemory.grow(0)}</p>`;
      } else {
        document.getElementById("output").innerHTML =
          "<p>WASM loaded, but memory access functions not found.</p>";
      }
    } else {
      document.getElementById("output").innerHTML =
        "<p>WASM loaded, but VM initialization function 'vm_init' not found.</p>";
    }
  } catch (error) {
    console.error("Error instantiating WASM:", error);
    document.getElementById("output").innerHTML =
      `<p>Error loading WASM: ${error.message}</p>`;
  }
}

document.getElementById("run").addEventListener("click", loadWasm);
