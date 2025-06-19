const std = @import("std");
const pixman = @import("pixman");
const cairo = @import("cairo");
const gif = @import("gif");
const allocator = std.heap.page_allocator;
pub fn main() !void {
    const gifpath = "/home/noble/Pictures/wallpapers/batman.gif";
    var error_code: c_int = 0;
    const file = gif.DGifOpenFileName(gifpath, &error_code) orelse return error.NoGif;
    std.log.debug("frame count is {d} and height is {d}", .{ file.*.ImageCount, file.*.SHeight });
    var record_type: gif.GifRecordType = undefined;
    var ExtCode: c_int = undefined;
    var Extension: [*c]gif.GifByteType = null;
    var framecount: usize = 0;
    var Row: c_int = undefined;
    var Col: c_int = undefined;
    var Width: c_int = undefined;
    var Height: c_int = undefined;
    var DISPOSAL_METHOD: c_int = undefined;
    var TRANSPARENCY_INDEX: c_int = undefined;
    var HAS_TRANSPARENCY: bool = false;
    const interlaced_offset = [_]c_int{ 0, 4, 2, 1 };
    const interlaced_jumps = [_]c_int{ 8, 8, 4, 2 };

    //allocate buffer
    var ScreenBuffer = try allocator.alloc(gif.GifRowType, @intCast(file.*.SHeight));
    defer allocator.free(ScreenBuffer);
    ScreenBuffer[0] = (try allocator.alloc(gif.GifPixelType, @intCast(file.*.SWidth))).ptr;

    for (0..@intCast(file.*.SWidth)) |i| {
        ScreenBuffer[0][i] = @intCast(file.*.SBackGroundColor);
    }

    for (1..@intCast(file.*.SHeight)) |i| {
        ScreenBuffer[i] = (try allocator.alloc(gif.GifPixelType, @intCast(file.*.SWidth))).ptr;
        @memcpy(ScreenBuffer[i][0..@intCast(file.*.SWidth)], ScreenBuffer[0][0..@intCast(file.*.SWidth)]);
    }

    while (record_type != gif.TERMINATE_RECORD_TYPE) {
        if (gif.DGifGetRecordType(file, &record_type) == gif.GIF_ERROR) {
            std.log.debug("Error occured while reading gif. Aborting", .{});
            break;
        }
        switch (record_type) {
            gif.EXTENSION_RECORD_TYPE => {
                //skip extensions
                if (gif.DGifGetExtension(file, &ExtCode, &Extension) == gif.GIF_ERROR) {
                    std.log.err("Something went wrong in obtaining the extension", .{});
                    break;
                }
                if (ExtCode == gif.GRAPHICS_EXT_FUNC_CODE) {
                    var GCB: gif.GraphicsControlBlock = undefined;
                    if (gif.DGifExtensionToGCB(Extension[0], Extension + 1, &GCB) == gif.GIF_ERROR) {
                        std.log.err("Error reading GCB", .{});
                        break;
                    }
                    std.log.debug("Disposal mode : {d}", .{GCB.DisposalMode});
                    DISPOSAL_METHOD = GCB.DisposalMode;
                    TRANSPARENCY_INDEX = GCB.TransparentColor;
                    HAS_TRANSPARENCY = GCB.TransparentColor != gif.NO_TRANSPARENT_COLOR;
                    std.log.debug("TRANSPARENCY INDEX {d}", .{TRANSPARENCY_INDEX});
                    std.log.debug("Has transparency: {}", .{HAS_TRANSPARENCY});
                    std.log.debug("delay time {d}", .{GCB.DelayTime});
                }
                while (Extension != null) {
                    if (gif.DGifGetExtensionNext(file, &Extension) == gif.GIF_ERROR) {
                        std.log.err("error in getting next extension.", .{});
                        break;
                    }
                }
            },
            gif.IMAGE_DESC_RECORD_TYPE => {
                std.log.debug("About to load a frame, disposal method : {}", .{DISPOSAL_METHOD});
                if (gif.DGifGetImageDesc(file) == gif.GIF_ERROR) {
                    std.log.err("error in getting image description", .{});
                    break;
                }

                Row = file.*.Image.Top;
                Col = file.*.Image.Left;
                Width = file.*.Image.Width;
                Height = file.*.Image.Height;
                const line_buffer = try allocator.alloc(gif.GifPixelType, @intCast(Width));
                defer allocator.free(line_buffer);

                if (file.*.Image.Interlace) {
                    for (0..4) |pass| {
                        var y: usize = @intCast(Row + interlaced_offset[pass]);
                        const end_y = @as(usize, @intCast(Row + Height));
                        while (y < end_y) {
                            if (gif.DGifGetLine(file, line_buffer.ptr, Width) == gif.GIF_ERROR) {
                                std.log.err("Error in getline (interlaced)", .{});
                                break;
                            }
                            for (0..@intCast(Width)) |x| {
                                const dst_x = @as(usize, @intCast(Col)) + x;
                                const pixel = line_buffer[x];
                                if (!HAS_TRANSPARENCY or pixel != TRANSPARENCY_INDEX) {
                                    ScreenBuffer[y][dst_x] = pixel;
                                }
                            }
                            y += @intCast(interlaced_jumps[pass]);
                        }
                    }
                } else {
                    for (0..@intCast(Height)) |h| {
                        if (gif.DGifGetLine(file, line_buffer.ptr, Width) == gif.GIF_ERROR) {
                            std.log.err("Error in getline (non-interlaced)", .{});
                            break;
                        }
                        const dst_y = @as(usize, @intCast(Row)) + h;
                        if (HAS_TRANSPARENCY) {
                            // Skip transparent pixels
                            for (0..@intCast(Width)) |x| {
                                const dst_x = @as(usize, @intCast(Col)) + x;
                                const pixel = line_buffer[x];
                                if (pixel != TRANSPARENCY_INDEX) {
                                    ScreenBuffer[dst_y][dst_x] = pixel;
                                }
                            }
                        } else {
                            // No transparency — fully overwrite
                            for (0..@intCast(Width)) |x| {
                                const dst_x = @as(usize, @intCast(Col)) + x;
                                ScreenBuffer[dst_y][dst_x] = line_buffer[x];
                            }
                        }
                    }
                }

                framecount += 1;
                try gen_png(file, ScreenBuffer, framecount, HAS_TRANSPARENCY, TRANSPARENCY_INDEX);
            },
            gif.TERMINATE_RECORD_TYPE => {
                std.log.err("last frame has been reached", .{});
            },
            else => {
                std.log.debug("Else block hit", .{});
            },
        }
    }
    std.log.debug("framecount: {d}", .{framecount});
}

