const std = @import("std");
const pixman = @import("pixman");
const cairo = @import("cairo");
const gif = @import("gif");
const allocator = std.heap.page_allocator;
const GIF_ERROR = gif.GIF_ERROR;

var composite_buffer: ?[]u32 = null;
var canvas_width: usize = 0;
var canvas_height: usize = 0;

pub fn initCompositeBuffer(width: usize, height: usize) !void {
    canvas_width = width;
    canvas_height = height;
    composite_buffer = try allocator.alloc(u32, width * height);
    @memset(composite_buffer.?, 0x00000000); //check if background color will work here
}

pub fn main() !void {
    const gifpath = "/home/noble/Pictures/wallpapers/Wonder Woman.gif";
    var error_code: c_int = 0;
    const file = gif.DGifOpenFileName(gifpath, &error_code) orelse return error.NoGif;
    var RecordType: gif.GifRecordType = undefined;
    try initCompositeBuffer(@intCast(file.*.SWidth), @intCast(file.*.SHeight));
    var ExtFunction: c_int = undefined;
    var ExtData: [*c]gif.GifByteType = undefined;
    var gcb: gif.GraphicsControlBlock = undefined; //the gcb of the current image in the iteration
    while (RecordType != gif.TERMINATE_RECORD_TYPE) {
        _ = gif.DGifGetRecordType(file, &RecordType);
        switch (RecordType) {
            gif.IMAGE_DESC_RECORD_TYPE => {
                //handle disposal modes
                std.debug.assert(gif.DGifGetImageDesc(file) != GIF_ERROR);
                //the current image
                var IMAGE = &file.*.SavedImages[@as(usize, @intCast(file.*.ImageCount)) - 1];
                const HEIGHT: usize = @intCast(IMAGE.ImageDesc.Height);
                const WIDTH: usize = @intCast(IMAGE.ImageDesc.Width);
                const SIZE = WIDTH * HEIGHT;
                const FRAME_LEFT: usize = @intCast(IMAGE.ImageDesc.Left);
                const FRAME_TOP: usize = @intCast(IMAGE.ImageDesc.Top);
                const _rasterbits_alloc = try allocator.alloc(gif.GifByteType, SIZE);

                //most important part, since we dont want to store the whole image in memory and we have a composite buffer storing old pixels, we can free rasterbits
                defer allocator.free(_rasterbits_alloc);
                switch (gcb.DisposalMode) {
                    0, 1 => {},
                    2 => {
                        for (0..HEIGHT) |v| {
                            for (0..WIDTH) |u| {
                                const canvas_x = FRAME_LEFT + u;
                                const canvas_y = FRAME_TOP + v;

                                if (canvas_x >= canvas_width or canvas_y >= canvas_height) continue;

                                const canvas_index = canvas_y * canvas_width + canvas_x;
                                composite_buffer.?[canvas_index] = @intCast(file.*.SBackGroundColor);
                            }
                        }
                    },
                    3 => {}, //todo, or maybe not tbh
                    else => {},
                }
                IMAGE.RasterBits = _rasterbits_alloc.ptr;
                if (IMAGE.ImageDesc.Interlace) {
                    const interlacedOffset = [_]usize{ 0, 4, 2, 1 };
                    const interlacedJumps = [_]usize{ 8, 8, 4, 2 };

                    //need to perform 4 passes
                    for (0..4) |i| {
                        var j = interlacedOffset[i];
                        const end = HEIGHT;
                        while (j < end) : (j += interlacedJumps[i]) {
                            std.debug.assert(gif.DGifGetLine(file, IMAGE.RasterBits + j * WIDTH, IMAGE.ImageDesc.Width) != GIF_ERROR);
                        }
                    }
                } else {
                    std.debug.assert(gif.DGifGetLine(file, IMAGE.RasterBits, IMAGE.ImageDesc.Height * IMAGE.ImageDesc.Width) != GIF_ERROR);
                }
                if (file.*.ExtensionBlocks != null) {
                    IMAGE.ExtensionBlocks = file.*.ExtensionBlocks;
                    IMAGE.ExtensionBlockCount = file.*.ExtensionBlockCount;

                    file.*.ExtensionBlocks = null;
                    file.*.ExtensionBlockCount = 0;
                }
                std.log.debug("LOCATED A DISPOSAL MODE OF {d}", .{gcb.DisposalMode});
                std.log.debug("LOCATED A TRANSPARENCY INDEX OF {d}", .{gcb.TransparentColor});
                std.log.debug("LOCATED A DELAY OF {d}", .{gcb.DelayTime});
                std.log.debug("\r\n", .{});
                try iter(file, IMAGE, gcb);
            },

            gif.EXTENSION_RECORD_TYPE => {
                std.debug.assert(gif.DGifGetExtension(file, &ExtFunction, &ExtData) != GIF_ERROR);
                if (ExtFunction == gif.GRAPHICS_EXT_FUNC_CODE) {
                    std.debug.assert(gif.DGifExtensionToGCB(ExtData[0], ExtData + 1, &gcb) != GIF_ERROR);
                }
                while (true) {
                    std.debug.assert(gif.DGifGetExtensionNext(file, &ExtData) != GIF_ERROR);
                    if (ExtData == null) break;
                }
            },

            gif.TERMINATE_RECORD_TYPE => {
                std.log.debug("Reached the end of file", .{});
            },
            else => {},
        }
    }
    if (composite_buffer) |cb| {
        allocator.free(cb);
    }
}

