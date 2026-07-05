#!/usr/bin/env ruby
# Adds TonoRewrite.shortcut as a bundle resource to the Tono app target.
# Idempotent: if the file reference already exists, this script is a no-op.

require 'xcodeproj'

PROJECT_PATH = '/Users/Ezra/Projects/apps/tono/ios/Tono.xcodeproj'
SHORTCUT_REL = '../shortcuts/TonoRewrite.shortcut'
TARGET_NAME = 'Tono'
GROUP_NAME = 'App'

project = Xcodeproj::Project.open(PROJECT_PATH)

target = project.targets.find { |t| t.name == TARGET_NAME }
abort "Target #{TARGET_NAME} not found" unless target

group = project.main_group[GROUP_NAME]
abort "Group #{GROUP_NAME} not found" unless group

# Idempotency: if a file reference with this path is already in the group, skip.
existing = group.files.find { |f| f.path == SHORTCUT_REL }
if existing
  # But make sure it's in the resources build phase.
  already_built = target.resources_build_phase.files_references.include?(existing)
  if already_built
    puts "TonoRewrite.shortcut already in #{GROUP_NAME} group and Tono target resources phase. Nothing to do."
    exit 0
  else
    puts "TonoRewrite.shortcut exists in #{GROUP_NAME} group but NOT in resources build phase — adding."
    target.resources_build_phase.add_file_reference(existing)
    project.save
    puts "Saved #{PROJECT_PATH}"
    exit 0
  end
end

file_ref = group.new_reference(SHORTCUT_REL)
# last_known_file_type is auto-detected for .shortcut; verify.
puts "Created file ref: path=#{file_ref.path} type=#{file_ref.last_known_file_type}"

target.resources_build_phase.add_file_reference(file_ref)
project.save
puts "Saved #{PROJECT_PATH} — TonoRewrite.shortcut added to #{GROUP_NAME} group and Tono target resources phase."