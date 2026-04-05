pub const State = enum {
    uninitialized,
    resetting,
    bus_ready,
    firmware_loading,
    firmware_ready,
    clm_loading,
    core_init,
    wifi_idle,
    scanning,
    joining,
    joined,
    err,
};

pub const Error = error{
    SpiBusNotReady,
    ClockTimeout,
    CoreResetFailed,
    FirmwareUploadFailed,
    ChipIdMismatch,
    IoctlTimeout,
};
