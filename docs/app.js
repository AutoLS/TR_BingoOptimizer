'use strict';

const LETTERS = ['B', 'I', 'N', 'G', 'O'];
const FULL = (1 << 25) - 1;
const EV_EPS = 0.000002;

const LINE_DEFS = [];
for (let row = 0; row < 5; row++) {
  const cells = [];
  let mask = 0;
  for (let col = 0; col < 5; col++) {
    cells.push(row * 5 + col);
    mask |= 1 << (row * 5 + col);
  }
  LINE_DEFS.push({ cells, mask });
}
for (let col = 0; col < 5; col++) {
  const cells = [];
  let mask = 0;
  for (let row = 0; row < 5; row++) {
    cells.push(row * 5 + col);
    mask |= 1 << (row * 5 + col);
  }
  LINE_DEFS.push({ cells, mask });
}
{
  const a = [];
  const b = [];
  let ma = 0;
  let mb = 0;
  for (let i = 0; i < 5; i++) {
    a.push(i * 5 + i);
    b.push(i * 5 + (4 - i));
    ma |= 1 << (i * 5 + i);
    mb |= 1 << (i * 5 + (4 - i));
  }
  LINE_DEFS.push({ cells: a, mask: ma });
  LINE_DEFS.push({ cells: b, mask: mb });
}

const state = {
  ready: false,
  marks: new Array(25).fill(0),
  phase: 'PLAYER',
  attempts: 0,
  pending: -1,
  history: [],
  marked: 0,
  candidates: [],
  best: -1,
  secondEv: -1,
  projection: null,
  showEV: true,
  request: 0,
  lineCounts: new Array(12).fill(0),
  completeLines: new Array(12).fill(false),
  bingoCells: new Set(),
};

const els = {
  stage: document.getElementById('stage'),
  statusPill: document.getElementById('statusPill'),
  statusText: document.getElementById('statusText'),
  boardCard: document.getElementById('boardCard'),
  boardCount: document.getElementById('boardCount'),
  colLabels: document.getElementById('colLabels'),
  rowLabels: document.getElementById('rowLabels'),
  boardGrid: document.getElementById('boardGrid'),
  bingoLines: document.getElementById('bingoLines'),
  bingosNow: document.getElementById('bingosNow'),
  projection: document.getElementById('projection'),
  projectionSub: document.getElementById('projectionSub'),
  attemptFraction: document.getElementById('attemptFraction'),
  pips: document.getElementById('pips'),
  attemptHint: document.getElementById('attemptHint'),
  instructionCard: document.getElementById('instructionCard'),
  instructionStep: document.getElementById('instructionStep'),
  instructionTitle: document.getElementById('instructionTitle'),
  instructionSub: document.getElementById('instructionSub'),
  recommendationCard: document.getElementById('recommendationCard'),
  recLabel: document.getElementById('recLabel'),
  recSide: document.getElementById('recSide'),
  recPlayer: document.getElementById('recPlayer'),
  recAwait: document.getElementById('recAwait'),
  recDone: document.getElementById('recDone'),
  bestCoord: document.getElementById('bestCoord'),
  bestEv: document.getElementById('bestEv'),
  recRank: document.getElementById('recRank'),
  recEdge: document.getElementById('recEdge'),
  recInsight1: document.getElementById('recInsight1'),
  recInsight2: document.getElementById('recInsight2'),
  finalScore: document.getElementById('finalScore'),
  optionsBody: document.getElementById('optionsBody'),
  pressureComplete: document.getElementById('pressureComplete'),
  pressureSegments: document.getElementById('pressureSegments'),
  pressureSummary: document.getElementById('pressureSummary'),
  undoButton: document.getElementById('undoButton'),
  resetButton: document.getElementById('resetButton'),
  heatButton: document.getElementById('heatButton'),
  loader: document.getElementById('loader'),
  loaderBar: document.getElementById('loaderBar'),
  loaderLabel: document.getElementById('loaderLabel'),
  loaderPercent: document.getElementById('loaderPercent'),
};

