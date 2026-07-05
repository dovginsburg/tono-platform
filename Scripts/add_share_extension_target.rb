#!/usr/bin/env ruby
# add_share_extension_target.rb
#
# Idempotently register the TonoShare (iOS Share Extension) target inside
# Tono.xcodeproj using the `xcodeproj` Ruby gem.
#
# This is the v1.0 wiring for the Apple-blocked-keyboard fallback (Dov
# 2026-07-01). The script does NOT regex-edit project.pbxproj — it uses
# the xcodeproj gem's AST API, so Xcode can re-open the project after
# the script runs.
#
# Steps performed (idempotent — running twice is safe):
#   1. Rename host target PRODUCT_NAME "Tono it" -> "Tono" in Debug+Release
#      build configs (display-name collision fix per architecture skill).
#   2. Rename host product_reference path "Tono it.app" -> "Tono.app".
#   3. Create ShareExtension target group if missing, add file references
#      for ShareRootView.swift, ShareViewController.swift, Info.plist,
#      and ShareExtension.entitlements.
#   4. Create PBXNativeTarget "TonoShare" (productType
#      com.apple.product-type.app-extension).
#   5. Add PBXSourcesBuildPhase including ShareRootView + ShareViewController
#      + all Shared/*.swift (excluding *Tests.swift).
#   6. Set TonoShare build settings (bundle id, entitlements, INFOPLIST_FILE).
#   7. Add Embed Foundation Extensions phase entry for TonoShare.appex.
#   8. Add PBXTargetDependency + PBXContainerItemProxy from host to share.
#   9. Save project.
#
# Usage:
#   ruby ios/scripts/add_share_extension_target.rb
#
# Prereq: `gem install xcodeproj` (already installed in this profile).

require "xcodeproj"

PROJECT_PATH   = File.expand_path(File.join(__dir__, "..", "Tono.xcodeproj"))
SHARE_DIR_REL  = "ShareExtension"
SHARED_DIR_REL = "Shared"

abort "Project not found at #{PROJECT_PATH}" unless Dir.exist?(PROJECT_PATH)

project     = Xcodeproj::Project.open(PROJECT_PATH)
host_target = project.targets.find { |t| t.name == "Tono" }
abort "Host target 'Tono' not found" unless host_target

# Helper: skip if file_ref already wired into this build phase.
def phase_has_file?(phase, ref)
  phase.files.any? { |bf| bf.file_ref == ref }
end

# ── 1. Display-name rename ────────────────────────────────────────────────
host_target.build_configurations.each do |cfg|
  if cfg.build_settings["PRODUCT_NAME"] == "Tono it"
    cfg.build_settings["PRODUCT_NAME"] = "Tono"
    puts "  renamed PRODUCT_NAME -> Tono (#{cfg.name})"
  end
end

# Update the host product reference's visible path so the .app folder
# name matches the new PRODUCT_NAME. The build follows PRODUCT_NAME; this
# is purely cosmetic so Xcode and Finder show "Tono.app" not "Tono it.app".
if host_target.product_reference.path == "Tono it.app"
  host_target.product_reference.path = "Tono.app"
  puts "  renamed product_reference -> Tono.app"
end

# ── 2. ShareExtension file references ─────────────────────────────────────
share_group = project.main_group.find_subpath(SHARE_DIR_REL, false)
share_group ||= project.main_group.new_group(SHARE_DIR_REL, SHARE_DIR_REL)

def find_or_add_file(group, basename)
  ref = group.files.find { |f| f.display_name == basename }
  return ref if ref
  group.new_reference(basename)
end

share_root_ref    = find_or_add_file(share_group, "ShareRootView.swift")
share_vc_ref      = find_or_add_file(share_group, "ShareViewController.swift")
share_info_ref    = find_or_add_file(share_group, "Info.plist")
share_entitle_ref = find_or_add_file(share_group, "ShareExtension.entitlements")

