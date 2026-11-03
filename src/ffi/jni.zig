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

    // Embedded autocomplete (Avro dictionary + iAvro suggestions). Always created,
    // alongside Byakaron.db when present. Non-fatal if OOM (Avro calls return empty).
    const ac_engine = ffi.byakaron_ac_create();

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

// ── P1: embedded autocomplete ───────────────────────────────────────────────

/// Bangla prefix completions: Byakaron.db when present, else the embedded Mem
/// lexicon. Returns String[].
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

/// 1 if word is known (Byakaron.db when present, else the embedded lexicon),
/// 0 otherwise, -1 on error.
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

// ── P1b: iAvro while-typing suggestions (embedded autocomplete) ─────────────
// OmicronLab Avro's (iAvro) candidate list, computed from the composed LATIN
// buffer (not Bangla). Kotlin side (com.byakaron.engine.ByakaronEngine):
//
//   private external fun nativeAvroSuggest(handle: Long, latin: String): Array<String>
//   private external fun nativeAvroSelect(handle: Long, latin: String, candidate: String): Int
//   private external fun nativeAvroExportSelections(handle: Long): String?
//   private external fun nativeAvroImportSelections(handle: Long, json: String): Int
//
// iAvro usage:
//   - On each key, call nativeAvroSuggest(latinBuffer). Element 0 is the decimal
//     index of the candidate to highlight; elements 1.. are the candidates in
//     Avro's order (punctuation already wrapped). Highlight result[1 + idx].
//   - Whenever the highlighted candidate changes (user taps/moves the
//     selection), call nativeAvroSelect(latinBuffer, candidate) so it is
//     highlighted first next time.
//   - On space, commit the highlighted candidate.
//   - Persist across sessions: save nativeAvroExportSelections() (JSON) on
//     shutdown/periodically, feed it to nativeAvroImportSelections() after
//     nativeCreate.

/// Avro candidates for `latin`. Returns String[]:
///   element 0   = selected index (decimal string, always < candidate count, "0" when empty)
///   element 1.. = candidates in Avro's order
/// Returns ["0"] (no candidates) on null input, missing engine, or failure.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeAvroSuggest(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    latin: jni.jstring,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");

    var candidates: [64][*:0]u8 = undefined;
    var selected: c_int = 0;
    var count: usize = 0;
    if (handle != 0 and latin != null and !j_env.isSameObject(latin, null)) {
        const session = sessionFromHandle(handle);
        if (session.autocomplete_engine != null) {
            var is_copy: bool = false;
            const l = jstrToC(&j_env, latin, &is_copy);
            defer j_env.releaseStringUTFChars(latin, l);
            count = ffi.byakaron_ac_suggest_list(
                session.autocomplete_engine,
                l,
                &candidates,
                candidates.len,
                &selected,
            );
        }
    }

    // result[0] = selected index, result[1..] = candidates
    const result = j_env.newObjectArray(@intCast(count + 1), string_class, null);
    var idx_buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrintSentinel(&idx_buf, "{d}", .{if (count == 0) 0 else selected}, 0) catch unreachable;
    const j_idx = j_env.newStringUTF(idx_str.ptr);
    j_env.setObjectArrayElement(result, 0, j_idx);
    j_env.deleteLocalRef(j_idx);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const j_word = j_env.newStringUTF(candidates[i]);
        j_env.setObjectArrayElement(result, @intCast(i + 1), j_word);
        j_env.deleteLocalRef(j_word);
        ffi.byakaron_string_free(candidates[i]);
    }
    return result;
}

/// Remember `candidate` as the user's choice for `latin`. 0 on success, -1 on error.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeAvroSelect(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    latin: jni.jstring,
    candidate: jni.jstring,
) callconv(.c) jni.jint {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    if (handle == 0 or latin == null or candidate == null or j_env.isSameObject(latin, null) or j_env.isSameObject(candidate, null)) return -1;
    const session = sessionFromHandle(handle);
    if (session.autocomplete_engine == null) return -1;

    var is_copy1: bool = false;
    const l = jstrToC(&j_env, latin, &is_copy1);
    defer j_env.releaseStringUTFChars(latin, l);

    var is_copy2: bool = false;
    const c = jstrToC(&j_env, candidate, &is_copy2);
    defer j_env.releaseStringUTFChars(candidate, c);

    return ffi.byakaron_ac_select(session.autocomplete_engine, l, c);
}