let worker = null;
const cells = [];
const svgLines = [];
const pips = [];
const segments = [];

/* -------------------------------------------------------------------------- */
/* Stage fit                                                                  */
/* -------------------------------------------------------------------------- */

function fitStage() {
  if (window.innerWidth <= 900) {
    document.documentElement.style.setProperty('--stage-scale', '1');
    return;
  }
  const scale = Math.min(window.innerWidth / 1360, window.innerHeight / 860);
  document.documentElement.style.setProperty('--stage-scale', String(scale));
}

window.addEventListener('resize', fitStage);
window.addEventListener('orientationchange', () => setTimeout(fitStage, 80));

/* -------------------------------------------------------------------------- */
/* Board construction                                                         */
/* -------------------------------------------------------------------------- */

function cellName(index) {
  return `${LETTERS[index % 5]}-${Math.floor(index / 5) + 1}`;
}

function buildBoard() {
  for (let col = 0; col < 5; col++) {
    const label = document.createElement('span');
    label.textContent = LETTERS[col];
    label.style.left = `${col * 126 + 58}px`;
    els.colLabels.appendChild(label);
  }

  for (let row = 0; row < 5; row++) {
    const label = document.createElement('span');
    label.textContent = String(row + 1);
    label.style.top = `${row * 126 + 58}px`;
    els.rowLabels.appendChild(label);
  }

  for (let index = 0; index < 25; index++) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'cell';
    button.dataset.index = String(index);
    button.setAttribute('role', 'gridcell');
    button.innerHTML = `
      <span class="cell-coord"></span>
      <span class="cell-target"></span>
      <span class="cell-ev"></span>
      <span class="ev-bar"><i></i></span>
      <span class="best-sparkle" aria-hidden="true"></span>
      <span class="mark" aria-hidden="true">
        <span class="mark-ring"></span>
        <span class="mark-label"></span>
      </span>
    `;
    button.querySelector('.cell-coord').textContent = cellName(index);
    button.addEventListener('click', () => onCellClick(index));
    els.boardGrid.appendChild(button);
    cells.push(button);
  }

  for (let line = 0; line < LINE_DEFS.length; line++) {
    const def = LINE_DEFS[line];
    const first = def.cells[0];
    const last = def.cells[def.cells.length - 1];
    const a = cellCenter(first);
    const b = cellCenter(last);
    const el = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    el.setAttribute('x1', String(a.x));
    el.setAttribute('y1', String(a.y));
    el.setAttribute('x2', String(b.x));
    el.setAttribute('y2', String(b.y));
    els.bingoLines.appendChild(el);
    svgLines.push(el);
  }
  // Keep the line layer above the tiles but below the daubers.
  els.boardGrid.appendChild(els.bingoLines);

  for (let i = 0; i < 8; i++) {
    const pip = document.createElement('span');
    pip.className = 'pip';
    els.pips.appendChild(pip);
    pips.push(pip);
  }

  for (let i = 0; i < 12; i++) {
    const segment = document.createElement('span');
    segment.className = 'segment';
    els.pressureSegments.appendChild(segment);
    segments.push(segment);
  }
}

function cellCenter(index) {
  return {
    x: (index % 5) * 126 + 58,
    y: Math.floor(index / 5) * 126 + 58,
  };
}

/* -------------------------------------------------------------------------- */
/* Game state                                                                 */
/* -------------------------------------------------------------------------- */

function computeMask() {
  let mask = 0;
  for (let i = 0; i < 25; i++) if (state.marks[i]) mask |= 1 << i;
  return mask;
}

function countLines(mask) {
  const counts = new Array(12).fill(0);
  const complete = new Array(12).fill(false);
  const bingoCells = new Set();
  for (let i = 0; i < LINE_DEFS.length; i++) {
    const line = LINE_DEFS[i];
    let filled = 0;
    for (const cell of line.cells) if (mask & (1 << cell)) filled++;
    counts[i] = filled;
    if (filled === 5) {
      complete[i] = true;
      for (const cell of line.cells) bingoCells.add(cell);
    }
  }
  return { counts, complete, bingoCells };
}

