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
]
framework_paths_to_add = ['$(PROJECT_DIR)/libs/MoltenVK']
links_to_add = %w[
  -lpyrowave -lgranite-vulkan -lgranite-math -lgranite-threading
  -lgranite-filesystem -lgranite-path -lgranite-volk -lspirv-cross-core
  -lgranite-stb -lgranite-util -lgranite-application-global
  -framework MoltenVK
]
defines_to_add = %w[
  HAVE_PYROWAVE=1 GRANITE_VULKAN_SYSTEM_HANDLES=1
  GRANITE_VULKAN_SPIRV_CROSS=1 PYROWAVE_PRECISION=1
  _DARWIN_C_SOURCE=1 _LIBCPP_REMOVE_TRANSITIVE_INCLUDES=1
]

project.targets.each do |target|
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
    links_to_add.each { |l| ld << l unless ld.include?(l) }
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

project.save
puts "Successfully integrated PyroWave into Xcode project"
RUBY
