// ============================================================================
// solver.jai -- Exact finite-horizon expectimax solver for the 5x5 bingo game.
//
// The board is a 25-bit mask. Every round the player marks one square, then
// the game marks one uniformly random other unmarked square. Eight rounds are
// played, so every finished board has exactly 16 marks.
//
// V_k(S) = optimal expected final bingo count with |S| = k marks and
//          8 - k/2 rounds remaining.
//
//   V_16(S) = number of completed lines in S
//   V_k(S)  = max over p in S' of  (1 / (24-k)) * sum over q in S'\p of
//                                       V_{k+2}(S + p + q)
//
// where k is even and S' is the set of unmarked cells. The full table is
// computed bottom-up once at startup (about 0.6 s optimized), then every
// recommendation is exact -- no heuristics, sampling, or lookahead guesses.
// ============================================================================

BOARD_DIM     :: 5;
BOARD_CELLS   :: 25;
BOARD_FULL    : u32 : (1 << 25) - 1;
BINGO_LINES   :: 12;
MAX_ATTEMPTS  :: 8;
MAX_MARKS     :: 16;

// Two values closer than this are treated as a tie. The DP values are
// expectations, and symmetry produces exactly equal values very often.
EV_EPS :: 0.000002;

BINGO_LINE_MASKS : [12] u32;

Solver :: struct {
    // V indexed directly by 25-bit mask. Only masks whose popcount is even
    // are meaningful. Kept for the entire run so later decisions are instant.
    values: [] float;
    // Scratch buffer for the odd-sized intermediate expectation sums.
    // Freed as soon as the table is complete.
    scratch: [] float;

    terminal_done: bool;
    ready: bool;
    stage: int;       // 0 = not started, 1 = terminal done, 9 = complete
    next_k: int;
};

Solver_Candidate :: struct {
    cell: int = -1;
    ev: float = -1.0e30;     // expected final bingo count if this cell is picked
    completes: int;          // lines this immediate mark completes
    threats: int;            // lines that become 4/5 after this mark
    lines: int;              // lines this cell belongs to
};

bit_mask :: (index: int) -> u32 {
    return cast(u32) (1 << index);
}

low_bits :: (count: int) -> u32 {
    if count <= 0 return 0;
    return cast(u32) ((1 << count) - 1);
}

next_combination :: (x: u32) -> u32 {
    // Gosper's hack: next integer with the same number of set bits.
    if x == 0 return 0;
    u := x & (~x + 1);
    v := x + u;
    if v == 0 return 0;
    return v + (((v ^ x) >> 2) / u);
}

count_set_bits :: (value: u32) -> int {
    x := value;
    result := 0;
    while x != 0 {
        x &= x - 1;
        result += 1;
    }
    return result;
}

solver_init_lines :: () {
    for r: 0..4 {
        mask : u32 = 0;
        for c: 0..4 mask |= bit_mask(r*BOARD_DIM + c);
        BINGO_LINE_MASKS[r] = mask;
    }
    for c: 0..4 {
        mask : u32 = 0;
        for r: 0..4 mask |= bit_mask(r*BOARD_DIM + c);
        BINGO_LINE_MASKS[5 + c] = mask;
    }

    mask : u32 = 0;
    for i: 0..4 mask |= bit_mask(i*BOARD_DIM + i);
    BINGO_LINE_MASKS[10] = mask;

    mask = 0;
    for i: 0..4 mask |= bit_mask(i*BOARD_DIM + (4 - i));
    BINGO_LINE_MASKS[11] = mask;
}

bingo_count :: (mask: u32) -> int {
    result := 0;
    for i: 0..BINGO_LINES-1 {
        line := BINGO_LINE_MASKS[i];
        if (mask & line) == line result += 1;
    }
    return result;
}

line_fill_counts :: (mask: u32, candidates_out: *[12] int) {
    for i: 0..BINGO_LINES-1 {
        candidates_out.*[i] = count_set_bits(mask & BINGO_LINE_MASKS[i]);
    }
}

