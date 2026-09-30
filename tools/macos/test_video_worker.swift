import Foundation

@main
struct VideoWorkerTests {
  static func main() {
    for _ in 0..<100 {
      let worker = Worker()
      let started = DispatchSemaphore(value: 0)
      let unblock = DispatchSemaphore(value: 0)
      let done = DispatchSemaphore(value: 0)
      let lock = NSLock()
      var events = [String]()
      func record(_ value: String) {
        lock.lock(); events.append(value); lock.unlock()
      }
      worker.enqueue {
        started.signal()
        unblock.wait()
        record("running-frame-finished")
      }
      precondition(started.wait(timeout: .now() + 2) == .success)
      worker.enqueue { record("obsolete-frame") }
      worker.shutdown {
        record("render-context-freed")
        done.signal()
      }
      worker.enqueue { record("late-frame") }
      precondition(done.wait(timeout: .now() + .milliseconds(1)) == .timedOut)
      unblock.signal()
      precondition(done.wait(timeout: .now() + 2) == .success)
      lock.lock()
      precondition(events == ["running-frame-finished", "render-context-freed"])
      lock.unlock()
    }
    print("PASS: 100 worker shutdown cycles drain in-flight frames and reject queued/late work")
  }
}
