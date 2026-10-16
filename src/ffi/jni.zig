//! JNI bindings for Byakaron engine on Android.
//! Connects ByakaronEngine Kotlin class to the Zig core.

const std = @import("std");
const ffi = @import("ffi.zig");
const jni = @import("jni");

pub const NativeEngineSession = struct {
    allocator: std.mem.Allocator,
    transliteration_engine: ?*ffi.Engine,
    spell_engine: ?*ffi.SpellHandle,
    autocomplete_engine: ?*ffi.AutoCompleteHandle,
};

fn sessionFromHandle(handle: jni.jlong) *NativeEngineSession {
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

fn jstrToC(j_env: *const jni.JNIEnv, jstr: jni.jstring, is_copy: *bool) [*:0]const u8 {
    return j_env.getStringUTFChars(jstr, is_copy);
}

/// Nullable Java string -> NUL-terminated C string, or "" when null.
/// Caller must call `releaseNullableCStr` with the same args when `owned` is true.
fn nullableCStr(j_env: *const jni.JNIEnv, jstr: jni.jstring, is_copy: *bool, owned: *bool) [*:0]const u8 {
    if (jstr == null or j_env.isSameObject(jstr, null)) {
        owned.* = false;
        return "";
    }
    owned.* = true;
    return j_env.getStringUTFChars(jstr, is_copy);
}

fn releaseNullableCStr(j_env: *const jni.JNIEnv, jstr: jni.jstring, cstr: [*:0]const u8, owned: bool) void {
    if (owned) {
        j_env.releaseStringUTFChars(jstr, cstr);
    }
}

fn stringArrayFromCStrings(
    j_env: *const jni.JNIEnv,
    string_class: jni.jclass,
    cstrs: [][*:0]u8,
    count: usize,
) jni.jobjectArray {
    const result = j_env.newObjectArray(@intCast(count), string_class, null);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const j_word = j_env.newStringUTF(cstrs[i]);
        j_env.setObjectArrayElement(result, @intCast(i), j_word);
        j_env.deleteLocalRef(j_word);
        ffi.byakaron_string_free(cstrs[i]);
    }
    return result;
}

fn emptyStringArray(j_env: *const jni.JNIEnv) jni.jobjectArray {
    const string_class = j_env.findClass("java/lang/String");
    return j_env.newObjectArray(0, string_class, null);
}

// ── Native Lifecycle ─────────────────────────────────────────────────────────

export fn Java_com_byakaron_engine_ByakaronEngine_nativeCreate(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    mode: jni.jint,
    db_path: jni.jstring,
) callconv(.c) jni.jlong {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);

    const allocator = std.heap.c_allocator;
    const session = allocator.create(NativeEngineSession) catch return 0;

    // Initialize transliteration engine (0 = Avro, 1 = Orva)
    const engine_mode: c_int = @intCast(mode);
    const trans_engine = ffi.byakaron_engine_create(engine_mode);

    var spell_engine: ?*ffi.SpellHandle = null;
    if (db_path != null and !j_env.isSameObject(db_path, null)) {
        var is_copy: bool = false;
        const path_cstr = j_env.getStringUTFChars(db_path, &is_copy);
        defer j_env.releaseStringUTFChars(db_path, path_cstr);
        spell_engine = ffi.byakaron_spell_create(path_cstr);
    }

    // Embedded autocomplete lexicon (only if no DB path was provided). Non-fatal if OOM.
    const ac_engine = if (spell_engine == null) ffi.byakaron_ac_create() else null;

    session.* = .{
        .allocator = allocator,
        .transliteration_engine = trans_engine,
        .spell_engine = spell_engine,
        .autocomplete_engine = ac_engine,
    };

    return @intCast(@intFromPtr(session));
}

