import Foundation
import NIO
import AsyncHTTPClient
import NIOHTTP1
import DequeModule

public final class HTTPClientFileDownloader: HTTPClientResponseDelegate {

  public typealias ProgressHandler = (_ total: Int64, _ current: Int64) -> Void
  public typealias HeadHandler = (HTTPResponseHead) throws -> Void

  fileprivate init(handle: NIOFileHandle, io: NonBlockingFileIO,
       headHandler: @escaping HeadHandler, onProgressChange: ProgressHandler?) {
    self.handle = handle
    self.io = io
    startDate = .init()
    self.headHandler = headHandler
    self.onProgressChange = onProgressChange
  }

  public struct Response {
    let startDate: Date
    let endDate: Date

    var interval: TimeInterval {
      endDate.timeIntervalSince(startDate)
    }
  }

  private let handle: NIOFileHandle
  private let io: NonBlockingFileIO
  //  var _buffer = ByteBuffer.init(ByteBufferView.init())
  let startDate: Date
  private var currentBytes: Int64 = 0
  private var totalBytes: Int64 = 0
  private let headHandler: HeadHandler
  private let onProgressChange: ProgressHandler?

  var bytesAllDownloaded: Bool {
    totalBytes > 0 && currentBytes == totalBytes
  }

  public func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
    //    dump(head.headers)
    do {
      try headHandler(head)
    } catch {
      return task.eventLoop.makeFailedFuture(error)
    }

    switch head.status {
    case .ok:
      if let length = Int64(head.headers["Content-Length"].first ?? "") {
        totalBytes = length
        return io.changeFileSize(fileHandle: handle, size: length, eventLoop: task.eventLoop)
      } else {
        return task.eventLoop.makeSucceededFuture(())
      }
    default:
      return task.eventLoop.makeFailedFuture(HTTPDownloaderError.invalidStatus(head))
    }

  }

  public func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
    //    print(buffer.readableBytes)
    //    var copy = buffer
    //    _buffer.writeBuffer(&copy)
    //    if _buffer.readableBytes > 1_000_000 {
    //      let write = _buffer
    //      _buffer = .init(.init())
    //      print("Writing \(Thread.current)")
    //      return io.write(fileHandle: handle, buffer: write, eventLoop: task.eventLoop)
    //    } else {
    //      return task.eventLoop.makeSucceededFuture(())
    //    }
    currentBytes += numericCast(buffer.readableBytes)
    self.onProgressChange?(totalBytes, currentBytes)
    return io.write(fileHandle: handle, buffer: buffer, eventLoop: task.eventLoop)
  }

  public func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
    return .init(startDate: startDate, endDate: .init())
  }

  fileprivate func close() {
    try! handle.close()
  }

}

public enum HTTPDownloaderError: Error {
  case invalidStatus(HTTPResponseHead)
}

public protocol HTTPDownloaderTaskInfoProtocol {
  var url: URL { get }
  var outputURL: URL { get }
  var watchProgress: Bool { get }

  func request() throws -> HTTPClient.Request
}

extension HTTPDownloaderTaskInfoProtocol {
  public func request() throws -> HTTPClient.Request {
    try .init(url: url)
  }
}

public struct HTTPDownloaderTaskInfo: HTTPDownloaderTaskInfoProtocol {
  public init(url: URL, outputURL: URL, watchProgress:  Bool) {
    self.url = url
    self.outputURL = outputURL
    self.watchProgress = watchProgress
  }

  public let url: URL
  public let outputURL: URL
  public let watchProgress:  Bool
}

public protocol HTTPDownloaderDelegate {

  associatedtype TaskInfo: HTTPDownloaderTaskInfoProtocol = HTTPDownloaderTaskInfo

  func downloadWillStart(downloader: HTTPDownloader<Self>, info: TaskInfo)
  func downloadStarted(downloader: HTTPDownloader<Self>, info: TaskInfo, task: HTTPClient.Task<HTTPClientFileDownloader.Response>)
  func downloadDidReceiveHead(downloader: HTTPDownloader<Self>, info: TaskInfo, head: HTTPResponseHead) throws
  func downloadProgressChanged(downloader: HTTPDownloader<Self>, info: TaskInfo, total: Int64, downloaded: Int64)
  func downloadWillRetry(downloader: HTTPDownloader<Self>, info: TaskInfo, error: Error, restRetry: Int)
  func downloadFinished(downloader: HTTPDownloader<Self>, info: TaskInfo, result: Result<HTTPClientFileDownloader.Response, Error>)
  /// called when download queue is empty.
  func downloadAllFinished(downloader: HTTPDownloader<Self>)

}

public extension HTTPDownloaderDelegate {
  func downloadWillStart(downloader: HTTPDownloader<Self>, info: TaskInfo) {}

  func downloadStarted(downloader: HTTPDownloader<Self>, info: TaskInfo, task: HTTPClient.Task<HTTPClientFileDownloader.Response>) {}

  func downloadDidReceiveHead(downloader: HTTPDownloader<Self>, info: TaskInfo, head: HTTPResponseHead) throws {}

  func downloadProgressChanged(downloader: HTTPDownloader<Self>, info: TaskInfo, total: Int64, downloaded: Int64) {}

