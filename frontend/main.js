'use strict';

// ── MIX character table (matches assembler.js MIX_CHAR_TABLE) ───────────────
// Index = MIX byte value (0–55); value = display character
const MIX_CHARSET = Array.from(' ABCDEFGHI~JKLMNOPQR`^STUVWXYZ0123456789.,()+-*/=$<>@;:\'');
const MIX_CHARMAP = Object.fromEntries(MIX_CHARSET.map((c, i) => [c, i]));
// Extra aliases for human input
MIX_CHARMAP['\u0394'] = 10; // Δ
MIX_CHARMAP['\u03a3'] = 20; // Σ
MIX_CHARMAP['\u03a0'] = 21; // Π

// Words per I/O block for each device
function blockWords(device) {
  if (device <= 15) return 100;          // tape (0-7) or disk (8-15)
  if (device === 16 || device === 17) return 16;  // card reader / card punch
  if (device === 18) return 24;          // line printer
  if (device === 19 || device === 20) return 14;  // typewriter / paper tape
  return 0;
}

// ── MIX opcode names, indexed by C field (0–63)
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

  hello_printer: `\
* Hello, World! — output to line printer (device 18, 24 words / 120 chars)
BUF     EQU     100
        ORIG    BUF
        ALF     HELLO         * H E L L O
        CON     6882509       *   W O R L  (space+WORL)
        CON     67108864      * D          (D+spaces)
        ORIG    3000
START   OUT     BUF(18)       * send block to printer
        HLT
        END     START`,

  hello_tty: `\
* Hello, World! — output to typewriter/terminal (device 19, 14 words / 70 chars)
BUF     EQU     100
        ORIG    BUF
        ALF     HELLO         * H E L L O
        CON     6882509       *   W O R L
        CON     67108864      * D
        ORIG    3000
START   OUT     BUF(19)       * send block to typewriter
        HLT
        END     START`,

  echo: `\
* Echo — read one card (device 16) then print it (device 18)
* Card reader: 16 words = 80 chars per card
* Printer:     24 words = 120 chars per block (extra words = spaces)
BUF     EQU     100
        ORIG    3000
START   JBUS    *(16)         * wait if card reader busy (NOP: always ready)
        IN      BUF(16)       * read 16 words from card reader into BUF
        JBUS    *(18)         * wait if printer busy (NOP)
        OUT     BUF(18)       * print 24 words (last 8 will be spaces)
        HLT
        END     START`,

  tty_echo: `\
* TTY echo — echo typewriter input back until a line starting with "."
* (adapted from Knuth TAOCP, jflude/taocp examples)
* Device 19 (typewriter): 14 words = 70 chars per block
* Usage: type lines in the TTY Input box, end with a line starting with "."
TTY     EQU     19
BUF     EQU     200
        ORIG    1000
OUTPUT  OUT     BUF(TTY)      * print BUF to typewriter
START   IN      BUF(TTY)      * read 14 words (70 chars) from TTY input
        JBUS    *(TTY)        * wait if busy (NOP: always ready)
        LDA     BUF           * load first word of input (first 5 chars)
        CMPA    PERIOD(1:1)   * compare only byte 1 (first char) with "."
        JNE     OUTPUT        * if not a period line: print and loop
        HLT
PERIOD  ALF     "."           * "." = MIX byte 40
        END     START`,

  primes500: `\
* Table of the first 500 primes — Knuth TAOCP Vol.1, Program P (section 1.3.2)
* Output goes to the line printer (device 18). Open the Printer tab to see it.
L       EQU     500
PRINTER EQU     18
PRIME   EQU     99
BUF0    EQU     2000
BUF1    EQU     BUF0+25
        ORIG    3000
START   IOC     0(PRINTER)    * skip to top of page
        LD1     =1-L=         * rI1 = 1-500 = -499
        LD2     =3=           * rI2 = 3 (first candidate N)
2H      INC1    1             * J++
        ST2     PRIME+L,1     * PRIME[J] = N
        J1Z     2F            * 500 primes found? jump to print section
4H      INC2    2             * N += 2 (next odd candidate)
        ENT3    2             * K = 2 (start from PRIME[2])
6H      ENTA    0             * clear rA
        ENTX    0,2           * rX = N
        DIV     PRIME,3       * rA = N/PRIME[K], rX = N mod PRIME[K]
        JXZ     4B            * remainder=0: N is composite, try next
        CMPA    PRIME,3       * compare quotient with PRIME[K]
        INC3    1             * K++
        JG      6B            * quotient > PRIME[K]: keep testing
        JMP     2B            * otherwise N is prime
2H      OUT     TITLE(PRINTER) * print title line
        ENT4    BUF1+10       * rI4 points into buffer 1
        ENT5    -50           * rI5 = -50
2H      INC5    L+1           * rI5 += 501
4H      LDA     PRIME,5       * load PRIME[rI5]
        CHAR                  * convert to decimal digits in rA:rX
        STX     0,4(1:4)      * store 4 digits into buffer word at rI4
        DEC4    1             * buffer pointer--
        DEC5    50            * rI5 -= 50 (step to next column)
        J5P     4B            * more primes on this line?
        OUT     0,4(PRINTER)  * print 24-word line
        LD4     24,4          * switch to other buffer (double-buffer)
        J5N     2B            * more lines?
        HLT
        ORIG    PRIME+1
        CON     2             * PRIME[1] = 2
        ORIG    BUF0-5
TITLE   ALF     "FIRST"
        ALF     " FIVE"
        ALF     " HUND"
        ALF     "RED P"
        ALF     "RIMES"
        ORIG    BUF0+24
        CON     BUF1+10
        ORIG    BUF1+24
        CON     BUF0+10
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
    batchSize: 1000,    // steps per rAF frame during Run
    memPage:   0,
    followPc:  true,    // when true, memory view auto-scrolls with PC
    viewStart: 0,       // first visible address in follow mode
    gotoAddr:  '',
    breakpoints: {},   // addr → true
    view:     'debug',   // 'debug' | 'asm'

    // Assembler state
    asmSource:     '',
    asmErrors:     [],
    asmOutput:     '',
    asmStatusText: 'Ready',

    // Step-back history: delta snapshots (dirty pages + registers)
    history:      [],
    MAX_HISTORY:  200,
    _memoryShadow: null,  // Uint8Array(24000) — mirror of WASM memory after each step

    // Symbol table (from last assemble)
    symbols:      {},   // name → address
    addrToSymbol: {},   // address → name
    addrToLine:   {},   // address → original source line

    // Watch panel
    watches:    [],   // [{addr, name}] — pinned memory addresses
    watchInput: '',

    // ── I/O device state ────────────────────────────────────────────────────
    ioView:    'printer',   // active tab: 'printer' | 'tty' | 'card' | 'storage'
    ioVisible: true,        // I/O panel visible
    // Output buffers (append-only; not rolled back on step-back)
    ioPrinter:   '',        // device 18: line printer output
    ioTty:       '',        // device 19: typewriter output
    ioCardPunch: '',        // device 17: card punch output
    ioPaperTape: '',        // device 20: paper tape output
    // Input buffers + positions (positions ARE included in step-back snapshots)
    ioCardInput: '',        // device 16: card reader input (user-editable)
    ioCardPos:   0,         // chars consumed from ioCardInput
    ioTtyInput:  '',        // device 19: typewriter input (user-editable)
    ioTtyPos:    0,         // chars consumed from ioTtyInput
    // Binary storage: tape (0-7) and disk (8-15)
    tapes: Array.from({length: 8},  () => ({ blocks: [], pos: 0 })),
    disks: Array.from({length: 8},  () => ({ blocks: {} })),

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
      const start = this.followPc ? this.viewStart : this.memPage * PAGE_SIZE;
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
          label:  this.addrToSymbol[addr] ?? '',
          source: this.addrToLine[addr]   ?? '',
        });
      }
      return out;
    },

    get watchValues() {
      void this.cycle;   // reactive dependency — re-evaluates after every step
      if (!this.memView) return [];
      return this.watches.map(({ addr, name }) => {
        const off   = addr * 6;
        const bytes = Array.from(this.memView.subarray(off, off + 5));
        const sign  = this.memView[off + 5];
        const v     = wordValue(bytes, sign);
        const chars = bytes.map(b => MIX_CHARSET[b] ?? ' ').join('');
        return { addr, name, bytes, sign, value: v, chars };
      });
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

        this._memoryShadow = new Uint8Array(size); // zeros = matches initial WASM memory
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

    // Build a delta snapshot: save pre-step registers + capture dirty pages from shadow.
    // Call AFTER vm_step() and handlePendingIo() so dirty is populated.
    _buildSnapshot(pre) {
      const lo = this.exports.vm_get_dirty_lo();
      const hi = this.exports.vm_get_dirty_hi();
      const pages = [];
      for (let p = 0; p < 32; p++) {
        if (lo >>> p & 1) this._capturePage(pages, p);
        if (hi >>> p & 1) this._capturePage(pages, p + 32);
      }
      // Update shadow with new values for dirty pages
      for (const { page } of pages) {
        const off = page * 64 * 6;
        const len = Math.min(384, 24000 - off);
        this._memoryShadow.set(this.memView.subarray(off, off + len), off);
      }
      return { ...pre, pages };
    },

    _capturePage(pages, pageIdx) {
      const off = pageIdx * 64 * 6;
      const len = Math.min(384, 24000 - off);
      if (len <= 0) return;
      const data = new Uint8Array(len);
      data.set(this._memoryShadow.subarray(off, off + len));
      pages.push({ page: pageIdx, data });
    },

    restoreSnapshot(snap) {
      const e = this.exports;
      // Restore only the pages that changed in that step
      for (const { page, data } of snap.pages) {
        const off = page * 64 * 6;
        this.memView.set(data, off);
        this._memoryShadow.set(data, off);
      }
      e.vm_clear_dirty();
      // Restore registers and state
      e.vm_set_reg_a(snap.regA);
      e.vm_set_reg_x(snap.regX);
      for (let i = 1; i <= 6; i++) e.vm_set_reg_i(i, snap.regI[i - 1]);
      e.vm_set_reg_j(snap.regJ);
      e.vm_set_pc(snap.pc);
      e.vm_set_cycle(snap.cycle);
      e.vm_set_halted(snap.halted ? 1 : 0);
      e.vm_set_overflow(snap.overflow ? 1 : 0);
      e.vm_set_cmp(snap.cmp === 'L' ? 0 : snap.cmp === 'G' ? 2 : 1);
      this.ioCardPos = snap.ioCardPos ?? 0;
      this.ioTtyPos  = snap.ioTtyPos  ?? 0;
      this.syncState();
    },

    step() {
      if (!this.loaded || this.halted) return;
      // Capture pre-step registers (cheaply, before executing)
      const pre = {
        pc: this.pc, cycle: this.cycle, halted: this.halted,
        overflow: this.overflow, cmp: this.cmp,
        regA: this.regA, regX: this.regX, regI: [...this.regI], regJ: this.regJ,
        ioCardPos: this.ioCardPos, ioTtyPos: this.ioTtyPos,
      };
      this.exports.vm_clear_dirty();
      this.exports.vm_step();
      this.handlePendingIo();
      // Build delta snapshot from dirty pages, push to history
      this.history.push(this._buildSnapshot(pre));
      if (this.history.length > this.MAX_HISTORY) this.history.shift();
      this.syncState();
      this._autoScroll();
    },

    stepBack() {
      if (!this.loaded || this.history.length === 0) return;
      this.restoreSnapshot(this.history.pop());
    },

    toggleRun() {
      if (this.running) {
        this.running = false;
        this.status  = 'Paused';
        // shadow sync happens inside _runFrame when it detects running=false
      } else {
        if (this.halted) return;
        this.running = true;
        this.status  = 'Running';
        requestAnimationFrame(() => this._runFrame());
      }
    },

    _runFrame() {
      if (!this.running) {
        // Sync shadow so single-step history is valid from here
        this._memoryShadow.set(this.memView);
        this.exports.vm_clear_dirty();
        return;
      }
      const e = this.exports;
      const n = this.batchSize;
      let done = false;
      for (let i = 0; i < n; i++) {
        if (e.vm_get_halted()) { done = true; break; }
        e.vm_step();
        this.handlePendingIo();
        if (this.breakpoints[e.vm_get_pc()]) { done = true; break; }
      }
      this.syncState();
      if (done) {
        this.running  = false;
        this.followPc = true;
        this.status   = this.halted ? 'Halted' : `Break @ ${this.pc}`;
        this._memoryShadow.set(this.memView);
        e.vm_clear_dirty();
        this._autoScroll();
      } else {
        requestAnimationFrame(() => this._runFrame());
      }
    },

    // Scroll the follow-mode window so PC stays visible.
    // Triggers only when PC is at the last 2 rows (advance half a page)
    // or has gone above the window (jump to PC near top).
    _autoScroll() {
      if (!this.followPc) return;
      const start = this.viewStart;
      const end   = start + PAGE_SIZE;
      if (this.pc >= start && this.pc < end - 2) return;  // comfortably visible — no change
      if (this.pc >= end - 2) {
        // Near bottom or off the bottom: advance half a page so PC lands in the middle
        this.viewStart = Math.min(4000 - PAGE_SIZE, this.pc - Math.floor(PAGE_SIZE / 2));
      } else {
        // Went above the window (e.g. jump/branch backward): show PC near top
        this.viewStart = Math.max(0, this.pc - 2);
      }
    },

    addWatch() {
      const s = this.watchInput.trim();
      if (!s) return;
      let addr;
      const n = parseInt(s, 10);
      if (!isNaN(n) && n >= 0 && n < 4000) {
        addr = n;
      } else {
        const sym = s.toUpperCase();
        addr = this.symbols[sym];
        if (addr === undefined) return;
      }
      if (this.watches.some(w => w.addr === addr)) { this.watchInput = ''; return; }
      const name = this.addrToSymbol[addr] ?? String(addr);
      this.watches = [...this.watches, { addr, name }];
      this.watchInput = '';
    },

    removeWatch(addr) {
      this.watches = this.watches.filter(w => w.addr !== addr);
    },

    toggleBreakpoint(a) {
      const bp = { ...this.breakpoints };
      if (bp[a]) delete bp[a]; else bp[a] = true;
      this.breakpoints = bp;
    },

    reset() {
      if (!this.loaded) return;
      if (this.running) { this.running = false; }
      this.history     = [];
      this.breakpoints = {};
      this.symbols      = {};
      this.addrToSymbol = {};
      this.addrToLine   = {};
      this.exports.vm_reset();
      this.exports.vm_clear_dirty();
      if (this._memoryShadow) this._memoryShadow.fill(0);
      this.syncState();
      this.memPage = 0;
      this.status  = 'Ready';
      this.ioCardPos = 0;
      this.ioTtyPos  = 0;
      this.tapes = Array.from({length: 8}, () => ({ blocks: [], pos: 0 }));
      this.disks = Array.from({length: 8}, () => ({ blocks: {} }));
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

        this.exports.vm_reset();
        this.history      = [];
        this.symbols      = {};
        this.addrToSymbol = {};
        this.addrToLine   = {};
        this.ioCardPos = 0;
        this.ioTtyPos  = 0;
        this.tapes = Array.from({length: 8}, () => ({ blocks: [], pos: 0 }));
        this.disks = Array.from({length: 8}, () => ({ blocks: {} }));

        const { startAddr, loaded, minAddr, maxAddr } = this.parseMix(buf);

        this.exports.vm_set_pc(startAddr);
        this.exports.vm_clear_dirty();
        this._memoryShadow.set(this.memView);
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

    prevPage() {
      if (this.followPc) this.memPage = Math.max(0, Math.floor(this.viewStart / PAGE_SIZE) - 1);
      else this.memPage = Math.max(0, this.memPage - 1);
      this.followPc = false;
    },
    nextPage() {
      if (this.followPc) this.memPage = Math.min(this.totalPages - 1, Math.floor(this.viewStart / PAGE_SIZE) + 1);
      else this.memPage = Math.min(this.totalPages - 1, this.memPage + 1);
      this.followPc = false;
    },
    jumpToPC() {
      this.followPc  = true;
      this.viewStart = Math.max(0, this.pc - 2);  // show PC near top, then auto-scroll will adjust
      this._autoScroll();
    },
    jumpToAddr() {
      const addr = parseInt(this.gotoAddr, 10);
      if (!isNaN(addr) && addr >= 0 && addr < 4000) {
        this.memPage  = Math.floor(addr / PAGE_SIZE);
        this.followPc = false;
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
      this.history   = [];
      this.ioCardPos = 0;
      this.ioTtyPos  = 0;
      this.tapes = Array.from({length: 8}, () => ({ blocks: [], pos: 0 }));
      this.disks = Array.from({length: 8}, () => ({ blocks: {} }));
      for (const { addr, value } of result.words) {
        this.exports.vm_write_word(addr, value);
      }
      this.exports.vm_set_pc(result.startAddr);

      // Save symbol table, reverse map, and source annotation
      this.symbols = result.symbols ?? {};
      this.addrToSymbol = {};
      for (const [name, addr] of Object.entries(this.symbols)) {
        if (!this.addrToSymbol[addr]) this.addrToSymbol[addr] = name;
      }
      this.addrToLine = result.addrToLine ?? {};

      // Sync shadow so step-back delta tracking starts clean
      this.exports.vm_clear_dirty();
      this._memoryShadow.set(this.memView);

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

    // ── I/O handling ─────────────────────────────────────────────────────────

    // Called after every vm_step() to process any I/O instruction that ran.
    handlePendingIo() {
      const e = this.exports;
      const kind = e.vm_get_io_kind();
      if (kind === 0) return;
      const device = e.vm_get_io_device();
      const addr   = e.vm_get_io_addr();
      const m      = e.vm_get_io_m();
      e.vm_clear_io();
      switch (kind) {
        case 1: this.ioOut(device, addr); break;
        case 2: this.ioIn(device, addr);  break;
        case 3: this.ioControl(device, m); break;
      }
    },

    // OUT M,F  — write one block from memory[addr..addr+blockWords-1] to device F
    ioOut(device, memAddr) {
      const n = blockWords(device);
      if (!n) return;
      if (device <= 15) {
        // Binary device: store raw word values
        const words = [];
        for (let i = 0; i < n; i++) words.push(this.exports.vm_read_word(memAddr + i));
        if (device <= 7) {
          const t = this.tapes[device];
          t.blocks[t.pos] = words;
          t.pos++;
          this.tapes = [...this.tapes];  // trigger reactivity
        } else {
          const blk = this.exports.vm_get_reg_x();
          this.disks[device - 8].blocks[blk] = words;
          this.disks = [...this.disks];
        }
        return;
      }
      // Character device: decode 5 MIX bytes per word → text
      let text = '';
      for (let i = 0; i < n; i++) {
        const off = (memAddr + i) * 6;
        for (let b = 0; b < 5; b++) text += MIX_CHARSET[this.memView[off + b]] ?? ' ';
      }
      text = text.trimEnd();
      if      (device === 17) this.ioCardPunch += text + '\n';
      else if (device === 18) this.ioPrinter   += text + '\n';
      else if (device === 19) this.ioTty       += text + '\n';
      else if (device === 20) this.ioPaperTape += text + '\n';
      // Auto-scroll output textareas
      this.$nextTick(() => {
        const id = device === 18 ? 'printerOut' : device === 19 ? 'ttyOut'
                 : device === 17 ? 'cardPunchOut' : 'paperTapeOut';
        const el = document.getElementById(id);
        if (el) el.scrollTop = el.scrollHeight;
      });
    },

    // IN M,F  — read one block from device F into memory[addr..addr+blockWords-1]
    ioIn(device, memAddr) {
      const n = blockWords(device);
      if (!n) return;
      if (device <= 15) {
        // Binary device: restore raw word values
        let words;
        if (device <= 7) {
          const t = this.tapes[device];
          words = t.blocks[t.pos] ?? new Array(n).fill(0);
          t.pos++;
          this.tapes = [...this.tapes];
        } else {
          const blk = this.exports.vm_get_reg_x();
          words = this.disks[device - 8].blocks[blk] ?? new Array(n).fill(0);
        }
        for (let i = 0; i < n; i++) this.exports.vm_write_word(memAddr + i, words[i] ?? 0);
        return;
      }
      // Character device: encode input chars as MIX bytes via vm_write_word (marks dirty)
      const src    = device === 16 ? this.ioCardInput : this.ioTtyInput;
      const posKey = device === 16 ? 'ioCardPos'     : 'ioTtyPos';
      const pos    = this[posKey];
      for (let i = 0; i < n; i++) {
        let v = 0;
        for (let b = 0; b < 5; b++) {
          const ch = ((pos + i * 5 + b) < src.length) ? src[pos + i * 5 + b].toUpperCase() : ' ';
          v = v * 64 + (MIX_CHARMAP[ch] ?? 0);
        }
        this.exports.vm_write_word(memAddr + i, v);
      }
      this[posKey] += n * 5;
    },

    // IOC M,F  — device control
    ioControl(device, m) {
      if (device <= 7) {
        // Tape: rewind if M=0, seek to end if M<0
        const t = this.tapes[device];
        if (m === 0) t.pos = 0;
        else if (m < 0) t.pos = t.blocks.length;
        this.tapes = [...this.tapes];
      } else if (device === 18) {
        // Printer: IOC advances to new page
        this.ioPrinter += '─── new page ───\n';
      }
      // Other character devices: no-op
    },

  }));
});