export fn Java_com_byakaron_engine_ByakaronEngine_nativeDestroy(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) void {
    _ = env;
    _ = thiz;
    if (handle == 0) return;

    const session = sessionFromHandle(handle);
    if (session.transliteration_engine) |e| ffi.byakaron_engine_destroy(e);
    if (session.spell_engine) |s| ffi.byakaron_spell_destroy(s);
    if (session.autocomplete_engine) |a| ffi.byakaron_ac_destroy(a);
    session.allocator.destroy(session);
}

// ── Core Keystroke Operation ────────────────────────────────────────────────
// Transliteration and ranked spell suggestions are produced together in a single
// native call per keystroke. Result is returned as a Java String[]:
//   element 0   = composed Bangla text
//   element 1.. = ranked suggestions

export fn Java_com_byakaron_engine_ByakaronEngine_nativeProcessKeystroke(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    input_text: jni.jstring,
    suggestion_limit: jni.jint,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");

    if (handle == 0 or input_text == null or j_env.isSameObject(input_text, null)) {
        const empty = j_env.newObjectArray(1, string_class, null);
        const empty_str = j_env.newStringUTF("");
        j_env.setObjectArrayElement(empty, 0, empty_str);
        j_env.deleteLocalRef(empty_str);
        return empty;
    }

    const session = sessionFromHandle(handle);

    var is_copy: bool = false;
    const raw_c_str = j_env.getStringUTFChars(input_text, &is_copy);
    defer j_env.releaseStringUTFChars(input_text, raw_c_str);

    const composed_c_str = ffi.byakaron_engine_transliterate(
        session.transliteration_engine,
        raw_c_str,
    );
    defer if (composed_c_str) |c| ffi.byakaron_string_free(c);

    const composed = composed_c_str orelse raw_c_str;

    var suggestions: [16][*:0]u8 = undefined;
    const count: usize = if (session.spell_engine != null and suggestion_limit > 0)
        ffi.byakaron_spell_suggest_list(
            session.spell_engine,
            composed,
            @intCast(suggestion_limit),
            &suggestions,
            suggestions.len,
        )
    else
        0;

    // result[0] = composed Bangla text, result[1..] = ranked suggestions
    const result = j_env.newObjectArray(@intCast(count + 1), string_class, null);
    const j_composed = j_env.newStringUTF(composed);
    j_env.setObjectArrayElement(result, 0, j_composed);
    j_env.deleteLocalRef(j_composed);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const j_word = j_env.newStringUTF(suggestions[i]);
        j_env.setObjectArrayElement(result, @intCast(i + 1), j_word);
        j_env.deleteLocalRef(j_word);
        ffi.byakaron_string_free(suggestions[i]);
    }

    return result;
}

// ── P0: context-aware keystroke + spell APIs ────────────────────────────────
// Same as nativeProcessKeystroke but ranks with n-gram context:
//   prev2 prev1 [composed] next

