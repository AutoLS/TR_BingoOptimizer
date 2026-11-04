// ============================================================================
// app.jai -- bingo calculator state, rules, input, and presentation.
// ============================================================================

// --- Layout ----------------------------------------------------------------
BOARD_X :: 24.0;
BOARD_Y :: 100.0;
BOARD_W :: 800.0;
BOARD_H :: 736.0;

PANEL_X :: 840.0;
PANEL_Y :: 100.0;
PANEL_W :: 496.0;
PANEL_H :: 736.0;

GRID_X :: 114.0;
GRID_Y :: 192.0;
CELL_SIZE :: 116.0;
CELL_GAP :: 10.0;
CELL_STEP :: CELL_SIZE + CELL_GAP;

RIGHT_X :: 864.0;
RIGHT_W :: 448.0;

Y_METRICS :: 145.0;
Y_ATTEMPT :: 232.0;
Y_INSTRUCTION :: 296.0;
H_INSTRUCTION :: 84.0;
Y_RECOMMEND :: 392.0;
H_RECOMMEND :: 176.0;
Y_OPTIONS :: 580.0;
H_OPTIONS :: 80.0;
Y_LINE_PRESSURE :: 670.0;
Y_BUTTONS :: 722.0;
BUTTON_H :: 38.0;
BUTTON_W :: 144.0;
Y_LEGEND :: 780.0;

COLUMN_LETTERS : [5] string = .[ "B", "I", "N", "G", "O" ];

// --- Types -----------------------------------------------------------------
Mark_Owner :: enum u8 {
    NONE;
    PLAYER;
    RANDOM;
}

Phase :: enum u8 {
    PLAYER;
    RANDOM;
    DONE;
}

Attempt :: struct {
    player: int;
    random: int;
}

Demo_Mode :: enum {
    NONE;
    MID;
    PENDING;
    DONE;
}

App :: struct {
    solver: *Solver;

    marks: [25] Mark_Owner;
    mask: u32;
    marked_count: int;
    attempts_used: int;
    phase: Phase;
    pending_player: int = -1;
    moves: [..] Attempt;

    candidates: [25] Solver_Candidate;
    best_cell: int = -1;
    second_ev: float = -1.0;
    ranked: [8] int;
    ranked_count: int;

    heatmap: bool = true;
    mark_times: [25] float64;
    rng: u64;
    ready_time: float64;
    screenshot_requested: bool;
    initialized: bool;
    hover_cell: int = -1;
};

// --- Small helpers ---------------------------------------------------------
plural_s :: (n: int) -> string {
    return ifx n == 1 then "" else "s";
}

cell_name :: (index: int) -> string {
    if index < 0 || index >= 25 return "--";
    return tprint("%1-%2", COLUMN_LETTERS[index % 5], index / 5 + 1);
}

cell_rect :: (index: int) -> Rectangle {
    col := index % 5;
    row := index / 5;
    return Rectangle.{
        GRID_X + cast(float) col * CELL_STEP,
        GRID_Y + cast(float) row * CELL_STEP,
        CELL_SIZE,
        CELL_SIZE,
    };
}

cell_center :: (index: int) -> Vector2 {
    rec := cell_rect(index);
    return Vector2.{ rec.x + rec.width * 0.5, rec.y + rec.height * 0.5 };
}

cell_from_point :: (point: Vector2) -> int {
    for i: 0..24 {
        if CheckCollisionPointRec(point, cell_rect(i)) return i;
    }
    return -1;
}

fmt_fixed :: (value: float, decimals: int) -> string {
    formatter : FormatFloat;
    formatter.value = value;
    formatter.trailing_width = decimals;
    formatter.zero_removal = .NO;
    return tprint("%", formatter);
}

fmt_projection :: (value: float) -> string {
    if value < 0 return "--";
    return fmt_fixed(value, 2);
}

fmt_ev :: (value: float) -> string {
    if value < -1.0e20 return "--";
    return fmt_fixed(value, 3);
}

ease_out_cubic :: (t: float) -> float {
    x := clamp(t, 0.0, 1.0);
    inv := 1.0 - x;
    return 1.0 - inv * inv * inv;
}

app_rng_next :: (app: *App) -> u32 {
    app.rng = app.rng * 6364136223846793005 + 1442695040888963407;
    return cast(u32) (app.rng >> 33);
}

// --- State -----------------------------------------------------------------
app_init :: (app: *App, solver: *Solver, seed: u64) {
    app.solver = solver;
    app.rng = seed;
    app.heatmap = true;
    app.phase = .PLAYER;
    app.pending_player = -1;
    app.initialized = false;
}

app_destroy :: (app: *App) {
    array_reset(*app.moves);
}

clear_recommendation :: (app: *App) {
    for i: 0..24 {
        app.candidates[i].cell = i;
        app.candidates[i].ev = -1.0e30;
        app.candidates[i].completes = 0;
        app.candidates[i].threats = 0;
        app.candidates[i].lines = 0;
    }
    app.best_cell = -1;
    app.second_ev = -1.0;
    app.ranked_count = 0;
}

app_recompute :: (app: *App) {
    if app.solver == null || !app.solver.ready {
        clear_recommendation(app);
        return;
    }

    if app.phase != .PLAYER {
        clear_recommendation(app);
        return;
    }

    best, second, legal := evaluate_moves(app.solver, app.mask, app.marked_count, *app.candidates);
    app.best_cell = best;
    app.second_ev = second;
    app.ranked_count = 0;
    if best >= 0 && legal > 0 {
        app.ranked_count = rank_candidates(*app.candidates, 3, *app.ranked);
    }
}

