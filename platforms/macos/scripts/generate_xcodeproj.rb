#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates a single, clean Byakaron.xcodeproj containing two targets:
#
#   • Byakaron      — the SwiftUI main app (sources in ByakaronSpell/Sources).
#                     This is the shippable product the user launches.
#   • ByakaronIME   — the InputMethodKit helper (sources in Byakaron/Sources),
#                     a faceless LSUIElement app embedded inside the main app at
#                     Contents/Library/InputMethods/ByakaronIME.app.
#
# The main app depends on the IME and copies it into that folder via a Copy
# Files build phase, mirroring the mozc/OpenVanilla layout that IMEInstaller.swift
# expects at runtime.
#
# Run from the repo root (or anywhere — paths are resolved relative to this file):
#   /usr/bin/ruby scripts/generate_xcodeproj.rb
#
# Prereqs: the Rust engine static lib must already be built
#   (engine/target/aarch64-apple-darwin/release/libavrobangla_engine.a),
# which the IME target links. Build it with `cargo build --release` first.

require 'xcodeproj'
require 'pathname'
require 'fileutils'

PROJECT_ROOT = Pathname.new(File.expand_path('..', __dir__))
PROJECT_PATH = PROJECT_ROOT / 'Byakaron.xcodeproj'

# IME sources are compiled under module name "Byakaron" so the Info.plist's
# InputMethodServerControllerClass "Byakaron.ByakaronInputController" resolves.
IME_MODULE_NAME = 'Byakaron'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

# Helper: link a system framework into a target's frameworks phase.
def link_system_framework(project, target, name)
  ref = project.frameworks_group.new_file("System/Library/Frameworks/#{name}.framework")
  ref.source_tree = 'SDKROOT'
  ref.last_known_file_type = 'wrapper.framework'
  ref.name = "#{name}.framework"
  target.frameworks_build_phase.add_file_reference(ref)
  ref
end

# Helper: add a group of files on disk to a target's compile phase.
def add_swift_sources(project, target, group_name, dir)
  group = project.main_group.new_group(group_name, dir.relative_path_from(PROJECT_ROOT).to_s)
  Dir[dir.join('*.swift').to_s].sort.each do |path|
    ref = group.new_file(Pathname.new(path).basename.to_s)
    target.source_build_phase.add_file_reference(ref)
  end
  group
end

# ── Shared build settings ─────────────────────────────────────────────────────
common = {
  'ALWAYS_SEARCH_USER_PATHS'  => 'NO',
  'CLANG_ENABLE_MODULES'      => 'YES',
  'CODE_SIGN_IDENTITY'        => '-',
  'CODE_SIGN_STYLE'           => 'Manual',
  'CODE_SIGN_ENTITLEMENTS'    => 'Byakaron/Resources/Byakaron.entitlements',
  'DEVELOPMENT_TEAM'          => '',
  'ENABLE_HARDENED_RUNTIME'   => 'YES',
  'PRODUCT_NAME'              => '$(TARGET_NAME)',
  'SWIFT_VERSION'             => '5.0',
}

def with_config(target, debug_extra, release_extra)
  target.build_configurations.each do |config|
    extra = config.name == 'Debug' ? debug_extra : release_extra
    config.build_settings.merge!(extra)
  end
end

debug_only = {
  'DEBUG_INFORMATION_FORMAT'            => 'dwarf',
  'ONLY_ACTIVE_ARCH'                    => 'YES',
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'DEBUG',
  'SWIFT_OPTIMIZATION_LEVEL'            => '-Onone',
}
release_only = {
  'DEBUG_INFORMATION_FORMAT' => 'dwarf-with-dsym',
  'ENABLE_NS_ASSERTIONS'     => 'NO',
  'SWIFT_COMPILATION_MODE'   => 'wholemodule',
  'SWIFT_OPTIMIZATION_LEVEL' => '-O',
}

# ══════════════════════════════════════════════════════════════════════════════
# Target 1: ByakaronIME (InputMethodKit helper)
# ══════════════════════════════════════════════════════════════════════════════
ime = project.new_target(:application, 'ByakaronIME', :osx, '13.0')

