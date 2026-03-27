'use strict';

// MIX character table: MIX byte value → ASCII character (MDK convention)
const MIX_CHAR_TABLE = ' ABCDEFGHI~JKLMNOPQR`^STUVWXYZ0123456789.,()+-*/=$<>@;:\'';
function charToMix(ch) {
  const idx = MIX_CHAR_TABLE.indexOf(ch.toUpperCase());
  return idx < 0 ? 0 : idx;
}

// Opcode table: name → [C, defaultF]
// For sub-opcode groups (JMP/JAN/INC etc.) the named entry bakes F in.
const ASM_OPS = {
  'NOP': [0,0],
  'ADD': [1,5], 'SUB': [2,5], 'MUL': [3,5], 'DIV': [4,5],
  'NUM': [5,0], 'CHAR': [5,1], 'HLT': [5,2],
  'SLA': [6,0], 'SRA': [6,1], 'SLAX': [6,2], 'SRAX': [6,3], 'SLC': [6,4], 'SRC': [6,5],
  'MOVE': [7,1],
  'LDA': [8,5], 'LD1': [9,5], 'LD2': [10,5], 'LD3': [11,5],
  'LD4': [12,5], 'LD5': [13,5], 'LD6': [14,5], 'LDX': [15,5],
  'LDAN': [16,5], 'LD1N': [17,5], 'LD2N': [18,5], 'LD3N': [19,5],
  'LD4N': [20,5], 'LD5N': [21,5], 'LD6N': [22,5], 'LDXN': [23,5],
  'STA': [24,5], 'ST1': [25,5], 'ST2': [26,5], 'ST3': [27,5],
  'ST4': [28,5], 'ST5': [29,5], 'ST6': [30,5], 'STX': [31,5],
  'STJ': [32,2], 'STZ': [33,5],
  'JBUS': [34,0], 'IOC': [35,0], 'IN': [36,0], 'OUT': [37,0], 'JRED': [38,0],
  'JMP':  [39,0], 'JSJ':  [39,1], 'JOV':  [39,2], 'JNOV': [39,3],
  'JL':   [39,4], 'JE':   [39,5], 'JG':   [39,6], 'JGE':  [39,7],
  'JNE':  [39,8], 'JLE':  [39,9],
  'JAN':  [40,0], 'JAZ':  [40,1], 'JAP':  [40,2], 'JANN': [40,3], 'JANZ': [40,4], 'JANP': [40,5],
  'J1N':  [41,0], 'J1Z':  [41,1], 'J1P':  [41,2], 'J1NN': [41,3], 'J1NZ': [41,4], 'J1NP': [41,5],
  'J2N':  [42,0], 'J2Z':  [42,1], 'J2P':  [42,2], 'J2NN': [42,3], 'J2NZ': [42,4], 'J2NP': [42,5],
  'J3N':  [43,0], 'J3Z':  [43,1], 'J3P':  [43,2], 'J3NN': [43,3], 'J3NZ': [43,4], 'J3NP': [43,5],
  'J4N':  [44,0], 'J4Z':  [44,1], 'J4P':  [44,2], 'J4NN': [44,3], 'J4NZ': [44,4], 'J4NP': [44,5],
  'J5N':  [45,0], 'J5Z':  [45,1], 'J5P':  [45,2], 'J5NN': [45,3], 'J5NZ': [45,4], 'J5NP': [45,5],
  'J6N':  [46,0], 'J6Z':  [46,1], 'J6P':  [46,2], 'J6NN': [46,3], 'J6NZ': [46,4], 'J6NP': [46,5],
  'JXN':  [47,0], 'JXZ':  [47,1], 'JXP':  [47,2], 'JXNN': [47,3], 'JXNZ': [47,4], 'JXNP': [47,5],
  'INCA': [48,0], 'DECA': [48,1], 'ENTA': [48,2], 'ENNA': [48,3],
  'INC1': [49,0], 'DEC1': [49,1], 'ENT1': [49,2], 'ENN1': [49,3],
  'INC2': [50,0], 'DEC2': [50,1], 'ENT2': [50,2], 'ENN2': [50,3],
  'INC3': [51,0], 'DEC3': [51,1], 'ENT3': [51,2], 'ENN3': [51,3],
  'INC4': [52,0], 'DEC4': [52,1], 'ENT4': [52,2], 'ENN4': [52,3],
  'INC5': [53,0], 'DEC5': [53,1], 'ENT5': [53,2], 'ENN5': [53,3],
  'INC6': [54,0], 'DEC6': [54,1], 'ENT6': [54,2], 'ENN6': [54,3],
  'INCX': [55,0], 'DECX': [55,1], 'ENTX': [55,2], 'ENNX': [55,3],
  'CMPA': [56,5], 'CMP1': [57,5], 'CMP2': [58,5], 'CMP3': [59,5],
  'CMP4': [60,5], 'CMP5': [61,5], 'CMP6': [62,5], 'CMPX': [63,5],
};

