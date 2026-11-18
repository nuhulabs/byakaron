//! The settings and their manifest (src/Composer/Settings.zig) as a module of
//! their own, for build tools that need no engine. Settings.zig reads
//! src/locale, so the module's root has to be here, above both.

pub const Settings = @import("Composer/Settings.zig");