ime_settings = common.merge(
  'INFOPLIST_FILE'             => 'Byakaron/Resources/Info-embedded.plist',
  'PRODUCT_BUNDLE_IDENTIFIER'  => 'dev.nuhu.byakaron.inputmethod.Byakaron',
  'PRODUCT_MODULE_NAME'        => IME_MODULE_NAME,
  'MACOSX_DEPLOYMENT_TARGET'   => '13.0',
  'HEADER_SEARCH_PATHS'        => '$(PROJECT_DIR)/engine/include',
  'LIBRARY_SEARCH_PATHS'       => '$(PROJECT_DIR)/engine/target/aarch64-apple-darwin/release',
  'SWIFT_OBJC_BRIDGING_HEADER' => 'Byakaron/Sources/BridgeHeader.h',
  'OTHER_LDFLAGS'              => '-lavrobangla_engine',
)
with_config(ime, debug_only.merge(ime_settings), release_only.merge(ime_settings))

add_swift_sources(project, ime, 'ByakaronIME', PROJECT_ROOT / 'Byakaron/Sources')

link_system_framework(project, ime, 'Cocoa')
link_system_framework(project, ime, 'InputMethodKit')
link_system_framework(project, ime, 'SwiftUI')

# Rust static engine
ime_res_group = project.main_group.new_group('ByakaronIME-Resources', 'Byakaron/Resources')
engine_lib = project.frameworks_group.new_file(
  'engine/target/aarch64-apple-darwin/release/libavrobangla_engine.a'
)
engine_lib.source_tree = 'SOURCE_ROOT'
ime.frameworks_build_phase.add_file_reference(engine_lib)

# IME resources: icons + the engine's data JSONs.
%w[iconTemplate.pdf AppIcon.icns].each do |f|
  ime.resources_build_phase.add_file_reference(ime_res_group.new_file(f))
end
ime_data_group = project.main_group.new_group('ByakaronIME-Data', 'data')
Dir[PROJECT_ROOT.join('data/*.json').to_s].sort.each do |path|
  ref = ime_data_group.new_file(Pathname.new(path).basename.to_s)
  ime.resources_build_phase.add_file_reference(ref)
end

# ══════════════════════════════════════════════════════════════════════════════
# Target 2: Byakaron (SwiftUI main app — the shippable product)
# ══════════════════════════════════════════════════════════════════════════════
app = project.new_target(:application, 'Byakaron', :osx, '26.0')

app_settings = common.merge(
  'INFOPLIST_FILE'            => 'ByakaronSpell/Resources/Info-shell.plist',
  'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.nuhu.byakaron.spell',
  'MACOSX_DEPLOYMENT_TARGET'  => '26.0',
  # Distinct Swift module name so it doesn't collide with the IME target, which
  # compiles under module "Byakaron". The product/bundle stays "Byakaron".
  'PRODUCT_MODULE_NAME'       => 'Byakaron_Spell',
)
with_config(app, debug_only.merge(app_settings), release_only.merge(app_settings))

add_swift_sources(project, app, 'Byakaron', PROJECT_ROOT / 'ByakaronSpell/Sources')

link_system_framework(project, app, 'SwiftUI')
link_system_framework(project, app, 'AppKit')
link_system_framework(project, app, 'Carbon')

# dictionary.json is loaded by SpellEngine.loadFromBundle().
app_data_group = project.main_group.new_group('Byakaron-Data', 'data')
dict_ref = app_data_group.new_file('dictionary.json')
app.resources_build_phase.add_file_reference(dict_ref)

# App icon (reuse the IME's icns).
app_res_group = project.main_group.new_group('Byakaron-Resources', 'Byakaron/Resources')
app.resources_build_phase.add_file_reference(app_res_group.new_file('AppIcon.icns'))

# ── Embed the IME inside the main app ─────────────────────────────────────────
# Build the IME first, then copy ByakaronIME.app into
# Contents/Library/InputMethods/ of the main app.
app.add_dependency(ime)

embed_phase = app.new_copy_files_build_phase('Embed Input Method')
embed_phase.symbol_dst_subfolder_spec = :wrapper
embed_phase.dst_path = 'Contents/Library/InputMethods'
ime_product = ime.product_reference
embed_ref = embed_phase.add_file_reference(ime_product)
embed_ref.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy', 'CodeSignOnCopy'] }

# ── Schemes ───────────────────────────────────────────────────────────────────
[[app, true], [ime, false]].each do |target, is_default|
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  run = Xcodeproj::XCScheme::LaunchAction.new(nil)
  run.build_configuration = 'Debug'
  scheme.launch_action = run
  scheme.save_as(PROJECT_PATH, target.name, is_default)
end

project.save

puts "Generated: #{PROJECT_PATH}"
puts "Targets: #{project.targets.map(&:name).join(', ')}"
puts "Main app 'Byakaron' embeds 'ByakaronIME' at Contents/Library/InputMethods/"
