// UF2 converter — turns an ELF binary into a UF2 file for flashing
// via the RP2040/RP2350 USB bootloader.
//
// UF2 format: https://github.com/microsoft/uf2
// Each 512-byte block carries up to 256 bytes of payload.
//
// Adopts Zig 0.16 "Juicy Main" (std.process.Init) to thread an `io` and a
// process-lifetime arena for allocation. Arena is the correct choice for a
// short-lived CLI — avoids the DebugAllocator O(n) per-alloc tracking overhead
// that `init.gpa` imposes in Debug builds.
const std = @import("std");

const UF2_MAGIC_START0: u32 = 0x0A324655; // "UF2\n"
const UF2_MAGIC_START1: u32 = 0x9E5D5157;
const UF2_MAGIC_END: u32 = 0x0AB16F30;
const UF2_FLAG_FAMILY: u32 = 0x00002000;
const UF2_PAYLOAD_SIZE: u32 = 256;

const FamilyId = enum(u32) {
    rp2040 = 0xe48bff56,
    rp2350 = 0xe48bff59, // RP2350 ARM
};

const UF2Block = extern struct {
    magic_start0: u32 = UF2_MAGIC_START0,
    magic_start1: u32 = UF2_MAGIC_START1,
    flags: u32 = UF2_FLAG_FAMILY,
    target_addr: u32,
    payload_size: u32 = UF2_PAYLOAD_SIZE,
    block_no: u32,
    num_blocks: u32,
    family_id: u32,
    data: [476]u8 = [_]u8{0} ** 476,
    magic_end: u32 = UF2_MAGIC_END,
};

comptime {
    std.debug.assert(@sizeOf(UF2Block) == 512);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: uf2conv <input.elf> <rp2040|rp2350> <output.uf2>\n", .{});
        std.process.exit(1);
    }

    const input_path = args[1];
    const family_str = args[2];
    const output_path = args[3];

    const family: FamilyId = if (std.mem.eql(u8, family_str, "rp2040"))
        .rp2040
    else if (std.mem.eql(u8, family_str, "rp2350"))
        .rp2350
    else {
        std.debug.print("error: unknown family '{s}'\n", .{family_str});
        std.process.exit(1);
    };

    const flash_base: u32 = 0x10000000;

    const cwd = std.Io.Dir.cwd();

    const input_file = try cwd.openFile(io, input_path, .{});
    defer input_file.close(io);

    var in_reader = input_file.reader(io, &.{});
    const binary = try in_reader.interface.allocRemaining(arena, .limited(16 * 1024 * 1024));

    // ELF parsing — extract loadable segments at flash addresses.
    // For simplicity, if it's a raw binary we convert directly.
    // For ELF, we extract .text and .data that live in flash.
    const payload = if (isElf(binary)) try extractElfPayload(arena, binary) else binary;

    // Calculate number of UF2 blocks
    const num_blocks: u32 = @intCast((payload.len + UF2_PAYLOAD_SIZE - 1) / UF2_PAYLOAD_SIZE);

    const output_file = try cwd.createFile(io, output_path, .{});
    defer output_file.close(io);

    var block_no: u32 = 0;
    var offset: usize = 0;
    while (offset < payload.len) : (block_no += 1) {
        var block = UF2Block{
            .target_addr = flash_base + @as(u32, @intCast(offset)),
            .block_no = block_no,
            .num_blocks = num_blocks,
            .family_id = @intFromEnum(family),
        };

        const chunk_size = @min(UF2_PAYLOAD_SIZE, payload.len - offset);
        @memcpy(block.data[0..chunk_size], payload[offset..][0..chunk_size]);

        const bytes: [*]const u8 = @ptrCast(&block);
        try output_file.writeStreamingAll(io, bytes[0..512]);
        // Advance by full UF2 payload slot; partial final chunk is zero-padded
        // (UF2Block.data defaults to zeroes), so fixed stepping stays correct.
        offset += UF2_PAYLOAD_SIZE;
    }

    // Route the success message to stdout rather than stderr. Zig's
    // build system flags any step with stderr output as "had output"
    // and echoes the command line — misleadingly prefixed with
    // "failed command:". Using stdout keeps the `zig build uf2`
    // log clean while still preserving the actual success diagnostic.
    var stdout_buf: [256]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io, &stdout_buf);
    stdout_fw.interface.print("uf2: wrote {d} blocks ({d} bytes payload) -> {s}\n", .{ num_blocks, payload.len, output_path }) catch {};
    stdout_fw.interface.flush() catch {};
}

fn isElf(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], "\x7fELF");
}

fn extractElfPayload(allocator: std.mem.Allocator, elf_data: []const u8) ![]u8 {
    // Minimal 32-bit ELF parser — only extract PT_LOAD segments in flash range
    if (elf_data.len < 52) return error.InvalidElf;

    const e_phoff = std.mem.readInt(u32, elf_data[28..32], .little);
    const e_phentsize = std.mem.readInt(u16, elf_data[42..44], .little);
    const e_phnum = std.mem.readInt(u16, elf_data[44..46], .little);

    const flash_base: u32 = 0x10000000;
    const flash_end: u32 = 0x10400000;

    var max_addr: u32 = flash_base;
    var min_addr: u32 = flash_end;

    // First pass: find address range
    for (0..e_phnum) |i| {
        const ph_offset = e_phoff + @as(u32, @intCast(i)) * e_phentsize;
        if (ph_offset + 32 > elf_data.len) continue;
        const ph = elf_data[ph_offset..];

        const p_type = std.mem.readInt(u32, ph[0..4], .little);
        if (p_type != 1) continue; // PT_LOAD

        const p_paddr = std.mem.readInt(u32, ph[12..16], .little);
        const p_filesz = std.mem.readInt(u32, ph[16..20], .little);

        if (p_paddr >= flash_base and p_paddr < flash_end and p_filesz > 0) {
            if (p_paddr < min_addr) min_addr = p_paddr;
            if (p_paddr + p_filesz > max_addr) max_addr = p_paddr + p_filesz;
        }
    }

    if (min_addr >= max_addr) return error.NoFlashSegments;

    const total_size = max_addr - min_addr;
    const output = try allocator.alloc(u8, total_size);
    @memset(output, 0xFF); // erased flash default

    // Second pass: copy segments
    for (0..e_phnum) |i| {
        const ph_offset = e_phoff + @as(u32, @intCast(i)) * e_phentsize;
        if (ph_offset + 32 > elf_data.len) continue;
        const ph = elf_data[ph_offset..];

        const p_type = std.mem.readInt(u32, ph[0..4], .little);
        if (p_type != 1) continue;

        const p_offset = std.mem.readInt(u32, ph[4..8], .little);
        const p_paddr = std.mem.readInt(u32, ph[12..16], .little);
        const p_filesz = std.mem.readInt(u32, ph[16..20], .little);

        if (p_paddr >= flash_base and p_paddr < flash_end and p_filesz > 0) {
            const dest_offset = p_paddr - min_addr;
            if (p_offset + p_filesz <= elf_data.len) {
                @memcpy(output[dest_offset..][0..p_filesz], elf_data[p_offset..][0..p_filesz]);
            }
        }
    }

    return output;
}
