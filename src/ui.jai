// ============================================================================
// ui.jai -- visual language and reusable raylib drawing helpers.
// ============================================================================

// The UI is authored in a 1360x860 world and presented through a fixed camera
// scale. A larger physical window plus oversized glyph atlases gives bigger,
// crisper text without re-laying out every screen.
WORLD_W :: 1360;
WORLD_H :: 860;
UI_SCALE :: 1.2;

WINDOW_W :: 1632;
WINDOW_H :: 1032;

UI_CAMERA : Camera2D = .{
    Vector2.{ 0.0, 0.0 },
    Vector2.{ 0.0, 0.0 },
    0.0,
    UI_SCALE,
};

ui_update_camera :: () {
    screen_w := cast(float) GetScreenWidth();
    screen_h := cast(float) GetScreenHeight();
    if screen_w <= 0.0 || screen_h <= 0.0 return;

    // Fit the fixed 1360x860 canvas into any window shape, centered. The
    // leftover area is letterboxed rather than stretching the UI.
    scale := min(screen_w / WORLD_W, screen_h / WORLD_H);
    UI_CAMERA.zoom = scale;
    UI_CAMERA.target = Vector2.{ 0.0, 0.0 };
    UI_CAMERA.offset = Vector2.{
        (screen_w - WORLD_W * scale) * 0.5,
        (screen_h - WORLD_H * scale) * 0.5,
    };
}

// --- Palette ---------------------------------------------------------------
C_BG_TOP      :: Color.{  8,  12,  22, 255 };
C_BG_BOTTOM   :: Color.{  4,   7,  14, 255 };
C_CARD        :: Color.{ 15,  22,  38, 255 };
C_CARD_ALT    :: Color.{ 20,  29,  49, 255 };
C_CELL        :: Color.{ 17,  27,  45, 255 };
C_CELL_HOVER  :: Color.{ 25,  38,  62, 255 };
C_BORDER      :: Color.{ 37,  50,  77, 255 };
C_BORDER_HI   :: Color.{ 53,  70, 105, 255 };
C_TEXT        :: Color.{ 240, 246, 255, 255 };
C_TEXT_SOFT   :: Color.{ 190, 203, 226, 255 };
C_TEXT_DIM    :: Color.{ 130, 146, 176, 255 };
C_TEXT_FAINT  :: Color.{  84,  99, 128, 255 };
C_GOLD        :: Color.{ 247, 198,  82, 255 };
C_GOLD_SOFT   :: Color.{ 255, 227, 156, 255 };
C_GOLD_DARK   :: Color.{ 100,  77,  26, 255 };
C_CYAN        :: Color.{  61, 217, 235, 255 };
C_CYAN_SOFT   :: Color.{ 182, 249, 255, 255 };
C_MAGENTA     :: Color.{ 219, 122, 255, 255 };
C_MAGENTA_SOFT:: Color.{ 245, 207, 255, 255 };
C_GREEN       :: Color.{ 106, 231, 164, 255 };
C_RED         :: Color.{ 255, 113, 134, 255 };

// --- Fonts -----------------------------------------------------------------
// Each atlas is rasterized well above its on-screen size and then sampled down
// through the UI camera. This keeps strokes sharp at 120 Hz / high-DPI and
// avoids the thin-stroke dropout caused by scaling one small atlas everywhere.
UI_FONT_DISPLAY       : Font;   // 120 px, large numbers / wordmark
UI_FONT_DISPLAY_MID   : Font;   // 56 px, column letters / titles
UI_FONT_DISPLAY_SMALL : Font;   // 36 px, headings in cards
UI_FONT_DISPLAY_MICRO : Font;   // 26 px, eyebrow labels / buttons
UI_FONT_BODY          : Font;   // 36 px, larger explanatory copy
UI_FONT_BODY_SMALL    : Font;   // 26 px, hints and legends

ui_load_atlas :: (file: string, size: s32) -> Font {
    font := LoadFontEx(get_c_string(file), size, null, 0);
    if !IsFontValid(font) return GetFontDefault();
    SetTextureFilter(font.texture, .TEXTURE_FILTER_BILINEAR);
    return font;
}

ui_set_window_icon :: () {
    icon := GenImageColor(32, 32, C_BG_TOP);
    cell : s32 = 6;
    gap : s32 = 2;
    margin : s32 = 5;
    for r: 0..2 {
        for c: 0..2 {
            color := C_CARD_ALT;
            if r == c color = C_GOLD;
            if r == 2 && c == 0 color = C_CYAN;
            ImageDrawRectangle(*icon, cast(s32) (margin + c*(cell+gap)),
                               cast(s32) (margin + r*(cell+gap)), cell, cell, color);
        }
    }
    SetWindowIcon(icon);
    UnloadImage(icon);
}

