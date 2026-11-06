'use strict';

// Exact finite-horizon expectimax for the 5x5 / 8-round bingo game.
//
// The DP keeps two dense 2^25 tables. V stores even-sized decision states and
// G stores the odd-sized 24-way random averages. Values are quantized to
// 1/4096 of a bingo, which keeps both tables at 64 MiB instead of 256 MiB.
// The maximum reachable value is well below 16, so Uint16 cannot overflow.

const FULL = (1 << 25) - 1;
const SCALE = 4096;
const EV_EPS = 0.000002;

const LINE_MASKS = [];
for (let row = 0; row < 5; row++) {
  let mask = 0;
  for (let col = 0; col < 5; col++) mask |= 1 << (row * 5 + col);
  LINE_MASKS.push(mask);
}
for (let col = 0; col < 5; col++) {
  let mask = 0;
  for (let row = 0; row < 5; row++) mask |= 1 << (row * 5 + col);
  LINE_MASKS.push(mask);
}
let diagonalA = 0;
let diagonalB = 0;
for (let i = 0; i < 5; i++) {
  diagonalA |= 1 << (i * 5 + i);
  diagonalB |= 1 << (i * 5 + (4 - i));
}
LINE_MASKS.push(diagonalA, diagonalB);

let values = null;   // Uint16Array(1 << 25), even counts
let scratch = null;  // Uint16Array(1 << 25), odd counts

function post(message) {
  self.postMessage(message);
}

function popcount32(x) {
  x = x - ((x >>> 1) & 0x55555555);
  x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
  x = (x + (x >>> 4)) & 0x0f0f0f0f;
  return (x * 0x01010101) >>> 24;
}

function lineCount(mask) {
  let count = 0;
  for (let i = 0; i < 12; i++) {
    if ((mask & LINE_MASKS[i]) === LINE_MASKS[i]) count++;
  }
  return count;
}

function nextCombination(x) {
  const u = x & -x;
  const v = x + u;
  return v + (((v ^ x) / u) >> 2);
}

function forEachCombination(k, fn) {
  if (k === 0) {
    fn(0);
    return;
  }
  let mask = (1 << k) - 1;
  while (mask <= FULL) {
    fn(mask);
    if (mask === FULL) break;
    mask = nextCombination(mask);
  }
}

function buildPolicy() {
  const started = performance.now();
  post({ type: 'progress', percent: 2, label: 'Allocating the exact policy tables...' });

  values = new Uint16Array(1 << 25);
  scratch = new Uint16Array(1 << 25);

  forEachCombination(16, (mask) => {
    values[mask] = lineCount(mask) * SCALE;
  });
  post({ type: 'progress', percent: 7, label: 'Scoring 2,042,975 terminal boards...' });

  for (let k = 14; k >= 0; k -= 2) {
    const oddCount = k + 1;

    forEachCombination(oddCount, (mask) => {
      let sum = 0;
      let count = 0;
      let missing = FULL ^ mask;
      while (missing) {
        const bit = missing & -missing;
        sum += values[mask | bit];
        count++;
        missing ^= bit;
      }
      scratch[mask] = Math.round(sum / count);
    });

    forEachCombination(k, (mask) => {
      let best = 0;
      let missing = FULL ^ mask;
      while (missing) {
        const bit = missing & -missing;
        const candidate = scratch[mask | bit];
        if (candidate > best) best = candidate;
        missing ^= bit;
      }
      values[mask] = best;
    });

    const completed = (14 - k) / 2 + 1;
    const percent = 8 + (completed / 8) * 90;
    post({
      type: 'progress',
      percent,
      label: k > 0
        ? `Resolving positions with ${k / 2} rounds left...`
        : 'Finalizing the policy...',
    });
  }

  scratch = null;
  const elapsed = performance.now() - started;
  post({
    type: 'ready',
    solveMs: elapsed,
    opening: values[0] / SCALE,
  });
}

function candidateBetter(a, b) {
  if (!b) return true;
  const difference = a.ev - b.ev;
  if (difference > EV_EPS) return true;
  if (difference < -EV_EPS) return false;

  if (a.completes !== b.completes) return a.completes > b.completes;
  if (a.threats !== b.threats) return a.threats > b.threats;
  if (a.lines !== b.lines) return a.lines > b.lines;

  const aRow = (a.cell / 5) | 0;
  const aCol = a.cell % 5;
  const bRow = (b.cell / 5) | 0;
  const bCol = b.cell % 5;
  const aCenter = (2 - aRow) * (2 - aRow) + (2 - aCol) * (2 - aCol);
  const bCenter = (2 - bRow) * (2 - bRow) + (2 - bCol) * (2 - bCol);
  if (aCenter !== bCenter) return aCenter < bCenter;
  return a.cell < b.cell;
}

function analyze(mask, marked, seq) {
  if (!values) {
    post({ type: 'analysis', seq, error: 'Policy is not ready.' });
    return;
  }

  const candidates = [];

  if (marked < 16 && marked % 2 === 0) {
    let best = null;
    const denominator = 24 - marked;

    for (let cell = 0; cell < 25; cell++) {
      const bit = 1 << cell;
      if (mask & bit) continue;

      const afterPlayer = mask | bit;
      let missing = FULL ^ afterPlayer;
      let sum = 0;
      while (missing) {
        const q = missing & -missing;
        sum += values[afterPlayer | q];
        missing ^= q;
      }

      const candidate = {
        cell,
        ev: sum / denominator / SCALE,
        completes: 0,
        threats: 0,
        lines: 0,
      };

      for (let i = 0; i < 12; i++) {
        const line = LINE_MASKS[i];
        if ((line & bit) === 0) continue;
        const filled = popcount32(afterPlayer & line);
        candidate.lines++;
        if (filled === 5) candidate.completes++;
        else if (filled === 4) candidate.threats++;
      }

      candidates.push(candidate);
      if (candidateBetter(candidate, best)) best = candidate;
    }

    let secondEv = -1;
    for (const candidate of candidates) {
      if (best && candidate.cell === best.cell) continue;
      if (candidate.ev > secondEv) secondEv = candidate.ev;
    }

    post({
      type: 'analysis',
      seq,
      marked,
      projection: best ? best.ev : 0,
      best: best ? best.cell : -1,
      secondEv,
      candidates,
    });
    return;
  }

  if (marked < 16 && marked % 2 === 1) {
    let sum = 0;
    let count = 0;
    let missing = FULL ^ mask;
    while (missing) {
      const q = missing & -missing;
      sum += values[mask | q];
      count++;
      missing ^= q;
    }
    post({
      type: 'analysis',
      seq,
      marked,
      projection: sum / count / SCALE,
      best: -1,
      secondEv: -1,
      candidates: [],
    });
    return;
  }

  post({
    type: 'analysis',
    seq,
    marked,
    projection: lineCount(mask),
    best: -1,
    secondEv: -1,
    candidates: [],
  });
}

self.onmessage = (event) => {
  const message = event.data || {};
  if (message.type !== 'analyze') return;
  try {
    analyze(message.mask >>> 0, message.marked | 0, message.seq | 0);
  } catch (error) {
    post({
      type: 'analysis',
      seq: message.seq | 0,
      error: error && error.message ? error.message : String(error),
    });
  }
};

try {
  buildPolicy();
} catch (error) {
  post({
    type: 'error',
    message: error && error.message ? error.message : String(error),
  });
}
