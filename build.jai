#run build();

build :: () {
    is_debug := false;
    for arg: get_toplevel_command_line() {
        if arg == "-debug" is_debug = true;
    }

    {
        w := compiler_create_workspace();

        options := get_build_options();
        options.output_executable_name = "BingoOptimizer";

        // raylib 6.0 in this Jai install rejects a valid OpenGL context when
        // DirectInput8Create fails (the failed joystick query leaves a stale
        // GLFW error). Raylib_Patched is an unmodified API copy of the module
        // linked against a locally rebuilt raylib with that check corrected.
        import_paths : [..] string;
        array_add(*import_paths, ..options.import_path);
        array_add(*import_paths, tprint("%modules", #filepath));
        options.import_path = import_paths;

        if is_debug {
            set_optimization(*options, .DEBUG);
            options.array_bounds_check = .ON;
            options.cast_bounds_check  = .FATAL;
            options.null_pointer_check = .ON;
        } else {
            // The startup DP is ~400 million table operations. Optimization
            // takes it from several seconds to well under one second.
            set_optimization(*options, .OPTIMIZED, preserve_debug_info = false);
            options.array_bounds_check = .OFF;
            options.cast_bounds_check  = .OFF;
            options.null_pointer_check = .OFF;

            // No console window in the shipped calculator.
            options.additional_linker_arguments = .["/SUBSYSTEM:WINDOWS", "/ENTRY:mainCRTStartup"];
        }

        set_build_options(options, w);
        remap_import(w, "", "raylib", "Raylib_Patched");
        add_build_file("./src/main.jai", w);
    }

    set_build_options_dc(.{do_output=false});
}

#import "Basic";
#import "Compiler";
