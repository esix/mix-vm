# MIX VM

A virtual machine for Donald Knuth's MIX computer from *The Art of Computer Programming*.
Implemented in Zig, runs in both the terminal and the browser.

## What is MIX?

MIX is Knuth's hypothetical computer used throughout TAOCP. It has:

- 4000 words of memory (each word is 5 six-bit bytes + a sign bit)
- Registers: rA, rX (full words), rI1–rI6 (index registers), rJ (return address)
- ~60 instructions covering arithmetic, load/store, jumps, shifts, and I/O
- 21 I/O devices: tape (0–7), disk (8–15), card reader (16), card punch (17), line printer (18), typewriter/TTY (19), paper tape (20)

## Requirements

- [Zig](https://ziglang.org/) 0.15+
- A web browser (for the browser debugger)
- A local HTTP server (for the browser debugger — see below)

## Building

```sh
# Build everything (CLI binary + WASM for the browser)
make

# Build just the CLI
make cli

# Build just the WASM (and copy it to frontend/)
make wasm
```

The CLI binary ends up at `zig-out/bin/mix-vm`.

## Browser debugger

The debugger lives in `frontend/`. It needs a local HTTP server because browsers
block `fetch()` on `file://` URLs (required to load the `.wasm` file).

**Any simple server works:**

```sh
# Python (usually pre-installed)
cd frontend && python3 -m http.server 8080

# Node (if you have it)
cd frontend && npx serve .
```

Then open `http://localhost:8080` in your browser.

The WASM loads automatically. `frontend/mix-vm.wasm` is committed so no build step is
needed to just try the debugger.

### Writing and running a program

1. Click **Assembler** in the toolbar
2. Write MIXAL code, or pick one of the built-in examples from the dropdown
3. Click **Assemble & Load** — the page switches to Debugger view automatically
4. Use the toolbar to step, run, or set breakpoints

You can also load a pre-compiled `.mix` binary (MDK format) with the **Load .mix** button
if you have [GNU MDK](https://www.gnu.org/software/mdk/) installed.

### Debugger controls

| Control | Action |
|---------|--------|
| **Step →** | Execute one instruction |
| **← Back** | Undo the last step (up to 200 steps) |
| **▶ Run / ▐▐ Stop** | Run continuously; steps are batched per animation frame |
| **Steps/frame** | Batch size: 1 / 10 / 100 / 1K / 10K steps per 60fps frame |
| **Reset** | Reset VM state and memory |
| **Load .mix** | Load a pre-compiled MDK-format binary |
| **Click a memory row** | Toggle breakpoint; Run stops here automatically |
| **→ PC** | Re-enable auto-follow; view tracks the program counter |
| **▲ / ▼** | Page through memory manually (disables auto-follow) |

### Memory view

The memory table shows every word on the current page with its address, sign, five bytes,
decoded instruction mnemonic, and integer value. After assembly:

- **Symbol labels** appear below the address (e.g. `START`, `LOOP`, `BUF0`)
- **Source annotation** shows the original MIXAL line dimmed below each decoded instruction

The view auto-follows the program counter: it stays put while PC is comfortably visible,
and scrolls forward by half a page when PC reaches within two rows of the bottom.
Navigating manually (▲/▼/address box) disables auto-follow; **→ PC** re-enables it.

### Watch panel

The Watch panel (below Registers in the sidebar) lets you pin memory addresses to always
see their current value:

- Type an address (e.g. `100`) or a symbol name (e.g. `PRIME`, `BUF0`) and press Enter
- Each watch shows the decimal value and the five bytes decoded as MIX characters
- Values update live after every step or batch run frame
- Remove individual watches with the × button

### Step-back

Up to 200 steps of history are kept. **← Back** restores the previous machine state
including registers, memory, and I/O input positions. Memory snapshots use dirty-page
tracking (64-word pages) so each snapshot stores only the bytes that changed, not a full
24 KB copy.

### I/O panel

The I/O panel at the bottom of the debugger shows all active devices split into tabs:

| Tab | Devices | Notes |
|-----|---------|-------|
| **Printer (18)** | Line printer | `OUT BUF(18)` appends 24-word lines (120 chars) |
| **TTY (19)** | Typewriter | `IN BUF(19)` reads from the Input box; `OUT BUF(19)` appends output |
| **Card I/O (16/17)** | Card reader + card punch | Paste card data (80 chars/card) in the reader input box |
| **Storage (0–15)** | Tape + disk | Block counts and rewind/erase controls |

Input positions for card reader and TTY are included in step-back snapshots, so `IN`
instructions can be rewound correctly.

### Assembler syntax (MIXAL)

```mixal
* This is a comment
LABEL   OPCODE  address,index(field)    * inline comment

* Examples:
        ORIG    3000        * set location counter
START   LDA     100         * rA = mem[100]
        LDA     100,3       * rA = mem[100 + rI3]
        LDA     100(1:3)    * rA = field (1:3) of mem[100]
        JMP     START       * unconditional jump
        CMPX    =42=        * compare rX with literal constant 42
        HLT
        END     START
```

**Directives:**

| Directive | Meaning |
|-----------|---------|
| `ORIG expr` | Set the location counter |
| `EQU expr` | Define a symbol (no word emitted) |
| `CON expr` | Emit a constant word |
| `ALF "HELLO"` | Emit 5 characters encoded as a MIX word |
| `END expr` | End of program; expr is the start address |

**Local labels** (`nH` / `nB` / `nF`) are supported, as used throughout TAOCP:

```mixal
2H      INC1    1           * 2H defines a local label
        J1Z     2F          * 2F references the next 2H forward
        JMP     2B          * 2B references the most recent 2H backward
```

## Terminal

```sh
# Run a MIXAL source file (assemble + execute)
zig-out/bin/mix-vm examples/gcd.mixal

# Compile to a .mix binary without running
zig-out/bin/mix-vm -c examples/gcd.mixal   # writes examples/gcd.mix

# Run a pre-compiled .mix binary
zig-out/bin/mix-vm examples/gcd.mix

# Interactive terminal debugger
zig-out/bin/mix-vm -d examples/gcd.mixal
```

### Terminal debugger commands

| Command | Action |
|---------|--------|
| `s` / `step` | Execute one instruction |
| `r` / `run` / `c` / `cont` | Run until halt or breakpoint |
| `p` / `regs` | Print all registers |
| `pc` | Print program counter |
| `b <addr>` | Toggle breakpoint at address |
| `bl` | List all breakpoints |
| `m <addr> [n]` | Show `n` words of memory (default 10) |
| `q` / `quit` | Exit |

## Example programs

| File | Description |
|------|-------------|
| `gcd.mixal` | GCD via Euclid's algorithm — `gcd(252, 105) = 21` |
| `max.mixal` | Find the maximum in an array of 10 numbers |
| `hello_printer.mixal` | Hello World to the line printer (device 18) |
| `hello_tty.mixal` | Hello World to the typewriter (device 19) |
| `echo.mixal` | Read one card (device 16), print it to the printer (device 18) |
| `tty_echo.mixal` | Echo TTY input back until a line starting with `.` |
| `primes500.mixal` | First 500 primes — TAOCP Vol. 1 Program P (§1.3.2) |

## Project layout

```
src/
  mix_memory.zig   — word layout (5 bytes + sign), 4000-word memory, dirty-page bitmap
  mix_vm.zig       — VM state: registers, PC, flags, pending I/O fields
  mix_cpu.zig      — full instruction set (~60 opcodes) including all I/O instructions
  mix_asm.zig      — two-pass MIXAL assembler (Zig, used by the CLI)
  main_wasm.zig    — WASM exports: VM control, memory access, dirty tracking, I/O
  main.zig         — CLI entry point: run / compile / interactive debugger
frontend/
  index.html       — debugger UI (Alpine.js 3 from CDN, no npm needed)
  main.js          — Alpine component: VM bridge, step-back, batch run, I/O, watch panel
  assembler.js     — two-pass MIXAL assembler in pure JS (used by the browser)
  style.css        — dark theme
  mix-vm.wasm      — compiled VM (committed; no build step needed to try the debugger)
examples/
  *.mixal          — MIXAL source programs (see table above)
```

## References

- *The Art of Computer Programming*, Vol. 1 — Donald Knuth (MIX defined in §1.3)
- [GNU MDK](https://www.gnu.org/software/mdk/) — reference MIX assembler/emulator
