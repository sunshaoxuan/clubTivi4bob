#ifndef RUNNER_UPDATE_BOOTSTRAP_H_
#define RUNNER_UPDATE_BOOTSTRAP_H_

// Returns false when recovery has been delegated to the detached rollback
// worker. The caller must exit before that worker can restore loaded files.
bool PrepareUpdateLaunch();

// A normal window close does not count as a failed startup.
void RecordNormalUpdateShutdown();

#endif  // RUNNER_UPDATE_BOOTSTRAP_H_