app_reset :: (app: *App) {
    for i: 0..24 {
        app.marks[i] = .NONE;
        app.mark_times[i] = 0;
    }
    app.mask = 0;
    app.marked_count = 0;
    app.attempts_used = 0;
    app.phase = .PLAYER;
    app.pending_player = -1;
    app.moves.count = 0;
    clear_recommendation(app);
    app_recompute(app);
}

app_mark_cell :: (app: *App, index: int, now: float64) -> bool {
    if index < 0 || index >= 25 return false;
    if app.marks[index] != .NONE return false;

    if app.phase == .PLAYER {
        app.marks[index] = .PLAYER;
        app.mask |= bit_mask(index);
        app.marked_count += 1;
        app.pending_player = index;
        app.phase = .RANDOM;
        app.mark_times[index] = now;
        clear_recommendation(app);
        return true;
    }

    if app.phase == .RANDOM {
        if index == app.pending_player return false;

        app.marks[index] = .RANDOM;
        app.mask |= bit_mask(index);
        app.marked_count += 1;
        app.mark_times[index] = now;
        array_add(*app.moves, Attempt.{ app.pending_player, index });
        app.attempts_used += 1;
        app.pending_player = -1;

        if app.attempts_used >= MAX_ATTEMPTS {
            app.phase = .DONE;
        } else {
            app.phase = .PLAYER;
        }

        app_recompute(app);
        return true;
    }

    return false;
}

app_undo :: (app: *App) -> bool {
    if app.phase == .RANDOM {
        index := app.pending_player;
        if index < 0 return false;
        app.marks[index] = .NONE;
        app.mask &= ~bit_mask(index);
        app.marked_count -= 1;
        app.mark_times[index] = 0;
        app.pending_player = -1;
        app.phase = .PLAYER;
        app_recompute(app);
        return true;
    }

    if app.moves.count <= 0 return false;

    last := app.moves[app.moves.count - 1];
    app.moves.count -= 1;

    if last.player >= 0 {
        app.marks[last.player] = .NONE;
        app.mask &= ~bit_mask(last.player);
        app.mark_times[last.player] = 0;
        app.marked_count -= 1;
    }
    if last.random >= 0 {
        app.marks[last.random] = .NONE;
        app.mask &= ~bit_mask(last.random);
        app.mark_times[last.random] = 0;
        app.marked_count -= 1;
    }

    app.attempts_used -= 1;
    app.phase = .PLAYER;
    app.pending_player = -1;
    app_recompute(app);
    return true;
}

app_can_undo :: (app: *App) -> bool {
    return app.phase == .RANDOM || app.moves.count > 0;
}

app_projection :: (app: *App) -> float {
    if app.solver == null || !app.solver.ready return -1.0;
    return solver_projection(app.solver, app.mask, app.marked_count);
}

app_current_bingos :: (app: *App) -> int {
    return bingo_count(app.mask);
}

app_toggle_heatmap :: (app: *App) {
    app.heatmap = !app.heatmap;
}

// --- Demo driving (only used by the hidden -demo command line mode) ---------
app_apply_demo :: (app: *App, rounds: int) {
    if rounds <= 0 return;
    for round: 0..rounds-1 {
        if app.phase != .PLAYER || app.best_cell < 0 break;

        player := app.best_cell;
        app_mark_cell(app, player, 0);
        if app.phase != .RANDOM break;

        q := -1;
        tries := 0;
        while tries < 200 && q < 0 {
            idx := cast(int) (app_rng_next(app) % 25);
            if idx != app.pending_player && app.marks[idx] == .NONE q = idx;
            tries += 1;
        }
        if q < 0 {
            for i: 0..24 {
                if app.marks[i] == .NONE && i != app.pending_player {
                    q = i;
                    break;
                }
            }
        }
        if q < 0 break;
        app_mark_cell(app, q, 0);
    }
}

// --- Layout helpers --------------------------------------------------------
undo_button_rect :: () -> Rectangle {
    return Rectangle.{ RIGHT_X, Y_BUTTONS, BUTTON_W, BUTTON_H };
}

reset_button_rect :: () -> Rectangle {
    return Rectangle.{ RIGHT_X + BUTTON_W + 8.0, Y_BUTTONS, BUTTON_W, BUTTON_H };
}

heatmap_button_rect :: () -> Rectangle {
    return Rectangle.{ RIGHT_X + (BUTTON_W + 8.0) * 2.0, Y_BUTTONS, BUTTON_W, BUTTON_H };
}

line_start_cell :: (line: int) -> int {
    if line < 5 return line * 5;
    if line < 10 return line - 5;
    if line == 10 return 0;
    return 4;
}

line_end_cell :: (line: int) -> int {
    if line < 5 return line * 5 + 4;
    if line < 10 return 20 + line - 5;
    if line == 10 return 24;
    return 20;
}

// --- Insight text ----------------------------------------------------------
recommendation_line1 :: (app: *App) -> string {
    if app.best_cell < 0 return "";
    candidate := app.candidates[app.best_cell];

    if app.marked_count == 0 {
        return "Center hub: it touches four different lines.";
    }
    if candidate.completes > 0 {
        return tprint("Completes % line% right now.", candidate.completes, plural_s(candidate.completes));
    }
    if candidate.threats > 0 {
        return tprint("Puts % line% at four of five.", candidate.threats, plural_s(candidate.threats));
    }
    return tprint("Builds % line% toward a bingo.", candidate.lines, plural_s(candidate.lines));
}

