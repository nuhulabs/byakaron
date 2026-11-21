//! Per-page SEO metadata. A page calls `set` first thing in its `Page`; the
//! layout reads it back (`get`) for <title>, the description, the canonical
//! URL and the Open Graph / Twitter tags, defaulting to the landing page's.

const zx = @import("zx");

pub const site = "https://byakaron.com";
pub const name = "Byakaron | ব্যাকরণ";
pub const default_title = name;
pub const default_description = "Byakaron (ব্যাকরণ) is a Bangla keyboard and spell checker for macOS, Windows, Linux, Android and the web. বাংলা লিখুন, নির্ভুল বানানে।";
/// From the landing page's hero (apps/web/app/public/og.png, 1200x630).
pub const image = site ++ "/og.png";

pub const Meta = struct {
    /// Site-relative path of the page, for the canonical URL ("/", "/app", ...).
    path: []const u8,
    title: []const u8 = default_title,
    description: []const u8 = default_description,
};

pub fn set(data: zx.PageData, m: Meta) void {
    data.set("meta.path", m.path);
    data.set("meta.title", m.title);
    data.set("meta.description", m.description);
}

pub fn get(data: zx.PageData) Meta {
    return .{
        .path = data.get("meta.path") orelse "/",
        .title = data.get("meta.title") orelse default_title,
        .description = data.get("meta.description") orelse default_description,
    };
}