pub fn iter(file: [*c]gif.GifFileType, savedImage: [*c]gif.SavedImage, gcb: gif.GraphicsControlBlock) !void {
    const colorMap = savedImage.*.ImageDesc.ColorMap orelse file.*.SColorMap;

    const frame_width: usize = @intCast(savedImage.*.ImageDesc.Width);
    const frame_height: usize = @intCast(savedImage.*.ImageDesc.Height);
    const frame_left: usize = @intCast(savedImage.*.ImageDesc.Left);
    const frame_top: usize = @intCast(savedImage.*.ImageDesc.Top);
    const framecount: usize = @intCast(file.*.ImageCount);
    const has_transparency = (gcb.TransparentColor != -1) and (gcb.TransparentColor >= 0);
    const transparent_index: u8 = if (has_transparency) @intCast(gcb.TransparentColor) else 0;

    //to argb32
    for (0..frame_height) |v| {
        for (0..frame_width) |u| {
            const canvas_x = frame_left + u;
            const canvas_y = frame_top + v;
            if (canvas_x >= canvas_width or canvas_y >= canvas_height) continue;
            const c = savedImage.*.RasterBits[v * frame_width + u];
            const canvas_index = canvas_y * canvas_width + canvas_x;
            if (has_transparency and c == transparent_index) {
                continue;
            } else {
                const rgb = colorMap.*.Colors[c];
                const r: u32 = @intCast(rgb.Red);
                const g: u32 = @intCast(rgb.Green);
                const b: u32 = @intCast(rgb.Blue);
                const argb = 0xFF << 24 | // Full alpha
                    r << 16 |
                    g << 8 |
                    b;

                composite_buffer.?[canvas_index] = argb;
            }
        }
    }
    const pixman_image = pixman.Image.createBits(
        .a8r8g8b8,
        @intCast(canvas_width),
        @intCast(canvas_height),
        @ptrCast(@alignCast(composite_buffer.?.ptr)),
        @intCast(canvas_width * 4),
    );
    const surface = cairo.cairo_image_surface_create_for_data(
        @ptrCast(@alignCast(pixman_image.?.getData())),
        cairo.CAIRO_FORMAT_ARGB32,
        @intCast(pixman_image.?.getWidth()),
        @intCast(pixman_image.?.getHeight()),
        @intCast(pixman_image.?.getStride()),
    );
    if (cairo.cairo_surface_status(surface) != cairo.CAIRO_STATUS_SUCCESS) {
        std.log.err("Could not create surface", .{});
        std.posix.exit(1);
    }
    std.debug.print("Surface created", .{});
    const filename = try std.fmt.allocPrint(allocator, "frame{d}.png", .{framecount});
    const status = cairo.cairo_surface_write_to_png(surface, @ptrCast(filename));
    if (status != cairo.CAIRO_STATUS_SUCCESS) {
        std.log.err("Could not write to png", .{});
    } else {
        std.log.debug("written to png", .{});
    }
}
