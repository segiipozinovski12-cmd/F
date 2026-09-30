import Foundation
import tor

/// Only the documented Tor embedding API is used. One daemon per process.
public enum EmbeddedTorCore {
    public static var version: String { String(cString:tor_api_get_provider_version()) }
    public static func run(arguments:[String]) -> Int32 {
        var argv = (["tor"] + arguments).map { strdup($0) } + [nil]
        defer { for value in argv { free(value) } }
        guard let config = tor_main_configuration_new() else { return -1 }
        defer { tor_main_configuration_free(config) }
        let result = argv.withUnsafeMutableBufferPointer { tor_main_configuration_set_command_line(config,Int32(arguments.count + 1),$0.baseAddress) }
        guard result == 0 else { return result }
        return tor_run_main(config)
    }
}
