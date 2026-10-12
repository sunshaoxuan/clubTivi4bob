/// Shared UI state for the platform-specific desktop update workers.
/// The Windows-prefixed names are retained for source compatibility.
enum WindowsUpdatePhase {
  idle,
  checking,
  upToDate,
  manualRequired,
  available,
  starting,
  downloading,
  verifying,
  ready,
  authorizing,
  awaitingExit,
  backingUp,
  installing,
  installed,
  failed,
}

class WindowsUpdateState {
  const WindowsUpdateState(
    this.phase, {
    this.version,
    this.percent,
    this.message,
    this.receivedBytes,
    this.totalBytes,
    this.requiresAuthorization = false,
    this.authorizationCancelled = false,
  });

  final WindowsUpdatePhase phase;
  final String? version;
  final int? percent;
  final String? message;
  final int? receivedBytes;
  final int? totalBytes;
  final bool requiresAuthorization;
  final bool authorizationCancelled;

  bool get visible => phase != WindowsUpdatePhase.idle;

  bool get busy => const {
    WindowsUpdatePhase.checking,
    WindowsUpdatePhase.available,
    WindowsUpdatePhase.starting,
    WindowsUpdatePhase.downloading,
    WindowsUpdatePhase.verifying,
    WindowsUpdatePhase.backingUp,
    WindowsUpdatePhase.installing,
    WindowsUpdatePhase.authorizing,
    WindowsUpdatePhase.awaitingExit,
  }.contains(phase);

  String get label => switch (phase) {
    WindowsUpdatePhase.idle => '',
    WindowsUpdatePhase.checking => '正在检查更新',
    WindowsUpdatePhase.upToDate => '已是最新版本',
    WindowsUpdatePhase.manualRequired => '更新服务暂未就绪',
    WindowsUpdatePhase.available || WindowsUpdatePhase.starting => '准备下载更新',
    WindowsUpdatePhase.downloading =>
      percent == null ? '正在下载更新' : '正在下载 $percent%',
    WindowsUpdatePhase.verifying => '正在校验更新',
    WindowsUpdatePhase.ready => '更新已就绪',
    WindowsUpdatePhase.authorizing => '等待 Windows 授权',
    WindowsUpdatePhase.awaitingExit => '已授权，准备安装',
    WindowsUpdatePhase.backingUp => '正在备份旧版',
    WindowsUpdatePhase.installing => '正在安装更新',
    WindowsUpdatePhase.installed => '更新已完成',
    WindowsUpdatePhase.failed => '更新失败，点击重试',
  };

  String get description =>
      message ??
      switch (phase) {
        WindowsUpdatePhase.checking => '正在连接 BobTV 更新服务，请稍候。',
        WindowsUpdatePhase.upToDate => '更新服务已确认，当前版本无需升级。',
        WindowsUpdatePhase.manualRequired => '安全安装包暂未提供，请稍后重试。无需到浏览器手工下载。',
        WindowsUpdatePhase.ready =>
          requiresAuthorization
              ? '已下载并校验通过。点击安装更新，在 Windows 提示中授权后会自动关闭 BobTV 并安装。'
              : '已下载并校验通过，关闭 BobTV 后自动安装。',
        WindowsUpdatePhase.authorizing => '请在 Windows 系统授权窗口中确认。取消授权会保留当前版本。',
        WindowsUpdatePhase.awaitingExit => 'Windows 已授权，关闭 BobTV 后即可完成安装。',
        WindowsUpdatePhase.installed => '当前版本已更新。',
        WindowsUpdatePhase.failed => '更新未完成，当前版本可继续使用。请重试或查看更新日志。',
        _ => '更新正在准备或处理中，尚未达到可安装状态。下载校验完成后才能安装。',
      };

  /// Do not replace active download or installation feedback with a new check.
  bool get canCheck => switch (phase) {
    WindowsUpdatePhase.idle ||
    WindowsUpdatePhase.upToDate ||
    WindowsUpdatePhase.manualRequired ||
    WindowsUpdatePhase.failed ||
    WindowsUpdatePhase.installed => true,
    _ => false,
  };

  static WindowsUpdateState? fromWorkerStatus(
    Map<String, dynamic> data, {
    required String version,
    String? runId,
    int? workerPid,
  }) {
    if (data['version'] != version ||
        (runId != null && data['runId'] != runId) ||
        (workerPid != null && data['workerPid'] != workerPid)) {
      return null;
    }
    final phase = switch (data['phase']) {
      'starting' || 'waiting' => WindowsUpdatePhase.starting,
      'downloading' => WindowsUpdatePhase.downloading,
      'verifying' => WindowsUpdatePhase.verifying,
      'ready' => WindowsUpdatePhase.ready,
      'authorizing' => WindowsUpdatePhase.authorizing,
      'awaitingExit' => WindowsUpdatePhase.awaitingExit,
      'backingUp' => WindowsUpdatePhase.backingUp,
      'installing' => WindowsUpdatePhase.installing,
      'installed' => WindowsUpdatePhase.installed,
      'failed' => WindowsUpdatePhase.failed,
      _ => null,
    };
    if (phase == null) return null;
    final percent = data['percent'];
    return WindowsUpdateState(
      phase,
      version: version,
      percent: percent is num ? percent.toInt().clamp(0, 100) : null,
      message: data['message'] is String ? data['message'] as String : null,
      receivedBytes: data['receivedBytes'] is num
          ? (data['receivedBytes'] as num).toInt()
          : null,
      totalBytes: data['totalBytes'] is num
          ? (data['totalBytes'] as num).toInt()
          : null,
      requiresAuthorization: data['requiresAuthorization'] == true,
      authorizationCancelled: data['authorizationCancelled'] == true,
    );
  }
}
