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
const SPEC_F  = { 0: 'NUM',  1: 'CHAR', 2: 'HLT' };
const SHIFT_F = { 0: 'SLA',  1: 'SRA',  2: 'SLAX', 3: 'SRAX', 4: 'SLC', 5: 'SRC' };
const JMP_F   = { 0: 'JMP',  1: 'JSJ',  2: 'JOV',  3: 'JNOV',
                  4: 'JL',   5: 'JE',   6: 'JG',   7: 'JGE', 8: 'JNE', 9: 'JLE' };

function decodeInstruction(bytes, sign) {
  const C = bytes[4], F = bytes[3], I = bytes[2];
  const AA = (bytes[0] << 6) | bytes[1];
  let name = OPCODES[C] ?? `?${C}`;
  if (C === 5)  name = SPEC_F[F]  ?? name;
  if (C === 6)  name = SHIFT_F[F] ?? name;
  if (C === 39) name = JMP_F[F]   ?? name;
  const s     = sign ? '-' : '+';
  const addr  = `${s}${String(AA).padStart(4, '0')}`;
  const idx   = I ? `,${I}` : '';
  const showF = C !== 5 && C !== 6 && C !== 39;
  const field = showF ? `(${Math.floor(F / 8)}:${F % 8})` : '';
  return `${name.padEnd(5)} ${addr}${idx}${field}`;
}

function wordValue(bytes, sign) {
  let v = 0;
  for (const b of bytes) v = v * 64 + b;
  return sign ? -v : v;
}

// Decode a signed i32 into MIX sign + 5 bytes for display
function fmtWord(v) {
  const s   = v < 0 ? '−' : '+';
  const abs = Math.abs(v);
  const b   = [
    (abs >>> 24) & 0x3F,
    (abs >>> 18) & 0x3F,
    (abs >>> 12) & 0x3F,
    (abs >>> 6)  & 0x3F,
     abs         & 0x3F,
  ];
  return `${s} ${b.map(x => String(x).padStart(2, '0')).join(' ')}`;
}

// Decode a signed i32 into MIX sign + 2 bytes for index registers
function fmtIndex(v) {
  const s   = v < 0 ? '−' : '+';
  const abs = Math.abs(v);
  const b   = [(abs >>> 6) & 0x3F, abs & 0x3F];
  return `${s} ${b.map(x => String(x).padStart(2, '0')).join(' ')}`;
}

const PAGE_SIZE = 32;

// ── Built-in example programs ────────────────────────────────────────────────
const ASM_EXAMPLES = {
  gcd: `\
* Greatest Common Divisor — Euclid's algorithm
* gcd(252, 105) = 21 stored at address R
M       EQU     1000
N       EQU     1001
R       EQU     1002
        ORIG    M
        CON     252
        CON     105
        CON     0
        ORIG    3000
START   LDA     M
        STA     U
        LDA     N
        STA     V
LOOP    LDA     U
        SRAX    5
        DIV     V
        JXZ     DONE
        LDA     V
        STA     U
        STX     V
        JMP     LOOP
DONE    LDA     V
        STA     R
        HLT
U       CON     0
V       CON     0
        END     START`,

  max: `\
* Find maximum value in array of 10 numbers
N       EQU     10
ARR     EQU     100
RESULT  EQU     110
        ORIG    ARR
        CON     14
        CON     3
        CON     99
        CON     27
        CON     51
        CON     8
        CON     72
        CON     45
        CON     6
        CON     31
        ORIG    3000
START   LDA     ARR
        ENT1    1
LOOP    CMPA    ARR,1
        JGE     NEXT
        LDA     ARR,1
NEXT    INC1    1
        CMP1    =N=
        JL      LOOP
        STA     RESULT
        HLT
        END     START`,
};

