import { readFileSync, writeFileSync } from 'fs';
import crypto from 'crypto';

const PBXPROJ = '/home/aerith/moonlight-ios/Moonlight.xcodeproj/project.pbxproj';
let content = readFileSync(PBXPROJ, 'utf8');

function uuid() {
  return 'P' + crypto.randomUUID().replace(/-/g, '').substring(0, 23).toUpperCase();
}

// Source file records
const srcRefs = [
  { type: 'sourcecode.c.h', name: 'PyroWaveRenderer.h', path: 'Limelight/Stream/PyroWaveRenderer.h' },
  { type: 'sourcecode.cpp.objcpp', name: 'PyroWaveRenderer.mm', path: 'Limelight/Stream/PyroWaveRenderer.mm' },
  { type: 'sourcecode.c.h', name: 'PyroWaveShaders.h', path: 'Limelight/Stream/PyroWaveShaders.h' },
];

// Library file records
const libRefs = [
  { type: 'archive.ar', name: 'libpyrowave.a', path: 'libs/PyroWave/lib/libpyrowave.a' },
  { type: 'archive.ar', name: 'libgranite-vulkan.a', path: 'libs/Granite/lib/libgranite-vulkan.a' },
  { type: 'archive.ar', name: 'libgranite-math.a', path: 'libs/Granite/lib/libgranite-math.a' },
  { type: 'archive.ar', name: 'libgranite-threading.a', path: 'libs/Granite/lib/libgranite-threading.a' },
  { type: 'archive.ar', name: 'libgranite-filesystem.a', path: 'libs/Granite/lib/libgranite-filesystem.a' },
  { type: 'archive.ar', name: 'libgranite-path.a', path: 'libs/Granite/lib/libgranite-path.a' },
  { type: 'archive.ar', name: 'libgranite-volk.a', path: 'libs/Granite/lib/libgranite-volk.a' },
  { type: 'archive.ar', name: 'libspirv-cross-core.a', path: 'libs/Granite/lib/libspirv-cross-core.a' },
  { type: 'archive.ar', name: 'libgranite-stb.a', path: 'libs/Granite/lib/libgranite-stb.a' },
  { type: 'archive.ar', name: 'libgranite-util.a', path: 'libs/Granite/lib/libgranite-util.a' },
  { type: 'archive.ar', name: 'libgranite-application-global.a', path: 'libs/Granite/lib/libgranite-application-global.a' },
  { type: 'wrapper.framework', name: 'MoltenVK.framework', path: 'libs/MoltenVK/MoltenVK.framework' },
];

// Assign UUIDs
const uuidMap = {};
const allRefs = [...srcRefs, ...libRefs];
for (const ref of allRefs) {
  uuidMap[ref.name] = uuid();
}

// ===== 1. Add PBXBuildFile entries =====
let bfEntries = '';
for (const ref of allRefs) {
  const buildUuid = uuid();
  bfEntries += `\t\t${buildUuid} /* ${ref.name} in Frameworks */ = {isa = PBXBuildFile; fileRef = ${uuidMap[ref.name]} /* ${ref.name} */; };\n`;
}

content = content.replace(
  /(\/\* End PBXBuildFile section \*\/)/,
  `${bfEntries}$1`
);

// ===== 2. Add PBXFileReference entries =====
let frEntries = '';
for (const ref of allRefs) {
  frEntries += `\t\t${uuidMap[ref.name]} /* ${ref.name} */ = {isa = PBXFileReference; lastKnownFileType = ${ref.type}; name = ${ref.name}; path = ${ref.path}; sourceTree = "<group>"; };\n`;
}

content = content.replace(
  /(\/\* End PBXFileReference section \*\/)/,
  `${frEntries}$1`
);

// ===== 3. Add source files to Sources build phase =====
// Find the Sources build phase - look for the files array that contains .m files
// We need to add our .mm source file there
for (const ref of srcRefs) {
  const buildUuid = findBuildUuid(content, ref.name);
  // Add to the Sources phase files array - find the Sources phase files list
  // We look for PBXSourcesBuildPhase section with a files array
  // For simplicity, find the first PBXSourcesBuildPhase's files array
  content = content.replace(
    /(PBXSourcesBuildPhase[^}]*files = \()/,
    `$1\n\t\t\t\t${buildUuid} /* ${ref.name} in Sources */,`
  );
}

