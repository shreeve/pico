/// Fixed-size memory pool for deterministic allocation.
/// Provides a scratch arena for temporary allocations and a dedicated
/// block for the MQuickJS VM heap.
///
/// We avoid dynamic allocation entirely on the firmware side.
/// All memory regions are carved from a single SRAM arena at boot.

pub const Region = struct {
    base: [*]u8,
    size: usize,
};

// Linker-provided heap boundaries
extern const _heap_start: u8;
extern const _heap_end: u8;

var initialized: bool = false;
var pool_base: [*]u8 = undefined;
var pool_size: usize = 0;
var pool_offset: usize = 0;

/// Initialize the memory system from linker-defined heap.
pub fn init() void {
    pool_base = @ptrCast(@constCast(&_heap_start));
    pool_size = @intFromPtr(&_heap_end) - @intFromPtr(&_heap_start);
    pool_offset = 0;
    initialized = true;
}

/// Allocate a contiguous region from the pool (bump allocator, no free).
/// Alignment is always 8 bytes for ARM compatibility.
pub fn alloc(size: usize) ?Region {
    const aligned_off = (pool_offset + 7) & ~@as(usize, 7);
    if (aligned_off + size > pool_size) return null;

    const region = Region{
        .base = pool_base + aligned_off,
        .size = size,
    };
    pool_offset = aligned_off + size;
    return region;
}

/// Reserve a block for the JS VM heap.
pub fn allocVmHeap(size: usize) ?Region {
    return alloc(size);
}

/// Reserve a block for a scratch buffer.
pub fn allocScratch(size: usize) ?Region {
    return alloc(size);
}

pub fn used() usize {
    return pool_offset;
}

pub fn remaining() usize {
    if (!initialized) return 0;
    return pool_size - pool_offset;
}

pub fn totalSize() usize {
    return pool_size;
}
