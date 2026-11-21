import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import '../../data/resource_package/resource_package.dart';
import '../../data/resource_package/resource_package_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/website_channel_catalog_service.dart';
import 'account_service.dart';
import 'regional_catalog_client.dart';

/// Serializes account changes, region downloads and atomic catalog replacement.
class RegionalCatalogService extends ChangeNotifier
    with WidgetsBindingObserver {
  RegionalCatalogService(
    this.database, {
    AccountService? account,
    RegionalCatalogClient? catalogClient,
    this.installDemo = true,
  }) : account = account ?? AccountService.instance,
       _clientOverride = catalogClient;

  final bool installDemo;
  final db.AppDatabase database;
  final AccountService account;
  final RegionalCatalogClient? _clientOverride;
  late final client = _clientOverride ?? RegionalCatalogClient(account);
  late final importer = WebsiteChannelCatalogService(database: database);
  late SharedPreferences prefs;
  Future<void>? _initializing;
  Future<void> _work = Future<void>.value();
  Timer? _timer;
  String? _owner;
  bool _closed = false;
  bool busy = false;
  Object? error;
  Set<String> selected = {};
  Map<String, int> available = {};
  RegionalCatalogBootstrap? _publisher;

  bool get hasAccess => !_closed && account.loggedIn && _owner == account.user?['id'];

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    prefs = await SharedPreferences.getInstance();
    await database.customStatement(
      'CREATE TABLE IF NOT EXISTS regional_account_cache (slot TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    );
    await account.initialize();
    if (_closed) return;
    _owner = prefs.getString('bobtv.regional.owner');
    await _switchAccount();
    if (installDemo) {
      const demoId = 'bobtv-demo';
      final providers = await database.getAllProviders();
      final demo = ResourcePackage.parse(
        await rootBundle.loadString('assets/data/demo.bobtv'),
      );
      await ResourcePackageStore(database).apply(
        providerId: demoId,
        package: demo,
        address: demo.updateUrl.toString(),
        create: !providers.any((p) => p.id == demoId),
      );
    }
    if (_closed) return;
    account.addListener(_accountChanged);
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(refresh()),
    );
    unawaited(refresh());
  }

  void _accountChanged() {
    if (_closed) return;
    // Invalidate access immediately, before any queued import can finish.
    notifyListeners();
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _work.then((_) async {
      if (_closed) return;
      busy = true;
      error = null;
      notifyListeners();
      try {
        await action();
      } catch (e) {
        error = e;
        rethrow;
      } finally {
        busy = false;
        if (!_closed) notifyListeners();
      }
    });
    _work = next.catchError((Object _) {});
    return next;
  }

  Future<String?> _getCache(String slot) async =>
      (await database
              .customSelect(
                'SELECT payload FROM regional_account_cache WHERE slot=?',
                variables: [Variable(slot)],
              )
              .getSingleOrNull())
          ?.read<String>('payload');

  Future<void> _putCache(String slot, String payload) =>
      database.customStatement(
        'INSERT OR REPLACE INTO regional_account_cache VALUES(?,?)',
        [slot, payload],
      );

  Future<void> _archive(String owner) async {
    // Preserve user edits and list membership when removing an account's view.
    final tables = [
      'channels',
      'favorite_list_channels',
      'epg_mappings',
      'failover_group_channels',
    ];
    final key = 'bobtv.regional.archive.$owner';
    final archive = jsonDecode(await _getCache(key) ?? '{}') as Map;
    final activeIds = (await database.getChannelsForProvider(
      WebsiteChannelCatalogService.providerId,
    )).map((c) => c.id).toSet();
    for (final table in tables) {
      final predicate = table == 'channels'
          ? "provider_id='bobtv-channel-catalog'"
          : "channel_id IN (SELECT id FROM channels WHERE provider_id='bobtv-channel-catalog')";
      final rows = await database
          .customSelect('SELECT * FROM $table WHERE $predicate')
          .get();
      final saved = <String, dynamic>{
        for (final row in archive[table] as List? ?? [])
          if (!activeIds.contains(
            table == 'channels' ? row['id'] : row['channel_id'],
          ))
            _rowKey(table, row as Map): row,
      };
      for (final row in rows) {
        saved[_rowKey(table, row.data)] = row.data;
      }
      archive[table] = saved.values.toList();
    }
    await _putCache(key, jsonEncode(archive));
  }

  String _rowKey(String table, Map row) => table == 'channels'
      ? '${row['id']}'
      : jsonEncode([
          row['channel_id'],
          row['list_id'],
          row['group_id'],
          row['provider_id'],
        ]);

  Future<void> _restore(String owner) async {
    final archive =
        jsonDecode(await _getCache('bobtv.regional.archive.$owner') ?? '{}')
            as Map;
    final ids = (await database.getChannelsForProvider(
      WebsiteChannelCatalogService.providerId,
    )).map((c) => c.id).toSet();
    for (final row in archive['channels'] as List? ?? []) {
      if (ids.contains(row['id'])) {
        await database.customStatement(
          'UPDATE channels SET favorite=?,hidden=?,sort_order=? WHERE id=?',
          [row['favorite'], row['hidden'], row['sort_order'], row['id']],
        );
      }
    }
    for (final table in [
      'favorite_list_channels',
      'epg_mappings',
      'failover_group_channels',
    ]) {
      for (final row in archive[table] as List? ?? []) {
        if (!ids.contains(row['channel_id'])) continue;
        final columns = (row as Map).keys.cast<String>().toList();
        await database.customStatement(
          'INSERT OR IGNORE INTO $table (${columns.join(',')}) VALUES (${columns.map((_) => '?').join(',')})',
          columns.map((c) => row[c]).toList(),
        );
      }
    }
  }

  Future<void> _switchAccount() async {
    final next = account.loggedIn ? (account.user?['id'] as String?) : null;
    if (next == _owner && prefs.getBool('bobtv.regional.migrated') == true)
      return;
    await database.withoutSharedReporting(() async {
      await _archive(_owner ?? 'legacy');
      final rows = await database.getChannelsForProvider(
        WebsiteChannelCatalogService.providerId,
      );
      await database.deleteChannelsByIds(rows.map((c) => c.id));
      await database.setSharedCatalogVersion('');
    });
    _owner = next;
    _publisher = null;
    available = {};
    selected = next == null
        ? {}
        : (prefs.getStringList('bobtv.regional.selected.$next') ?? []).toSet();
    if (next == null) {
      await prefs.remove('bobtv.regional.owner');
    } else {
      await prefs.setString('bobtv.regional.owner', next);
      // Adopt pre-account favorites once, retaining their exact route IDs.
      if (!prefs.containsKey('bobtv.regional.legacyOwner')) {
        final legacy = await _getCache('bobtv.regional.archive.legacy');
        if (legacy != null &&
            await _getCache('bobtv.regional.archive.$next') == null) {
          await _putCache('bobtv.regional.archive.$next', legacy);
        }
        await prefs.setString('bobtv.regional.legacyOwner', next);
      }
    }
    await prefs.setBool('bobtv.regional.migrated', true);
    notifyListeners();
  }

  Future<void> attach(Map<String, dynamic> imported) async {
    await initialize();
    final publisher = await client.verifyBootstrap(imported);
    await prefs.setString('bobtv.regional.bootstrap', jsonEncode(imported));
    _publisher = publisher;
  }

  Future<void> loadRegions() async {
    await initialize();
    await _serial(() async {
      await _switchAccount();
      if (!hasAccess) throw const AccountException('login_required');
      final imported =
          jsonDecode(
                prefs.getString('bobtv.regional.bootstrap') ??
                    jsonEncode(
                      await account.regionalCatalogRequest('bootstrap.bobtv'),
                    ),
              )
              as Map<String, dynamic>;
      _publisher = await client.verifyBootstrap(imported);
      try {
        available = await client.regions(_publisher!);
      } on AccountException catch (e) {
        if (e.code != 'device_not_registered') rethrow;
        await client.enroll(_publisher!);
        available = await client.regions(_publisher!);
      }
    });
  }

  Future<void> select(Set<String> regions) async {
    await initialize();
    if (!hasAccess || regions.any((r) => !available.containsKey(r))) {
      throw const AccountException('login_required');
    }
    await _serial(() => _refresh(regions));
  }

  Future<void> refresh() async {
    await initialize();
    try {
      await _serial(() async {
        await _switchAccount();
        if (hasAccess && selected.isNotEmpty) await _refresh(selected);
      });
    } catch (_) {
      // Retain the active account's last validated cache on network failure.
    }
  }

  Future<void> _refresh(Set<String> regions) async {
    final owner = _owner;
    if (owner == null || !hasAccess) return;
    _publisher ??= await client.verifyBootstrap(
      await account.regionalCatalogRequest('bootstrap.bobtv'),
    );
    final snapshots = <Map<String, dynamic>>[];
    for (final region in regions.toList()..sort()) {
      final key = 'bobtv.regional.cache.$owner.$region';
      final cached = await _getCache(key);
      final previous = cached == null
          ? null
          : jsonDecode(cached) as Map<String, dynamic>;
      final update = await client.syncSnapshot(
        _publisher!,
        region,
        knownRevision: previous?['revision'] as String?,
      );
      if (!hasAccess || _owner != owner) return;
      final snapshot = update ?? previous;
      if (snapshot == null)
        throw const FormatException('Missing regional cache');
      if (update != null) await _putCache(key, jsonEncode(update));
      snapshots.add(snapshot);
    }
    final categories = <String, dynamic>{};
    final channels = <String, dynamic>{};
    for (final snapshot in snapshots) {
      final catalog = snapshot['catalog'] as Map;
      for (final category in catalog['categories'] as List) {
        categories[category['id'] as String] = category;
      }
      for (final channel in catalog['channels'] as List) {
        channels[channel['id'] as String] = channel;
      }
    }
    final version = sha256
        .convert(
          utf8.encode(
            jsonEncode([owner, snapshots.map((s) => s['revision']).toList()]),
          ),
        )
        .toString();
    if (!hasAccess || _owner != owner) return;
    await database.withoutSharedReporting(() async {
      await _archive(owner);
      await importer.applyVerifiedSnapshot({
        'schemaVersion': 1,
        'version': version,
        'categories': categories.values.toList(),
        'channels': channels.values.toList(),
      });
      if (!hasAccess || _owner != owner)
        throw const AccountException('login_required');
      await _restore(owner);
    });
    selected = Set.of(regions);
    await prefs.setStringList(
      'bobtv.regional.selected.$owner',
      selected.toList()..sort(),
    );
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    account.removeListener(_accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    importer.dispose();
    super.dispose();
  }
}
