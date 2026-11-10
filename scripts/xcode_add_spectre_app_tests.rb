#!/usr/bin/env ruby
# SPECTRE Capture — creates the "SpectreAppTests" unit-test target (hosted by the Tella app)
# and its shared scheme. Separate from Tella's own "TellaTests", whose upstream sources
# (VaultManagerTests, ModelStubs, MockCryptoManager) no longer compile against Tella 3.3.
# Idempotent. Usage: gem install xcodeproj && ruby scripts/xcode_add_spectre_app_tests.rb
require 'xcodeproj'

root = File.expand_path('..', __dir__)
path = File.join(root, 'Tella.xcodeproj')
project = Xcodeproj::Project.open(path)
app = project.targets.find { |t| t.name == 'Tella' } or abort 'target Tella not found'
name = 'SpectreAppTests'

target = project.targets.find { |t| t.name == name }
unless target
  target = project.new_target(:unit_test_bundle, name, :ios, '15.0', nil, :swift)
  target.add_dependency(app)
end
target.build_configurations.each do |c|
  s = c.build_settings
  s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Tella.app/Tella'
  s['BUNDLE_LOADER'] = '$(TEST_HOST)'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'ch.spectre.capture.apptests'
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['CODE_SIGN_STYLE'] = 'Automatic'
end

group = project.main_group.children.find { |c| c.display_name == name } || project.main_group.new_group(name, name)
Dir.glob(File.join(root, name, '*.swift')).sort.each do |abs|
  rel = File.basename(abs)
  next if group.files.any? { |f| f.path == rel }
  target.add_file_references([group.new_reference(rel)])
end
# Stale reference left in TellaTests after the move
tests = project.targets.find { |t| t.name == 'TellaTests' }
if tests
  tests.source_build_phase.files.select { |bf| bf.file_ref && bf.file_ref.path.to_s == 'SpectreIntegrationTests.swift' }.each do |bf|
    ref = bf.file_ref
    tests.source_build_phase.remove_build_file(bf)
    ref.remove_from_project
  end
end
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(target)
scheme.set_launch_target(app)
scheme.save_as(path, name, true)
puts "#{name}: target + shared scheme ready"
