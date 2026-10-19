#!/usr/bin/env python3
"""Rebuild the checked-in Xcode project without XcodeGen or other packages."""
from pathlib import Path
import hashlib, json, plistlib

root = Path(__file__).resolve().parent.parent
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(object_key, **values):
    key = ident(object_key); objects[key] = values; return key
def ref(name): return ident(name)
sources = sorted((root / "Margherita").glob("*.swift"))
build_files = []
children = []
for path in sources:
    f = obj("file:" + path.name, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
    children.append(f)
    build_files.append(obj("build:" + path.name, isa="PBXBuildFile", fileRef=f))
assets = obj("assets", isa="PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Assets.xcassets", sourceTree="<group>")
children.append(assets)
children.append(obj("info", isa="PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
sounds = obj("sound-folder", isa="PBXFileReference", lastKnownFileType="folder", path="Resources", sourceTree="<group>")
children.append(sounds)
licenses = obj("license-folder", isa="PBXFileReference", lastKnownFileType="folder", path="Licenses", sourceTree="<group>")
children.append(licenses)
resources = obj("resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647,
                files=[obj("build-assets", isa="PBXBuildFile", fileRef=assets), obj("build-sounds", isa="PBXBuildFile", fileRef=sounds), obj("build-licenses", isa="PBXBuildFile", fileRef=licenses)], runOnlyForDeploymentPostprocessing=0)
source_phase = obj("sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=build_files, runOnlyForDeploymentPostprocessing=0)
frameworks = obj("frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
product = obj("product", isa="PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="Margherita.app", sourceTree="BUILT_PRODUCTS_DIR")
product_group = obj("products", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>")
source_group = obj("source-group", isa="PBXGroup", children=children, path="Margherita", sourceTree="<group>")
main_group = obj("main-group", isa="PBXGroup", children=[source_group, product_group], sourceTree="<group>")
project_configs, target_configs = [], []
for name in ["Debug", "Release"]:
    base = dict(SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="13.0", SWIFT_VERSION="5.0",
                CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", GCC_C_LANGUAGE_STANDARD="gnu17",
                ALWAYS_SEARCH_USER_PATHS="NO", ONLY_ACTIVE_ARCH="YES" if name=="Debug" else "NO",
                DEBUG_INFORMATION_FORMAT="dwarf" if name=="Debug" else "dwarf-with-dsym")
    if name == "Debug": base.update(SWIFT_OPTIMIZATION_LEVEL="-Onone", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG")
    else: base.update(SWIFT_OPTIMIZATION_LEVEL="-O", SWIFT_COMPILATION_MODE="wholemodule")
    project_configs.append(obj("project-" + name, isa="XCBuildConfiguration", buildSettings=base, name=name))
    settings = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.oscar.margherita",
                    INFOPLIST_FILE="Margherita/Info.plist", GENERATE_INFOPLIST_FILE="NO",
                    CODE_SIGN_IDENTITY="-", CODE_SIGN_STYLE="Manual", CODE_SIGNING_ALLOWED="YES",
                    DEVELOPMENT_TEAM="", ENABLE_APP_SANDBOX="NO", ENABLE_HARDENED_RUNTIME="NO",
                    ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", COMBINE_HIDPI_IMAGES="YES",
                    LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks"],
                    SWIFT_EMIT_LOC_STRINGS="NO", MARKETING_VERSION="1.0.1", CURRENT_PROJECT_VERSION="1.0.1")
    target_configs.append(obj("target-" + name, isa="XCBuildConfiguration", buildSettings=settings, name=name))
pc = obj("project-configs", isa="XCConfigurationList", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
tc = obj("target-configs", isa="XCConfigurationList", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
target = obj("target", isa="PBXNativeTarget", buildConfigurationList=tc, buildPhases=[source_phase, frameworks, resources],
             buildRules=[], dependencies=[], name="Margherita", productName="Margherita", productReference=product, productType="com.apple.product-type.application")
project = obj("project", isa="PBXProject", attributes={"BuildIndependentTargetsInParallel":"YES", "LastSwiftUpdateCheck":"1500", "LastUpgradeCheck":"1500"},
              buildConfigurationList=pc, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0,
              knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=[target])
def emit(value, depth=0):
    pad = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join("\t"*(depth+1) + json.dumps(str(k)) + " = " + emit(v, depth+1) + ";\n" for k,v in value.items()) + pad + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t"*(depth+1)+emit(v, depth+1)+",\n" for v in value) + pad + ")"
    if isinstance(value, int): return str(value)
    return json.dumps(str(value))
project_dir = root / "Margherita.xcodeproj"
project_dir.mkdir(exist_ok=True)
project_data = dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)
(project_dir/"project.pbxproj").write_text("// !$*UTF8*$!\n" + emit(project_data) + "\n")
scheme_dir = project_dir/"xcshareddata"/"xcschemes"
scheme_dir.mkdir(parents=True,exist_ok=True)
(scheme_dir/"Margherita.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
  <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Margherita.app" BlueprintName="Margherita" ReferencedContainer="container:Margherita.xcodeproj"/>
  </BuildActionEntry></BuildActionEntries>
 </BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Margherita.app" BlueprintName="Margherita" ReferencedContainer="container:Margherita.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Margherita.app" BlueprintName="Margherita" ReferencedContainer="container:Margherita.xcodeproj"/></BuildableProductRunnable>
 </ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
plist = dict(CFBundleDevelopmentRegion="en", CFBundleDisplayName="Margherita", CFBundleExecutable="$(EXECUTABLE_NAME)",
             CFBundleIconName="AppIcon", CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleInfoDictionaryVersion="6.0",
             CFBundleName="$(PRODUCT_NAME)", CFBundlePackageType="APPL", CFBundleShortVersionString="1.0.1", CFBundleVersion="1.0.1",
             LSMinimumSystemVersion="13.0", NSHighResolutionCapable=True, NSPrincipalClass="NSApplication",
             NSHumanReadableCopyright="Margherita. Free, local, yours.",
             SUFeedURL="https://github.com/REPLACE_OWNER/REPLACE_REPOSITORY/releases/latest/download/appcast.xml",
             SUPublicEDKey="REPLACE_WITH_GENERATE_KEYS_PUBLIC_KEY",
             SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUVerifyUpdateBeforeExtraction=True,
             NSAppleEventsUsageDescription="Margherita controls installed Office and iWork apps only when you request document conversion. Allow Automation to use their layout export engines.")
with (root/"Margherita"/"Info.plist").open("wb") as f: plistlib.dump(plist,f)
print("Generated Margherita.xcodeproj and shared Run scheme.")