recommendation_line2 :: (app: *App) -> string {
    if app.best_cell < 0 return "";
    edge := app.candidates[app.best_cell].ev - app.second_ev;
    if app.second_ev < -1.0e20 || edge <= 0.0005 {
        return "Tied for the best expected final score.";
    }
    return tprint("Leads the second-best pick by +%.", fmt_fixed(edge, 4));
}

// --- Board rendering -------------------------------------------------------
owner_color :: (owner: Mark_Owner) -> Color {
    if owner == .PLAYER return C_CYAN;
    if owner == .RANDOM return C_MAGENTA;
    return C_TEXT_FAINT;
}

owner_soft :: (owner: Mark_Owner) -> Color {
    if owner == .PLAYER return C_CYAN_SOFT;
    if owner == .RANDOM return C_MAGENTA_SOFT;
    return C_TEXT_SOFT;
}

cell_is_bingo_cell :: (mask: u32, index: int) -> bool {
    bit := bit_mask(index);
    for line: 0..BINGO_LINES-1 {
        line_mask := BINGO_LINE_MASKS[line];
        if (line_mask & bit) != 0 && (mask & line_mask) == line_mask return true;
    }
    return false;
}

draw_cell_base :: (app: *App, index: int, ev_min: float, ev_max: float) {
    rec := cell_rect(index);
    center := Vector2.{ rec.x + rec.width * 0.5, rec.y + rec.height * 0.5 };
    owner := app.marks[index];
    is_best := index == app.best_cell && app.phase == .PLAYER;
    is_hovered := index == app.hover_cell;
    on_bingo := cell_is_bingo_cell(app.mask, index);

    fill := C_CELL;
    if owner == .PLAYER fill = ColorLerp(C_CELL, Color.{ 15, 61, 69, 255 }, 0.85);
    if owner == .RANDOM fill = ColorLerp(C_CELL, Color.{ 56, 33, 70, 255 }, 0.85);
    if on_bingo fill = ColorLerp(fill, Color.{ 20, 54, 43, 255 }, 0.55);
    if is_best fill = ColorLerp(fill, Color.{ 43, 35, 19, 255 }, 0.55);
    if is_hovered && owner == .NONE fill = ifx is_best then ColorLerp(fill, C_GOLD, 0.04) else C_CELL_HOVER;

    border := C_BORDER;
    if is_hovered border = C_BORDER_HI;
    if on_bingo border = Fade(C_GREEN, 0.45);
    if is_best border = C_GOLD;

    if is_best {
        glow := Rectangle.{ rec.x - 2.0, rec.y - 2.0, rec.width + 4.0, rec.height + 4.0 };
        DrawRectangleRoundedLinesEx(glow, ui_roundness(glow, 15.0), 18, 5.0, Fade(C_GOLD, 0.07));
    }

    ui_panel(rec, fill, border, 13.0);
    if is_best {
        DrawRectangleRoundedLinesEx(rec, ui_roundness(rec, 13.0), 18, 2.0, C_GOLD_SOFT);
    }

    // Coordinate tag.
    coordinate_color := ifx owner == .NONE then C_TEXT_FAINT else Fade(owner_color(owner), 0.90);
    ui_text(UI_FONT_DISPLAY, cell_name(index), rec.x + 11.0, rec.y + 7.0, 12.0, 0.8,
            coordinate_color);

    if owner == .NONE {
        // Quiet center target for empty cells.
        if !is_best && !is_hovered {
            DrawCircleLinesV(center, 7.0, Fade(C_TEXT_FAINT, 0.22));
            DrawCircleV(center, 1.6, Fade(C_TEXT_FAINT, 0.32));
        }

        if app.phase == .PLAYER && app.heatmap {
            candidate := app.candidates[index];
            if candidate.ev > -1.0e29 {
                t : float = 1.0;
                spread := ev_max - ev_min;
                if spread > 0.00001 t = clamp((candidate.ev - ev_min) / spread, 0.0, 1.0);

                bar_bg := Rectangle.{ rec.x + 12.0, rec.y + rec.height - 10.0, 46.0, 2.5 };
                DrawRectangleRec(bar_bg, Fade(C_BORDER, 0.45));
                bar := Rectangle.{ bar_bg.x, bar_bg.y, 12.0 + 34.0 * t, bar_bg.height };
                bar_color := ifx is_best then C_GOLD else C_CYAN;
                DrawRectangleRec(bar, Fade(bar_color, ifx is_best then 0.95 else 0.18 + 0.40 * t));

                ui_text_right(UI_FONT_DISPLAY, fmt_ev(candidate.ev), rec.x + rec.width - 11.0,
                              rec.y + rec.height - 29.0, 13.0, 0.0,
                              ifx is_best then C_GOLD_SOFT else Fade(C_TEXT_DIM, 0.92));
            }
        }
    }

    if is_best {
        ui_sparkle(Vector2.{ rec.x + rec.width - 18.0, rec.y + 18.0 }, 7.0, C_GOLD_SOFT);
        // A small gold corner tick anchors the eye even when the EV text is off.
        DrawRectangleRec(Rectangle.{ rec.x + 1.0, rec.y + 1.0, 4.0, 4.0 }, C_GOLD);
    }
}

