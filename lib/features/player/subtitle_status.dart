enum SubtitlePhase {
  idle,
  searching,
  warming,
  synchronizing,
  unavailable,
  channelUnsupported,
  serviceUnavailable,
  programmeUnavailable,
  suspended,
  connecting,
  ready,
  englishFallback,
}

extension SubtitlePhaseMessage on SubtitlePhase {
  String? get message => switch (this) {
    SubtitlePhase.idle || SubtitlePhase.ready => null,
    SubtitlePhase.searching => '正在查找字幕…',
    SubtitlePhase.warming => '字幕服务准备中…',
    SubtitlePhase.synchronizing => '正在同步字幕…',
    SubtitlePhase.unavailable => '暂未找到可用字幕',
    SubtitlePhase.channelUnsupported => '该频道尚未接入外部字幕',
    SubtitlePhase.serviceUnavailable => '字幕服务暂不可用',
    SubtitlePhase.programmeUnavailable => '缺少节目信息，暂无法查找字幕',
    SubtitlePhase.suspended => '插播期间暂停字幕',
    SubtitlePhase.connecting => '正在接入字幕…',
    SubtitlePhase.englishFallback => '正在使用英文字幕',
  };

  bool get busy => const {
    SubtitlePhase.searching,
    SubtitlePhase.warming,
    SubtitlePhase.synchronizing,
    SubtitlePhase.connecting,
  }.contains(this);
}