// ── Assemble MIXAL source → [{addr, value}] ──────────────────────────────────
function assembleMixal(source) {
  const errors = [];

  // ── 1. Parse lines into tokens ─────────────────────────────────────────
  const lines = source.split('\n').map((raw, idx) => {
    const lineNum = idx + 1;
    const r = raw.replace(/\r$/, '');

    // Blank or full-line comment
    if (!r.trim() || /^[ \t]*\*/.test(r)) return { lineNum, raw: r, skip: true };

    let pos = 0;
    let label = '';

    // Label: starts at column 0 (no leading whitespace)
    if (r.length > 0 && r[0] !== ' ' && r[0] !== '\t') {
      while (pos < r.length && r[pos] !== ' ' && r[pos] !== '\t') pos++;
      label = r.slice(0, pos).toUpperCase();
    }
    while (pos < r.length && (r[pos] === ' ' || r[pos] === '\t')) pos++;

    // Comment after label only
    if (pos >= r.length || r[pos] === '*')
      return { lineNum, raw: r, label, opcode: '', operand: '', skip: false };

    // Opcode
    const opStart = pos;
    while (pos < r.length && r[pos] !== ' ' && r[pos] !== '\t') pos++;
    const opcode = r.slice(opStart, pos).toUpperCase();
    while (pos < r.length && (r[pos] === ' ' || r[pos] === '\t')) pos++;

    // Operand: quoted strings count as single token (don't stop at space inside quotes)
    const opndStart = pos;
    if (pos < r.length && (r[pos] === '"' || r[pos] === "'")) {
      const q = r[pos++];
      while (pos < r.length && r[pos] !== q) pos++;
      if (pos < r.length) pos++;  // consume closing quote
    } else {
      while (pos < r.length && r[pos] !== ' ' && r[pos] !== '\t') pos++;
    }
    const operand = r.slice(opndStart, pos);

    return { lineNum, raw: r, label, opcode, operand, skip: false };
  });

  // ── 2. Symbol table + expression evaluator ─────────────────────────────
  const symbols = {};

  function evalExpr(expr, loc) {
    const s = expr.trim();
    if (!s) return 0;
    // Tokenize
    const tokens = [];
    let i = 0;
    while (i < s.length) {
      const ch = s[i];
      if (ch === ' ' || ch === '\t') { i++; continue; }
      if (ch >= '0' && ch <= '9') {
        let n = '';
        while (i < s.length && s[i] >= '0' && s[i] <= '9') n += s[i++];
        // Local label reference: nB (backward) or nF (forward)
        if (i < s.length && (s[i] === 'B' || s[i] === 'b' || s[i] === 'F' || s[i] === 'f')) {
          const dir = s[i++].toUpperCase();
          const digit = parseInt(n, 10);
          const defs = localDefs[digit] || [];
          let target;
          if (dir === 'B') {
            const prev = defs.filter(a => a <= loc);
            target = prev.length > 0 ? Math.max(...prev) : undefined;
          } else {
            const next = defs.filter(a => a > loc);
            target = next.length > 0 ? Math.min(...next) : undefined;
          }
          if (target === undefined) throw new Error(`No local label ${digit}H found ${dir === 'B' ? 'before' : 'after'} loc ${loc}`);
          tokens.push({ t: 'v', v: target });
        } else {
          tokens.push({ t: 'v', v: parseInt(n, 10) });
        }
      } else if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) {
        let sym = '';
        while (i < s.length && /[A-Za-z0-9]/.test(s[i])) sym += s[i++];
        sym = sym.toUpperCase();
        if (!(sym in symbols)) throw new Error(`Undefined symbol '${sym}'`);
        tokens.push({ t: 'v', v: symbols[sym] });
      } else if (ch === '*') {
        // If previous token is a value → multiply operator; else → location counter
        const prev = tokens[tokens.length - 1];
        if (prev && prev.t === 'v') tokens.push({ t: 'op', v: '*' });
        else {
          if (loc === undefined) throw new Error('Location counter (*) not available here');
          tokens.push({ t: 'v', v: loc });
        }
        i++;
      } else if (ch === '+') { tokens.push({ t: 'op', v: '+' }); i++; }
      else if (ch === '-') { tokens.push({ t: 'op', v: '-' }); i++; }
      else if (ch === '/') {
        if (s[i+1] === '/') { tokens.push({ t: 'op', v: '//' }); i += 2; }
        else { tokens.push({ t: 'op', v: '/' }); i++; }
      } else if (ch === ':') { tokens.push({ t: 'op', v: ':' }); i++; }
      else i++;
    }
    if (!tokens.length) return 0;

    // MIXAL evaluates strictly left-to-right (no precedence)
    let acc = 0, op = '+';
    for (const tok of tokens) {
      if (tok.t === 'v') {
        switch (op) {
          case '+':  acc += tok.v; break;
          case '-':  acc -= tok.v; break;
          case '*':  acc *= tok.v; break;
          case '/':  acc = Math.trunc(acc / tok.v); break;
          case '//': acc = Math.floor(acc / tok.v); break;
          case ':':  acc = 8 * acc + tok.v; break;
        }
        op = '+'; // reset after use
      } else {
        op = tok.v;
      }
    }
    return acc;
  }

  // ── 3. Pass 1: collect symbols + literal placeholders ──────────────────
  let loc = 0;
  const litExprs  = [];  // [{expr, addr}] in order of first appearance
  const litMap    = {};  // expr string → index in litExprs
  const localDefs = {};  // n → sorted list of addresses where nH was defined

  function collectLiteral(operand) {
    if (!operand.startsWith('=')) return;
    const end = operand.indexOf('=', 1);
    if (end < 1) return;
    const expr = operand.slice(1, end);
    if (!(expr in litMap)) {
      litMap[expr] = litExprs.length;
      litExprs.push({ expr, addr: -1 });
    }
  }

  for (const line of lines) {
    if (line.skip || !line.opcode) { line.loc = loc; continue; }
    line.loc = loc;
    const { opcode, operand, label, lineNum } = line;

    if (opcode === 'EQU') {
      if (label) {
        try { symbols[label] = evalExpr(operand, loc); }
        catch (e) { errors.push(`Line ${lineNum}: ${e.message}`); symbols[label] = 0; }
      }
    } else if (opcode === 'ORIG') {
      try { loc = evalExpr(operand, loc); }
      catch (e) { errors.push(`Line ${lineNum}: ${e.message}`); }
      line.loc = loc;
    } else if (opcode === 'END') {
      // Assign addresses to accumulated literals
      for (const li of litExprs) { li.addr = loc; loc++; }
      line.loc = loc;
    } else if (opcode === 'CON' || opcode === 'ALF' || opcode in ASM_OPS) {
      if (label) {
        if (/^\d+H$/.test(label)) {
          // Local label nH: register address in localDefs[n]
          const n = parseInt(label.slice(0, -1), 10);
          if (!localDefs[n]) localDefs[n] = [];
          localDefs[n].push(loc);
        } else {
          symbols[label] = loc;
        }
      }
      collectLiteral(operand);
      loc++;
    } else {
      errors.push(`Line ${lineNum}: Unknown opcode '${opcode}'`);
    }
  }

  // Resolve END operand → startAddr
  let startAddr = 0;
  for (const line of lines) {
    if (!line.skip && line.opcode === 'END') {
      try { startAddr = evalExpr(line.operand, 0); }
      catch (e) { errors.push(`END: ${e.message}`); }
      break;
    }
  }

  if (errors.length) return { words: [], startAddr: 0, errors };

  // ── 4. Pass 2: emit words ───────────────────────────────────────────────
  const words = [];

  function emit(addr, value) {
    if (addr < 0 || addr >= 4000) { errors.push(`Address ${addr} out of range`); return; }
    words.push({ addr, value });
  }

  // Encode a MIX instruction as i32 (compatible with vm_write_word)
  function encodeInstr(addr, index, field, c) {
    const sign = addr < 0 ? 1 : 0;
    const aa   = Math.abs(addr) & 0xFFF;      // 12-bit address magnitude
    const a1   = (aa >> 6) & 0x3F;
    const a2   =  aa & 0x3F;
    const mag  = a1 * 16777216 + a2 * 262144 + (index & 0x3F) * 4096
               + (field & 0x3F) * 64 + (c & 0x3F);
    return sign ? -mag : mag;
  }

  // Parse instruction operand  → {addr, index, field}
  function parseOpnd(operand, loc) {
    let s = operand || '0';
    let litAddr = null;

    // Literal constant =expr=
    if (s.startsWith('=')) {
      const end = s.indexOf('=', 1);
      if (end >= 1) {
        const li = litExprs[litMap[s.slice(1, end)]];
        if (li) litAddr = li.addr;
        s = s.slice(end + 1); // keep index/field if any
      }
    }

    // Field spec (L:R) or plain value (device number etc.) — suffix
    let field = null;
    const fp = s.lastIndexOf('(');
    if (fp >= 0 && s.endsWith(')')) {
      const fspec = s.slice(fp + 1, -1);
      const ci = fspec.indexOf(':');
      if (ci >= 0) {
        const L = parseInt(fspec.slice(0, ci), 10);
        const R = parseInt(fspec.slice(ci + 1), 10);
        if (!isNaN(L) && !isNaN(R)) field = 8 * L + R;
      } else {
        // Plain number or symbol (e.g. device unit for I/O, or raw field value)
        try { field = evalExpr(fspec, loc); } catch (_) { /* leave null */ }
      }
      s = s.slice(0, fp);
    }

    // Index register ,n — suffix
    let index = 0;
    const ci = s.lastIndexOf(',');
    if (ci >= 0) {
      index = parseInt(s.slice(ci + 1), 10);
      if (isNaN(index)) index = 0;
      s = s.slice(0, ci);
    }

    // Address expression (or use literal address)
    const addr = litAddr !== null ? litAddr : (s ? evalExpr(s, loc) : 0);
    return { addr, index, field };
  }

  loc = 0;
  for (const line of lines) {
    if (line.skip || !line.opcode) continue;
    loc = line.loc;
    const { opcode, operand, lineNum } = line;

    if (opcode === 'EQU' || opcode === 'END') continue;

    if (opcode === 'ORIG') {
      try { loc = evalExpr(operand, loc); } catch (e) { errors.push(`Line ${lineNum}: ${e.message}`); }
      continue;
    }

    if (opcode === 'CON') {
      try { emit(loc, evalExpr(operand, loc)); }
      catch (e) { errors.push(`Line ${lineNum}: ${e.message}`); }
      continue;
    }

    if (opcode === 'ALF') {
      let chars = operand;
      if ((chars.startsWith('"') && chars.endsWith('"')) ||
          (chars.startsWith("'") && chars.endsWith("'")))
        chars = chars.slice(1, -1);
      while (chars.length < 5) chars += ' ';
      const b = [...chars.slice(0, 5)].map(charToMix);
      emit(loc, b[0]*16777216 + b[1]*262144 + b[2]*4096 + b[3]*64 + b[4]);
      continue;
    }

    if (opcode in ASM_OPS) {
      const [c, defF] = ASM_OPS[opcode];
      try {
        const { addr, index, field } = parseOpnd(operand, loc);
        emit(loc, encodeInstr(addr, index, field !== null ? field : defF, c));
      } catch (e) { errors.push(`Line ${lineNum}: ${e.message}`); }
      continue;
    }
  }

  // Emit literal constant words
  for (const li of litExprs) {
    if (li.addr < 0) continue;
    try { emit(li.addr, evalExpr(li.expr, li.addr)); }
    catch (e) { errors.push(`Literal '=${li.expr}=': ${e.message}`); }
  }

  // Build addr → source-line map for debugger annotation
  const addrToLine = {};
  for (const line of lines) {
    if (line.skip) continue;
    const op = line.opcode;
    if (!op || op === 'EQU' || op === 'ORIG' || op === 'END') continue;
    if (line.loc !== undefined && line.loc >= 0 && line.loc < 4000)
      addrToLine[line.loc] = line.raw.trim();
  }

  return { words, startAddr, errors, symbols, addrToLine };
}
