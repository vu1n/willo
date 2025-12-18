// willo_bridge.h
// C API for Willo terminal rendering bridge
//
// This defines the contract between the Ghostty VT parser (Zig) and
// the Willo Metal renderer (Swift). The WilloRenderCell struct is
// 16-byte aligned for optimal Metal buffer performance.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// MARK: - Render Cell Structure
// =============================================================================

/// A single terminal cell ready for Metal rendering.
/// 16-byte aligned struct - perfect for Metal buffer alignment.
///
/// Color format: Packed RGBA8888 (Little Endian: 0xAABBGGRR)
/// This can be read as uchar4 in Metal shaders for automatic normalization.
typedef struct __attribute__((aligned(16))) {
    uint32_t codepoint;    ///< Unicode codepoint (u21 range: 0-0x10FFFF)
    uint32_t fg_color;     ///< Foreground: packed RGBA (0xAABBGGRR)
    uint32_t bg_color;     ///< Background: packed RGBA (0xAABBGGRR)
    uint16_t flags;        ///< Style flags (see WILLO_FLAG_* constants)
    uint16_t _padding;     ///< Explicit padding for 16-byte alignment
} WilloRenderCell;

// Style flag constants
#define WILLO_FLAG_BOLD         (1 << 0)
#define WILLO_FLAG_ITALIC       (1 << 1)
#define WILLO_FLAG_UNDERLINE    (1 << 2)
#define WILLO_FLAG_STRIKETHROUGH (1 << 3)
#define WILLO_FLAG_BLINK        (1 << 4)
#define WILLO_FLAG_INVERSE      (1 << 5)
#define WILLO_FLAG_INVISIBLE    (1 << 6)
#define WILLO_FLAG_CURSOR       (1 << 7)
#define WILLO_FLAG_WIDE         (1 << 8)   ///< Wide character (CJK)
#define WILLO_FLAG_WIDE_SPACER  (1 << 9)   ///< Spacer for wide char

// =============================================================================
// MARK: - Terminal Info Structure
// =============================================================================

/// Terminal state information returned by willo_term_get_info
typedef struct {
    uint16_t rows;          ///< Number of rows in terminal
    uint16_t cols;          ///< Number of columns in terminal
    uint16_t cursor_x;      ///< Cursor column position (0-indexed)
    uint16_t cursor_y;      ///< Cursor row position (0-indexed)
    uint32_t bg_color;      ///< Default background color (packed RGBA)
    uint32_t fg_color;      ///< Default foreground color (packed RGBA)
    uint32_t cursor_color;  ///< Cursor color (packed RGBA)
    bool cursor_visible;    ///< Whether cursor should be displayed
    uint8_t cursor_style;   ///< 0=bar, 1=block, 2=underline
    uint8_t _padding[2];    ///< Alignment padding
} WilloTerminalInfo;

// =============================================================================
// MARK: - Opaque Terminal Handle
// =============================================================================

/// Opaque pointer to the internal Ghostty terminal instance
typedef struct WilloTerminal WilloTerminal;

// =============================================================================
// MARK: - Lifecycle Functions
// =============================================================================

/// Create a new terminal instance with the given dimensions.
/// @param rows Number of rows (typically 24-50)
/// @param cols Number of columns (typically 80-200)
/// @return New terminal handle, or NULL on allocation failure
WilloTerminal* willo_term_new(uint16_t rows, uint16_t cols);

/// Free a terminal instance and all associated resources.
/// @param term Terminal handle (safe to pass NULL)
void willo_term_free(WilloTerminal* term);

// =============================================================================
// MARK: - Input Functions
// =============================================================================

/// Feed raw terminal data (ANSI escape sequences) to the parser.
/// This is the main input method - call it with data from SSH/Mosh.
/// @param term Terminal handle
/// @param data Raw bytes to parse (ANSI sequences, UTF-8 text)
/// @param len Number of bytes in data
void willo_term_feed(WilloTerminal* term, const char* data, size_t len);

/// Resize the terminal to new dimensions.
/// This triggers reflow of content if needed.
/// @param term Terminal handle
/// @param rows New row count
/// @param cols New column count
void willo_term_resize(WilloTerminal* term, uint16_t rows, uint16_t cols);

// =============================================================================
// MARK: - Rendering Functions
// =============================================================================

/// Get terminal information (dimensions, cursor, colors).
/// @param term Terminal handle
/// @param out_info Pointer to WilloTerminalInfo struct to fill
void willo_term_get_info(WilloTerminal* term, WilloTerminalInfo* out_info);

/// Render the visible terminal grid to a flat buffer.
/// The buffer is filled row-by-row, left-to-right.
/// @param term Terminal handle
/// @param out_buffer Pre-allocated buffer to fill with cells
/// @param max_cells Maximum cells to write (should be rows * cols)
/// @return Number of cells actually written
size_t willo_term_render(
    WilloTerminal* term,
    WilloRenderCell* out_buffer,
    size_t max_cells
);

/// Check if the terminal has any dirty regions since last render.
/// This can be used to skip rendering if nothing changed.
/// @param term Terminal handle
/// @return true if any cells have changed since last willo_term_render call
bool willo_term_is_dirty(WilloTerminal* term);

/// Clear the dirty flag. Call after rendering.
/// @param term Terminal handle
void willo_term_clear_dirty(WilloTerminal* term);

#ifdef __cplusplus
}
#endif
