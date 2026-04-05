/// Lightweight cooperative task scheduler.
/// Tasks are simple callbacks with an optional context pointer.
/// No preemption -- each task runs to completion.

pub const TaskFn = *const fn (?*anyopaque) void;

const Task = struct {
    func: TaskFn,
    ctx: ?*anyopaque,
    active: bool,
};

const MAX_TASKS = 32;
var tasks: [MAX_TASKS]Task = [_]Task{.{ .func = undefined, .ctx = null, .active = false }} ** MAX_TASKS;
var ready_head: usize = 0;
var ready_tail: usize = 0;

const QUEUE_SIZE = 64;
var ready_queue: [QUEUE_SIZE]usize = undefined;

pub const TaskHandle = usize;

/// Register a task. Returns a handle for later scheduling.
pub fn register(func: TaskFn, ctx: ?*anyopaque) !TaskHandle {
    for (&tasks, 0..) |*t, i| {
        if (!t.active) {
            t.* = .{ .func = func, .ctx = ctx, .active = true };
            return i;
        }
    }
    return error.TooManyTasks;
}

/// Mark a task as ready to run.
pub fn schedule(handle: TaskHandle) void {
    if (handle >= MAX_TASKS or !tasks[handle].active) return;
    const next = (ready_tail + 1) % QUEUE_SIZE;
    if (next == ready_head) return; // queue full
    ready_queue[ready_tail] = handle;
    ready_tail = next;
}

/// Run all tasks currently in the ready queue.
pub fn runReady() void {
    while (ready_head != ready_tail) {
        const handle = ready_queue[ready_head];
        ready_head = (ready_head + 1) % QUEUE_SIZE;

        if (handle < MAX_TASKS and tasks[handle].active) {
            tasks[handle].func(tasks[handle].ctx);
        }
    }
}

/// Remove a task.
pub fn unregister(handle: TaskHandle) void {
    if (handle < MAX_TASKS) {
        tasks[handle].active = false;
    }
}

pub fn hasWork() bool {
    return ready_head != ready_tail;
}
