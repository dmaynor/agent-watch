/// Abstract input events
pub const InputEvent = union(enum) {
    key: Key,
    resize: struct { width: u16, height: u16 },
    none,
};

pub const Key = enum {
    up,
    down,
    left,
    right,
    tab,
    shift_tab,
    enter,
    escape,
    f12,
    quit,
    char_q,
    char_j,
    char_k,
    other,
};