/// Learned choices as JSON (`{"<latin>":"<Bangla>"}`) to persist, or null on error.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeAvroExportSelections(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) jni.jstring {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    if (handle == 0) return null;
    const session = sessionFromHandle(handle);
    if (session.autocomplete_engine == null) return null;

    const json = ffi.byakaron_ac_export_selections(session.autocomplete_engine) orelse return null;
    defer ffi.byakaron_string_free(json);
    return j_env.newStringUTF(json);
}

/// Merge choices saved with nativeAvroExportSelections. 0 on success, -1 on
/// error (invalid JSON, no engine).
export fn Java_com_byakaron_engine_ByakaronEngine_nativeAvroImportSelections(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    json: jni.jstring,
) callconv(.c) jni.jint {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    if (handle == 0 or json == null or j_env.isSameObject(json, null)) return -1;
    const session = sessionFromHandle(handle);
    if (session.autocomplete_engine == null) return -1;

    var is_copy: bool = false;
    const j = jstrToC(&j_env, json, &is_copy);
    defer j_env.releaseStringUTFChars(json, j);
    return ffi.byakaron_ac_import_selections(session.autocomplete_engine, j);
}

// ── P2: Byakaron.db prefix / next-word + tokenization ──────────────────────────

/// Prefix completions from Byakaron.db dictionary. Returns String[].
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

/// Next-word predictions from Byakaron.db bigrams. Returns String[].
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

/// Trigram next-word predictions from Byakaron.db trigrams (prev2, prev1 -> next). Returns String[].
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

// ── Composer: the whole keyboard (src/Composer.zig) ─────────────────────────
// Kotlin side (com.byakaron.engine.ByakaronEngine):
//
//   private external fun nativeComposerCreate(dataDir: String, spellDb: String?): Long
//   private external fun nativeComposerDestroy(handle: Long)
//   private external fun nativeComposerKey(handle: Long, kind: Int, ch: Int, mods: Int): String?
//   private external fun nativeComposerLastHandled(handle: Long): Boolean
//   private external fun nativeComposerPick(handle: Long, index: Int): String?
//   private external fun nativeComposerFlush(handle: Long): String
//   private external fun nativeComposerReset(handle: Long)
//   private external fun nativeComposerRefresh(handle: Long)
//   private external fun nativeComposerState(handle: Long): Array<String>
//   private external fun nativeComposerPollUpdate(handle: Long): Boolean
//   private external fun nativeSettingsGet(handle: Long): String?
//   private external fun nativeSettingsSet(handle: Long, json: String): Int
//   private external fun nativeUserdictGet(handle: Long): String?
//   private external fun nativeUserdictAdd(handle: Long, word: String): Int
//   private external fun nativeUserdictRemove(handle: Long, word: String): Int
//
// Usage (IME thread only, the composer is single-threaded):
//   - kind/ch/mods are BYAKARON_KEY_* / ASCII / BYAKARON_MOD_* (byakaron.h).
//   - nativeComposerKey and nativeComposerPick return the text to commit, or
//     null when there is none; nativeComposerLastHandled then tells whether that
//     key was consumed (false: also let the editor have the key, after the commit).
//   - Redraw from nativeComposerState after every call (layout below).
//   - Spelling corrections arrive on a worker thread; instead of calling into
//     the JVM from it, the callback sets a flag. Call nativeComposerPollUpdate on
//     each key (or from a UI-thread timer): when it returns true, call
//     nativeComposerRefresh and redraw.

/// Handle behind the jlong: the composer plus the state JNI keeps around it.
const JniComposer = struct {
    composer: *ffi.ComposerHandle,
    /// Set by the corrector's worker thread, cleared by nativeComposerPollUpdate.
    updated: std.atomic.Value(bool) = .init(false),
    /// `handled` of the last key/pick result.
    last_handled: bool = false,
};