draw_cell_mark :: (app: *App, index: int, now: float64) {
    owner := app.marks[index];
    if owner == .NONE return;

    rec := cell_rect(index);
    center := Vector2.{ rec.x + rec.width * 0.5, rec.y + rec.height * 0.5 };
    color := owner_color(owner);
    soft := owner_soft(owner);

    t : float = 1.0;
    if app.mark_times[index] > 0 {
        age := now - app.mark_times[index];
        t = clamp(cast(float) (age / 0.24), 0.0, 1.0);
    }
    grew := 0.55 + 0.45 * ease_out_cubic(t);
    alpha := 0.35 + 0.65 * ease_out_cubic(t);

    DrawCircleV(center, 27.0 * grew, Fade(color, 0.08 * alpha));
    DrawRing(center, 19.0 * grew, 24.0 * grew, 0.0, 360.0, 40, Fade(color, 0.92 * alpha));
    DrawCircleV(center, 10.0 * grew, Fade(color, 0.25 * alpha));
    DrawCircleV(center, 4.0 * grew, Fade(soft, alpha));

    label := ifx owner == .PLAYER then "YOU" else "RNG";
    ui_text_center(UI_FONT_DISPLAY, label, center.x, rec.y + 86.0, 10.5, 1.4,
                   Fade(color, 0.98 * alpha));
}

draw_board :: (app: *App, now: float64) {
    board_rec := Rectangle.{ BOARD_X, BOARD_Y, BOARD_W, BOARD_H };
    ui_soft_panel(board_rec, C_CARD, C_BORDER, 20.0);

    bingos := app_current_bingos(app);
    ui_eyebrow("CURRENT BOARD", 48.0, 122.0, C_TEXT_DIM);
    ui_text_right(UI_FONT_DISPLAY, tprint("% / 12 BINGOS", bingos), 800.0, 120.0,
                  12.0, 1.4, ifx bingos > 0 then C_GOLD else C_TEXT_DIM);

    // Column letters.
    for c: 0..4 {
        center_x := GRID_X + cast(float) c * CELL_STEP + CELL_SIZE * 0.5;
        ui_text_center(UI_FONT_DISPLAY, COLUMN_LETTERS[c], center_x, 150.0, 25.0, 1.6,
                       C_TEXT_SOFT);
    }

    // Row numbers.
    for r: 0..4 {
        center_y := GRID_Y + cast(float) r * CELL_STEP + CELL_SIZE * 0.5;
        ui_text_right(UI_FONT_DISPLAY, tprint("%", r + 1), GRID_X - 15.0,
                      center_y - 9.0, 13.5, 1.0, C_TEXT_FAINT);
    }

    // Heatmap bounds.
    ev_min : float = 1.0e30;
    ev_max : float = -1.0e30;
    if app.phase == .PLAYER {
        for i: 0..24 {
            if app.marks[i] != .NONE continue;
            ev := app.candidates[i].ev;
            if ev <= -1.0e29 continue;
            if ev < ev_min ev_min = ev;
            if ev > ev_max ev_max = ev;
        }
    }
    if ev_min > ev_max {
        ev_min = 0;
        ev_max = 1;
    }

    for i: 0..24 draw_cell_base(app, i, ev_min, ev_max);

    // Completed lines sit above the board tile but below the daubers.
    for line: 0..BINGO_LINES-1 {
        line_mask := BINGO_LINE_MASKS[line];
        if (app.mask & line_mask) != line_mask continue;
        start := cell_center(line_start_cell(line));
        end := cell_center(line_end_cell(line));
        DrawLineEx(start, end, 9.0, Fade(C_GREEN, 0.08));
        DrawLineEx(start, end, 3.5, Fade(C_GREEN, 0.48));
        DrawCircleV(start, 3.5, Fade(C_GREEN, 0.70));
        DrawCircleV(end, 3.5, Fade(C_GREEN, 0.70));
    }

    for i: 0..24 draw_cell_mark(app, i, now);
}

// --- Right-hand analysis panel ---------------------------------------------
draw_metric_divider :: (y: float) {
    ui_divider(RIGHT_X, RIGHT_X + RIGHT_W, y, Fade(C_BORDER, 0.65));
}

draw_metrics :: (app: *App) {
    current := app_current_bingos(app);
    projection := app_projection(app);

    ui_eyebrow("BINGOS NOW", RIGHT_X, Y_METRICS, C_TEXT_DIM);
    ui_text(UI_FONT_DISPLAY, tprint("%", current), RIGHT_X, Y_METRICS + 13.0, 41.0, 0.0,
            C_TEXT);
    current_width := ui_text_width(UI_FONT_DISPLAY, tprint("%", current), 41.0, 0.0);
    ui_text(UI_FONT_BODY, "of 12 lines", RIGHT_X + current_width + 12.0,
            Y_METRICS + 37.0, 11.0, 0.2, C_TEXT_FAINT);

    DrawRectangle(1042, cast(s32) (Y_METRICS + 2.0), 1, 64, Fade(C_BORDER, 0.7));

    ui_eyebrow("EXPECTED FINAL", 1064.0, Y_METRICS, C_TEXT_DIM);
    ui_text(UI_FONT_DISPLAY, fmt_projection(projection), 1064.0, Y_METRICS + 13.0,
            34.0, 0.0, C_GOLD);
    sub := "exact optimal value";
    if app.phase == .RANDOM sub = "random mark pending";
    if app.phase == .DONE sub = "final result";
    ui_text(UI_FONT_BODY, sub, 1064.0, Y_METRICS + 52.0, 11.0, 0.2, C_TEXT_FAINT);

    draw_metric_divider(220.0);
}

