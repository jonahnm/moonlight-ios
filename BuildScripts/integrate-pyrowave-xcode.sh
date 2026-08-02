#!/bin/bash
# Integrate PyroWave files into the Xcode project
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PROJECT_DIR="$SCRIPT_DIR/.."

# Backup
cp "$PROJECT_DIR/Moonlight.xcodeproj/project.pbxproj" \
   "$PROJECT_DIR/Moonlight.xcodeproj/project.pbxproj.bak"

ruby << 'RUBY'
require 'xcodeproj'

project_path = File.join(ENV['PROJECT_DIR'], 'Moonlight.xcodeproj')
project = Xcodeproj::Project.open(project_path)

main_group = project.main_group
stream_group = main_group['Moonlight']['Stream'] || begin
  sg = main_group['Moonlight'].new_group('Stream', 'Stream')
  sg
end

files_to_add = ['PyroWaveRenderer.h', 'PyroWaveRenderer.mm', 'PyroWaveShaders.h']
files_to_add.each do |f|
  file_ref = stream_group.new_file(f)
  project.targets.each do |target|
    unless target.source_build_phase.files_references.include?(file_ref)
      target.add_file_references([file_ref])
    end
  end
end

lib_paths_to_add = [
  '$(PROJECT_DIR)/libs/Granite/lib',
  '$(PROJECT_DIR)/libs/PyroWave/lib',
]
header_paths_to_add = [
  '$(PROJECT_DIR)/libs/Granite/include',
  '$(PROJECT_DIR)/libs/PyroWave/include',
  '$(PROJECT_DIR)/libs/MoltenVK/include',
  '$(PROJECT_DIR)/libs/SDL2/include',
]
framework_paths_to_add = ['$(PROJECT_DIR)/libs/MoltenVK']
# Auto-detect Granite libs from libs/Granite/lib/
granite_libs = Dir.glob(File.join(ENV['PROJECT_DIR'], 'libs', 'Granite', 'lib', '*.a'))
               .map { |f| "-l" + File.basename(f).sub(/^lib/, '').sub(/\.a$/, '') }
links_to_add = %w[-lpyrowave] + granite_libs
frameworks_to_add = %w[MoltenVK QuartzCore Metal IOSurface IOKit]
ios_only_frameworks = %w[IOKit]
defines_to_add = %w[
  HAVE_PYROWAVE=1 GRANITE_VULKAN_SYSTEM_HANDLES=1
  GRANITE_VULKAN_SPIRV_CROSS=1 PYROWAVE_PRECISION=1
  _LIBCPP_HAS_NO_WIDE_CHARACTERS=1
]

project.targets.each do |target|
  # Detect whether this target targets tvOS by checking SDKROOT in its configs
  is_tvos = target.build_configurations.any? do |config|
    sdkroot = config.build_settings['SDKROOT']
    sdkroot.to_s.match?(/appletv/)
  end

  target.build_configurations.each do |config|
    hs = (config.build_settings['HEADER_SEARCH_PATHS'] || [])
    hs = hs.split if hs.is_a?(String)
    header_paths_to_add.each { |p| hs << p unless hs.include?(p) }
    config.build_settings['HEADER_SEARCH_PATHS'] = hs

    ls = (config.build_settings['LIBRARY_SEARCH_PATHS'] || [])
    ls = ls.split if ls.is_a?(String)
    lib_paths_to_add.each { |p| ls << p unless ls.include?(p) }
    config.build_settings['LIBRARY_SEARCH_PATHS'] = ls

    fs = (config.build_settings['FRAMEWORK_SEARCH_PATHS'] || [])
    fs = fs.split if fs.is_a?(String)
    framework_paths_to_add.each { |p| fs << p unless fs.include?(p) }
    config.build_settings['FRAMEWORK_SEARCH_PATHS'] = fs

    ld = (config.build_settings['OTHER_LDFLAGS'] || [])
    ld = ld.split if ld.is_a?(String)
    ld << '$(inherited)' unless ld.include?('$(inherited)')
    links_to_add.each { |l| ld << l unless ld.include?(l) }
    # Skip iOS-only frameworks (e.g. IOKit) on tvOS targets
    frameworks_to_add.reject { |fw| is_tvos && ios_only_frameworks.include?(fw) }.each do |fw|
      pair = ['-framework', fw]
      ld.concat(pair) unless ld.each_cons(2).include?(pair)
    end
    config.build_settings['OTHER_LDFLAGS'] = ld

    config.build_settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
    config.build_settings['CLANG_CXX_LIBRARY'] = 'libc++'

    gcc = (config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] || ['$(inherited)'])
    gcc = gcc.split if gcc.is_a?(String)
    gcc << '$(inherited)' unless gcc.include?('$(inherited)')
    defines_to_add.each { |d| gcc << d unless gcc.include?(d) }
    config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = gcc
  end
end

# Add MoltenVK.framework to Embed Frameworks phase
moltenvk_path = File.join(ENV['PROJECT_DIR'], 'libs', 'MoltenVK', 'MoltenVK.framework')
# Always embed if MoltenVK.framework exists (it's restored from cache)
if File.directory?(moltenvk_path)
  # Find or create the Embed Frameworks build phase
  embed_phase = nil
  project.targets.first.build_phases.each do |bp|
    if bp.isa == 'PBXCopyFilesBuildPhase' && bp.name == 'Embed Frameworks'
      embed_phase = bp
      break
    end
  end
  unless embed_phase
    embed_phase = project.new(Xcodeproj::Project::PBXCopyFilesBuildPhase)
    embed_phase.name = 'Embed Frameworks'
    embed_phase.dst_subfolder_spec = '10'  # frameworks
    project.targets.first.build_phases << embed_phase
  end
  # Add framework file ref if not already present
  ref = project.frameworks_group.files.find { |f| f.path == 'MoltenVK.framework' }
  unless ref
    ref = project.frameworks_group.new_file('libs/MoltenVK/MoltenVK.framework')
    project.targets.first.frameworks_build_phase.add_file_reference(ref)
  end
  embed_phase.add_file_reference(ref) unless embed_phase.files_references.include?(ref)
end

project.save
puts "Successfully integrated PyroWave into Xcode project"
RUBY