fn composerFromHandle(handle: jni.jlong) ?*JniComposer {
    if (handle == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

fn onComposerUpdate(userdata: ?*anyopaque) callconv(.c) void {
    const jc: *JniComposer = @ptrCast(@alignCast(userdata orelse return));
    jc.updated.store(true, .release);
}

/// Commit text of a key result as a Java string, or null when empty.
fn keyResultToJava(j_env: *const jni.JNIEnv, jc: *JniComposer, r: ffi.ByakaronKeyResult) jni.jstring {
    jc.last_handled = r.handled != 0;
    if (r.commit[0] == 0) return null;
    return j_env.newStringUTF(r.commit);
}

/// Create a composer on `data_dir` (settings.json, selections.json,
/// user-words.txt). `spell_db` may be null (no spelling corrections). Returns 0
/// on failure.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerCreate(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    data_dir: jni.jstring,
    spell_db: jni.jstring,
) callconv(.c) jni.jlong {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    if (data_dir == null or j_env.isSameObject(data_dir, null)) return 0;

    const allocator = std.heap.c_allocator;
    const jc = allocator.create(JniComposer) catch return 0;
    // Initialised before create: the corrector thread may signal right away.
    jc.* = .{ .composer = undefined };

    var is_copy: bool = false;
    const dir = jstrToC(&j_env, data_dir, &is_copy);
    defer j_env.releaseStringUTFChars(data_dir, dir);

    var db_copy: bool = false;
    var db_owned = false;
    const db = nullableCStr(&j_env, spell_db, &db_copy, &db_owned);
    defer releaseNullableCStr(&j_env, spell_db, db, db_owned);

    const composer = ffi.byakaron_composer_create(
        dir,
        if (db_owned) db else null,
        onComposerUpdate,
        jc,
    ) orelse {
        allocator.destroy(jc);
        return 0;
    };
    jc.composer = composer;
    return @intCast(@intFromPtr(jc));
}

export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerDestroy(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) void {
    _ = env;
    _ = thiz;
    const jc = composerFromHandle(handle) orelse return;
    // Destroying the composer joins the corrector thread, so no callback can
    // touch `jc` afterwards.
    ffi.byakaron_composer_destroy(jc.composer);
    std.heap.c_allocator.destroy(jc);
}

/// One key: returns the text to commit or null; see nativeComposerLastHandled.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerKey(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    kind: jni.jint,
    ch: jni.jint,
    mods: jni.jint,
) callconv(.c) jni.jstring {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const jc = composerFromHandle(handle) orelse return null;
    const r = ffi.byakaron_composer_key(jc.composer, kind, @bitCast(ch), @bitCast(mods));
    return keyResultToJava(&j_env, jc, r);
}

/// Whether the last nativeComposerKey / nativeComposerPick consumed the key.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerLastHandled(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) jni.jboolean {
    _ = env;
    _ = thiz;
    const jc = composerFromHandle(handle) orelse return jni.boolToJboolean(false);
    return jni.boolToJboolean(jc.last_handled);
}

/// Pick the index-th candidate of the current page; returns the text to commit or null.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerPick(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    index: jni.jint,
) callconv(.c) jni.jstring {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const jc = composerFromHandle(handle) orelse return null;
    if (index < 0) return null;
    const r = ffi.byakaron_composer_pick(jc.composer, @intCast(index));
    return keyResultToJava(&j_env, jc, r);
}

/// Commit the word being typed (focus out). Returns "" when nothing was typed.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerFlush(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) jni.jstring {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const jc = composerFromHandle(handle) orelse return j_env.newStringUTF("");
    return j_env.newStringUTF(ffi.byakaron_composer_flush(jc.composer));
}

/// Drop the word being typed.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerReset(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) void {
    _ = env;
    _ = thiz;
    const jc = composerFromHandle(handle) orelse return;
    ffi.byakaron_composer_reset(jc.composer);
}

/// Rebuild the candidates after nativeComposerPollUpdate returned true.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerRefresh(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) void {
    _ = env;
    _ = thiz;
    const jc = composerFromHandle(handle) orelse return;
    ffi.byakaron_composer_refresh(jc.composer);
}

/// Number of header elements before the candidates in nativeComposerState.
const state_header_len = 7;