draw_attempts :: (app: *App) {
    ui_eyebrow("ATTEMPT", RIGHT_X, Y_ATTEMPT, C_TEXT_DIM);

    current_attempt := app.attempts_used + 1;
    if app.phase == .RANDOM current_attempt = app.attempts_used + 1;
    if app.phase == .DONE current_attempt = MAX_ATTEMPTS;
    if current_attempt > MAX_ATTEMPTS current_attempt = MAX_ATTEMPTS;

    ui_text_right(UI_FONT_DISPLAY, tprint("% / %", current_attempt, MAX_ATTEMPTS),
                  RIGHT_X + RIGHT_W, Y_ATTEMPT - 2.0, 14.5, 1.0, C_TEXT_SOFT);

    pip_gap := 8.0;
    pip_width := (RIGHT_W - pip_gap * 7.0) / 8.0;
    for i: 0..7 {
        rec := Rectangle.{ RIGHT_X + cast(float) i * (pip_width + pip_gap),
                           Y_ATTEMPT + 22.0, pip_width, 6.0 };
        completed := i < app.attempts_used;
        pending := i == app.attempts_used && app.phase == .RANDOM;
        filled := completed || app.phase == .DONE;

        bg := C_CARD_ALT;
        border := C_BORDER;
        ui_panel(rec, bg, border, 3.0);

        if filled {
            ui_panel(rec, C_GOLD, C_GOLD_SOFT, 3.0);
        } else if pending {
            half := Rectangle.{ rec.x, rec.y, rec.width * 0.5, rec.height };
            DrawRectangleRounded(half, ui_roundness(half, 3.0), 8, C_CYAN);
            DrawRectangleRoundedLinesEx(rec, ui_roundness(rec, 3.0), 8, 1.0,
                                        Fade(C_CYAN, 0.55));
        }
    }

    hint := "Every round marks one pick plus one random square.";
    if app.phase == .DONE hint = "All eight rounds are complete.";
    ui_text(UI_FONT_BODY, hint, RIGHT_X, Y_ATTEMPT + 39.0, 11.5, 0.1, C_TEXT_FAINT);
    draw_metric_divider(286.0);
}

draw_instruction :: (app: *App) {
    rec := Rectangle.{ RIGHT_X, Y_INSTRUCTION, RIGHT_W, H_INSTRUCTION };
    accent := C_CYAN;
    step_text := "STEP 1 OF 2";
    title := "Mark your chosen square.";
    sub := "Click a cell on the board. The best next move is in gold.";

    if app.phase == .RANDOM {
        accent = C_MAGENTA;
        step_text = "STEP 2 OF 2";
        title = "Record the game's random mark.";
        sub = tprint("Your pick: %. Click the square the game marked.", cell_name(app.pending_player));
    } else if app.phase == .DONE {
        accent = C_GREEN;
        step_text = "RUN COMPLETE";
        title = "The board is finished.";
        sub = tprint("% bingos. Undo the last round or reset.", app_current_bingos(app));
    }

    ui_panel(rec, C_CARD_ALT, Fade(accent, 0.28), 12.0);
    DrawRectangle(cast(s32) rec.x, cast(s32) (rec.y + 14.0), 3,
                  cast(s32) (rec.height - 28.0), accent);

    ui_text(UI_FONT_DISPLAY, step_text, rec.x + 18.0, rec.y + 12.0, 10.5, 1.5, accent);
    ui_text(UI_FONT_DISPLAY, title, rec.x + 18.0, rec.y + 28.0, 17.5, 0.5, C_TEXT);
    ui_text(UI_FONT_BODY, sub, rec.x + 18.0, rec.y + 55.0, 12.5, 0.1, C_TEXT_DIM);

    icon_center := Vector2.{ rec.x + rec.width - 27.0, rec.y + 27.0 };
    if app.phase == .RANDOM {
        DrawPoly(icon_center, 4, 8.0, 45.0, C_MAGENTA);
        DrawPolyLinesEx(icon_center, 4, 8.0, 45.0, 1.0, C_MAGENTA_SOFT);
    } else if app.phase == .DONE {
        ui_check(icon_center, 8.0, 2.0, C_GREEN);
    } else {
        DrawCircleLinesV(icon_center, 8.0, C_CYAN);
        DrawCircleV(icon_center, 3.0, C_CYAN);
    }
}