ui_load_fonts :: () {
    UI_FONT_DISPLAY       = ui_load_atlas("assets/fonts/ChakraPetch.ttf", 120);
    UI_FONT_DISPLAY_MID   = ui_load_atlas("assets/fonts/ChakraPetch.ttf", 56);
    UI_FONT_DISPLAY_SMALL = ui_load_atlas("assets/fonts/ChakraPetch.ttf", 36);
    UI_FONT_DISPLAY_MICRO = ui_load_atlas("assets/fonts/ChakraPetch.ttf", 26);
    UI_FONT_BODY          = ui_load_atlas("assets/fonts/OpenSans-Regular.ttf", 36);
    UI_FONT_BODY_SMALL    = ui_load_atlas("assets/fonts/OpenSans-Regular.ttf", 26);
}

ui_unload_fonts :: () {
    default_id := GetFontDefault().texture.id;
    if UI_FONT_DISPLAY.texture.id != default_id       UnloadFont(UI_FONT_DISPLAY);
    if UI_FONT_DISPLAY_MID.texture.id != default_id   UnloadFont(UI_FONT_DISPLAY_MID);
    if UI_FONT_DISPLAY_SMALL.texture.id != default_id UnloadFont(UI_FONT_DISPLAY_SMALL);
    if UI_FONT_DISPLAY_MICRO.texture.id != default_id UnloadFont(UI_FONT_DISPLAY_MICRO);
    if UI_FONT_BODY.texture.id != default_id          UnloadFont(UI_FONT_BODY);
    if UI_FONT_BODY_SMALL.texture.id != default_id    UnloadFont(UI_FONT_BODY_SMALL);
}

// Calls pass the logical family (UI_FONT_DISPLAY or UI_FONT_BODY); this maps
// it to the atlas whose raster size is closest to the requested draw size.
ui_pick_font :: (font: Font, size: float) -> Font {
    if font.texture.id == UI_FONT_DISPLAY.texture.id {
        if size <= 13.0 return UI_FONT_DISPLAY_MICRO;
        if size <= 20.0 return UI_FONT_DISPLAY_SMALL;
        if size <= 36.0 return UI_FONT_DISPLAY_MID;
        return UI_FONT_DISPLAY;
    }
    if size <= 11.5 return UI_FONT_BODY_SMALL;
    return UI_FONT_BODY;
}

// --- Text ------------------------------------------------------------------
ui_text_width :: (font: Font, text: string, size: float, spacing: float) -> float {
    if text.count == 0 return 0.0;
    actual := ui_pick_font(font, size);
    return MeasureTextEx(actual, get_c_string(text), size, spacing).x;
}

ui_text :: (font: Font, text: string, x: float, y: float, size: float,
            spacing: float, color: Color) {
    if text.count == 0 return;
    actual := ui_pick_font(font, size);
    DrawTextEx(actual, get_c_string(text), Vector2.{ x, y }, size, spacing, color);
}

ui_text_center :: (font: Font, text: string, center_x: float, y: float, size: float,
                   spacing: float, color: Color) {
    width := ui_text_width(font, text, size, spacing);
    ui_text(font, text, center_x - width * 0.5, y, size, spacing, color);
}

ui_text_right :: (font: Font, text: string, right_x: float, y: float, size: float,
                  spacing: float, color: Color) {
    width := ui_text_width(font, text, size, spacing);
    ui_text(font, text, right_x - width, y, size, spacing, color);
}

ui_eyebrow :: (text: string, x: float, y: float, color: Color) {
    ui_text(UI_FONT_DISPLAY, text, x, y, 11.0, 1.6, color);
}

// --- Geometry --------------------------------------------------------------
ui_rect :: (x: float, y: float, w: float, h: float) -> Rectangle {
    return Rectangle.{ x, y, w, h };
}

ui_roundness :: (rec: Rectangle, radius: float) -> float {
    smaller := min(rec.width, rec.height);
    if smaller <= 0 return 0;
    return clamp(radius / smaller, 0.0, 1.0);
}

ui_panel :: (rec: Rectangle, fill: Color, border: Color, radius: float) {
    roundness := ui_roundness(rec, radius);
    DrawRectangleRounded(rec, roundness, 18, fill);
    if border.a > 0 {
        DrawRectangleRoundedLinesEx(rec, roundness, 18, 1.0, border);
    }
}

ui_soft_panel :: (rec: Rectangle, fill: Color, border: Color, radius: float) {
    shadow := Rectangle.{ rec.x, rec.y + 6.0, rec.width, rec.height };
    DrawRectangleRounded(shadow, ui_roundness(shadow, radius), 18, Fade(BLACK, 0.30));
    ui_panel(rec, fill, border, radius);
}

