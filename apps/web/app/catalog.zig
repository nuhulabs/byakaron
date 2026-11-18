//! Where every platform gets Byakaron: installers on the public
//! `nuhulabs/Byakaron-Assets` repo (stable names under
//! `/releases/latest/download/…`) and store listings. Read by the landing
//! and download pages.

const std = @import("std");

pub const Catalog = struct {
    site: []const u8,
    repo: []const u8,
    stores: Stores,
    assets: []const Asset,
};

pub const Stores = struct {
    android: []const u8,
    ios: []const u8,
};

pub const Asset = struct {
    id: []const u8,
    label: []const u8,
    detail: []const u8,
    file: []const u8,
};

pub const catalog: Catalog = @import("downloads.zon");

/// `https://github.com/<repo>/releases/latest/download/<file>`.
pub fn latest(arena: std.mem.Allocator, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "https://github.com/{s}/releases/latest/download/{s}", .{ catalog.repo, file });
}