fn gen_png(
    file: [*c]gif.GifFileType,
    ScreenBuffer: [][*c]u8,
    frame: usize,
    has_transparency: bool,
    transparency_index: c_int,
) !void {
    const ColorMap = file.*.Image.ColorMap orelse file.*.SColorMap;
    if (ColorMap == null) {
        std.log.err("No color map found", .{});
        return;
    }
    //claude ai is a G for this
    const argb_buffer = try allocator.alloc(u32, @intCast(file.*.SWidth * file.*.SHeight));
    defer allocator.free(argb_buffer);
    // Convert indexed colors to RGB
    for (0..@intCast(file.*.SHeight)) |y| {
        for (0..@intCast(file.*.SWidth)) |x| {
            const argb_offset = y * @as(usize, @intCast(file.*.SWidth)) + x;
            const pixel_index = ScreenBuffer[y][x];
            if (has_transparency and pixel_index == transparency_index) {
                argb_buffer[argb_offset] = 0x00000000; // fully transparent
            } else {
                const color = ColorMap.*.Colors[pixel_index];
                argb_buffer[argb_offset] = 0xFF000000 |
                    (@as(u32, color.Red) << 16) |
                    (@as(u32, color.Green) << 8) |
                    @as(u32, color.Blue);
            }
        }
    }
    const pixman_image = pixman.Image.createBits(.a8r8g8b8, @intCast(file.*.SWidth), @intCast(file.*.SHeight), @ptrCast(@alignCast(argb_buffer.ptr)), @intCast(file.*.SWidth * 4));

    //for testing purpose write a pixman image
    const surface = cairo.cairo_image_surface_create_for_data(
        @ptrCast(@alignCast(pixman_image.?.getData())),
        cairo.CAIRO_FORMAT_ARGB32,
        pixman_image.?.getWidth(),
        pixman_image.?.getHeight(),
        pixman_image.?.getStride(),
    );
    defer cairo.cairo_surface_destroy(surface);
    if (cairo.cairo_surface_status(surface) != cairo.CAIRO_STATUS_SUCCESS) {
        std.log.err("Could not create surface", .{});
        std.posix.exit(1);
    }
    const filename = try std.fmt.allocPrint(allocator, "frame{d}.png", .{frame});
    const status = cairo.cairo_surface_write_to_png(surface, @ptrCast(filename));
    if (status != cairo.CAIRO_STATUS_SUCCESS) {
        std.log.err("Could not write to png", .{});
    } else {
        std.log.debug("written to png", .{});
    }
}