export fn Java_com_byakaron_engine_ByakaronEngine_nativeProcessKeystrokeCtx(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    input_text: jni.jstring,
    prev2: jni.jstring,
    prev1: jni.jstring,
    next: jni.jstring,
    suggestion_limit: jni.jint,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");

    if (handle == 0 or input_text == null or j_env.isSameObject(input_text, null)) {
        const empty = j_env.newObjectArray(1, string_class, null);
        const empty_str = j_env.newStringUTF("");
        j_env.setObjectArrayElement(empty, 0, empty_str);
        j_env.deleteLocalRef(empty_str);
        return empty;
    }

    const session = sessionFromHandle(handle);

    var is_copy: bool = false;
    const raw_c_str = jstrToC(&j_env, input_text, &is_copy);
    defer j_env.releaseStringUTFChars(input_text, raw_c_str);

    const composed_c_str = ffi.byakaron_engine_transliterate(
        session.transliteration_engine,
        raw_c_str,
    );
    defer if (composed_c_str) |c| ffi.byakaron_string_free(c);
    const composed = composed_c_str orelse raw_c_str;

    var c2: bool = false;
    var owned2 = false;
    var c1: bool = false;
    var owned1 = false;
    var cn: bool = false;
    var ownedn = false;
    const s_prev2 = nullableCStr(&j_env, prev2, &c2, &owned2);
    const s_prev1 = nullableCStr(&j_env, prev1, &c1, &owned1);
    const s_next = nullableCStr(&j_env, next, &cn, &ownedn);
    defer releaseNullableCStr(&j_env, prev2, s_prev2, owned2);
    defer releaseNullableCStr(&j_env, prev1, s_prev1, owned1);
    defer releaseNullableCStr(&j_env, next, s_next, ownedn);

    var suggestions: [32][*:0]u8 = undefined;
    const count: usize = if (session.spell_engine != null and suggestion_limit > 0)
        ffi.byakaron_spell_suggest_ctx_list(
            session.spell_engine,
            composed,
            s_prev2,
            s_prev1,
            s_next,
            @intCast(suggestion_limit),
            &suggestions,
            suggestions.len,
        )
    else
        0;

    const result = j_env.newObjectArray(@intCast(count + 1), string_class, null);
    const j_composed = j_env.newStringUTF(composed);
    j_env.setObjectArrayElement(result, 0, j_composed);
    j_env.deleteLocalRef(j_composed);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const j_word = j_env.newStringUTF(suggestions[i]);
        j_env.setObjectArrayElement(result, @intCast(i + 1), j_word);
        j_env.deleteLocalRef(j_word);
        ffi.byakaron_string_free(suggestions[i]);
    }
    return result;
}

/// Spell-only context suggest for already-composed Bangla. Returns String[].
export fn Java_com_byakaron_engine_ByakaronEngine_nativeSuggestCtx(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    word: jni.jstring,
    prev2: jni.jstring,
    prev1: jni.jstring,
    next: jni.jstring,
    suggestion_limit: jni.jint,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");
    if (handle == 0 or word == null or j_env.isSameObject(word, null)) {
        return j_env.newObjectArray(0, string_class, null);
    }
    const session = sessionFromHandle(handle);
    if (session.spell_engine == null) {
        return j_env.newObjectArray(0, string_class, null);
    }

    var is_copy: bool = false;
    const w = jstrToC(&j_env, word, &is_copy);
    defer j_env.releaseStringUTFChars(word, w);

    var c2: bool = false;
    var owned2 = false;
    var c1: bool = false;
    var owned1 = false;
    var cn: bool = false;
    var ownedn = false;
    const s_prev2 = nullableCStr(&j_env, prev2, &c2, &owned2);
    const s_prev1 = nullableCStr(&j_env, prev1, &c1, &owned1);
    const s_next = nullableCStr(&j_env, next, &cn, &ownedn);
    defer releaseNullableCStr(&j_env, prev2, s_prev2, owned2);
    defer releaseNullableCStr(&j_env, prev1, s_prev1, owned1);
    defer releaseNullableCStr(&j_env, next, s_next, ownedn);

    var suggestions: [32][*:0]u8 = undefined;
    const count = ffi.byakaron_spell_suggest_ctx_list(
        session.spell_engine,
        w,
        s_prev2,
        s_prev1,
        s_next,
        @intCast(suggestion_limit),
        &suggestions,
        suggestions.len,
    );
    return stringArrayFromCStrings(&j_env, string_class, suggestions[0..count], count);
}

/// Full-text spell check. Returns JSON `[{token,known,suggestions}]` or null.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeCheck(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    text: jni.jstring,
) callconv(.c) jni.jstring {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    if (handle == 0 or text == null or j_env.isSameObject(text, null)) return null;
    const session = sessionFromHandle(handle);
    if (session.spell_engine == null) return null;

    var is_copy: bool = false;
    const c_text = jstrToC(&j_env, text, &is_copy);
    defer j_env.releaseStringUTFChars(text, c_text);

    const json = ffi.byakaron_spell_check(session.spell_engine, c_text) orelse return null;
    defer ffi.byakaron_string_free(json);
    return j_env.newStringUTF(json);
}