/// What to draw, as String[]:
///   [0] preedit (inline text, "" when not composing)
///   [1] composing     "1" / "0"
///   [2] panelVisible  "1" / "0"
///   [3] vertical      "1" / "0"
///   [4] highlight     index within the page (decimal)
///   [5] page          (decimal)
///   [6] pageCount     (decimal)
///   [7..] the current page's candidates
/// Returns the 7 header elements with an empty preedit for a null handle.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerState(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) jni.jobjectArray {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const string_class = j_env.findClass("java/lang/String");

    var st: ffi.ByakaronComposerState = .{
        .composing = 0,
        .preedit = "",
        .panel_visible = 0,
        .vertical = 0,
        .candidates = undefined,
        .candidate_count = 0,
        .highlight = 0,
        .page = 0,
        .page_count = 0,
    };
    if (composerFromHandle(handle)) |jc| ffi.byakaron_composer_state(jc.composer, &st);

    const result = j_env.newObjectArray(@intCast(state_header_len + st.candidate_count), string_class, null);
    var bufs: [state_header_len - 1][24]u8 = undefined;
    const header = [state_header_len][*:0]const u8{
        st.preedit,
        if (st.composing != 0) "1" else "0",
        if (st.panel_visible != 0) "1" else "0",
        if (st.vertical != 0) "1" else "0",
        (std.fmt.bufPrintSentinel(&bufs[0], "{d}", .{st.highlight}, 0) catch unreachable).ptr,
        (std.fmt.bufPrintSentinel(&bufs[1], "{d}", .{st.page}, 0) catch unreachable).ptr,
        (std.fmt.bufPrintSentinel(&bufs[2], "{d}", .{st.page_count}, 0) catch unreachable).ptr,
    };
    for (header, 0..) |s, i| {
        const j_s = j_env.newStringUTF(s);
        j_env.setObjectArrayElement(result, @intCast(i), j_s);
        j_env.deleteLocalRef(j_s);
    }
    for (st.candidates[0..st.candidate_count], 0..) |c, i| {
        const j_s = j_env.newStringUTF(c);
        j_env.setObjectArrayElement(result, @intCast(state_header_len + i), j_s);
        j_env.deleteLocalRef(j_s);
    }
    return result;
}

/// True once after spelling corrections arrived (then call nativeComposerRefresh).
export fn Java_com_byakaron_engine_ByakaronEngine_nativeComposerPollUpdate(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) jni.jboolean {
    _ = env;
    _ = thiz;
    const jc = composerFromHandle(handle) orelse return jni.boolToJboolean(false);
    return jni.boolToJboolean(jc.updated.swap(false, .acq_rel));
}

/// Shared settings as JSON (see src/Composer/Settings.zig), or null on error.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeSettingsGet(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) jni.jstring {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const jc = composerFromHandle(handle) orelse return null;
    const json = ffi.byakaron_settings_get(jc.composer) orelse return null;
    defer ffi.byakaron_string_free(json);
    return j_env.newStringUTF(json);
}

/// Apply and save settings JSON. 0 on success, -1 on invalid JSON / error.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeSettingsSet(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    json: jni.jstring,
) callconv(.c) jni.jint {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const jc = composerFromHandle(handle) orelse return -1;
    if (json == null or j_env.isSameObject(json, null)) return -1;
    var is_copy: bool = false;
    const j = jstrToC(&j_env, json, &is_copy);
    defer j_env.releaseStringUTFChars(json, j);
    return ffi.byakaron_settings_set(jc.composer, j);
}

/// Personal dictionary as a JSON array of words, or null on error.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeUserdictGet(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
) callconv(.c) jni.jstring {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const jc = composerFromHandle(handle) orelse return null;
    const json = ffi.byakaron_userdict_get(jc.composer) orelse return null;
    defer ffi.byakaron_string_free(json);
    return j_env.newStringUTF(json);
}

/// 1 if added, 0 if already present or not a word, -1 on error.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeUserdictAdd(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    word: jni.jstring,
) callconv(.c) jni.jint {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const jc = composerFromHandle(handle) orelse return -1;
    if (word == null or j_env.isSameObject(word, null)) return -1;
    var is_copy: bool = false;
    const w = jstrToC(&j_env, word, &is_copy);
    defer j_env.releaseStringUTFChars(word, w);
    return ffi.byakaron_userdict_add(jc.composer, w);
}

/// 1 if removed, 0 if absent, -1 on error.
export fn Java_com_byakaron_engine_ByakaronEngine_nativeUserdictRemove(
    env: *jni.cjni.JNIEnv,
    thiz: jni.jobject,
    handle: jni.jlong,
    word: jni.jstring,
) callconv(.c) jni.jint {
    _ = thiz;
    const j_env = jni.JNIEnv.warp(env);
    const jc = composerFromHandle(handle) orelse return -1;
    if (word == null or j_env.isSameObject(word, null)) return -1;
    var is_copy: bool = false;
    const w = jstrToC(&j_env, word, &is_copy);
    defer j_env.releaseStringUTFChars(word, w);
    return ffi.byakaron_userdict_remove(jc.composer, w);
}

// Silence unused helper when all callers are optimized out in some builds.
comptime {
    _ = emptyStringArray;
}