function currentBingos() {
  return state.completeLines.reduce((sum, value) => sum + (value ? 1 : 0), 0);
}

function onCellClick(index) {
  if (!state.ready) return;

  if (state.phase === 'PLAYER') {
    if (state.marks[index] !== 0) return;
    state.marks[index] = 1;
    state.pending = index;
    state.marked++;
    state.phase = 'RANDOM';
    render();
    analyze();
    return;
  }

  if (state.phase === 'RANDOM') {
    if (state.marks[index] !== 0) return;
    if (index === state.pending) return;
    state.marks[index] = 2;
    state.marked++;
    state.history.push({ player: state.pending, random: index });
    state.attempts++;
    state.pending = -1;
    state.phase = state.attempts >= 8 ? 'DONE' : 'PLAYER';
    render();
    analyze();
  }
}

function undo() {
  if (!state.ready) return;

  if (state.phase === 'RANDOM' && state.pending >= 0) {
    state.marks[state.pending] = 0;
    state.marked--;
    state.pending = -1;
    state.phase = 'PLAYER';
    render();
    analyze();
    return;
  }

  const last = state.history.pop();
  if (!last) return;
  state.marks[last.player] = 0;
  state.marks[last.random] = 0;
  state.marked -= 2;
  state.attempts--;
  state.pending = -1;
  state.phase = 'PLAYER';
  render();
  analyze();
}

function reset() {
  if (!state.ready) return;
  state.marks.fill(0);
  state.phase = 'PLAYER';
  state.attempts = 0;
  state.pending = -1;
  state.history.length = 0;
  state.marked = 0;
  state.candidates = [];
  state.best = -1;
  state.secondEv = -1;
  state.projection = null;
  state.lineCounts.fill(0);
  state.completeLines.fill(false);
  state.bingoCells.clear();
  render();
  analyze();
}

function toggleEV() {
  if (!state.ready) return;
  state.showEV = !state.showEV;
  els.heatButton.classList.toggle('active', state.showEV);
  els.heatButton.setAttribute('aria-pressed', String(state.showEV));
  renderBoard();
}

/* -------------------------------------------------------------------------- */
/* Worker                                                                     */
/* -------------------------------------------------------------------------- */

function startWorker() {
  try {
    worker = new Worker('solver-worker.js');
  } catch (error) {
    showLoadError(error);
    return;
  }

  worker.onmessage = (event) => {
    const message = event.data || {};
    if (message.type === 'progress') {
      setProgress(message.percent || 0, message.label || 'Building policy...');
      return;
    }
    if (message.type === 'ready') {
      state.ready = true;
      setProgress(100, 'Policy ready.');
      els.statusPill.classList.remove('building');
      els.statusText.textContent = 'POLICY READY';
      els.loader.classList.add('hidden');
      analyze();
      return;
    }
    if (message.type === 'error') {
      showLoadError(message.message || 'Policy build failed.');
      return;
    }
    if (message.type === 'analysis') {
      if (!state.ready || message.seq !== state.request) return;
      if (message.error) {
        console.error(message.error);
        return;
      }
      state.candidates = Array.isArray(message.candidates) ? message.candidates : [];
      state.best = message.best;
      state.secondEv = message.secondEv;
      state.projection = message.projection;
      render();
    }
  };

  worker.onerror = (error) => {
    console.error(error);
    showLoadError(error.message || 'The solver worker could not start.');
  };
}

function setProgress(percent, label) {
  const clamped = Math.max(0, Math.min(100, percent));
  els.loaderBar.style.width = `${clamped}%`;
  els.loaderPercent.textContent = `${Math.round(clamped)}%`;
  if (label) els.loaderLabel.textContent = label;
}

function showLoadError(error) {
  els.loader.classList.add('error');
  els.loaderPercent.textContent = '!';
  els.loaderLabel.textContent = 'Unable to build the exact policy.';
  els.loaderBar.style.width = '100%';
  const copy = els.loader.querySelector('.loader-copy');
  if (copy) {
    copy.textContent = `${error && error.message ? error.message : error}. Try a current desktop browser with Web Workers enabled.`;
  }
  els.statusPill.classList.add('building');
  els.statusText.textContent = 'POLICY ERROR';
}

