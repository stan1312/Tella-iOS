#!/usr/bin/env ruby
# SPECTRE Capture — adds the SPECTRE sources to the Tella Xcode project (idempotent).
#   * Tella/Spectre/*.swift                  -> target "Tella"
#   * SpectreCore/Sources/SpectreCore/*.swift -> target "Tella" (compiled in-app with CryptoKit)
#   * TellaTests/Spectre*.swift              -> target "TellaTests"
# Usage: gem install xcodeproj && ruby scripts/xcode_integrate_spectre.rb
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'Tella.xcodeproj'))
app = project.targets.find { |t| t.name == 'Tella' } or abort 'target Tella not found'
tests = project.targets.find { |t| t.name == 'TellaTests' }

def ensure_group(parent, name, path)
  parent.children.find { |c| c.respond_to?(:display_name) && c.display_name == name } ||
    parent.new_group(name, path)
end

def add_files(project, group, dir, pattern, target)
  added = 0
  # drop references to files that no longer exist (renames)
  group.files.each do |f|
    next if File.exist?(File.join(dir, f.path.to_s))
    target.source_build_phase.remove_file_reference(f)
    f.remove_from_project
  end
  Dir.glob(File.join(dir, pattern)).sort.each do |abs|
    rel = File.basename(abs)
    next if group.files.any? { |f| f.path == rel }
    ref = group.new_reference(rel)
    target.add_file_references([ref])
    added += 1
  end
  added
end

tella_group = project.main_group.children.find { |c| c.display_name == 'Tella' } or abort 'group Tella not found'
spectre_group = ensure_group(tella_group, 'Spectre', 'Spectre')
n1 = add_files(project, spectre_group, File.join(root, 'Tella/Spectre'), '*.swift', app)

core_group = ensure_group(project.main_group, 'SpectreCore', 'SpectreCore/Sources/SpectreCore')
n2 = add_files(project, core_group, File.join(root, 'SpectreCore/Sources/SpectreCore'), '*.swift', app)

n3 = 0
if tests
  tests_group = project.main_group.children.find { |c| c.display_name == 'TellaTests' }
  n3 = add_files(project, tests_group, File.join(root, 'TellaTests'), 'Spectre*.swift', tests) if tests_group
end

project.save
puts "SPECTRE files added: app=#{n1} core=#{n2} tests=#{n3}"
