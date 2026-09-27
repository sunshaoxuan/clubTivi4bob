/// Resolves a channel against the current list after discovery or filtering.
/// Positions are transient, while channel IDs remain stable across rebuilds.
class ChannelListIdentity {
  const ChannelListIdentity._();

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