function analyze() {
  if (!state.ready || !worker) return;
  const mask = computeMask();
  const seq = ++state.request;
  worker.postMessage({ type: 'analyze', mask, marked: state.marked, seq });
}

/* -------------------------------------------------------------------------- */
/* Rendering                                                                  */
/* -------------------------------------------------------------------------- */

function compareCandidates(a, b) {
  const difference = a.ev - b.ev;
  if (difference > EV_EPS) return -1;
  if (difference < -EV_EPS) return 1;
  if (a.completes !== b.completes) return b.completes - a.completes;
  if (a.threats !== b.threats) return b.threats - a.threats;
  if (a.lines !== b.lines) return b.lines - a.lines;
  const aRow = Math.floor(a.cell / 5);
  const aCol = a.cell % 5;
  const bRow = Math.floor(b.cell / 5);
  const bCol = b.cell % 5;
  const aCenter = (2 - aRow) ** 2 + (2 - aCol) ** 2;
  const bCenter = (2 - bRow) ** 2 + (2 - bCol) ** 2;
  if (aCenter !== bCenter) return aCenter - bCenter;
  return a.cell - b.cell;
}

function render() {
  const info = countLines(computeMask());
  state.lineCounts = info.counts;
  state.completeLines = info.complete;
  state.bingoCells = info.bingoCells;

  renderBoard();
  renderMetrics();
  renderAttempts();
  renderInstruction();
  renderRecommendation();
  renderOptions();
  renderPressure();
  renderControls();
}

function renderBoard() {
  const info = state.completeLines;
  const evByCell = new Map();
  let minEv = Infinity;
  let maxEv = -Infinity;

  if (state.phase === 'PLAYER') {
    for (const candidate of state.candidates) {
      evByCell.set(candidate.cell, candidate);
      if (candidate.ev < minEv) minEv = candidate.ev;
      if (candidate.ev > maxEv) maxEv = candidate.ev;
    }
  }

  const bingos = currentBingos();
  els.boardCount.textContent = `${bingos} / 12 BINGOS`;
  els.boardCount.classList.toggle('has-bingo', bingos > 0);
  els.boardCard.classList.add('board');
  els.boardCard.classList.toggle('phase-player', state.phase === 'PLAYER');
  els.boardCard.classList.toggle('phase-random', state.phase === 'RANDOM');
  els.boardCard.classList.toggle('phase-done', state.phase === 'DONE');
  els.boardCard.classList.toggle('ev-hidden', !state.showEV);

  for (let index = 0; index < 25; index++) {
    const button = cells[index];
    const mark = state.marks[index];
    const candidate = evByCell.get(index);
    const isBest = state.phase === 'PLAYER' && index === state.best;
    const onBingo = state.bingoCells.has(index);

    button.classList.toggle('player', mark === 1);
    button.classList.toggle('random', mark === 2);
    button.classList.toggle('best', isBest);
    button.classList.toggle('bingo', onBingo);
    button.setAttribute('aria-disabled', state.phase === 'DONE' || mark !== 0 ? 'true' : 'false');

    const markLabel = button.querySelector('.mark-label');
    markLabel.textContent = mark === 1 ? 'YOU' : mark === 2 ? 'RNG' : '';

    const ev = button.querySelector('.cell-ev');
    const bar = button.querySelector('.ev-bar i');
    if (state.phase === 'PLAYER' && candidate) {
      ev.textContent = candidate.ev.toFixed(3);
      const span = maxEv - minEv;
      const t = span > 0 ? Math.max(0, Math.min(1, (candidate.ev - minEv) / span)) : 1;
      bar.style.width = `${12 + 34 * t}px`;
    } else {
      ev.textContent = '';
      bar.style.width = '0';
    }

    let label = cellName(index);
    if (mark === 1) label += ', your mark';
    if (mark === 2) label += ', random mark';
    if (isBest) label += ', best next move';
    if (candidate) label += `, expected final ${candidate.ev.toFixed(3)}`;
    button.setAttribute('aria-label', label);
  }

  for (let i = 0; i < svgLines.length; i++) {
    svgLines[i].classList.toggle('active', Boolean(info[i]));
  }
}

