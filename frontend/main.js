'use strict';

// MIX opcode names, indexed by C field (0–63)
const OPCODES = [
  'NOP',  'ADD',  'SUB',  'MUL',  'DIV',  'SPEC', 'SHIFT','MOVE',
  'LDA',  'LD1',  'LD2',  'LD3',  'LD4',  'LD5',  'LD6',  'LDX',
  'LDAN', 'LD1N', 'LD2N', 'LD3N', 'LD4N', 'LD5N', 'LD6N', 'LDXN',
  'STA',  'ST1',  'ST2',  'ST3',  'ST4',  'ST5',  'ST6',  'STX',
  'STJ',  'STZ',  'JBUS', 'IOC',  'IN',   'OUT',  'JRED', 'JMP',
  'JAN',  'J1N',  'J2N',  'J3N',  'J4N',  'J5N',  'J6N',  'JXN',
  'INCA', 'INC1', 'INC2', 'INC3', 'INC4', 'INC5', 'INC6', 'INCX',
  'CMPA', 'CMP1', 'CMP2', 'CMP3', 'CMP4', 'CMP5', 'CMP6', 'CMPX',
];

// Sub-operations encoded in the F field for certain opcodes
const SPEC_F  = { 0: 'NUM',  1: 'CHAR', 2: 'HLT' };
const SHIFT_F = { 0: 'SLA',  1: 'SRA',  2: 'SLAX', 3: 'SRAX', 4: 'SLC', 5: 'SRC' };
const JMP_F   = { 0: 'JMP',  1: 'JSJ',  2: 'JOV',  3: 'JNOV',
                  4: 'JL',   5: 'JE',   6: 'JG',   7: 'JGE',  8: 'JNE', 9: 'JLE' };

// Decode a MIX word into a human-readable assembly string.
// bytes: [b0,b1,b2,b3,b4], sign: 0 (positive) or 1 (negative)
function decodeInstruction(bytes, sign) {
  const C = bytes[4], F = bytes[3], I = bytes[2];
  const AA = (bytes[0] << 6) | bytes[1];

  // Resolve name, accounting for opcodes that use F as a sub-opcode
  let name = OPCODES[C] ?? `?${C}`;
  if (C === 5)  name = SPEC_F[F]  ?? name;
  if (C === 6)  name = SHIFT_F[F] ?? name;
  if (C === 39) name = JMP_F[F]   ?? name;

  const s     = sign ? '-' : '+';
  const addr  = `${s}${String(AA).padStart(4, '0')}`;
  const idx   = I ? `,${I}` : '';

  // Show F as (L:R) field spec for regular instructions;
  // skip it for SPEC/SHIFT/JMP where F encodes the sub-opcode
  const showField = C !== 5 && C !== 6 && C !== 39;
  const field = showField ? `(${Math.floor(F / 8)}:${F % 8})` : '';

  return `${name.padEnd(5)} ${addr}${idx}${field}`;
}

function wordValue(bytes, sign) {
  let v = 0;
  for (const b of bytes) v = v * 64 + b;
  return sign ? -v : v;
}

const PAGE_SIZE = 32; // words per page in the memory view