/// 1 if word is in lexicon, 0 if unknown, -1 on error / no DB.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeIsCorrect(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    word: jni.jstring,
) callconv(.c) jni.jint {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    if (handle == 0 or word == null or j_env.isSameObject(word, null)) return -1;
    const session = sessionFromHandle(handle);
    if (session.spell_engine == null) return -1;

    var is_copy: bool = false;
    const w = jstrToC(&j_env, word, &is_copy);
    defer j_env.releaseStringUTFChars(word, w);
    return ffi.byakaron_spell_is_correct(session.spell_engine, w);
}

// ── P1: embedded autocomplete (no DB) ───────────────────────────────────────

/// Bangla prefix completions from the embedded Mem lexicon. Returns String[].
export fn Java_com_byakaron_engine_ByakaronEngine_nativeAcPrefix(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    prefix: jni.jstring,
    suggestion_limit: jni.jint,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");
    if (handle == 0 or prefix == null or j_env.isSameObject(prefix, null)) {
        return j_env.newObjectArray(0, string_class, null);
    }
    const session = sessionFromHandle(handle);
    if (session.spell_engine == null and session.autocomplete_engine == null) {
        return j_env.newObjectArray(0, string_class, null);
    }

    var is_copy: bool = false;
    const p = jstrToC(&j_env, prefix, &is_copy);
    defer j_env.releaseStringUTFChars(prefix, p);

    var out: [32][*:0]u8 = undefined;
    const count: usize = if (session.spell_engine != null and suggestion_limit > 0)
        ffi.byakaron_spell_prefix_list(
            session.spell_engine,
            p,
            @intCast(suggestion_limit),
            &out,
            out.len,
        )
    else if (session.autocomplete_engine != null and suggestion_limit > 0)
        ffi.byakaron_ac_prefix_list(
            session.autocomplete_engine,
            p,
            @intCast(suggestion_limit),
            &out,
            out.len,
        )
    else
        0;
    return stringArrayFromCStrings(&j_env, string_class, out[0..count], count);
}

/// 1 if word is in the embedded lexicon, 0 otherwise, -1 on error.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeAcContains(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    word: jni.jstring,
) callconv(.c) jni.jint {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    if (handle == 0 or word == null or j_env.isSameObject(word, null)) return -1;
    const session = sessionFromHandle(handle);
    if (session.spell_engine == null and session.autocomplete_engine == null) return -1;

    var is_copy: bool = false;
    const w = jstrToC(&j_env, word, &is_copy);
    defer j_env.releaseStringUTFChars(word, w);
    if (session.spell_engine != null) {
        return ffi.byakaron_spell_is_correct(session.spell_engine, w);
    }
    if (session.autocomplete_engine != null) {
        return ffi.byakaron_ac_contains(session.autocomplete_engine, w);
    }
    return -1;
}

// ── P2: spell.db prefix / next-word + tokenization ──────────────────────────

/// Prefix completions from spell.db dictionary. Returns String[].
export fn Java_com_byakaron_engine_ByakaronEngine_nativePrefixSuggest(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    prefix: jni.jstring,
    suggestion_limit: jni.jint,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");
    if (handle == 0 or prefix == null or j_env.isSameObject(prefix, null)) {
        return j_env.newObjectArray(0, string_class, null);
    }
    const session = sessionFromHandle(handle);
    if (session.spell_engine == null) {
        return j_env.newObjectArray(0, string_class, null);
    }

    var is_copy: bool = false;
    const p = jstrToC(&j_env, prefix, &is_copy);
    defer j_env.releaseStringUTFChars(prefix, p);

    var out: [32][*:0]u8 = undefined;
    const count = ffi.byakaron_spell_prefix_list(
        session.spell_engine,
        p,
        @intCast(suggestion_limit),
        &out,
        out.len,
    );
    return stringArrayFromCStrings(&j_env, string_class, out[0..count], count);
}