draw_recommendation :: (app: *App) {
    rec := Rectangle.{ RIGHT_X, Y_RECOMMEND, RIGHT_W, H_RECOMMEND };
    has_move := app.best_cell >= 0 && app.phase == .PLAYER;
    border := ifx has_move then Fade(C_GOLD, 0.42) else C_BORDER;
    fill := C_CARD_ALT;

    ui_panel(rec, fill, border, 14.0);

    if has_move {
        ui_text(UI_FONT_DISPLAY, "NEXT BEST MOVE", rec.x + 18.0, rec.y + 13.0, 11.0, 1.5,
                C_GOLD);
        candidate := app.candidates[app.best_cell];
        ui_text_right(UI_FONT_DISPLAY, "EV MAXIMAL", rec.x + rec.width - 18.0,
                      rec.y + 13.0, 10.0, 1.2, Fade(C_GOLD, 0.72));

        ui_text(UI_FONT_DISPLAY, cell_name(app.best_cell), rec.x + 18.0, rec.y + 34.0,
                53.0, 0.0, C_GOLD_SOFT);
        ui_sparkle(Vector2.{ rec.x + 108.0, rec.y + 48.0 }, 6.0, C_GOLD);

        rank_text := tprint("RANK 1 OF % LEGAL", 25 - app.marked_count);
        ui_text(UI_FONT_BODY, rank_text, rec.x + 20.0, rec.y + 98.0, 10.5, 0.3,
                C_TEXT_FAINT);

        DrawRectangle(cast(s32) (rec.x + 180.0), cast(s32) (rec.y + 34.0), 1,
                      cast(s32) 76.0, Fade(C_BORDER, 0.7));

        ui_eyebrow("EXPECTED FINAL", rec.x + 202.0, rec.y + 34.0, C_TEXT_DIM);
        ui_text(UI_FONT_DISPLAY, fmt_ev(candidate.ev), rec.x + 202.0, rec.y + 48.0,
                27.0, 0.0, C_GOLD_SOFT);
        edge := candidate.ev - app.second_ev;
        edge_text := "best available move";
        if app.second_ev > -1.0e20 {
            if edge > 0.0005 {
                edge_text = tprint("+% over 2nd best", fmt_fixed(edge, 4));
            } else {
                edge_text = "tied with 2nd best";
            }
        }
        ui_text(UI_FONT_BODY, edge_text, rec.x + 202.0, rec.y + 83.0, 11.0, 0.2,
                C_TEXT_FAINT);

        ui_divider(rec.x + 18.0, rec.x + rec.width - 18.0, rec.y + 118.0,
                   Fade(C_BORDER, 0.65));
        ui_text(UI_FONT_BODY, recommendation_line1(app), rec.x + 18.0, rec.y + 129.0,
                11.5, 0.2, C_TEXT_SOFT);
        ui_text(UI_FONT_BODY, recommendation_line2(app), rec.x + 18.0, rec.y + 150.0,
                11.5, 0.2, C_TEXT_DIM);
    } else if app.phase == .RANDOM {
        ui_text(UI_FONT_DISPLAY, "NEXT BEST MOVE", rec.x + 18.0, rec.y + 13.0, 11.0, 1.5,
                C_TEXT_FAINT);
        ui_text(UI_FONT_DISPLAY, "AWAITING", rec.x + 18.0, rec.y + 36.0, 35.0, 0.0,
                C_MAGENTA_SOFT);
        ui_text(UI_FONT_DISPLAY, "RANDOM MARK", rec.x + 18.0, rec.y + 76.0, 17.0, 1.0,
                C_MAGENTA);
        ui_divider(rec.x + 18.0, rec.x + rec.width - 18.0, rec.y + 110.0,
                   Fade(C_BORDER, 0.65));
        ui_text(UI_FONT_BODY, "The exact next recommendation depends on", rec.x + 18.0,
                rec.y + 124.0, 11.5, 0.2, C_TEXT_SOFT);
        ui_text(UI_FONT_BODY, "which square the game marks. It appears next.", rec.x + 18.0,
                rec.y + 145.0, 11.5, 0.2, C_TEXT_DIM);
    } else {
        bingos := app_current_bingos(app);
        ui_text(UI_FONT_DISPLAY, "FINAL SCORE", rec.x + 18.0, rec.y + 13.0, 11.0, 1.5,
                C_GREEN);
        ui_text(UI_FONT_DISPLAY, tprint("%", bingos), rec.x + 18.0, rec.y + 34.0,
                53.0, 0.0, C_TEXT);
        ui_text(UI_FONT_DISPLAY, "BINGOS", rec.x + 92.0, rec.y + 57.0, 13.0, 1.4,
                C_TEXT_DIM);
        ui_divider(rec.x + 18.0, rec.x + rec.width - 18.0, rec.y + 110.0,
                   Fade(C_BORDER, 0.65));
        ui_text(UI_FONT_BODY, "Eight rounds are in the books.", rec.x + 18.0,
                rec.y + 124.0, 11.5, 0.2, C_TEXT_SOFT);
        ui_text(UI_FONT_BODY, "Undo to revisit a decision, or reset for a new board.",
                rec.x + 18.0, rec.y + 145.0, 11.5, 0.2, C_TEXT_DIM);
    }
}

draw_options :: (app: *App) {
    ui_eyebrow("TOP OPTIONS", RIGHT_X, Y_OPTIONS + 2.0, C_TEXT_DIM);
    ui_text_right(UI_FONT_BODY, "expected final", RIGHT_X + RIGHT_W, Y_OPTIONS + 3.0,
                  10.0, 0.1, C_TEXT_FAINT);

    if app.phase != .PLAYER || app.ranked_count <= 0 {
        message := "Recommendations appear after each random mark is recorded.";
        if app.phase == .DONE message = "Run complete. Undo or reset to review the board.";
        ui_text(UI_FONT_BODY, message, RIGHT_X, Y_OPTIONS + 27.0, 11.5, 0.1, C_TEXT_DIM);
        return;
    }

    for rank: 0..app.ranked_count-1 {
        index := app.ranked[rank];
        candidate := app.candidates[index];
        row_y := Y_OPTIONS + 24.0 + cast(float) rank * 18.0;

        color := ifx rank == 0 then C_GOLD_SOFT else C_TEXT_SOFT;
        ui_text_right(UI_FONT_DISPLAY, tprint("%", rank + 1), RIGHT_X + 10.0,
                      row_y, 11.0, 0.8, ifx rank == 0 then C_GOLD else C_TEXT_FAINT);
        ui_text(UI_FONT_DISPLAY, cell_name(index), RIGHT_X + 24.0, row_y, 12.5, 0.8, color);

        stat := "hub";
        if candidate.completes > 0 stat = tprint("completes %", candidate.completes);
        else if candidate.threats > 0 stat = tprint("sets up %", candidate.threats);
        else stat = tprint("touches %", candidate.lines);
        ui_text(UI_FONT_BODY, stat, RIGHT_X + 74.0, row_y + 1.0, 11.0, 0.2, C_TEXT_FAINT);

        ui_text_right(UI_FONT_DISPLAY, fmt_ev(candidate.ev), RIGHT_X + RIGHT_W, row_y,
                      11.0, 0.0, color);
    }
}