document.addEventListener('alpine:init', () => {
  Alpine.data('vm', () => ({

    // WASM handles
    exports: null,
    memView: null,   // live Uint8Array pointing into WASM linear memory

    // VM state (mirrored from WASM)
    pc:    0,
    cycle: 0,

    // UI state
    loaded:  false,
    loading: false,
    error:   null,
    status:  'Not loaded',
    running: false,
    _runInterval: null,
    runSpeed: 10,   // Hz
    memPage:  0,
    gotoAddr: '',

    // Step-back history: array of { pc, cycle, mem: Uint8Array }
    history:     [],
    MAX_HISTORY: 200,

    // ── computed ────────────────────────────────────────────────────────────

    get statusClass() {
      if (this.error)  return 'status-error';
      if (this.loaded) return 'status-ok';
      return 'status-idle';
    },

    get totalPages() {
      return Math.ceil(4000 / PAGE_SIZE);
    },

    // Slice of words visible on the current memory page
    get visibleWords() {
      if (!this.memView) return [];
      const start = this.memPage * PAGE_SIZE;
      const end   = Math.min(start + PAGE_SIZE, 4000);
      const out   = [];
      for (let addr = start; addr < end; addr++) {
        const off   = addr * 6;
        const bytes = [
          this.memView[off],     this.memView[off + 1], this.memView[off + 2],
          this.memView[off + 3], this.memView[off + 4],
        ];
        const sign = this.memView[off + 5];
        out.push({
          addr,
          bytes,
          sign,
          instr: decodeInstruction(bytes, sign),
          value: wordValue(bytes, sign),
        });
      }
      return out;
    },

    // ── WASM loading ─────────────────────────────────────────────────────────

    async load() {
      this.loading = true;
      this.error   = null;
      this.status  = 'Loading…';
      try {
        const buf = await fetch('mix-vm.wasm').then(r => {
          if (!r.ok) throw new Error(`HTTP ${r.status} fetching mix-vm.wasm`);
          return r.arrayBuffer();
        });

        const { instance } = await WebAssembly.instantiate(buf, {
          env: {
            abort: () => { throw new Error('WASM panic (see console)'); },
          },
        });

        this.exports = instance.exports;
        this.exports.vm_init();

        // Create a live view into the VM's memory buffer.
        // vm_get_memory_ptr() returns the pointer inside WASM linear memory
        // where the 24 000-byte vm_memory.data array lives.
        const ptr  = this.exports.vm_get_memory_ptr();
        const size = this.exports.vm_get_memory_required_size();
        this.memView = new Uint8Array(this.exports.memory.buffer, ptr, size);

        this.syncState();
        this.loaded = true;
        this.status = 'Ready';
      } catch (e) {
        this.error  = e.message;
        this.status = 'Error';
        console.error(e);
      } finally {
        this.loading = false;
      }
    },

    // ── VM control ───────────────────────────────────────────────────────────

    syncState() {
      this.cycle = this.exports.vm_get_state();
      this.pc    = this.exports.vm_get_pc ? this.exports.vm_get_pc() : 0;
    },

    saveSnapshot() {
      this.history.push({
        pc:    this.pc,
        cycle: this.cycle,
        mem:   new Uint8Array(this.memView), // copy, not a live view
      });
      if (this.history.length > this.MAX_HISTORY) this.history.shift();
    },

    restoreSnapshot(snap) {
      // Write the saved memory bytes back into WASM linear memory
      const ptr    = this.exports.vm_get_memory_ptr();
      const target = new Uint8Array(this.exports.memory.buffer, ptr, snap.mem.length);
      target.set(snap.mem);
      this.pc    = snap.pc;
      this.cycle = snap.cycle;
    },

    step() {
      if (!this.loaded) return;
      this.saveSnapshot();
      this.exports.vm_step();
      this.syncState();
    },

    stepBack() {
      if (!this.loaded || this.history.length === 0) return;
      this.restoreSnapshot(this.history.pop());
    },

    toggleRun() {
      if (this.running) {
        clearInterval(this._runInterval);
        this._runInterval = null;
        this.running = false;
        this.status  = 'Paused';
      } else {
        this.running = true;
        this.status  = 'Running';
        this._runInterval = setInterval(() => this.step(), Math.round(1000 / this.runSpeed));
      }
    },

    applySpeed() {
      if (this.running) {
        clearInterval(this._runInterval);
        this._runInterval = setInterval(() => this.step(), Math.round(1000 / this.runSpeed));
      }
    },

    reset() {
      if (!this.loaded) return;
      if (this.running) this.toggleRun();
      this.history = [];
      this.exports.vm_reset();
      this.syncState();
      this.memPage = 0;
      this.status  = 'Ready';
    },

    // ── Navigation ───────────────────────────────────────────────────────────

    prevPage()   { this.memPage = Math.max(0, this.memPage - 1); },
    nextPage()   { this.memPage = Math.min(this.totalPages - 1, this.memPage + 1); },
    jumpToPC()   { this.memPage = Math.floor(this.pc / PAGE_SIZE); },
    jumpToAddr() {
      const addr = parseInt(this.gotoAddr, 10);
      if (!isNaN(addr) && addr >= 0 && addr < 4000) {
        this.memPage = Math.floor(addr / PAGE_SIZE);
      }
    },

  }));
});