ui_divider :: (x1: float, x2: float, y: float, color: Color) {
    DrawLineEx(Vector2.{ x1, y }, Vector2.{ x2, y }, 1.0, color);
}

ui_progress :: (rec: Rectangle, fraction: float, fill: Color, background: Color) {
    ui_panel(rec, background, Color.{ 0, 0, 0, 0 }, rec.height * 0.5);
    f := clamp(fraction, 0.0, 1.0);
    if f <= 0 return;

    fill_width := rec.width * f;
    if fill_width < rec.height fill_width = rec.height;
    if fill_width > rec.width fill_width = rec.width;
    fill_rec := Rectangle.{ rec.x, rec.y, fill_width, rec.height };
    DrawRectangleRounded(fill_rec, ui_roundness(fill_rec, rec.height * 0.5), 18, fill);
}

// A tiny four-point sparkle. Line drawing is used instead of triangles so the
// mark is visible even when the render batch's triangle winding is culled.
ui_sparkle :: (center: Vector2, radius: float, color: Color) {
    DrawLineEx(Vector2.{ center.x - radius, center.y },
               Vector2.{ center.x + radius, center.y }, 2.0, color);
    DrawLineEx(Vector2.{ center.x, center.y - radius },
               Vector2.{ center.x, center.y + radius }, 2.0, color);
    DrawLineEx(Vector2.{ center.x - radius * 0.48, center.y - radius * 0.48 },
               Vector2.{ center.x + radius * 0.48, center.y + radius * 0.48 }, 1.2,
               Fade(color, 0.75));
    DrawLineEx(Vector2.{ center.x - radius * 0.48, center.y + radius * 0.48 },
               Vector2.{ center.x + radius * 0.48, center.y - radius * 0.48 }, 1.2,
               Fade(color, 0.75));
    DrawCircleV(center, 1.5, color);
}

ui_check :: (center: Vector2, size: float, thickness: float, color: Color) {
    a := Vector2.{ center.x - size, center.y };
    b := Vector2.{ center.x - size * 0.25, center.y + size * 0.75 };
    c := Vector2.{ center.x + size, center.y - size * 0.75 };
    DrawLineEx(a, b, thickness, color);
    DrawLineEx(b, c, thickness, color);
}

ui_chevron_down :: (center: Vector2, size: float, thickness: float, color: Color) {
    DrawLineEx(Vector2.{ center.x - size, center.y - size * 0.5 },
               Vector2.{ center.x, center.y + size * 0.5 }, thickness, color);
    DrawLineEx(Vector2.{ center.x, center.y + size * 0.5 },
               Vector2.{ center.x + size, center.y - size * 0.5 }, thickness, color);
}

// --- Widgets ---------------------------------------------------------------
ui_pill :: (x: float, y: float, text: string, fg: Color, bg: Color, border: Color) -> float {
    width := ui_text_width(UI_FONT_DISPLAY, text, 11.0, 1.2) + 24.0;
    height := 25.0;
    rec := Rectangle.{ x, y, width, height };
    ui_panel(rec, bg, border, 12.5);
    DrawCircleV(Vector2.{ x + 11.0, y + height * 0.5 }, 3.2, fg);
    ui_text(UI_FONT_DISPLAY, text, x + 19.0, y + 6.0, 11.0, 1.2, fg);
    return width;
}

ui_pill_right :: (right_x: float, y: float, text: string, fg: Color, bg: Color, border: Color) -> float {
    width := ui_text_width(UI_FONT_DISPLAY, text, 11.0, 1.2) + 24.0;
    ui_pill(right_x - width, y, text, fg, bg, border);
    return width;
}

ui_mouse_world :: () -> Vector2 {
    // GetMousePosition is already in window pixels. Only the UI camera inverse
    // belongs here; applying an extra DPI factor shifts every hitbox.
    return GetScreenToWorld2D(GetMousePosition(), UI_CAMERA);
}

ui_button_clicked :: (rec: Rectangle, enabled: bool) -> bool {
    return enabled && IsMouseButtonPressed(.MOUSE_BUTTON_LEFT)
        && CheckCollisionPointRec(ui_mouse_world(), rec);
}

