import Foundation

/// Only ciphertext is checkpointed. Keys and plaintext never enter this cache.
final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Data,Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var file: FileHandle?
    private var path: URL?
    private var offset = 0
    private var total = 0
    private var failure: Error?
    private let maximum = 50*1024*1024+64
    private let guardLock = NSLock()

    static var directory: URL {
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("VO1D-ciphertext",isDirectory:true)
    }
    static func clear() { try? FileManager.default.removeItem(at:directory) }

    func download(_ source: URLRequest,id: String,configuration: URLSessionConfiguration) async throws -> Data {
        guard id.range(of:"^[A-Za-z0-9_-]{40,64}$",options:.regularExpression) != nil else { throw MessengerError.invalid("Неверный ID загрузки") }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try FileManager.default.createDirectory(at:Self.directory,withIntermediateDirectories:true)
                    let path=Self.directory.appendingPathComponent(id)
                    self.path=path
                    let attrs=try? FileManager.default.attributesOfItem(atPath:path.path)
                    offset=(attrs?[.size] as? NSNumber)?.intValue ?? 0
                    if offset>maximum { try FileManager.default.removeItem(at:path); offset=0 }
                    if !FileManager.default.fileExists(atPath:path.path) {
                        guard FileManager.default.createFile(atPath:path.path,contents:Data(),
                            attributes:[.protectionKey:FileProtectionType.complete]) else { throw MessengerError.invalid("Не удалось создать временный шифрованный файл") }
                    }
                    file=try FileHandle(forWritingTo:path)
                    try file?.seekToEnd()
                    var request=source
                    if offset>0 { request.setValue("bytes=\(offset)-",forHTTPHeaderField:"Range") }
                    let queue=OperationQueue(); queue.maxConcurrentOperationCount=1
                    let session=URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
                    self.session=session; self.continuation=continuation
                    let task=session.dataTask(with:request)
                    guardLock.lock(); self.task=task; guardLock.unlock()
                    task.resume()
                    if Task.isCancelled { task.cancel() }
                } catch { try? file?.close(); file=nil; continuation.resume(throwing:error) }
            }
        } onCancel: {
            self.guardLock.lock(); let task=self.task; self.guardLock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http=response as? HTTPURLResponse else { throw MessengerError.invalid("Нет ответа файла") }
            guard [200,206].contains(http.statusCode) else {
                if http.statusCode==416,let path { try? FileManager.default.removeItem(at:path) }
                throw HTTPFailure(status:http.statusCode,detail:"Ошибка загрузки \(http.statusCode)")
            }
            if http.statusCode==200 { try file?.truncate(atOffset:0); try file?.seek(toOffset:0); offset=0 }
            if http.statusCode==206 {
                let prefix="bytes \(offset)-"
                guard http.value(forHTTPHeaderField:"Content-Range")?.hasPrefix(prefix)==true else {
                    throw MessengerError.invalid("Неверный диапазон продолжения")
                }
            }
            total=offset
            guard response.expectedContentLength<0 || response.expectedContentLength+Int64(offset)<=Int64(maximum) else {
                throw MessengerError.invalid("Файл превышает лимит")
            }
            completionHandler(.allow)
        } catch { failure=error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive data: Data) {
        do {
            guard total+data.count<=maximum else { throw MessengerError.invalid("Файл превышает лимит") }
            try file?.write(contentsOf:data)
            total+=data.count
        } catch { failure=error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) {
        let result: Result<Data,Error>
        do {
            try file?.close(); file=nil
            if let failure { throw failure }
            if let error { throw error }
            guard let path else { throw MessengerError.invalid("Файл не сохранён") }
            let bytes=try Data(contentsOf:path,options:.mappedIfSafe)
            guard bytes.count>0, bytes.count<=maximum else { throw MessengerError.invalid("Неверный размер файла") }
            result = .success(bytes)
            try? FileManager.default.removeItem(at:path)
        } catch { result = .failure(error) }
        let saved=continuation; continuation=nil
        saved?.resume(with:result)
        session.finishTasksAndInvalidate()
        self.session=nil
    }
}
