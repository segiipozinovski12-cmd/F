import Foundation
import Darwin
import EmbeddedTor

@MainActor
final class EmbeddedTorManager: ObservableObject {
    static let shared = EmbeddedTorManager()
    @Published private(set) var progress = 0
    @Published private(set) var ready = false
    @Published private(set) var status = "Tor не запущен"
    private var started = false
    private var exited = false
    private var configuredBridges = ""
    private var cookieURL: URL?
    static let socksPort = 19050
    nonisolated private static let controlPort = 19051

    nonisolated static func bridgeLines(_ text: String) throws -> [String] {
        let lines = text.split(whereSeparator:\.isNewline).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.count <= 8 else { throw MessengerError.invalid("Поддерживается до 8 мостов") }
        for line in lines {
            // Native C-Tor supports vanilla bridges. External obfs4/snowflake processes
            // are not available in the iOS sandbox and must not be silently simulated.
            guard line.range(of:"^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}:[0-9]{1,5} [A-Fa-f0-9]{40}$",options:.regularExpression) != nil else {
                throw MessengerError.invalid("Мост: IPv4:порт и 40-символьный отпечаток. obfs4 и Snowflake здесь не встроены.")
            }
            let pieces = line.split(separator:" ")[0].split(separator:":")
            guard pieces.count == 2, let port = Int(pieces[1]), (1...65535).contains(port),
                  pieces[0].split(separator:".").allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) else { throw MessengerError.invalid("Неверный адрес моста") }
        }
        return lines
    }
    func start(bridges: String) async throws {
        let lines = try Self.bridgeLines(bridges), canonical = lines.joined(separator:"\n")
        guard !exited else { throw MessengerError.invalid("Tor завершился. Полностью перезапусти приложение.") }
        if started, configuredBridges != canonical { throw MessengerError.invalid("Мосты изменены. Полностью перезапусти приложение, чтобы Tor применил их.") }
        if !started {
            let directory = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("VO1D-Tor",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete,.posixPermissions:0o700])
            var excluded = directory; var resources = URLResourceValues(); resources.isExcludedFromBackup = true; try excluded.setResourceValues(resources)
            cookieURL = directory.appendingPathComponent("control_auth_cookie")
            var args = ["--ignore-missing-torrc","-f",directory.appendingPathComponent("torrc").path,
                "--DataDirectory",directory.path,"--SocksPort","127.0.0.1:\(Self.socksPort) IsolateSOCKSAuth",
                "--ControlPort","127.0.0.1:\(Self.controlPort)","--CookieAuthentication","1",
                "--CookieAuthFile",cookieURL!.path,"--ClientOnly","1","--AvoidDiskWrites","1",
                "--SafeLogging","1","--Log","err stderr","--quiet"]
            if !lines.isEmpty { args += ["--UseBridges","1"]; for line in lines { args += ["--Bridge",line] } }
            started = true; configuredBridges = canonical; status = "Tor запускается"
            let arguments = args
            DispatchQueue(label:"io.vo1d.tor",qos:.utility).async { [weak self] in
                let result = EmbeddedTorCore.run(arguments:arguments)
                Task { @MainActor in self?.exited = true; self?.ready = false; self?.status = "Tor завершился (\(result))" }
            }
        }
        if ready { return }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try Task.checkCancellation()
            guard !exited else { throw MessengerError.invalid("Tor не смог запуститься") }
            if let cookieURL, let cookie = try? Data(contentsOf:cookieURL), cookie.count == 32 {
                if let value = try? await Task.detached(priority:.utility,operation:{ try Self.bootstrap(cookie:cookie) }).value {
                    progress = value; status = "Tor подключается · \(value)%"
                    if value == 100 { ready = true; status = "Tor готов"; return }
                }
            }
            try await Task.sleep(for:.milliseconds(500))
        }
        throw MessengerError.invalid("Tor ещё подключается. Сообщения остаются в очереди; прямое подключение запрещено.")
    }
    nonisolated private static func bootstrap(cookie: Data) throws -> Int {
        let fd = Darwin.socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw MessengerError.invalid("Контроллер Tor недоступен") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec:2,tv_usec:0)
        _ = setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(controlPort).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw MessengerError.invalid("Tor ещё запускается") }
        func exchange(_ command: String) throws -> String {
            let bytes = Data((command + "\r\n").utf8)
            let sent = bytes.withUnsafeBytes { Darwin.send(fd,$0.baseAddress,bytes.count,0) }
            guard sent == bytes.count else { throw MessengerError.invalid("Контроллер Tor не отвечает") }
            var data = Data(), buffer = [UInt8](repeating:0,count:4096)
            while data.count < 16384 {
                let size = Darwin.recv(fd,&buffer,buffer.count,0)
                guard size > 0 else { throw MessengerError.invalid("Контроллер Tor не отвечает") }
                data.append(contentsOf:buffer.prefix(size))
                if let text = String(data:data,encoding:.utf8), text.hasSuffix("250 OK\r\n") { return text }
                if let text = String(data:data,encoding:.utf8), text.hasPrefix("5") { throw MessengerError.invalid("Контроллер Tor отклонил запрос") }
            }
            throw MessengerError.invalid("Неверный ответ контроллера Tor")
        }
        _ = try exchange("AUTHENTICATE \(Crypto.hex(cookie))")
        let response = try exchange("GETINFO status/bootstrap-phase")
        guard let range = response.range(of:"PROGRESS=[0-9]{1,3}",options:.regularExpression), let value = Int(response[range].dropFirst(9)), (0...100).contains(value) else { throw MessengerError.invalid("Неверный статус Tor") }
        return value
    }
}
