import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Bounded hardware/resource probes. No host name, serial, URL or user path.
class DiagnosticEnvironment {
  static final instance = DiagnosticEnvironment();
  Map<String, Object> _cached = {};
  DateTime? _sampledAt;
  Future<Map<String, Object>>? _running;

  Map<String, Object> get current => {
    ..._cached,
    'cpuLogicalCores': Platform.numberOfProcessors,
    'architecture': Abi.current().toString(),
    'rssBytes': ProcessInfo.currentRss,
    'maxRssBytes': ProcessInfo.maxRss,
    'dartVersion':
        RegExp(r'^\d+\.\d+\.\d+').firstMatch(Platform.version)?[0] ?? 'unknown',
    if (_sampledAt != null)
      'environmentAgeMs': DateTime.now().difference(_sampledAt!).inMilliseconds,
  };

  Future<Map<String, Object>> sample() =>
      _running ??= _sample().whenComplete(() => _running = null);

  static Future<String> _command(String executable, List<String> args) async {
    final process = await Process.start(executable, args);
    // Bound output as well as runtime. Probe arguments never include secrets.
    final output = process.stdout.take(32).fold<List<int>>([], (a, b) {
      if (a.length + b.length > 32768) throw StateError('Probe output limit');
      return a..addAll(b);
    });
    final errors = process.stderr.drain<void>();
    try {
      final result = await Future.wait<Object?>([
        process.exitCode,
        output,
        errors,
      ]).timeout(const Duration(seconds: 4));
      if (result.first != 0) throw StateError('Probe failed');
      return utf8.decode(result[1] as List<int>, allowMalformed: true).trim();
    } finally {
      process.kill();
    }
  }

  static Map<String, Object> parseMacMemory(String text) {
    final page = int.tryParse(
      RegExp(r'page size of (\d+) bytes').firstMatch(text)?.group(1) ?? '',
    );
    if (page == null) return {};
    int pages(String name) =>
        int.tryParse(
          RegExp(
                '^${RegExp.escape(name)}:\\s+(\\d+)',
                multiLine: true,
              ).firstMatch(text)?.group(1) ??
              '',
        ) ??
        0;
    final free = pages('Pages free');
    return {
      'freeMemoryBytes': free * page,
      // Inactive/speculative pages are reclaimable, not a guaranteed allocation.
      'reclaimableMemoryBytes':
          (free + pages('Pages inactive') + pages('Pages speculative')) * page,
      'compressedMemoryBytes': pages('Pages occupied by compressor') * page,
    };
  }

  Future<Map<String, Object>> _sample() async {
    final clock = Stopwatch()..start();
    final data = <String, Object>{};
    var failures = 0;
    Future<void> probe(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        failures++;
      }
    }

