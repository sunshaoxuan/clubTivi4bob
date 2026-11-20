#!/usr/bin/env ruby
# Creates a separate, simulator-only XCTest harness. Does not modify Runner.
require 'fileutils'
require 'xcodeproj'
root=File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(root)
FileUtils.cp(File.join(__dir__, 'native_ui_probe.swift'), File.join(root,'NativeProbe.swift'))
p=Xcodeproj::Project.new(File.join(root,'NativeProbe.xcodeproj'))
t=p.new_target(:ui_test_bundle,'NativeProbe',:ios,'13.0')
f=p.main_group.new_file('NativeProbe.swift');t.source_build_phase.add_file_reference(f)
t.build_configurations.each do |c|
 c.build_settings['PRODUCT_BUNDLE_IDENTIFIER']='com.briconbric.bobtv.nativeprobe'
 c.build_settings['GENERATE_INFOPLIST_FILE']='YES'
 c.build_settings['SWIFT_VERSION']='5.0'
 c.build_settings['CODE_SIGNING_ALLOWED']='NO'
 c.build_settings['TARGETED_DEVICE_FAMILY']='1,2'
end
p.save
scheme=Xcodeproj::XCScheme.new
scheme.add_build_target(t);scheme.add_test_target(t);scheme.save_as(p.path,'NativeProbe',true)
puts p.path
