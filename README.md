# MIX VM

A virtual machine for Donald Knuth's MIX computer from *The Art of Computer Programming*.
Implemented in Zig, runs in both the terminal and the browser.

## What is MIX?

MIX is Knuth's hypothetical computer used throughout TAOCP. It has:
- 4000 words of memory (each word is 5 six-bit bytes + a sign)
- Registers: rA, rX (full words), rI1–rI6 (index), rJ (return address)
- ~60 instructions covering arithmetic, load/store, jumps, shifts, and I/O

## Requirements

- [Zig](https://ziglang.org/) 0.15+
- A web browser (for the debugger)
- A local HTTP server (for the debugger — see below)

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

# Zig (if you want to stay in the ecosystem)
# just open the browser after running one of the above
```

Then open `http://localhost:8080` in your browser.

The WASM loads automatically when the page opens. No build step is needed to
*use* the debugger — `frontend/mix-vm.wasm` is already compiled and committed.

### Writing and running a program

1. Click **Assembler** in the toolbar
2. Write MIXAL code, or pick one of the built-in examples from the dropdown
3. Click **Assemble & Load** — the page switches to Debugger view automatically
4. Use the toolbar to step, run, or set breakpoints

You can also load a pre-compiled `.mix` binary (MDK format) with the
**Load .mix** button if you have [GNU MDK](https://www.gnu.org/software/mdk/) installed.

### Debugger controls

| Control | Action |
|---------|--------|
| **Step →** | Execute one instruction |
| **← Back** | Undo the last step (up to 200 steps) |
| **▶ Run / ▐▐ Stop** | Run continuously at the selected speed |
| **Reset** | Reset VM state and clear history |
| **Speed slider** | 1–200 Hz |
| **Click a memory row** | Toggle breakpoint (red marker); Run stops here automatically |
| **→ PC** | Jump memory view to current program counter |

### Assembler syntax (MIXAL)

```mixal
* This is a comment
LABEL   OPCODE  address,index(field)

* Examples:
        ORIG    3000        * set location counter
START   LDA     100         * rA = mem[100]
        LDA     100,3       * rA = mem[100 + rI3]
        LDA     100(1:3)    * rA = field (1:3) of mem[100]
        JMP     START       * unconditional jump
        CMPX    =42=        * compare rX with literal 42
        HLT
        END     START
```

**Directives:**

| Directive | Meaning |
|-----------|---------|
| `ORIG expr` | Set location counter |
| `EQU expr` | Define a symbol (no code emitted) |
| `CON expr` | Emit a constant word |
| `ALF "HELLO"` | Emit 5 characters as a MIX word |
| `END expr` | End of program; expr is the start address |

## Terminal

The CLI binary is at `zig-out/bin/mix-vm` after `make` or `make cli`.

```sh
# Run a MIXAL source file (assemble + execute)
zig-out/bin/mix-vm examples/gcd.mixal

# Compile a .mixal source to a .mix binary (no execution)
zig-out/bin/mix-vm -c examples/gcd.mixal   # writes examples/gcd.mix

# Run a pre-compiled .mix binary
zig-out/bin/mix-vm examples/gcd.mix

# Interactive debugger
zig-out/bin/mix-vm -d examples/gcd.mixal
```

### Debugger commands

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

## Project layout

```
src/
  mix_memory.zig   — word layout (5 bytes + sign) and 4000-word memory
  mix_vm.zig       — VM state: registers, PC, flags
  mix_cpu.zig      — full instruction set (~60 opcodes)
  mix_asm.zig      — two-pass MIXAL assembler (Zig)
  main_wasm.zig    — WASM exports used by the browser debugger
  main.zig         — CLI: run, compile (-c), interactive debugger (-d)
frontend/
  index.html       — debugger UI (Alpine.js from CDN, no npm needed)
  main.js          — Alpine component: WASM bridge, step-back, .mix loader
  assembler.js     — two-pass MIXAL assembler (pure JS)
  style.css        — dark theme
  mix-vm.wasm      — compiled VM (committed so no build step is needed to try it)
examples/
  gcd.mixal        — GCD via Euclid's algorithm (gcd(252,105) = 21)
  max.mixal        — find maximum in an array of 10 numbers
  hello.mixal      — Hello World (requires I/O, not yet supported)
  primes.mixal     — prime sieve (requires I/O, not yet supported)
```

## References

- *The Art of Computer Programming*, Vol. 1 — Donald Knuth (MIX is defined in §1.3)
- [GNU MDK](https://www.gnu.org/software/mdk/) — reference MIX assembler/emulator
