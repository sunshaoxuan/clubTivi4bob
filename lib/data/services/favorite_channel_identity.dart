import 'channel_name_normalizer.dart';
import 'manual_channel_category.dart';

/// Same service across providers; preserve country, UHD and radio distinctions.
String favoriteChannelIdentity({
  required String name,
  String? group,
  String? tvgName,
  String? tvgId,
}) {
  final normalized = ChannelNameNormalizer.normalize(name);
  final destination = ChannelCategoryDestination.fromGroup(group);
  // Numbered CCTV services are unambiguous even in older provider groups.
  final country = RegExp(r'^cctv\d+(plus)?$').hasMatch(normalized)
      ? ''
      : destination?.country ?? '';
  final uhd = [
    name,
    tvgName ?? '',
    tvgId ?? '',
  ].any(ChannelNameNormalizer.isUltraHd);
  final audio = (group ?? '')
      .split(' / ')
      .any((part) => part == '广播' || part == '电视伴音');
  return '$country|$normalized|${uhd ? 'uhd' : 'standard'}|${audio ? 'radio' : 'tv'}';
}