/// Next-word predictions from spell.db bigrams. Returns String[].
export fn Java_com_byakaron_engine_ByakaronEngine_nativeNextWordSuggest(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    prev_word: jni.jstring,
    suggestion_limit: jni.jint,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");
    if (handle == 0 or prev_word == null or j_env.isSameObject(prev_word, null)) {
        return j_env.newObjectArray(0, string_class, null);
    }
    const session = sessionFromHandle(handle);
    if (session.spell_engine == null) {
        return j_env.newObjectArray(0, string_class, null);
    }

    var is_copy: bool = false;
    const p = jstrToC(&j_env, prev_word, &is_copy);
    defer j_env.releaseStringUTFChars(prev_word, p);

    var out: [32][*:0]u8 = undefined;
    const count = ffi.byakaron_spell_next_word_list(
        session.spell_engine,
        p,
        @intCast(suggestion_limit),
        &out,
        out.len,
    );
    return stringArrayFromCStrings(&j_env, string_class, out[0..count], count);
}

/// Trigram next-word predictions from spell.db trigrams (prev2, prev1 -> next). Returns String[].
export fn Java_com_byakaron_engine_ByakaronEngine_nativeTrigramNextWordSuggest(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    prev2: jni.jstring,
    prev1: jni.jstring,
    suggestion_limit: jni.jint,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");
    if (handle == 0 or prev2 == null or prev1 == null or j_env.isSameObject(prev2, null) or j_env.isSameObject(prev1, null)) {
        return j_env.newObjectArray(0, string_class, null);
    }
    const session = sessionFromHandle(handle);
    if (session.spell_engine == null) {
        return j_env.newObjectArray(0, string_class, null);
    }

    var is_copy1: bool = false;
    const p1 = jstrToC(&j_env, prev2, &is_copy1);
    defer j_env.releaseStringUTFChars(prev2, p1);

    var is_copy2: bool = false;
    const p2 = jstrToC(&j_env, prev1, &is_copy2);
    defer j_env.releaseStringUTFChars(prev1, p2);

    var out: [32][*:0]u8 = undefined;
    const count = ffi.byakaron_spell_trigram_next_word_list(
        session.spell_engine,
        p1,
        p2,
        @intCast(suggestion_limit),
        &out,
        out.len,
    );
    return stringArrayFromCStrings(&j_env, string_class, out[0..count], count);
}

/// Bangla word tokens (nukta-normalized). Works even with handle == 0.
/// Returns String[] (empty when no words).
export fn Java_com_byakaron_engine_ByakaronEngine_nativeTokenize(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    text: jni.jstring,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    _ = handle;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");
    if (text == null or j_env.isSameObject(text, null)) {
        return j_env.newObjectArray(0, string_class, null);
    }

    var is_copy: bool = false;
    const c_text = jstrToC(&j_env, text, &is_copy);
    defer j_env.releaseStringUTFChars(text, c_text);

    var out: [64][*:0]u8 = undefined;
    const count = ffi.byakaron_tokenize_list(c_text, &out, out.len);
    if (count == 0) return j_env.newObjectArray(0, string_class, null);
    return stringArrayFromCStrings(&j_env, string_class, out[0..count], count);
}

export fn Java_com_byakaron_engine_ByakaronEngine_nativeFreeString(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    str_ptr: jni.jlong,
) callconv(.c) void {
    _ = env;
    _ = thiz;
    if (str_ptr != 0) {
        const ptr: [*:0]u8 = @ptrFromInt(@as(usize, @intCast(str_ptr)));
        ffi.byakaron_string_free(ptr);
    }
}

// Silence unused helper when all callers are optimized out in some builds.
comptime {
    _ = emptyStringArray;
}
