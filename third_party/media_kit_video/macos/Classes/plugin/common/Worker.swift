// https://stackoverflow.com/questions/49043257/how-to-ensure-to-run-some-code-on-same-background-thread/49075382#49075382
import Foundation

class Worker {
  public typealias Job = () -> Void

  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSRecursiveLock()
  private var thread: Thread!
  private var queue = [Job]()
  private var canceled: Bool = false
  private var accepting: Bool = true

  init() {
    thread = Thread(block: loop)
    thread.start()
  }

  public func cancel() {
    signalCancel()
    thread.cancel()
  }

  public func enqueue(_ job: @escaping Job) {
    let accepted = locked {
      guard accepting else { return false }
      queue.append(job)
      return true
    }
    if accepted { semaphore.signal() }
  }

  // Drain the running job, discard queued frame work, then release native
  // resources on their owning thread before acknowledging disposal.
  public func shutdown(_ cleanup: @escaping Job) {
    let accepted = locked {
      guard accepting else { return false }
      accepting = false
      queue.removeAll()
      queue.append {
        cleanup()
        self.cancel()
      }
      return true
    }
    if accepted { semaphore.signal() }
  }

  private func loop() {
    while true {
      semaphore.wait()

      if isCanceled() {
        return
      }

      if let job = getFirstJob() { job() }
    }
  }

  private func signalCancel() {
    locked {
      canceled = true
      accepting = false
      queue.removeAll()
    }

    semaphore.signal()
  }

  private func isCanceled() -> Bool {
    let c = locked {
      canceled
    }

    return c
  }

  private func getFirstJob() -> Job? {
    let job = locked {
      queue.isEmpty ? nil : queue.removeFirst()
    }

    return job
  }

  private func locked<T>(do block: () -> T) -> T {
    lock.lock()
    defer {
      lock.unlock()
    }

    return block()
  }
}
