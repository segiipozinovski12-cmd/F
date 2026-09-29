#!/usr/bin/env python3
"""Regenerate the committed Xcode project with only Python's standard library."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'ios'
PROJECT = IOS / 'VO1DMessenger.xcodeproj'
PROJECT.mkdir(exist_ok=True)

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def q(value):
    return json.dumps(str(value))

objects = []
def obj(name, isa, fields):
    ident = uid(name)
    objects.append(f'{ident} = {{ isa = {isa}; {fields} }};')
    return ident

def array(items):
    return '(' + ', '.join(items) + (',' if items else '') + ')'

def ref_file(path, kind, root='SOURCE_ROOT'):
    return obj(path, 'PBXFileReference', f'lastKnownFileType = {kind}; path = {q(path)}; sourceTree = {q(root)};')

appfiles = sorted((IOS / 'VO1DMessenger').glob('*.swift'))
testfiles = sorted((IOS / 'VO1DMessengerTests').glob('*.swift'))
apprefs, testrefs, appbuild, testbuild = [], [], [], []
for files, refs, builds in [(appfiles, apprefs, appbuild), (testfiles, testrefs, testbuild)]:
    for file in files:
        path = file.relative_to(IOS).as_posix()
        ref = ref_file(path, 'sourcecode.swift'); refs.append(ref)
        builds.append(obj(path + ':build', 'PBXBuildFile', f'fileRef = {ref};'))
app_product = obj('app-product', 'PBXFileReference', 'explicitFileType = wrapper.application; path = VO1DMessenger.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product = obj('test-product', 'PBXFileReference', 'explicitFileType = wrapper.cfbundle; path = VO1DMessengerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', 'PBXGroup', f'children = {array([app_product,test_product])}; name = Products; sourceTree = "<group>";')
appgroup = obj('app-group', 'PBXGroup', f'children = {array(apprefs)}; name = VO1DMessenger; sourceTree = "<group>";')
testgroup = obj('test-group', 'PBXGroup', f'children = {array(testrefs)}; name = VO1DMessengerTests; sourceTree = "<group>";')
main = obj('main-group','PBXGroup',f'children = {array([appgroup,testgroup,products])}; sourceTree = "<group>";')
privacy = ref_file('VO1DMessenger/PrivacyInfo.xcprivacy', 'text.xml')
privacy_build = obj('privacy-build','PBXBuildFile',f'fileRef = {privacy};')
appsrc = obj('app-sources','PBXSourcesBuildPhase',f'buildActionMask = 2147483647; files = {array(appbuild)}; runOnlyForDeploymentPostprocessing = 0;')
testsrc = obj('test-sources','PBXSourcesBuildPhase',f'buildActionMask = 2147483647; files = {array(testbuild)}; runOnlyForDeploymentPostprocessing = 0;')
resources = obj('app-resources','PBXResourcesBuildPhase',f'buildActionMask = 2147483647; files = {array([privacy_build])}; runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('app-frameworks','PBXFrameworksBuildPhase','buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')

def configurations(name, settings):
    ids=[]
    for mode in ['Debug','Release']:
        allsettings=dict(settings)
        allsettings.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode=='Debug' else '-O', 'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym'})
        if mode == 'Debug':
            allsettings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
            allsettings['ENABLE_TESTABILITY']='YES'
        if name=='app':
            allsettings['INFOPLIST_FILE']='VO1DMessenger/Info.Debug.plist' if mode=='Debug' else 'VO1DMessenger/Info.plist'
        content=' '.join(f'{k} = {q(v)};' for k,v in allsettings.items())
        ids.append(obj(f'{name}-{mode}','XCBuildConfiguration',f'buildSettings = {{ {content} }}; name = {mode};'))
    return obj(name+'-configs','XCConfigurationList',f'buildConfigurations = {array(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

projectconfigs=configurations('project', {'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','GCC_C_LANGUAGE_STANDARD':'gnu17','ENABLE_USER_SCRIPT_SANDBOXING':'YES'})
appconfigs=configurations('app',{'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'io.vo1d.messenger','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic','MARKETING_VERSION':'1.0.0','CURRENT_PROJECT_VERSION':'1','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','SWIFT_EMIT_LOC_STRINGS':'YES','GENERATE_INFOPLIST_FILE':'NO'})
testconfigs=configurations('test',{'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'io.vo1d.messenger.tests','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic','GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/VO1DMessenger.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/VO1DMessenger','BUNDLE_LOADER':'$(TEST_HOST)','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
app=uid('app-target'); project=uid('project')
proxy=obj('test-proxy','PBXContainerItemProxy',f'containerPortal = {project}; proxyType = 1; remoteGlobalIDString = {app}; remoteInfo = VO1DMessenger;')
dep=obj('test-dep','PBXTargetDependency',f'target = {app}; targetProxy = {proxy};')
obj('app-target','PBXNativeTarget',f'buildConfigurationList = {appconfigs}; buildPhases = {array([appsrc,frameworks,resources])}; buildRules = (); dependencies = (); name = VO1DMessenger; productName = VO1DMessenger; productReference = {app_product}; productType = "com.apple.product-type.application";')
test=obj('test-target','PBXNativeTarget',f'buildConfigurationList = {testconfigs}; buildPhases = {array([testsrc])}; buildRules = (); dependencies = {array([dep])}; name = VO1DMessengerTests; productName = VO1DMessengerTests; productReference = {test_product}; productType = "com.apple.product-type.bundle.unit-test";')
obj('project','PBXProject',f'attributes = {{ LastUpgradeCheck = 1600; TargetAttributes = {{ {app} = {{ CreatedOnToolsVersion = 16.0; }}; {test} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {app}; }}; }}; }}; buildConfigurationList = {projectconfigs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ru; hasScannedForEncodings = 0; knownRegions = (ru,en,Base); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {array([app,test])};')
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
schemes=PROJECT/'xcshareddata'/'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
def buildref(ident,name,product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:VO1DMessenger.xcodeproj"/>'
ar=buildref(app,'VO1DMessenger','VO1DMessenger.app'); tr=buildref(test,'VO1DMessengerTests','VO1DMessengerTests.xctest')
(schemes/'VO1DMessenger.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ar}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{tr}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ar}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ar}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated', PROJECT)