solver_begin :: (solver: *Solver) {
    solver_init_lines();

    solver.values  = NewArray(1 << 25, float, initialized = false);
    solver.scratch = NewArray(1 << 25, float, initialized = false);
    solver.terminal_done = false;
    solver.ready = false;
    solver.stage = 0;
    solver.next_k = 16;
}

solver_destroy :: (solver: *Solver) {
    if solver.values.count  > 0 free(solver.values.data);
    if solver.scratch.count > 0 free(solver.scratch.data);
    solver.values = .[];
    solver.scratch = .[];
    solver.terminal_done = false;
    solver.ready = false;
}

solver_progress :: (solver: *Solver) -> float {
    return clamp(cast(float) solver.stage / 9.0, 0.0, 1.0);
}

solver_build_terminal :: (solver: *Solver) {
    values := solver.values;

    combination : u32 = low_bits(MAX_MARKS);
    while combination != 0 {
        values[combination] = xx bingo_count(combination);

        next := next_combination(combination);
        if next == 0 || next > BOARD_FULL break;
        combination = next;
    }

    solver.terminal_done = true;
    solver.stage = 1;
    solver.next_k = 14;
}

solver_compute_level :: (solver: *Solver, k: int) {
    values := solver.values;
    scratch := solver.scratch;

    // Build G(T) = sum over q not in T of V_{k+2}(T + q), for every odd T
    // of size k+1. This turns each player move's 24 random outcomes into one
    // lookup plus a division.
    combination : u32 = low_bits(k + 1);
    while combination != 0 {
        missing := BOARD_FULL & ~combination;
        sum : float = 0;
        while missing != 0 {
            q := missing & (~missing + 1);
            sum += values[combination | q];
            missing &= missing - 1;
        }
        scratch[combination] = sum;

        next := next_combination(combination);
        if next == 0 || next > BOARD_FULL break;
        combination = next;
    }

    // Evaluate every even-sized state with k marks.
    state : u32 = ifx k == 0 then 0 else low_bits(k);
    denom := cast(float) (BOARD_CELLS - k - 1);
    while true {
        unused := BOARD_FULL & ~state;
        best : float = -1.0e30;
        while unused != 0 {
            p := unused & (~unused + 1);
            candidate := scratch[state | p] / denom;
            if candidate > best best = candidate;
            unused &= unused - 1;
        }
        values[state] = best;

        if k == 0 break;
        next := next_combination(state);
        if next == 0 || next > BOARD_FULL break;
        state = next;
    }
}

// Computes one stage and returns true when the whole table is ready. Call it
// once per frame while the loading screen is visible.
solver_step :: (solver: *Solver) -> bool {
    if solver.ready return true;

    if !solver.terminal_done {
        solver_build_terminal(solver);
        return false;
    }

    if solver.next_k < 0 {
        solver.ready = true;
        return true;
    }

    solver_compute_level(solver, solver.next_k);
    solver.next_k -= 2;
    solver.stage += 1;

    if solver.next_k < 0 {
        // The V table stays resident; the odd-state scratch is no longer used.
        free(solver.scratch.data);
        solver.scratch = .[];
        solver.ready = true;
        solver.stage = 9;
    }

    return solver.ready;
}

// Expected final bingo count from a state whose mark count may be even or odd.
// An odd state is "player has picked, random mark pending"; its projection is
// the average over every possible random square.
solver_projection :: (solver: *Solver, mask: u32, marked_count: int) -> float {
    if !solver.ready || marked_count > 16 return -1.0;

    if marked_count % 2 == 0 {
        return solver.values[mask];
    }

    if marked_count > 15 return -1.0;
    unused := BOARD_FULL & ~mask;
    count := 25 - marked_count;
    if count <= 0 return -1.0;

    sum : float = 0;
    while unused != 0 {
        q := unused & (~unused + 1);
        sum += solver.values[mask | q];
        unused &= unused - 1;
    }
    return sum / cast(float) count;
}

