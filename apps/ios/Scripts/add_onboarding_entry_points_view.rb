#!/usr/bin/env ruby
# add_onboarding_entry_points_view.rb
#
# Idempotently register ios/App/OnboardingEntryPointsView.swift in the
# Tono target's Sources build phase using the xcodeproj gem (no regex).
#
# Background: OnboardingEntryPointsView.swift exists on disk and is the
# view referenced by TonoApp.swift:57 ("OnboardingEntryPointsView { ... }").
# Without this file being a member of the Tono target, the Swift compiler
# cannot find the symbol and the build fails with:
#   error: cannot find 'OnboardingEntryPointsView' in scope
#
# Run from repo root:
#   ruby ios/Scripts/add_onboarding_entry_points_view.rb

require "xcodeproj"

PROJECT_PATH = File.expand_path(File.join(__dir__, "..", "Tono.xcodeproj"))
APP_GROUP    = "App"
FILENAME     = "OnboardingEntryPointsView.swift"

abort "Project not found at #{PROJECT_PATH}" unless Dir.exist?(PROJECT_PATH)

project     = Xcodeproj::Project.open(PROJECT_PATH)
host_target = project.targets.find { |t| t.name == "Tono" }
abort "Host target 'Tono' not found" unless host_target

app_group = project.main_group.find_subpath(APP_GROUP, false)
app_group ||= project.main_group.new_group(APP_GROUP, APP_GROUP)

# Find or create the file reference inside the App group.
file_ref = app_group.files.find { |f| f.display_name == FILENAME }
unless file_ref
  file_ref = app_group.new_reference(FILENAME)
  puts "  added file reference: App/#{FILENAME}"
else
  puts "  file reference already present: App/#{FILENAME}"
end

# Add to the host target's Sources build phase (idempotent).
sources_phase = host_target.source_build_phase
already_linked = sources_phase.files.any? { |bf| bf.file_ref == file_ref }
if already_linked
  puts "  already in Tono Sources build phase"
else
  sources_phase.add_file_reference(file_ref)
  puts "  linked OnboardingEntryPointsView.swift into Tono Sources build phase"
end

project.save
puts "saved: #{PROJECT_PATH}"
