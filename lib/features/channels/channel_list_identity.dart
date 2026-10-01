/// Resolves a channel against the current list after discovery or filtering.
/// Positions are transient, while channel IDs remain stable across rebuilds.
class ChannelListIdentity {
  const ChannelListIdentity._();

  /// Fullscreen must retain the playing channel even when filters exclude it.
  static List<T> includingCurrent<T>(
    List<T> channels, T current, String Function(T channel) idOf,
  ) => indexOf(channels, idOf(current), idOf) >= 0
      ? List<T>.of(channels)
      : [current, ...channels];

  static int indexOf<T>(
    List<T> channels,
    String? channelId,
    String Function(T channel) idOf,
  ) {
    if (channelId == null) return -1;
    return channels.indexWhere((channel) => idOf(channel) == channelId);
  }

  static bool matches(String? channelId, String visibleChannelId) =>
      channelId != null && channelId == visibleChannelId;
}