  func downloadWillRetry(downloader: HTTPDownloader<Self>, info: TaskInfo, error: Error, restRetry: Int) {}

  func downloadFinished(downloader: HTTPDownloader<Self>, info: TaskInfo, result: Result<HTTPClientFileDownloader.Response, Error>) {}

  func downloadAllFinished(downloader: HTTPDownloader<Self>) {}
}

public final class HTTPDownloader<D: HTTPDownloaderDelegate> {
  private let httpClient: HTTPClient
  private let fileIO: NonBlockingFileIO
  private let ioPool = NIOThreadPool(numberOfThreads: 1)
  private let maxCoucurrent: Int
  private let timeout: TimeAmount
  private let retryLimit: Int
  /// ignore error, check only file is all downloaded
  private let allowUncleanFinished: Bool

  public private(set) var queue = Deque<D.TaskInfo>()
  private var downloadingCount = 0
  private let queueLock: NSRecursiveLock = .init()
  private let delegate: D
  private let delegateThreadPool = NIOThreadPool(numberOfThreads: 1)

  public init(httpClient: HTTPClient,
              retryLimit: Int = 0,
              maxCoucurrent: Int = 2, timeout: TimeAmount = .minutes(1),
              allowUncleanFinished: Bool,
              delegate: D) {
    ioPool.start()
    delegateThreadPool.start()
    fileIO = .init(threadPool: ioPool)
    self.httpClient = httpClient
    self.retryLimit = retryLimit
    self.maxCoucurrent = maxCoucurrent
    self.timeout = timeout
    self.delegate = delegate
    self.allowUncleanFinished = allowUncleanFinished
  }

  deinit {
    try! ioPool.syncShutdownGracefully()
    try! delegateThreadPool.syncShutdownGracefully()
  }

  public func download(info: D.TaskInfo) {
    download(contentsOf: CollectionOfOne(info))
  }

  public func cancelAll() {
    queueLock.lock()
    defer {
      queueLock.unlock()
    }
    queue.removeAll()
  }

  public func download<C>(contentsOf infos: C) where C: Collection, C.Element == D.TaskInfo {
    if _slowPath(infos.isEmpty) {
      return
    }
    queueLock.lock()
    defer {
      queueLock.unlock()
    }
    queue.append(contentsOf: infos)
    downloadNextItem(hasFinishedItem: false)
  }

  private func downloadNextItem(hasFinishedItem: Bool) {
    queueLock.lock()
    defer {
      queueLock.unlock()
    }
    if hasFinishedItem {
      precondition(downloadingCount > 0)
      downloadingCount -= 1
    }
    if queue.isEmpty && downloadingCount == 0 {
      self.delegateThreadPool.submit { _ in
        self.delegate.downloadAllFinished(downloader: self)
      }
    } else {
      while downloadingCount < maxCoucurrent, !queue.isEmpty {
        let firstItem = queue.removeFirst()
        downloadingCount += 1
        _download(info: firstItem, restRetry: retryLimit)
      }
    }
  }

  private func _download(info: D.TaskInfo, restRetry: Int) {
    //    precondition(!fm.fileExistance(at: info.outputURL).exists)
    delegateThreadPool.submit { _ in
      self.delegate.downloadWillStart(downloader: self, info: info)
    }
    do {
      let handle = try NIOFileHandle(
        path: info.outputURL.path,
        mode: .write,
        flags: .allowFileCreation())

      let handler: HTTPClientFileDownloader.ProgressHandler?
      if info.watchProgress {
        handler =  { total, current in
          self.delegateThreadPool.submit { _ in
            self.delegate.downloadProgressChanged(downloader: self, info: info, total: total, downloaded: current)
          }
        }
      } else {
        handler = nil
      }

      let httpHandler = HTTPClientFileDownloader(handle: handle, io: fileIO, headHandler: { head in
        try self.delegate.downloadDidReceiveHead(downloader: self, info: info, head: head)
      }, onProgressChange: handler)
      let task = try httpClient.execute(request: info.request(),
                                        delegate: httpHandler,
                                        deadline: .now() + timeout)
      _ = task.futureResult.always { result in
        httpHandler.close()

        func retry(error: Error) {
          //retry
          let restRetry = restRetry - 1
          self.delegateThreadPool.submit { _ in
            self.delegate.downloadWillRetry(downloader: self, info: info, error: error, restRetry: restRetry)
          }
          self._download(info: info, restRetry: restRetry)
        }

        func finished() {
          self.delegateThreadPool.submit { _ in
            self.delegate.downloadFinished(downloader: self, info: info, result: result)
          }
          self.downloadNextItem(hasFinishedItem: true)
        }

        switch result {
        case .success:
          finished()
        case .failure(let error):
          if self.allowUncleanFinished, httpHandler.bytesAllDownloaded {
            finished()
          } else if restRetry > 0 {
            retry(error: error)
          } else {
            finished()
          }
        }
      }
      delegateThreadPool.submit { _ in
        self.delegate.downloadStarted(downloader: self, info: info, task: task)
      }
    } catch {
      // No retry handling
      delegateThreadPool.submit { _ in
        self.delegate.downloadFinished(downloader: self, info: info, result: .failure(error))
      }
    }
  }
}