# ── 3. PBXNativeTarget ────────────────────────────────────────────────────
share_target = project.targets.find { |t| t.name == "TonoShare" }
unless share_target
  share_target = project.new_target(
    :app_extension,
    "TonoShare",
    :ios,
    "16.0",
    project.products_group,
    :swift
  )
  puts "  created PBXNativeTarget TonoShare"
end

sources_phase = share_target.source_build_phase

# ── 4. Sources phase: ShareRootView + ShareViewController + Shared/ ───────
# Add Shared/ sources (ToneEngine, TonoBackend, SharedKeychain, etc.) so
# the share extension has the same rewrite engine the keyboard uses.
shared_group = project.main_group.find_subpath(SHARED_DIR_REL, false)
if shared_group
  added = 0
  shared_group.files.each do |file_ref|
    next unless file_ref.path && file_ref.path.end_with?(".swift")
    next if file_ref.path.end_with?("Tests.swift")
    unless phase_has_file?(sources_phase, file_ref)
      sources_phase.add_file_reference(file_ref)
      added += 1
    end
  end
  puts "  wired #{added} Shared/*.swift files into TonoShare sources"
end

[share_root_ref, share_vc_ref].each do |ref|
  unless phase_has_file?(sources_phase, ref)
    sources_phase.add_file_reference(ref)
    puts "  added #{ref.display_name} to Sources phase"
  end
end

# ── 5. Build settings for TonoShare ───────────────────────────────────────
share_target.build_configurations.each do |cfg|
  base = {
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.tonoit.app.share",
    "INFOPLIST_FILE"            => "#{SHARE_DIR_REL}/Info.plist",
    "CODE_SIGN_ENTITLEMENTS"    => "#{SHARE_DIR_REL}/ShareExtension.entitlements",
    "CODE_SIGN_STYLE"           => "Automatic",
    "DEVELOPMENT_TEAM"          => "4938S9TTBM",
    "SKIP_INSTALL"              => "YES",
    "TARGETED_DEVICE_FAMILY"    => "1,2",
    "SDKROOT"                   => "iphoneos",
    "LD_RUNPATH_SEARCH_PATHS"   => [
      "$(inherited)",
      "@executable_path/Frameworks",
      "@executable_path/../../Frameworks",
    ],
    "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
    "COMPILER_INDEX_STORE_ENABLE"       => "NO",
    "SWIFT_VERSION"                     => "5.0",
  }
  if cfg.name == "Debug"
    base["PROVISIONING_PROFILE_SPECIFIER"] = ""
  else
    base["PROVISIONING_PROFILE_SPECIFIER"] = "ASC AppStore com.tonoit.app.share"
  end
  base.each { |k, v| cfg.build_settings[k] = v }
end

# ── 6. Embed Foundation Extensions phase on host Tono target ─────────────
embed_phase = host_target.copy_files_build_phases.find do |p|
  p.symbol_dst_subfolder_spec == :plug_ins
end
unless embed_phase
  embed_phase = host_target.new_copy_files_build_phase("Embed Foundation Extensions")
  embed_phase.symbol_dst_subfolder_spec = :plug_ins
  embed_phase.dst_path = ""
  puts "  created Embed Foundation Extensions build phase"
end

share_product_ref = share_target.product_reference
unless embed_phase.files.any? { |bf| bf.file_ref == share_product_ref }
  embed_phase.add_file_reference(share_product_ref)
  puts "  added TonoShare.appex to Embed Foundation Extensions"
end

# ── 7. PBXTargetDependency + PBXContainerItemProxy ───────────────────────
existing_dep = host_target.dependencies.find do |d|
  d.target == share_target rescue false
end
unless existing_dep
  host_target.add_dependency(share_target)
  puts "  added PBXTargetDependency host -> TonoShare"
end

project.save

puts "\n✅ Saved #{PROJECT_PATH}"
puts "Share target buildable name: #{share_target.product_reference.path}"