draw_line_pressure :: (app: *App) {
    counts : [12] int;
    line_fill_counts(app.mask, *counts);
    complete := 0;
    edge := 0;
    building := 0;
    for i: 0..BINGO_LINES-1 {
        if counts[i] >= 5 complete += 1;
        else if counts[i] == 4 edge += 1;
        else if counts[i] == 3 building += 1;
    }

    ui_eyebrow("LINE PRESSURE", RIGHT_X, Y_LINE_PRESSURE, C_TEXT_DIM);
    ui_text_right(UI_FONT_DISPLAY, tprint("% COMPLETE", complete), RIGHT_X + RIGHT_W,
                  Y_LINE_PRESSURE - 1.0, 10.5, 1.0, ifx complete > 0 then C_GREEN else C_TEXT_FAINT);

    segment_w := 32.0;
    segment_gap := 4.0;
    total := 12.0 * segment_w + 11.0 * segment_gap;
    start_x := RIGHT_X + (RIGHT_W - total) * 0.5;
    for i: 0..BINGO_LINES-1 {
        rec := Rectangle.{ start_x + cast(float) i * (segment_w + segment_gap),
                           Y_LINE_PRESSURE + 17.0, segment_w, 12.0 };
        fill := C_BORDER;
        border := Fade(C_BORDER, 0.0);
        if counts[i] == 2 fill = Fade(C_CYAN, 0.24);
        if counts[i] == 3 fill = Fade(C_CYAN, 0.48);
        if counts[i] == 4 fill = Fade(C_GOLD, 0.66);
        if counts[i] >= 5 fill = C_GREEN;
        ui_panel(rec, fill, border, 4.0);
    }

    summary := tprint("% at 4/5   % at 3/5", edge, building);
    ui_text(UI_FONT_BODY, summary, RIGHT_X, Y_LINE_PRESSURE + 34.0, 11.0, 0.1,
            C_TEXT_DIM);
}

draw_controls :: (app: *App) {
    undo_rec := undo_button_rect();
    reset_rec := reset_button_rect();
    heat_rec := heatmap_button_rect();

    ui_button_draw(undo_rec, "UNDO", "Z", false, app_can_undo(app));
    ui_button_draw(reset_rec, "RESET", "R", false, true);
    ui_button_draw(heat_rec, "EV LABELS", "H", app.heatmap, true);
}

draw_legend :: () {
    y := Y_LEGEND;
    dot_y := y + 6.0;

    DrawCircleV(Vector2.{ RIGHT_X + 6.0, dot_y }, 4.0, C_CYAN);
    ui_text(UI_FONT_BODY, "YOUR MARK", RIGHT_X + 16.0, y, 10.5, 0.3, C_TEXT_DIM);

    DrawCircleV(Vector2.{ RIGHT_X + 101.0, dot_y }, 4.0, C_MAGENTA);
    ui_text(UI_FONT_BODY, "RANDOM", RIGHT_X + 111.0, y, 10.5, 0.3, C_TEXT_DIM);

    ui_sparkle(Vector2.{ RIGHT_X + 181.0, dot_y }, 6.0, C_GOLD);
    ui_text(UI_FONT_BODY, "BEST NEXT", RIGHT_X + 193.0, y, 10.5, 0.3, C_TEXT_DIM);

    ui_text_right(UI_FONT_BODY, "EV = EXPECTED FINAL", RIGHT_X + RIGHT_W, y, 10.0, 0.2,
                  C_TEXT_FAINT);
}

draw_analysis :: (app: *App) {
    panel_rec := Rectangle.{ PANEL_X, PANEL_Y, PANEL_W, PANEL_H };
    ui_soft_panel(panel_rec, C_CARD, C_BORDER, 20.0);

    ui_eyebrow("LIVE ANALYSIS", RIGHT_X, 122.0, C_TEXT_DIM);
    ui_text_right(UI_FONT_DISPLAY, "EXACT DP", RIGHT_X + RIGHT_W, 122.0, 9.0, 1.3,
                  Fade(C_GREEN, 0.82));

    draw_metrics(app);
    draw_attempts(app);
    draw_instruction(app);
    draw_recommendation(app);
    draw_options(app);
    draw_line_pressure(app);
    draw_controls(app);
    draw_legend();
}