solver_candidate_better :: (a: Solver_Candidate, b: Solver_Candidate) -> bool {
    if a.cell < 0 return false;
    if b.cell < 0 return true;

    difference := a.ev - b.ev;
    if difference > EV_EPS  return true;
    if difference < -EV_EPS return false;

    // Exact-EV ties are broken for legibility only. Any of these moves is
    // optimal under the expected-score objective.
    if a.completes != b.completes return a.completes > b.completes;
    if a.threats   != b.threats   return a.threats   > b.threats;
    if a.lines     != b.lines     return a.lines     > b.lines;

    a_row := a.cell / 5;
    a_col := a.cell % 5;
    b_row := b.cell / 5;
    b_col := b.cell % 5;
    a_center := (2 - a_row) * (2 - a_row) + (2 - a_col) * (2 - a_col);
    b_center := (2 - b_row) * (2 - b_row) + (2 - b_col) * (2 - b_col);
    if a_center != b_center return a_center < b_center;
    return a.cell < b.cell;
}

// Fills candidates_out.*[] for every legal next cell. Returns the best cell, the EV of the
// second-best cell (or the best if only one exists), and the legal move count.
evaluate_moves :: (solver: *Solver, mask: u32, marked_count: int,
                   candidates_out: *[25] Solver_Candidate) -> (best_cell: int, second_ev: float, count: int) {
    for i: 0..24 {
        candidates_out.*[i].cell = i;
        candidates_out.*[i].ev = -1.0e30;
        candidates_out.*[i].completes = 0;
        candidates_out.*[i].threats = 0;
        candidates_out.*[i].lines = 0;
    }

    if !solver.ready || marked_count >= MAX_MARKS || marked_count % 2 != 0 {
        return -1, -1.0, 0;
    }

    legal_count := BOARD_CELLS - marked_count;
    if legal_count <= 0 return -1, -1.0, 0;

    denom := cast(float) (legal_count - 1);
    if denom <= 0 return -1, -1.0, 0;

    best := -1;
    for p: 0..24 {
        p_bit := bit_mask(p);
        if (mask & p_bit) != 0 continue;

        after_player := mask | p_bit;
        missing := BOARD_FULL & ~after_player;
        sum : float = 0;
        while missing != 0 {
            q := missing & (~missing + 1);
            sum += solver.values[after_player | q];
            missing &= missing - 1;
        }

        candidate : Solver_Candidate;
        candidate.cell = p;
        candidate.ev = sum / denom;

        for i: 0..BINGO_LINES-1 {
            line := BINGO_LINE_MASKS[i];
            if (line & p_bit) == 0 continue;
            filled := count_set_bits(after_player & line);
            candidate.lines += 1;
            if filled == 5 candidate.completes += 1;
            else if filled == 4 candidate.threats += 1;
        }

        candidates_out.*[p] = candidate;
        if best < 0 || solver_candidate_better(candidate, candidates_out.*[best]) best = p;
    }

    if best < 0 return -1, -1.0, 0;

    // Second-best EV is only used for the "edge" readout on the card. Compare
    // on raw EV so the number is meaningful rather than tie-broken noise.
    second := -1.0e30;
    for p: 0..24 {
        if p == best || candidates_out.*[p].ev <= -1.0e29 continue;
        if candidates_out.*[p].ev > second second = candidates_out.*[p].ev;
    }
    if second <= -1.0e29 second = candidates_out.*[best].ev;

    return best, second, legal_count;
}

// Picks the top `wanted` cells from a filled candidate table. Useful for the
// compact alternatives panel in the UI.
rank_candidates :: (candidates_out: *[25] Solver_Candidate, wanted: int,
                    ranked: *[8] int) -> int {
    used : [25] bool;
    result := 0;

    for r: 0..wanted-1 {
        best := -1;
        for p: 0..24 {
            if used[p] || candidates_out.*[p].ev <= -1.0e29 continue;
            if best < 0 || solver_candidate_better(candidates_out.*[p], candidates_out.*[best]) best = p;
        }
        if best < 0 break;
        ranked.*[result] = best;
        result += 1;
        used[best] = true;
    }
    return result;
}
