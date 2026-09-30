// swift-tools-version: 5.9
import PackageDescription

let package = Package(name:"EmbeddedTor",platforms:[.iOS(.v17)],products:[.library(name:"EmbeddedTor",targets:["EmbeddedTor"])],targets:[
    .binaryTarget(name:"tor",url:"https://github.com/iCepa/Tor.framework/releases/download/v409.13.1/tor.xcframework.zip",checksum:"851174402abc8655273264f6b877a625648e52e6f9dd490b35e7cb94c2c924c6"),
    .target(name:"EmbeddedTor",dependencies:["tor"],linkerSettings:[.linkedLibrary("z"),.linkedLibrary("resolv"),.linkedFramework("Security"),.linkedFramework("SystemConfiguration")])
])