// --- Loading screen --------------------------------------------------------
draw_loading :: (solver: *Solver, now: float64) {
    ui_background();
    ui_header("BUILDING POLICY", C_GOLD);

    card := Rectangle.{ 330.0, 218.0, 700.0, 420.0 };
    ui_soft_panel(card, C_CARD, C_BORDER, 22.0);

    ui_eyebrow("ONE-TIME PRECOMPUTATION", card.x + 38.0, card.y + 35.0, C_GOLD);
    ui_text(UI_FONT_DISPLAY, "SOLVING THE OPTIMAL POLICY", card.x + 38.0, card.y + 56.0,
            27.0, 0.8, C_TEXT);

    ui_text(UI_FONT_BODY, "The calculator is resolving every reachable board and",
            card.x + 39.0, card.y + 100.0, 15.0, 0.1, C_TEXT_SOFT);
    ui_text(UI_FONT_BODY, "the exact expected value of all eight rounds.",
            card.x + 39.0, card.y + 123.0, 15.0, 0.1, C_TEXT_SOFT);

    fraction := solver_progress(solver);
    bar := Rectangle.{ card.x + 38.0, card.y + 170.0, card.width - 76.0, 13.0 };
    ui_progress(bar, fraction, C_GOLD, Fade(C_BORDER, 0.62));

    percent := cast(int) (fraction * 100.0 + 0.5);
    ui_text_right(UI_FONT_DISPLAY, tprint("%\%", percent), card.x + card.width - 38.0,
                  card.y + 195.0, 11.0, 1.0, C_GOLD_SOFT);

    stage_text := "Preparing the state space...";
    if solver.stage == 1 stage_text = "Scoring 2,042,975 terminal boards...";
    if solver.stage >= 2 && solver.stage <= 8 {
        rounds_left := solver.stage - 1;
        stage_text = tprint("Resolving positions with % round% left...", rounds_left,
                            plural_s(rounds_left));
    }
    if solver.stage >= 9 stage_text = "Finalizing the policy...";
    ui_text(UI_FONT_BODY, stage_text, card.x + 38.0, card.y + 199.0, 14.0, 0.1,
            C_TEXT_SOFT);

    // Spinner ring.
    spinner_center := Vector2.{ card.x + card.width - 54.0, card.y + 55.0 };
    angle := cast(float) (now * 160.0);
    angle = angle - cast(float) (cast(int) (angle / 360.0)) * 360.0;
    DrawRing(spinner_center, 13.0, 16.0, angle, angle + 235.0, 32, Fade(C_GOLD, 0.9));
    DrawCircleV(spinner_center, 2.2, C_GOLD);

    ui_divider(card.x + 38.0, card.x + card.width - 38.0, card.y + 246.0,
               Fade(C_BORDER, 0.65));

    ui_eyebrow("WHY THIS IS FAST", card.x + 38.0, card.y + 272.0, C_TEXT_FAINT);
    ui_text(UI_FONT_BODY, "16.2 million decision states collapse into one exact table.",
            card.x + 38.0, card.y + 294.0, 14.0, 0.1, C_TEXT_SOFT);
    ui_text(UI_FONT_BODY, "After this one-time pass, every recommendation is instant.",
            card.x + 38.0, card.y + 317.0, 14.0, 0.1, C_TEXT_SOFT);

    ui_text(UI_FONT_BODY, "No sampling. No heuristic scoring. No lookahead guesses.",
            card.x + 38.0, card.y + 354.0, 12.0, 0.2, C_TEXT_DIM);
}

// --- Overall app frame -----------------------------------------------------
draw_app :: (app: *App, now: float64) {
    ui_background();
    ui_header("POLICY READY", C_GREEN);
    draw_board(app, now);
    draw_analysis(app);
}

// --- Input -----------------------------------------------------------------
handle_input :: (app: *App, now: float64) {
    mouse := ui_mouse_world();

    app.hover_cell = -1;
    if app.phase == .PLAYER || app.phase == .RANDOM {
        index := cell_from_point(mouse);
        if index >= 0 && app.marks[index] == .NONE {
            if !(app.phase == .RANDOM && index == app.pending_player) {
                app.hover_cell = index;
            }
        }
    }

    undo_rec := undo_button_rect();
    reset_rec := reset_button_rect();
    heat_rec := heatmap_button_rect();

    if IsMouseButtonPressed(.MOUSE_BUTTON_LEFT) {
        if ui_button_clicked(undo_rec, app_can_undo(app)) {
            app_undo(app);
        } else if ui_button_clicked(reset_rec, true) {
            app_reset(app);
        } else if ui_button_clicked(heat_rec, true) {
            app_toggle_heatmap(app);
        } else if app.hover_cell >= 0 {
            app_mark_cell(app, app.hover_cell, now);
            app.hover_cell = -1;
        }
    }

    if IsKeyPressed(.KEY_Z) && app_can_undo(app) {
        app_undo(app);
    }
    if IsKeyPressed(.KEY_R) {
        app_reset(app);
    }
    if IsKeyPressed(.KEY_H) {
        app_toggle_heatmap(app);
    }
    if IsKeyPressed(.KEY_F12) {
        app.screenshot_requested = true;
    }

    pointer := app.hover_cell >= 0;
    if app_can_undo(app) && CheckCollisionPointRec(mouse, undo_rec) pointer = true;
    if CheckCollisionPointRec(mouse, reset_rec) pointer = true;
    if CheckCollisionPointRec(mouse, heat_rec) pointer = true;

    if pointer {
        SetMouseCursor(.MOUSE_CURSOR_POINTING_HAND);
    } else {
        SetMouseCursor(.MOUSE_CURSOR_DEFAULT);
    }
}
