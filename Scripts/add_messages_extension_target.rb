#!/usr/bin/env ruby
# add_messages_extension_target.rb
#
# Idempotently register the TonoMessagesExtension (iMessage Extension) target
# inside Tono.xcodeproj using the `xcodeproj` Ruby gem.
#
# Steps performed (idempotent — running twice is safe):
#   1. Create TonoMessagesExtension target group if missing, add file references
#      for MessagesViewController.swift, Info.plist, TonoMessagesExtension.entitlements.
#   2. Create PBXNativeTarget "TonoMessagesExtension" (productType
#      com.apple.product-type.app-extension.messages).
#   3. Add PBXSourcesBuildPhase including MessagesViewController.swift
#      + all Shared/*.swift (excluding *Tests.swift).
#   4. Set TonoMessagesExtension build settings (bundle id, entitlements, INFOPLIST_FILE).
#   5. Add Embed Foundation Extensions phase entry for TonoMessagesExtension.appex.
#   6. Add PBXTargetDependency + PBXContainerItemProxy from host to messages ext.
#   7. Save project.
#
# Usage:
#   ruby ios/scripts/add_messages_extension_target.rb
#
# Prereq: `gem install xcodeproj` (already installed in this profile).

require "xcodeproj"

PROJECT_PATH    = File.expand_path(File.join(__dir__, "..", "Tono.xcodeproj"))
MESSAGES_DIR_REL = "TonoMessagesExtension"
SHARED_DIR_REL  = "Shared"

abort "Project not found at #{PROJECT_PATH}" unless Dir.exist?(PROJECT_PATH)

project     = Xcodeproj::Project.open(PROJECT_PATH)
host_target = project.targets.find { |t| t.name == "Tono" }
abort "Host target 'Tono' not found" unless host_target

def phase_has_file?(phase, ref)
  phase.files.any? { |bf| bf.file_ref == ref }
end

# ── 1. TonoMessagesExtension file references ─────────────────────────────────
messages_group = project.main_group.find_subpath(MESSAGES_DIR_REL, false)
messages_group ||= project.main_group.new_group(MESSAGES_DIR_REL, MESSAGES_DIR_REL)

def find_or_add_file(group, basename)
  ref = group.files.find { |f| f.display_name == basename }
  return ref if ref
  group.new_reference(basename)
end

messages_vc_ref      = find_or_add_file(messages_group, "MessagesViewController.swift")
messages_info_ref    = find_or_add_file(messages_group, "Info.plist")
messages_entitle_ref = find_or_add_file(messages_group, "TonoMessagesExtension.entitlements")

# ── 2. PBXNativeTarget ────────────────────────────────────────────────────
messages_target = project.targets.find { |t| t.name == "TonoMessagesExtension" }
unless messages_target
  messages_target = project.new_target(
    :messages_extension,
    "TonoMessagesExtension",
    :ios,
    "16.0",
    project.products_group,
    :swift
  )
  puts "  created PBXNativeTarget TonoMessagesExtension"
end

sources_phase = messages_target.source_build_phase

# ── 3. Sources phase: MessagesViewController + Shared/ ───────────────────────
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
  puts "  wired #{added} Shared/*.swift files into TonoMessagesExtension sources"
end

[messages_vc_ref].each do |ref|
  unless phase_has_file?(sources_phase, ref)
    sources_phase.add_file_reference(ref)
    puts "  added #{ref.display_name} to Sources phase"
  end
end

# ── 4. Build settings for TonoMessagesExtension ───────────────────────────────
messages_target.build_configurations.each do |cfg|
  base = {
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.tonoit.app.messages",
    "INFOPLIST_FILE"            => "#{MESSAGES_DIR_REL}/Info.plist",
    "CODE_SIGN_ENTITLEMENTS"    => "#{MESSAGES_DIR_REL}/TonoMessagesExtension.entitlements",
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
    base["PROVISIONING_PROFILE_SPECIFIER"] = "ASC AppStore com.tonoit.app.messages"
  end
  base.each { |k, v| cfg.build_settings[k] = v }
end

# ── 5. Embed Foundation Extensions phase on host Tono target ─────────────
embed_phase = host_target.copy_files_build_phases.find do |p|
  p.symbol_dst_subfolder_spec == :plug_ins
end
unless embed_phase
  embed_phase = host_target.new_copy_files_build_phase("Embed Foundation Extensions")
  embed_phase.symbol_dst_subfolder_spec = :plug_ins
  embed_phase.dst_path = ""
  puts "  created Embed Foundation Extensions build phase"
end

messages_product_ref = messages_target.product_reference
unless embed_phase.files.any? { |bf| bf.file_ref == messages_product_ref }
  embed_phase.add_file_reference(messages_product_ref)
  puts "  added TonoMessagesExtension.appex to Embed Foundation Extensions"
end

# ── 6. PBXTargetDependency + PBXContainerItemProxy ───────────────────────
existing_dep = host_target.dependencies.find do |d|
  d.target == messages_target rescue false
end
unless existing_dep
  host_target.add_dependency(messages_target)
  puts "  added PBXTargetDependency host -> TonoMessagesExtension"
end

project.save

puts "\n✓ Saved #{PROJECT_PATH}"
puts "Messages extension buildable name: #{messages_target.product_reference.path}"
