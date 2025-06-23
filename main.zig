const std = @import("std");
const ffmpeg = @import("ffmpeg");
const cairo = @import("cairo");
const pixman = @import("pixman");

const allocator = std.heap.page_allocator;

pub fn main() !void {
    var fmt_ctx: [*c]ffmpeg.AVFormatContext = null;
    var codec_ctx: [*c]ffmpeg.AVCodecContext = null;
    var rgb_frame: [*c]ffmpeg.AVFrame = null;
    var frame: [*c]ffmpeg.AVFrame = null;
    var packet: [*c]ffmpeg.AVPacket = null;

    //open file
    _ = ffmpeg.avformat_open_input(&fmt_ctx, "/home/noble/Pictures/wallpapers/preconvert/zero-two-in-water-3343.mp4", null, null);
    _ = ffmpeg.avformat_find_stream_info(fmt_ctx, null);
    var video_stream_index: usize = undefined;

    for (0..@intCast(fmt_ctx.*.nb_streams)) |i| {
        if (fmt_ctx.*.streams[i].*.codecpar.*.codec_type == ffmpeg.AVMEDIA_TYPE_VIDEO) {
            video_stream_index = i;
            std.log.debug("Located video stream", .{});
            break;
        }
    }
    const _codec = ffmpeg.avcodec_find_decoder(fmt_ctx.*.streams[video_stream_index].*.codecpar.*.codec_id);
    codec_ctx = ffmpeg.avcodec_alloc_context3(_codec);
    _ = ffmpeg.avcodec_parameters_to_context(codec_ctx, fmt_ctx.*.streams[video_stream_index].*.codecpar);
    _ = ffmpeg.avcodec_open2(codec_ctx, _codec, null);

    frame = ffmpeg.av_frame_alloc();
    packet = ffmpeg.av_packet_alloc();
    rgb_frame = ffmpeg.av_frame_alloc();

    const HEIGHT = codec_ctx.*.height;
    const WIDTH = codec_ctx.*.width;
    const src_pix_fmt = codec_ctx.*.pix_fmt;

    std.log.debug("Video dimensinons {d}x{d}", .{ WIDTH, HEIGHT });

    const sws_ctx = ffmpeg.sws_getContext(
        WIDTH,
        HEIGHT,
        src_pix_fmt,
        WIDTH,
        HEIGHT,
        ffmpeg.AV_PIX_FMT_BGRA,
        ffmpeg.SWS_BILINEAR,
        null,
        null,
        null,
    );

    const argb_buffer_size = ffmpeg.av_image_get_buffer_size(ffmpeg.AV_PIX_FMT_ARGB, WIDTH, HEIGHT, 1);
    const argb_buffer = try allocator.alignedAlloc(u8, @alignOf(u32), @intCast(argb_buffer_size));
    defer allocator.free(argb_buffer);

    // Setup RGB frame
    _ = ffmpeg.av_image_fill_arrays(&rgb_frame.*.data[0], &rgb_frame.*.linesize[0], argb_buffer.ptr, ffmpeg.AV_PIX_FMT_ARGB, WIDTH, HEIGHT, 1);

    var frame_count: usize = 0;
    while (ffmpeg.av_read_frame(fmt_ctx, packet) >= 0) {
        if (packet.*.stream_index == video_stream_index) {
            _ = ffmpeg.avcodec_send_packet(codec_ctx, packet);
            defer ffmpeg.av_packet_unref(packet);
            while (ffmpeg.avcodec_receive_frame(codec_ctx, frame) == 0) {
                frame_count += 1;
                std.log.debug("Located frame {d}", .{frame_count});

                _ = ffmpeg.sws_scale(sws_ctx, @ptrCast(&frame.*.data[0]), &frame.*.linesize[0], 0, HEIGHT, @ptrCast(&rgb_frame.*.data[0]), &rgb_frame.*.linesize[0]);

                const pixel_count = @as(usize, @intCast(WIDTH * HEIGHT));
                const argb_pixels: []u32 = std.mem.bytesAsSlice(u32, argb_buffer[0 .. pixel_count * 4]);
                try iter(argb_pixels, WIDTH, HEIGHT, frame_count);
            }
        }
    }
}

fn iter(buffer: []u32, width: c_int, height: c_int, framecount: usize) !void {
    // defer allocator.free(buffer);

    const pixman_image = pixman.Image.createBits(
        .a8r8g8b8,
        @intCast(width),
        @intCast(height),
        @ptrCast(@alignCast(buffer.ptr)),
        @intCast(width * 4),
    );
    const surface = cairo.cairo_image_surface_create_for_data(
        @ptrCast(@alignCast(pixman_image.?.getData())),
        cairo.CAIRO_FORMAT_ARGB32,
        @intCast(pixman_image.?.getWidth()),
        @intCast(pixman_image.?.getHeight()),
        @intCast(pixman_image.?.getStride()),
    );

    if (cairo.cairo_surface_status(surface) != cairo.CAIRO_STATUS_SUCCESS) {
        std.log.err("Cpuld not create surface", .{});
    }
    const filename = try std.fmt.allocPrint(allocator, "frame{d}.png", .{framecount});
    _ = cairo.cairo_surface_write_to_png(surface, @ptrCast(filename));
    std.log.debug("surface created succeduflly", .{});
}