    if (Platform.isMacOS) {
      await Future.wait([
        probe(() async {
          final values = (await _command('/usr/sbin/sysctl', [
            '-n',
            'machdep.cpu.brand_string',
            'hw.memsize',
            'kern.osversion',
          ])).split('\n');
          if (values.length != 3) throw const FormatException();
          data['cpuModel'] = values[0];
          data['totalMemoryBytes'] = int.parse(values[1]);
          data['osBuild'] = values[2];
        }),
        probe(() async {
          data['osVersion'] = await _command('/usr/bin/sw_vers', [
            '-productVersion',
          ]);
        }),
        probe(() async {
          data.addAll(parseMacMemory(await _command('/usr/bin/vm_stat', [])));
        }),
        probe(() async {
          final text = await _command('/usr/sbin/sysctl', [
            '-n',
            'vm.swapusage',
            'vm.loadavg',
          ]);
          final used = RegExp(r'used\s*=\s*([\d.]+)M').firstMatch(text);
          if (used != null)
            data['swapUsedBytes'] = (double.parse(used[1]!) * 1024 * 1024)
                .round();
          final load = RegExp(r'\{\s*([\d.]+)').firstMatch(text);
          if (load != null) data['cpuLoad1m'] = double.parse(load[1]!);
        }),
        probe(() async {
          final text = await _command('/bin/ps', [
            '-axo',
            'pid=,ppid=,%cpu=,rss=,ucomm=',
          ]);
          final rows = text
              .split('\n')
              .map((line) => line.trim().split(RegExp(r'\s+')))
              .where((r) => r.length >= 5)
              .toList();
          final family = <int>{pid};
          var count = 0;
          while (count != family.length) {
            count = family.length;
            for (final row in rows) {
              if (family.contains(int.tryParse(row[1]))) {
                family.add(int.parse(row[0]));
              }
            }
          }
          var rss = 0;
          var cpu = 0.0;
          for (final row in rows) {
            if (!family.contains(int.tryParse(row[0]))) continue;
            final usage = double.parse(row[2]);
            final memory = int.parse(row[3]) * 1024;
            rss += memory;
            cpu += usage;
            if (int.parse(row[0]) == pid) data['processCpuPercent'] = usage;
            final name = row.sublist(4).join(' ').split('/').last;
            final component = name == 'bobtv-client-asr'
                ? 'asr'
                : name == 'ffmpeg'
                ? 'ffmpeg'
                : name == 'bobtv-airplay'
                ? 'airplay'
                : null;
            if (component != null) {
              data['${component}CpuPercent'] =
                  (data['${component}CpuPercent'] as num? ?? 0) + usage;
              data['${component}RssBytes'] =
                  (data['${component}RssBytes'] as num? ?? 0) + memory;
            }
          }
          data['processTreeRssSumBytes'] = rss;
          data['processTreeCpuPercent'] = cpu;
          data['helperProcessCount'] = family.length - 1;
          data['cpuMeasurement'] = 'ps_lifetime_average';
        }),
        probe(() async {
          final text = await _command('/bin/df', [
            '-Pk',
            Directory.systemTemp.path,
          ]);
          final parts = text.split('\n').last.trim().split(RegExp(r'\s+'));
          data['freeDiskBytes'] = int.parse(parts[3]) * 1024;
        }),
      ]);
    } else if (Platform.isLinux || Platform.isAndroid) {
      await probe(() async {
        final mem = await File('/proc/meminfo').readAsString();
        for (final entry in {
          'MemTotal': 'totalMemoryBytes',
          'MemAvailable': 'availableMemoryBytes',
          'MemFree': 'freeMemoryBytes',
        }.entries) {
          final match = RegExp(
            '^${entry.key}:\\s+(\\d+)',
            multiLine: true,
          ).firstMatch(mem);
          if (match != null) data[entry.value] = int.parse(match[1]!) * 1024;
        }
        final cpu = await File('/proc/cpuinfo').readAsString();
        final model = RegExp(
          r'^(?:model name|Hardware)\s*:\s*(.+)$',
          multiLine: true,
        ).firstMatch(cpu);
        if (model != null) data['cpuModel'] = model[1]!;
        data['cpuLoad1m'] = double.parse(
          (await File('/proc/loadavg').readAsString()).split(' ').first,
        );
        data['kernelVersion'] = (await File(
          '/proc/sys/kernel/osrelease',
        ).readAsString()).trim();
        if (Platform.isLinux) {
          final release = await File('/etc/os-release').readAsString();
          final version = RegExp(
            r'^VERSION_ID="?([^"\n]+)',
            multiLine: true,
          ).firstMatch(release)?[1];
          if (version != null) data['osVersion'] = version;
        }
      });
    } else if (Platform.isWindows) {
      await probe(() async {
        final text = await _command('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'$o=Get-CimInstance Win32_OperatingSystem; '
              r'$c=Get-CimInstance Win32_Processor | Select-Object -First 1; '
              r'@{osVersion=$o.Version;osBuild=$o.BuildNumber;cpuModel=$c.Name;'
              r'totalMemoryBytes=([long]$o.TotalVisibleMemorySize*1024);'
              r'availableMemoryBytes=([long]$o.FreePhysicalMemory*1024);'
              r'systemCpuPercent=$c.LoadPercentage} | ConvertTo-Json -Compress',
        ]);
        final parsed = jsonDecode(text) as Map<String, dynamic>;
        for (final entry in parsed.entries) {
          if (entry.value is String || entry.value is num) {
            data[entry.key] = entry.value as Object;
          }
        }
      });
    }
    data['environmentProbe'] = Platform.isIOS
        ? 'unsupported'
        : failures > 0 ||
              !data.keys.toSet().containsAll({
                'osVersion',
                'cpuModel',
                'totalMemoryBytes',
              })
        ? 'partial'
        : 'complete';
    data['environmentProbeDurationMs'] = clock.elapsedMilliseconds;
    if (Platform.isMacOS || Platform.isWindows) {
      final executable = File(Platform.resolvedExecutable).parent;
      final resources = Platform.isMacOS
          ? Directory('${executable.path}/../Resources')
          : executable;
      final ffmpeg = File(
        Platform.isMacOS
            ? '${resources.path}/Tools/ffmpeg'
            : '${resources.path}/Tools/ffmpeg.exe',
      );
      data['ffmpegBundled'] = await ffmpeg.exists();
      data['airplayHelperAvailable'] = await File(
        Platform.isMacOS
            ? '${resources.path}/AirPlay/bobtv-airplay/bobtv-airplay'
            : '${resources.path}/AirPlay/bobtv-airplay.exe',
      ).exists();
    }
    _cached = data;
    _sampledAt = DateTime.now();
    return current;
  }
}