// ===== 4. Add library/framework files to Frameworks build phase =====
for (const ref of libRefs) {
  const buildUuid = findBuildUuid(content, ref.name);
  content = content.replace(
    /(PBXFrameworksBuildPhase[^}]*files = \()/,
    `$1\n\t\t\t\t${buildUuid} /* ${ref.name} in Frameworks */,`
  );
}

// ===== 5. Add files to Limelight/Stream group =====
// Find the PBXGroup for Limelight/Stream and add children
content = content.replace(
  /(path = Limelight;[\s\S]*?children = \(\n[\s\S]*?\n\t\t\t\);)/,
  (match) => {
    // Find the Stream subgroup inside Limelight
    return match;
  }
);

// Actually, let's just find the Stream group and add children there
// The Stream group has path = "Stream" and is inside Limelight
content = content.replace(
  /(name = Stream;[\s\S]*?path = Stream;[\s\S]*?children = \(\n)([\s\S]*?)(\n\t\t\t\);)/,
  (match, before, children, after) => {
    let newChildren = children;
    for (const ref of srcRefs) {
      const childRef = uuidMap[ref.name];
      if (!newChildren.includes(childRef)) {
        newChildren += `\t\t\t\t${childRef} /* ${ref.name} */,\n`;
      }
    }
    return `${before}${newChildren}${after}`;
  }
);

// ===== 6. Add library groups and files =====
// Add libs group if it doesn't exist, or add to it
// Look for a group with path = "libs"
if (!content.includes('path = libs;')) {
  // Need to add libs group - add it at root level
  content = content.replace(
    /(mainGroup = [A-Z0-9]{24};)/,
    (match) => {
      return match;
    }
  );
}

// Add library files to the root group's children
// Find the main group's children array
content = content.replace(
  /(children = \(\n)([\s\S]*?)(\n\t\t\t\);)/m,
  (match, before, children, after) => {
    if (children.includes('MoltenVK.framework')) return match; // Already added
    let newChildren = children;
    for (const ref of libRefs) {
      const childRef = uuidMap[ref.name];
      if (!newChildren.includes(childRef)) {
        newChildren += `\t\t\t\t${childRef} /* ${ref.name} */,\n`;
      }
    }
    return `${before}${newChildren}${after}`;
  }
);

// ===== 7. Add xcconfig reference =====
// First add a PBXFileReference for the xcconfig
const xcconfigUuid = uuid();
const xcconfigEntry = `\t\t${xcconfigUuid} /* PyroWave.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = PyroWave.xcconfig; path = Configs/PyroWave.xcconfig; sourceTree = "<group>"; };\n`;

content = content.replace(
  /(\/\* End PBXFileReference section \*\/)/,
  `${xcconfigEntry}$1`
);

// Add xcconfig to root group
content = content.replace(
  /(children = \(\n)([\s\S]*?)(\n\t\t\t\);)/m,
  (match, before, children, after) => {
    if (children.includes('PyroWave.xcconfig')) return match;
    return `${before}${children}\t\t\t\t${xcconfigUuid} /* PyroWave.xcconfig */,${after}`;
  }
);

// ===== 8. Add xcconfig reference to all build configurations =====
// Find each XCBuildConfiguration and add the xcconfig reference
content = content.replace(
  /(buildSettings = \{\n)/g,
  (match) => match
);

// For each build configuration, set the baseConfigurationReference
// Look for configurations that don't already have one
content = content.replace(
  /(name = (Debug|Release)\n\t\t\t);/g,
  (match, p1) => {
    if (content.includes(`baseConfigurationReference = ${xcconfigUuid}`)) return match;
    return `baseConfigurationReference = ${xcconfigUuid} /* PyroWave.xcconfig */;\n${p1});`;
  }
);

writeFileSync(PBXPROJ.replace('.pbxproj', '.pbxproj.modified'), content, 'utf8');
console.log('Generated patched project.pbxproj.modified');
console.log('Reviewed ' + allRefs.length + ' file references');
