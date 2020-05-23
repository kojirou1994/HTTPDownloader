import Foundation
import NIO
import AsyncHTTPClient
import NIOHTTP1
import KwiftUtility

public final class HTTPClientFileDownloader: HTTPClientResponseDelegate {

  public typealias ProgressHandler = (Int64, Int64) -> Void

  init(handle: NIOFileHandle, io: NonBlockingFileIO, onProgressChange: ProgressHandler?) {
    self.handle = handle
    self.io = io
    startDate = .init()
    self.onProgressChange = onProgressChange
  }

  public struct Response {
    let startDate: Date
    let endDate: Date

    var interval: TimeInterval {
      endDate.timeIntervalSince(startDate)
    }
  }

  let handle: NIOFileHandle
  let io: NonBlockingFileIO
  //  var _buffer = ByteBuffer.init(ByteBufferView.init())
  let startDate: Date
  private var currentBytes: Int64 = 0
  private var totalBytes: Int64 = 0
  private let onProgressChange: ProgressHandler?

  public func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
    //    dump(head.headers)
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
    .init(startDate: startDate, endDate: .init())
  }

  deinit {
    do {
      try handle.close()
    } catch {
      print("Failed to close file handle \(error)")
    }
  }
}

public enum HTTPDownloaderError: Error {
  case invalidStatus(HTTPResponseHead)
}

public protocol HTTPDownloaderTaskInfoProtocol {
  var url: URL { get }
  var outputURL: URL { get }
  var watchProgress: Bool { get }
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
  func downloadProgressChanged(downloader: HTTPDownloader<Self>, info: TaskInfo, total: Int64, downloaded: Int64)
  func downloadFinished(downloader: HTTPDownloader<Self>, info: TaskInfo, result: Result<HTTPClientFileDownloader.Response, Error>)
  func downloadAllFinished(downloader: HTTPDownloader<Self>)

}

public final class HTTPDownloader<D: HTTPDownloaderDelegate> {
  private let httpClient: HTTPClient
  private let fileIO: NonBlockingFileIO
  private let ioPool = NIOThreadPool(numberOfThreads: 1)
  private let maxCoucurrent: Int

  public private(set) var queue = Queue<D.TaskInfo>()
  private var downloadingCount = 0
  private let queueLock: NSRecursiveLock = .init()
  private let delegate: D
  private let delegateThreadPool = NIOThreadPool(numberOfThreads: 1)

  public init(httpClient: HTTPClient, maxCoucurrent: Int = 2, delegate: D) {
    ioPool.start()
    delegateThreadPool.start()
    fileIO = .init(threadPool: ioPool)
    self.httpClient = httpClient
    self.maxCoucurrent = maxCoucurrent
    self.delegate = delegate
  }

  @inlinable
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

  public func download<C>(contentsOf infos: C) where C: Sequence, C.Element == D.TaskInfo {
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
      while downloadingCount < maxCoucurrent, let firstItem = queue.removeFirst() {
        downloadingCount += 1
        _download(info: firstItem)
      }
    }
  }

  private func _download(info: D.TaskInfo) {
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

      let httpHandler = HTTPClientFileDownloader(handle: handle, io: fileIO, onProgressChange: handler)
      let task = try httpClient.execute(request: HTTPClient.Request(url: info.url),
                                        delegate: httpHandler)
      _ = task.futureResult.always { result in
        self.delegateThreadPool.submit { _ in
          self.delegate.downloadFinished(downloader: self, info: info, result: result)
        }
        self.downloadNextItem(hasFinishedItem: true)
      }
      delegateThreadPool.submit { _ in
        self.delegate.downloadStarted(downloader: self, info: info, task: task)
      }
    } catch {
      delegateThreadPool.submit { _ in
        self.delegate.downloadFinished(downloader: self, info: info, result: .failure(error))
      }
    }
  }
}
