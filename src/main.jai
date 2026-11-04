// ============================================================================
// Bingo Optimizer
//
// A 5x5 bingo calculator: eight rounds, each round marks one player-chosen
// square and one uniformly random other square. The solver computes the exact
// expected final bingo count for every reachable board and highlights the
// optimal next pick after every observed random result.
//
// Build from the project root:
//   jai.exe build.jai
// ============================================================================

#import "Basic";
#import "Math";
#import "raylib";

#load "solver.jai";
#load "ui.jai";
#load "app.jai";

parse_args :: (args: [] string) -> (string, Demo_Mode, bool) {
    result_shot := "";
    result_demo : Demo_Mode = .NONE;
    result_loading := false;

    i := 0;
    while i < args.count {
        if args[i] == "-shot" && i + 1 < args.count {
            result_shot = args[i + 1];
            i += 1;
        } else if args[i] == "-demo" && i + 1 < args.count {
            if args[i + 1] == "mid"     result_demo = .MID;
            if args[i + 1] == "pending" result_demo = .PENDING;
            if args[i + 1] == "done"    result_demo = .DONE;
            i += 1;
        } else if args[i] == "-loading" {
            result_loading = true;
        }
        i += 1;
    }
    return result_shot, result_demo, result_loading;
}

main :: () {
    SetTraceLogLevel(.LOG_ERROR);
    SetConfigFlags(.FLAG_WINDOW_RESIZABLE);
    InitWindow(WINDOW_W, WINDOW_H, get_c_string("Bingo Optimizer - Exact Expectimax"));
    defer CloseWindow();

    SetTargetFPS(60);
    SetExitKey(.KEY_ESCAPE);
    SetWindowMinSize(1024, 648);

    app_directory := GetApplicationDirectory();
    if app_directory != null ChangeDirectory(app_directory);
    MakeDirectory(get_c_string("screenshots"));

    ui_set_window_icon();
    ui_load_fonts();
    defer ui_unload_fonts();

    solver : Solver;
    solver_begin(*solver);
    defer solver_destroy(*solver);

    seed := cast(u64) (GetTime() * 1000000.0);
    app : App;
    app_init(*app, *solver, seed);
    defer app_destroy(*app);

    args := get_command_line_arguments();
    defer array_reset(*args);

    shot_path, demo_mode, loading_shot := parse_args(args);
    auto_shot := shot_path.count > 0;
    shot_taken := false;

    // Demo screenshots should be reproducible and free of hover highlights.
    if demo_mode != .NONE app.rng = 1234567;
    if auto_shot SetMousePosition(1, 1);

    while !WindowShouldClose() {
        reset_temporary_storage();
        now := GetTime();
        ui_update_camera();

        if !solver.ready {
            BeginDrawing();
            ClearBackground(C_BG_BOTTOM);
            BeginMode2D(UI_CAMERA);
            draw_loading(*solver, now);
            EndMode2D();

            if auto_shot && loading_shot && !shot_taken && solver.stage >= 4 {
                rlDrawRenderBatchActive();
                TakeScreenshot(get_c_string(shot_path));
                shot_taken = true;
            }

            EndDrawing();

            if auto_shot && shot_taken break;

            solver_step(*solver);
            continue;
        }

        if !app.initialized {
            app_reset(*app);
            if demo_mode == .MID     app_apply_demo(*app, 3);
            if demo_mode == .PENDING {
                app_apply_demo(*app, 2);
                if app.best_cell >= 0 app_mark_cell(*app, app.best_cell, 0);
            }
            if demo_mode == .DONE    app_apply_demo(*app, 8);
            app.ready_time = now;
            app.initialized = true;
        }

        handle_input(*app, now);

        BeginDrawing();
        ClearBackground(C_BG_BOTTOM);
        BeginMode2D(UI_CAMERA);
        draw_app(*app, now);
        EndMode2D();

        if app.screenshot_requested {
            rlDrawRenderBatchActive();
            TakeScreenshot("screenshots/bingo.png");
            app.screenshot_requested = false;
        }

        if auto_shot && !shot_taken && now - app.ready_time >= 0.85 {
            rlDrawRenderBatchActive();
            TakeScreenshot(get_c_string(shot_path));
            shot_taken = true;
        }

        EndDrawing();

        if auto_shot && shot_taken break;
    }
}