function renderMetrics() {
  const bingos = currentBingos();
  els.bingosNow.textContent = String(bingos);

  if (state.projection !== null && Number.isFinite(state.projection)) {
    els.projection.textContent = state.projection.toFixed(2);
  } else {
    els.projection.textContent = '--';
  }

  let sub = 'exact optimal value';
  if (state.phase === 'RANDOM') sub = 'random mark pending';
  if (state.phase === 'DONE') sub = 'final result';
  els.projectionSub.textContent = sub;
}

function renderAttempts() {
  const current = state.phase === 'DONE' ? 8 : Math.min(8, state.attempts + 1);
  els.attemptFraction.textContent = `${current} / 8`;

  for (let i = 0; i < pips.length; i++) {
    const completed = i < state.attempts || state.phase === 'DONE';
    const pending = i === state.attempts && state.phase === 'RANDOM';
    pips[i].classList.toggle('complete', completed);
    pips[i].classList.toggle('pending', pending && !completed);
  }

  els.attemptHint.textContent = state.phase === 'DONE'
    ? 'All eight rounds are complete.'
    : 'Every round marks one pick plus one random square.';
}

function renderInstruction() {
  els.instructionCard.dataset.phase = state.phase.toLowerCase();
  if (state.phase === 'PLAYER') {
    els.instructionStep.textContent = 'STEP 1 OF 2';
    els.instructionTitle.textContent = 'Mark your chosen square.';
    els.instructionSub.textContent = 'Click a cell on the board. The best next move is in gold.';
  } else if (state.phase === 'RANDOM') {
    els.instructionStep.textContent = 'STEP 2 OF 2';
    els.instructionTitle.textContent = "Record the game's random mark.";
    els.instructionSub.textContent = `Your pick: ${cellName(state.pending)}. Click the square the game marked.`;
  } else {
    els.instructionStep.textContent = 'RUN COMPLETE';
    els.instructionTitle.textContent = 'The board is finished.';
    els.instructionSub.textContent = `${currentBingos()} bingos. Undo the last round or reset.`;
  }
}

function renderRecommendation() {
  const card = els.recommendationCard;
  const hasMove = state.phase === 'PLAYER' && state.best >= 0;
  card.classList.toggle('has-move', hasMove);
  card.classList.toggle('is-await', state.phase === 'RANDOM');
  card.classList.toggle('is-done', state.phase === 'DONE');

  els.recPlayer.hidden = !hasMove;
  els.recAwait.hidden = state.phase !== 'RANDOM';
  els.recDone.hidden = state.phase !== 'DONE';
  els.recSide.textContent = hasMove ? 'EV MAXIMAL' : '';
  els.recLabel.textContent = state.phase === 'DONE'
    ? 'FINAL SCORE'
    : 'NEXT BEST MOVE';

  if (hasMove) {
    const best = state.candidates.find((candidate) => candidate.cell === state.best);
    if (!best) return;
    const legal = 25 - state.marked;
    els.bestCoord.textContent = cellName(best.cell);
    els.bestEv.textContent = best.ev.toFixed(3);
    els.recRank.textContent = `RANK 1 OF ${legal} LEGAL`;

    const edge = state.secondEv >= 0 ? best.ev - state.secondEv : null;
    if (edge === null) {
      els.recEdge.textContent = 'best available move';
    } else if (edge > 0.0005) {
      els.recEdge.textContent = `+${edge.toFixed(4)} over 2nd best`;
    } else {
      els.recEdge.textContent = 'tied with 2nd best';
    }

    if (state.marked === 0) {
      els.recInsight1.textContent = 'Center hub: it touches four different lines.';
    } else if (best.completes > 0) {
      els.recInsight1.textContent = `Completes ${best.completes} line${best.completes === 1 ? '' : 's'} right now.`;
    } else if (best.threats > 0) {
      els.recInsight1.textContent = `Puts ${best.threats} line${best.threats === 1 ? '' : 's'} at four of five.`;
    } else {
      els.recInsight1.textContent = `Builds ${best.lines} line${best.lines === 1 ? '' : 's'} toward a bingo.`;
    }

    if (edge === null || edge <= 0.0005) {
      els.recInsight2.textContent = 'Tied for the best expected final score.';
    } else {
      els.recInsight2.textContent = `Leads the second-best pick by +${edge.toFixed(4)}.`;
    }
  }

  if (state.phase === 'DONE') {
    els.finalScore.textContent = String(currentBingos());
  }
}

