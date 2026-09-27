import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/local/database.dart' as db;
import 'provider_manager.dart';

class DefaultM3uSource {
  final String id;
  final String name;
  final String url;

  const DefaultM3uSource({
    required this.id,
    required this.name,
    required this.url,
  });
}

/// Adds the curated hotel-TV sources once, then refreshes sources that remain
/// installed. A source removed by the user is not restored on later launches.
class DefaultProviderBootstrap {
  static const _installedKey = 'hotel_tv_default_sources_installed_v4';
  static const refreshInterval = Duration(hours: 6);

  static const sources = <DefaultM3uSource>[
    DefaultM3uSource(
      id: 'hotel-guovin-ipv4',
      name: 'Guovin IPv4',
      url:
          'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv4/result.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-chinaiptv',
      name: 'ChinaIPTV',
      url:
          'https://raw.githubusercontent.com/hujingguang/ChinaIPTV/main/cnTV_AutoUpdate.m3u8',
    ),
    DefaultM3uSource(
      id: 'hotel-myiptv-ipv4',
      name: 'myIPTV IPv4',
      url:
          'https://raw.githubusercontent.com/suxuang/myIPTV/refs/heads/main/ipv4.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-burningc4-ipv4',
      name: 'BurningC4 IPv4',
      url:
          'https://raw.githubusercontent.com/BurningC4/Chinese-IPTV/master/TV-IPV4.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-kimentanm-ipv4',
      name: 'Kimentanm IPv4',
      url:
          'https://raw.githubusercontent.com/Kimentanm/aptv/master/m3u/iptv.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-guovin-ipv6',
      name: 'Guovin 混合线路',
      url:
          'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv6/result.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-myiptv-ipv6',
      name: 'myIPTV 混合线路',
      url:
          'https://raw.githubusercontent.com/suxuang/myIPTV/refs/heads/main/ipv6.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-vbskycn-ipv4',
      name: 'vbskycn IPv4',
      url: 'https://live.zbds.top/tv/iptv4.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-yuechan-ipv4',
      name: 'YueChan IPv4',
      url:
          'https://raw.githubusercontent.com/YueChan/Live/refs/heads/main/IPTV.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-iptv-org-cn',
      name: 'IPTV.org 中国频道',
      url: 'https://iptv-org.github.io/iptv/countries/cn.m3u',
    ),
    DefaultM3uSource(
      id: 'hotel-best-fan-status',
      name: 'best-fan 每日检测线路',
      url:
          'https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all_status.m3u8',
    ),
  ];

  final db.AppDatabase database;
  final ProviderManager manager;

  const DefaultProviderBootstrap({
    required this.database,
    required this.manager,
  });

  Future<void> run() async {
    final prefs = await SharedPreferences.getInstance();
    final installationComplete = prefs.getBool(_installedKey) ?? false;

    var providers = await database.getAllProviders();
    var byId = {for (final provider in providers) provider.id: provider};

    if (!installationComplete) {
      for (final source in sources) {
        if (byId.containsKey(source.id)) continue;
        try {
          await manager.addM3uProvider(
            id: source.id,
            name: source.name,
            url: source.url,
          );
        } catch (error) {
          debugPrint(
            '[Hotel TV] Initial source load failed: '
            '${source.name}: $error',
          );
        }
      }

      providers = await database.getAllProviders();
      byId = {for (final provider in providers) provider.id: provider};
      if (sources.every((source) => byId.containsKey(source.id))) {
        await prefs.setBool(_installedKey, true);
      }
    }

    final refreshBefore = DateTime.now().subtract(refreshInterval);
    for (final source in sources) {
      final provider = byId[source.id];
      if (provider == null || !provider.enabled) continue;
      if (provider.lastRefresh != null &&
          provider.lastRefresh!.isAfter(refreshBefore)) {
        continue;
      }
      try {
        await manager.refreshProvider(source.id);
      } catch (error) {
        debugPrint('[Hotel TV] Source refresh failed: ${source.name}: $error');
      }
    }
  }
}