ui_button_draw :: (rec: Rectangle, label: string, shortcut: string, active: bool,
                   enabled: bool) {
    hovered := enabled && CheckCollisionPointRec(ui_mouse_world(), rec);
    bg := ifx active then Fade(C_GOLD, 0.12) else C_CARD_ALT;
    if hovered && enabled bg = ifx active then Fade(C_GOLD, 0.18) else C_CELL_HOVER;
    border := ifx active then Fade(C_GOLD, 0.72) else C_BORDER;
    fg := ifx enabled then (ifx active then C_GOLD_SOFT else C_TEXT_SOFT) else C_TEXT_FAINT;

    ui_panel(rec, bg, border, 10.0);

    label_width := ui_text_width(UI_FONT_DISPLAY, label, 12.0, 1.1);
    key_width := ifx shortcut.count > 0 then ui_text_width(UI_FONT_BODY, shortcut, 10.0, 0.0) + 13.0 else 0.0;
    total := label_width + key_width + 6.0;
    start_x := rec.x + (rec.width - total) * 0.5;
    ui_text(UI_FONT_DISPLAY, label, start_x, rec.y + rec.height * 0.5 - 7.5, 12.0, 1.1, fg);
    if shortcut.count > 0 {
        key_x := start_x + label_width + 6.0;
        key_rec := Rectangle.{ key_x, rec.y + rec.height * 0.5 - 9.0, key_width, 18.0 };
        ui_panel(key_rec, Fade(BLACK, 0.18), Fade(border, 0.55), 4.0);
        ui_text_center(UI_FONT_BODY, shortcut, key_rec.x + key_rec.width * 0.5,
                       key_rec.y + 3.5, 10.0, 0.0, fg);
    }
}

// --- Decorative ------------------------------------------------------------
ui_background :: () {
    DrawRectangleGradientV(0, 0, WORLD_W, WORLD_H, C_BG_TOP, C_BG_BOTTOM);

    // Faint construction grid.
    spacing := 64;
    x := 0;
    while x <= WORLD_W {
        DrawLineEx(Vector2.{ xx x, 0 }, Vector2.{ xx x, WORLD_H }, 1.0, Fade(C_BORDER, 0.055));
        x += spacing;
    }
    y := 0;
    while y <= WORLD_H {
        DrawLineEx(Vector2.{ 0, xx y }, Vector2.{ WORLD_W, xx y }, 1.0, Fade(C_BORDER, 0.055));
        y += spacing;
    }

    // Two distant concentric accents keep the dark background from feeling flat.
    DrawCircleLinesV(Vector2.{ 1130.0, 110.0 }, 260.0, Fade(C_CYAN, 0.035));
    DrawCircleLinesV(Vector2.{ 1130.0, 110.0 }, 330.0, Fade(C_CYAN, 0.022));
    DrawCircleLinesV(Vector2.{ 190.0, 760.0 }, 280.0, Fade(C_GOLD, 0.025));
}

ui_logo :: (x: float, y: float) {
    cell := 8.0;
    gap := 2.0;
    for r: 0..2 {
        for c: 0..2 {
            rec := Rectangle.{ x + xx c*(cell+gap), y + xx r*(cell+gap), cell, cell };
            fill := C_CARD_ALT;
            border := C_BORDER;
            if (r == c) { fill = C_GOLD; border = C_GOLD_SOFT; }
            if r == 2 && c == 0 { fill = C_CYAN; border = C_CYAN_SOFT; }
            ui_panel(rec, fill, border, 2.0);
        }
    }
}

ui_header :: (status_text: string, status_color: Color) {
    // Logo + wordmark.
    ui_logo(24.0, 25.0);
    ui_text(UI_FONT_DISPLAY, "BINGO", 62.0, 13.0, 27.0, 1.4, C_TEXT);
    ui_text(UI_FONT_DISPLAY, "OPTIMIZER", 136.0, 13.0, 27.0, 1.4, C_GOLD);
    ui_text(UI_FONT_BODY, "Exact expectimax - optimal picks under random marks",
            63.0, 48.0, 12.0, 0.2, C_TEXT_DIM);

    // Right-side status.
    right := 1336.0;
    status_w := ui_text_width(UI_FONT_DISPLAY, status_text, 11.0, 1.2) + 24.0;
    attempts_text := "8 ATTEMPTS";
    attempts_w := ui_text_width(UI_FONT_DISPLAY, attempts_text, 11.0, 1.2) + 24.0;

    ui_pill_right(right, 19.0, status_text, status_color, Fade(status_color, 0.08),
                  Fade(status_color, 0.30));
    ui_pill_right(right - status_w - 8.0, 19.0, attempts_text, C_TEXT_DIM,
                  Fade(C_CARD_ALT, 0.75), C_BORDER);
    ui_pill_right(right - status_w - 8.0 - attempts_w - 8.0, 19.0, "5 x 5", C_TEXT_DIM,
                  Fade(C_CARD_ALT, 0.75), C_BORDER);

    // Hairline.
    DrawRectangle(24, 82, WORLD_W - 48, 1, Fade(C_BORDER, 0.8));
    DrawRectangle(24, 82, 190, 1, Fade(C_GOLD, 0.7));
}