function optionStat(candidate) {
  if (candidate.completes > 0) return `completes ${candidate.completes}`;
  if (candidate.threats > 0) return `sets up ${candidate.threats}`;
  return `touches ${candidate.lines}`;
}

function renderOptions() {
  els.optionsBody.textContent = '';
  if (state.phase !== 'PLAYER' || state.candidates.length === 0) {
    const message = document.createElement('p');
    message.className = 'options-message';
    message.textContent = state.phase === 'DONE'
      ? 'Run complete. Undo or reset to review the board.'
      : 'Recommendations appear after each random mark is recorded.';
    els.optionsBody.appendChild(message);
    return;
  }

  const sorted = [...state.candidates].sort(compareCandidates).slice(0, 3);
  for (let rank = 0; rank < sorted.length; rank++) {
    const candidate = sorted[rank];
    const row = document.createElement('div');
    row.className = `option-row${rank === 0 ? ' first' : ''}`;
    row.innerHTML = `
      <span class="option-rank">${rank + 1}</span>
      <span class="option-cell">${cellName(candidate.cell)}</span>
      <span class="option-stat">${optionStat(candidate)}</span>
      <span class="option-ev">${candidate.ev.toFixed(3)}</span>
    `;
    els.optionsBody.appendChild(row);
  }
}

function renderPressure() {
  const counts = state.lineCounts;
  let complete = 0;
  let edge = 0;
  let building = 0;

  for (let i = 0; i < 12; i++) {
    const count = counts[i];
    if (count >= 5) complete++;
    else if (count === 4) edge++;
    else if (count === 3) building++;

    const segment = segments[i];
    segment.className = 'segment';
    if (count >= 5) segment.classList.add('s5');
    else if (count === 4) segment.classList.add('s4');
    else if (count === 3) segment.classList.add('s3');
    else if (count === 2) segment.classList.add('s2');
  }

  els.pressureComplete.textContent = `${complete} COMPLETE`;
  els.pressureComplete.style.color = complete > 0 ? 'var(--green)' : '';
  els.pressureSummary.textContent = `${edge} at 4/5\u00A0\u00A0\u00A0${building} at 3/5`;
}

function renderControls() {
  const canUndo = state.phase === 'RANDOM' || state.history.length > 0;
  els.undoButton.disabled = !canUndo;
  els.heatButton.classList.toggle('active', state.showEV);
  els.heatButton.setAttribute('aria-pressed', String(state.showEV));
}

/* -------------------------------------------------------------------------- */
/* Input                                                                      */
/* -------------------------------------------------------------------------- */

els.undoButton.addEventListener('click', undo);
els.resetButton.addEventListener('click', reset);
els.heatButton.addEventListener('click', toggleEV);

window.addEventListener('keydown', (event) => {
  if (event.ctrlKey || event.metaKey || event.altKey) return;
  const tag = event.target && event.target.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;

  if (event.key === 'z' || event.key === 'Z') {
    event.preventDefault();
    undo();
  } else if (event.key === 'r' || event.key === 'R') {
    event.preventDefault();
    reset();
  } else if (event.key === 'h' || event.key === 'H') {
    event.preventDefault();
    toggleEV();
  }
});

/* -------------------------------------------------------------------------- */
/* Start                                                                      */
/* -------------------------------------------------------------------------- */

fitStage();
buildBoard();
render();
startWorker();