/// Preserves diagnostic cause and code locations without raw private payloads.
class DiagnosticFailure {
  static String code(Object error) {
    if (error is DiagnosticRemoteException) return error.code;
    if (error is OutOfMemoryError) return 'out_of_memory';
    if (error is TimeoutException) return 'timeout';
    if (error is SocketException) {
      final number = error.osError?.errorCode;
      if ({65, 101, 113, 10051, 10065}.contains(number)) return 'no_route';
      if ({61, 111, 10061}.contains(number)) return 'connection_refused';
      if ({1, 13, 10013}.contains(number)) return 'permission_denied';
      return 'socket';
    }
    if (error is ProcessException && error.errorCode == 2)
      return 'missing_dependency';
    if (error is HandshakeException) return 'tls';
    if (error is HttpException) return 'http';
    if (error is FormatException) return 'format';
    return 'other';
  }

  static Map<String, Object> describe(Object error, [StackTrace? stack]) => {
    'errorType': error is DiagnosticRemoteException
        ? error.errorType
        : error.runtimeType.toString(),
    'errorCode': code(error),
    if (error is SocketException && error.osError != null)
      'osErrorCode': error.osError!.errorCode,
    if (error is ProcessException) 'osErrorCode': error.errorCode,
    if (error is DiagnosticRemoteException && error.osErrorCode != null)
      'osErrorCode': error.osErrorCode!,
    if (stack != null)
      'stackFrames': RegExp(
        r'(?:package:[A-Za-z0-9_]+/[A-Za-z0-9_./-]+\.dart|dart:[A-Za-z0-9_./-]+):\d+(?::\d+)?',
      ).allMatches(stack.toString()).take(12).map((m) => m[0]!).join('\n'),
  };
}

class DiagnosticRemoteException implements Exception {
  DiagnosticRemoteException(
    this.message, {
    required this.code,
    required this.errorType,
    this.osErrorCode,
  });
  final String message, code, errorType;
  final int? osErrorCode;
  @override
  String toString() => message;
}

class DiagnosticNetwork {
  static bool sameSubnet(String local, String remote, int prefix) {
    final a = InternetAddress(local).rawAddress;
    final b = InternetAddress(remote).rawAddress;
    if (a.length != b.length || prefix < 0 || prefix > a.length * 8) {
      throw const FormatException('Incompatible network prefix');
    }
    for (var bit = 0; bit < prefix; bit++) {
      final mask = 1 << (7 - bit % 8);
      if ((a[bit ~/ 8] & mask) != (b[bit ~/ 8] & mask)) return false;
    }
    return true;
  }

  static Future<Map<String, Object>> inspect(
    String receiver, {
    int? port,
  }) async {
    final clock = Stopwatch()..start();
    final result = <String, Object>{'networkProbe': 'partial'};
    if (InternetAddress.tryParse(receiver) == null) return result;
    result['receiverAddress'] = receiver;
    if (port != null) result['receiverPort'] = port;
    try {
      if (Platform.isMacOS) {
        final route = await DiagnosticEnvironment._command('/sbin/route', [
          '-n',
          'get',
          receiver,
        ]);
        final name = RegExp(r'interface:\s*(\S+)').firstMatch(route)?[1];
        if (name == null || !RegExp(r'^[A-Za-z0-9_.-]{1,40}$').hasMatch(name)) {
          throw const FormatException();
        }
        result.addAll({
          'interfaceName': name,
          'routeAvailable': true,
          'vpnInterface': RegExp(r'^(utun|tun|tap|wg)').hasMatch(name),
        });
        final gateway = RegExp(r'gateway:\s*(\S+)').firstMatch(route)?[1];
        if (gateway != null && InternetAddress.tryParse(gateway) != null) {
          result['gatewayAddress'] = gateway;
        }
        final config = await DiagnosticEnvironment._command('/sbin/ifconfig', [
          name,
        ]);
        final addresses = RegExp(
          r'inet (\d+\.\d+\.\d+\.\d+) netmask 0x([0-9a-f]+)',
        ).allMatches(config);
        for (final address in addresses) {
          final mask = int.parse(address[2]!, radix: 16);
          final prefix = mask
              .toRadixString(2)
              .split('')
              .where((c) => c == '1')
              .length;
          if (mask != ((0xffffffff << (32 - prefix)) & 0xffffffff)) continue;
          final same = sameSubnet(address[1]!, receiver, prefix);
          if (!result.containsKey('localAddress') || same) {
            result.addAll({
              'localAddress': address[1]!,
              'prefixLength': prefix,
              'sameSubnet': same,
              'localAddressSource': 'interface_candidate',
              'networkProbe': 'complete',
            });
          }
          if (same) break;
        }
      } else {
        // Missing platform probes remain explicit; never assume a /24 mask.
        result['networkProbe'] = 'unsupported';
      }
    } catch (_) {
      result['networkProbe'] = 'partial';
    }
    result['networkProbeDurationMs'] = clock.elapsedMilliseconds;
    return result;
  }
}