document.addEventListener('alpine:init', () => {
  Alpine.data('vm', () => ({

    // WASM handles
    exports: null,
    memView: null,  // live Uint8Array into WASM linear memory

    // VM state (mirrors WASM)
    pc:       0,
    cycle:    0,
    halted:   false,
    overflow: false,
    cmp:      'E',     // 'L' | 'E' | 'G'
    regA:     0,       // i32
    regX:     0,       // i32
    regI:     [0, 0, 0, 0, 0, 0],  // i32 × 6
    regJ:     0,       // u32

    // UI state
    loaded:   false,
    loading:  false,
    error:    null,
    status:   'Not loaded',
    running:  false,
    _runInterval: null,
    runSpeed: 10,
    memPage:  0,
    gotoAddr: '',
    view:     'debug',   // 'debug' | 'asm'

    // Assembler state
    asmSource:     '',
    asmErrors:     [],
    asmOutput:     '',
    asmStatusText: 'Ready',

    // Step-back history: snapshots of full machine state
    history:     [],
    MAX_HISTORY: 200,

    // ── Computed ────────────────────────────────────────────────────────────

    get statusClass() {
      if (this.error)  return 'status-error';
      if (this.halted) return 'status-halted';
      if (this.loaded) return 'status-ok';
      return 'status-idle';
    },

    get totalPages() { return Math.ceil(4000 / PAGE_SIZE); },

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
          addr, bytes, sign,
          instr: decodeInstruction(bytes, sign),
          value: wordValue(bytes, sign),
        });
      }
      return out;
    },

    // ── Format helpers (called from templates) ───────────────────────────

    fmtWord,
    fmtIndex,

    fmtAddr(v) { return String(v).padStart(4, '0'); },

    cmpLabel(v) { return v === 'L' ? 'L (less)' : v === 'G' ? 'G (greater)' : 'E (equal)'; },

    // ── WASM loading ─────────────────────────────────────────────────────

    init() { this.load(); },

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
          env: { abort: () => { throw new Error('WASM panic (see console)'); } },
        });
        this.exports = instance.exports;
        this.exports.vm_init();

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

    // ── VM control ───────────────────────────────────────────────────────

    syncState() {
      const e = this.exports;
      this.cycle    = e.vm_get_cycle();
      this.pc       = e.vm_get_pc();
      this.halted   = !!e.vm_get_halted();
      this.overflow = !!e.vm_get_overflow();
      const c = e.vm_get_cmp();
      this.cmp = c === 0 ? 'L' : c === 2 ? 'G' : 'E';
      this.regA = e.vm_get_reg_a();
      this.regX = e.vm_get_reg_x();
      for (let i = 1; i <= 6; i++) this.regI[i - 1] = e.vm_get_reg_i(i);
      this.regJ = e.vm_get_reg_j();
    },

    saveSnapshot() {
      this.history.push({
        pc:       this.pc,
        cycle:    this.cycle,
        halted:   this.halted,
        overflow: this.overflow,
        cmp:      this.cmp,
        regA:     this.regA,
        regX:     this.regX,
        regI:     [...this.regI],
        regJ:     this.regJ,
        mem:      new Uint8Array(this.memView),  // copy
      });
      if (this.history.length > this.MAX_HISTORY) this.history.shift();
    },

    restoreSnapshot(snap) {
      const e = this.exports;
      // Restore memory
      new Uint8Array(e.memory.buffer, e.vm_get_memory_ptr(), snap.mem.length).set(snap.mem);
      // Restore registers
      e.vm_set_reg_a(snap.regA);
      e.vm_set_reg_x(snap.regX);
      for (let i = 1; i <= 6; i++) e.vm_set_reg_i(i, snap.regI[i - 1]);
      e.vm_set_reg_j(snap.regJ);
      // Restore VM state
      e.vm_set_pc(snap.pc);
      e.vm_set_cycle(snap.cycle);
      e.vm_set_halted(snap.halted ? 1 : 0);
      e.vm_set_overflow(snap.overflow ? 1 : 0);
      e.vm_set_cmp(snap.cmp === 'L' ? 0 : snap.cmp === 'G' ? 2 : 1);
      this.syncState();
    },

    step() {
      if (!this.loaded || this.halted) return;
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
        this._runInterval = setInterval(() => {
          if (this.halted) { this.toggleRun(); return; }
          this.step();
        }, Math.round(1000 / this.runSpeed));
      }
    },

    applySpeed() {
      if (this.running) {
        clearInterval(this._runInterval);
        this._runInterval = setInterval(() => {
          if (this.halted) { this.toggleRun(); return; }
          this.step();
        }, Math.round(1000 / this.runSpeed));
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

    // ── .mix file loader ─────────────────────────────────────────────────

    // Parse an MDK-format .mix binary (ArrayBuffer) and load it into VM memory.
    // Format:
    //   Header (16 bytes): magic 0xBEEFDEAD, version, ?, start_address
    //   String section:    u32 filename_len, u32 ?, filename bytes, symbol bytes, ';'
    //   Records (repeating):
    //     if u32 has bit 31 set  → new block at (u32 & 0x7FFFFFFF), no line number follows
    //     else                   → word (bit30=sign, bits0-29=magnitude) + u16 line number
    parseMix(buf) {
      const data = new Uint8Array(buf);
      const view = new DataView(buf);

      if (view.getUint32(0, true) !== 0xBEEFDEAD)
        throw new Error('Not a valid .mix file (bad magic number)');
      if (data.length < 25)
        throw new Error('File too short to be a valid .mix file');

      const startAddr = view.getUint32(12, true);

      // Scan for the ';' separator that ends the string section
      let sep = 24;
      while (sep < data.length && data[sep] !== 0x3B) sep++;
      if (sep >= data.length)
        throw new Error('Malformed .mix file: missing ";" separator');

      let cur     = startAddr;
      let i       = sep + 1;
      let loaded  = 0;
      let minAddr = Infinity;
      let maxAddr = -Infinity;

      while (i + 3 < data.length) {
        const w = view.getUint32(i, true);

        if (w & 0x80000000) {
          cur = w & 0x7FFFFFFF;   // block-start marker
          i += 4;
        } else {
          const sign = (w >>> 30) & 1;
          const mag  =  w & 0x3FFFFFFF;
          this.exports.vm_write_word(cur, sign ? -mag : mag);
          if (cur < minAddr) minAddr = cur;
          if (cur > maxAddr) maxAddr = cur;
          cur++;
          loaded++;
          i += 6;   // 4-byte word + 2-byte line number
        }
      }

      if (loaded === 0) throw new Error('No words found in .mix file');
      return { startAddr, loaded, minAddr, maxAddr };
    },

    async loadMixFile(event) {
      const file = event.target.files[0];
      event.target.value = '';   // allow re-selecting the same file
      if (!file || !this.loaded) return;

      try {
        const buf = await file.arrayBuffer();

        this.exports.vm_reset();   // clear registers and memory
        this.history = [];

        const { startAddr, loaded, minAddr, maxAddr } = this.parseMix(buf);

        this.exports.vm_set_pc(startAddr);
        this.syncState();
        this.jumpToPC();
        this.status = `${file.name}: ${loaded} words (${minAddr}–${maxAddr}), PC=${startAddr}`;
      } catch (e) {
        this.error  = e.message;
        this.status = 'Load error';
        console.error(e);
      }
    },

    // ── Navigation ──────────────────────────────────────────────────────

    prevPage()   { this.memPage = Math.max(0, this.memPage - 1); },
    nextPage()   { this.memPage = Math.min(this.totalPages - 1, this.memPage + 1); },
    jumpToPC()   { this.memPage = Math.floor(this.pc / PAGE_SIZE); },
    jumpToAddr() {
      const addr = parseInt(this.gotoAddr, 10);
      if (!isNaN(addr) && addr >= 0 && addr < 4000) {
        this.memPage = Math.floor(addr / PAGE_SIZE);
      }
    },

    // ── Assembler ────────────────────────────────────────────────────────

    asmAssemble() {
      if (!this.loaded) return;
      this.asmErrors  = [];
      this.asmOutput  = '';
      this.asmStatusText = 'Assembling…';

      let result;
      try {
        result = assembleMixal(this.asmSource);
      } catch (e) {
        this.asmErrors = [`Internal assembler error: ${e.message}`];
        this.asmStatusText = 'Error';
        return;
      }

      if (result.errors.length) {
        this.asmErrors = result.errors;
        this.asmStatusText = `${result.errors.length} error(s)`;
        return;
      }

      // Load into VM
      this.exports.vm_reset();
      this.history = [];
      for (const { addr, value } of result.words) {
        this.exports.vm_write_word(addr, value);
      }
      this.exports.vm_set_pc(result.startAddr);
      this.syncState();
      this.jumpToPC();

      const n = result.words.length;
      this.asmOutput = `OK — ${n} word${n !== 1 ? 's' : ''} loaded, PC=${result.startAddr}`;
      this.asmStatusText = `Loaded ${n} words`;
      this.status = `Assembled: ${n} words, PC=${result.startAddr}`;

      // Switch to debugger view so user can step
      this.view = 'debug';
    },

    asmLoadExample(event) {
      const key = event.target.value;
      event.target.value = '';
      if (!key) return;
      this.asmSource = ASM_EXAMPLES[key] ?? '';
    },

  }));
});
