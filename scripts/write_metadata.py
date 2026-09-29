#!/usr/bin/env python3
import plistlib
from pathlib import Path
root=Path(__file__).resolve().parents[1]/'ios'/'VO1DMessenger'
info={'CFBundleDisplayName':'VO1D','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'$(PRODUCT_NAME)','CFBundlePackageType':'APPL','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],'UISupportedInterfaceOrientations~ipad':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'NSCameraUsageDescription':'Камера нужна для сканирования QR-приглашения собеседника.','NSMicrophoneUsageDescription':'Микрофон нужен для записи голосовых сообщений.','NSFaceIDUsageDescription':'Face ID защищает доступ к личным сообщениям.','UIUserInterfaceStyle':'Dark','ITSAppUsesNonExemptEncryption':True}
(root/'Info.plist').write_bytes(plistlib.dumps(info))
info['NSAppTransportSecurity']={'NSAllowsArbitraryLoads':True}
(root/'Info.Debug.plist').write_bytes(plistlib.dumps(info))
privacy={'NSPrivacyTracking':False,'NSPrivacyTrackingDomains':[],'NSPrivacyCollectedDataTypes':[], 'NSPrivacyAccessedAPITypes':[]}
(root/'PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps(privacy))
