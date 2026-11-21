import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:server_box/core/monitor/http.dart';
import 'package:server_box/data/model/server/server_private_info.dart';
import 'package:server_box/data/provider/server/all.dart';
import 'package:server_box/data/provider/server/single.dart';
import 'package:server_box/data/res/build_data.dart';
import 'package:server_box/data/store/entity_store.dart';
import 'package:server_box/data/store/schema.dart';
import 'package:server_box/data/store/stores.dart';

/// Local CLI access to the running app's encrypted store and live providers.
final class Bridge {
  Bridge._(this._server, this._socketDir, this._token, this._file, this._container);

  final HttpServer _server;
  final Directory _socketDir;
  final String _token;
  final File _file;
  final ProviderContainer _container;

  static Future<Bridge> start(ProviderContainer container, File file) async {
    final random = Random.secure();
    final token = base64Url.encode(List.generate(32, (_) => random.nextInt(256)));
    final socketDir = await Directory.systemTemp.createTemp('sbcli-');
    final socket = '${socketDir.path}/s';
    HttpServer? server;
    try {
      await _protect(socketDir.path, '700');
      final address = InternetAddress(socket, type: InternetAddressType.unix);
      server = await HttpServer.bind(address, 0);
      server.idleTimeout = const Duration(seconds: 10);
      final staging = await file.parent.createTemp('.bridge-');
      try {
        final info = File('${staging.path}/info');
        await info.create(exclusive: true);
        await _protect(info.path, '600');
        await info.writeAsString(jsonEncode({'api': 1, 'socket': socket, 'token': token}));
        await info.rename(file.path);
      } finally {
        await staging.delete(recursive: true);
      }
      final bridge = Bridge._(server, socketDir, token, file, container);
      server.listen(bridge._handle);
      return bridge;
    } catch (_) {
      await server?.close(force: true);
      await socketDir.delete(recursive: true);
      rethrow;
    }
  }

  static Future<void> _protect(String path, String mode) async {
    final chmod = await Process.run('/bin/chmod', [mode, path]);
    if (chmod.exitCode != 0) throw StateError('Cannot set CLI bridge permissions');
  }

  Future<void> stop() async {
    await _server.close(force: true);
    await _socketDir.delete(recursive: true);
    if (await _file.exists()) {
      final info = jsonDecode(await _file.readAsString());
      if (info is Map && info['token'] == _token) await _file.delete();
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    late Map<String, Object?> payload;
    try {
      if (!_authorized(request)) throw const _RequestError(401, 'Unauthorized');
      payload = await _route(request);
    } on _RequestError catch (e) {
      response.statusCode = e.status;
      payload = {'error': e.message};
    } on DuplicateNameException {
      response.statusCode = 409;
      payload = {'error': 'A server with this name already exists'};
    } on ServerChangedConcurrently {
      response.statusCode = 409;
      payload = {'error': 'Server changed concurrently. Retry the request.'};
    } on SpiValidationException {
      response.statusCode = 400;
      payload = {'error': 'Invalid combination of connection settings'};
    } catch (e) {
      Loggers.app.warning('Local CLI request failed (${e.runtimeType})');
      response.statusCode = 500;
      payload = {'error': 'ServerBox could not complete the request'};
    }
    response.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(jsonEncode(payload));
    await response.close();
  }

  bool _authorized(HttpRequest request) {
    final headers = request.headers;
    if (headers['origin'] != null || headers[HttpHeaders.hostHeader]?.singleOrNull != 'localhost') {
      return false;
    }
    final given = headers[HttpHeaders.authorizationHeader]?.singleOrNull;
    final expected = 'Bearer $_token';
    if (given == null || given.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= given.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<Map<String, Object?>> _route(HttpRequest request) async {
    final path = request.uri.pathSegments;
    final method = request.method;
    if (path.length == 2 && path[0] == 'v1' && path[1] == 'health' && method == 'GET') {
      return {'api': 1, 'build': BuildData.build};
    }
    if (path.length == 2 && path[0] == 'v1' && path[1] == 'keys' && method == 'GET') {
      return {
        'keys': [for (final key in Stores.key.fetch()) {'id': key.id, 'name': key.name}],
      };
    }
    if (path.length < 2 || path[0] != 'v1' || path[1] != 'servers') {
      throw const _RequestError(404, 'Unknown endpoint');
    }
    final servers = _container.read(serversProvider.notifier);
    if (path.length == 2 && method == 'GET') {
      final records = _container.read(serversProvider).servers.values;
      return {'servers': records.map(_record).toList()};
    }
    if (path.length == 2 && method == 'POST') {
      _requireWritable();
      final record = await _body(request);
      final spi = _decode(record..['id'] = Spi.parseId(null));
      await servers.saveServerFromCli(spi);
      return {'server': _record(spi)};
    }
    if (path.length < 3 || path.length > 4) throw const _RequestError(404, 'Unknown endpoint');
    final id = path[2];
    final patch = path.length == 3 && method == 'PATCH' ? await _body(request) : null;
    final spi = servers.pick(id: id);
    if (spi == null) throw const _RequestError(404, 'No such server');
    if (patch != null) {
      _requireWritable();
      final previous = jsonDecode(jsonEncode(spi)) as Map<String, dynamic>;
      for (final entry in patch.entries) {
        final old = previous[entry.key];
        final value = entry.value;
        previous[entry.key] = old is Map<String, dynamic> && value is Map<String, dynamic>
            ? {...old, ...value}
            : value;
      }
      final updated = _decode(previous);
      await servers.saveServerFromCli(updated, previous: spi);
      return {'server': _record(updated)};
    }
    if (path.length == 3 && method == 'GET') return {'server': _record(spi)};
    if (path.length == 3 && method == 'DELETE') {
      _requireWritable();
      await servers.delServer(id);
      return {'deleted': id};
    }
    if (path.length == 4 && path[3] == 'status' && method == 'GET') {
      final state = _container.read(serverProvider(id));
      return {
        'id': id,
        'connection': state.conn.name,
        'latencyMs': state.latencyMs,
        'cpuUsedPercent': state.status.cpu.usedPercent(),
        'memoryTotalKiB': state.status.mem.total == 0 ? null : state.status.mem.total,
        'memoryUsedKiB': state.status.mem.total == 0 ? null : state.status.mem.used,
        'disks': [
          for (final disk in state.status.disk)
            {'mount': disk.mount, 'usedPercent': disk.usedPercent},
        ],
      };
    }
    if (path.length == 4 && path[3] == 'monitor' && method == 'GET') {
      final monitor = spi.monitorOn;
      if (monitor == null) throw const _RequestError(409, 'Monitor is disabled or unconfigured');
      final lease = MonitorClientLease(monitor);
      try {
        final capabilities = await lease.client.capabilities().timeout(const Duration(seconds: 20));
        return {'id': id, 'reachable': true, 'version': capabilities.version};
      } catch (e, s) {
        // The reason belongs in the app's log, not in the reply: a failing
        // sign-in is a wrong password, an address that is not there, or a
        // vault the app cannot write to, and the caller can only act on the
        // first two.
        Loggers.app.warning('CLI Monitor check failed for $id', e, s);
        throw const _RequestError(502, 'Monitor authentication or capability check failed');
      } finally {
        lease.release();
      }
    }
    throw const _RequestError(404, 'Unknown endpoint');
  }

  static void _requireWritable() {
    if (SchemaVersion.readsAhead) throw const _RequestError(409, 'This build opened a newer store');
  }

  // Backup JSON includes credentials and remote environment variables.
  static Map<String, Object?> _record(Spi spi) => {
    'id': spi.id,
    'name': spi.name,
    'tags': spi.tags,
    'local': spi.local,
    'autoConnect': spi.autoConnect,
    'sshEnabled': spi.sshEnabled,
    'monitorEnabled': spi.monitorEnabled,
    'preferredTransport': spi.preferredTransport?.name,
    if (spi.ssh case final ssh?) 'ssh': {
      'ip': ssh.ip,
      'port': ssh.port,
      'user': ssh.user,
      'keyConfigured': ssh.keyId != null || ssh.resolvedIdentityFiles.isNotEmpty,
      'jumpIds': ssh.resolvedJumpIds,
    },
    if (spi.monitorHttp case final monitor?) 'monitorHttp': {
      'origin': _origin(monitor.addr),
      'fallbackOrigin': _origin(monitor.fallbackAddr),
      'allowInsecure': monitor.allowInsecure,
    },
  };

  static String? _origin(String? address) {
    if (address == null) return null;
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty || !(uri.isScheme('http') || uri.isScheme('https'))) return null;
    return uri.origin;
  }

  static Spi _decode(Map<String, dynamic> record) {
    try {
      final spi = Spi.fromJson(record);
      if (spi.name.trim().isEmpty) throw const FormatException();
      if (spi.ssh case final ssh?) {
        if (ssh.ip.trim().isEmpty || ssh.user.trim().isEmpty || ssh.port < 1 || ssh.port > 65535) {
          throw const FormatException();
        }
        // A key id that names nothing is a foreign-key failure at save time,
        // which is a worse answer than this one: the caller wrote an id, and
        // the id is what is wrong.
        if (ssh.keyId case final keyId? when Stores.key.fetchOneRaw(keyId) == null) {
          throw const _RequestError(400, 'No such key');
        }
      }
      if (spi.monitorHttp case final monitor?) {
        for (final address in monitor.addrs) {
          final uri = Uri.parse(address);
          if (!(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
            throw const FormatException();
          }
        }
      }
      return spi;
    } on FormatException {
      throw const _RequestError(400, 'Invalid server name or connection settings');
    } on TypeError {
      throw const _RequestError(400, 'Invalid server field type');
    }
  }

  static Future<Map<String, dynamic>> _body(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const _RequestError(415, 'Expected application/json');
    }
    final bytes = <int>[];
    try {
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > 32 * 1024) {
          throw const _RequestError(413, 'Request is too large');
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> || decoded.isEmpty) throw const FormatException();
      const fields = {
        'name', 'tags', 'local', 'autoConnect', 'sshEnabled', 'monitorEnabled', 'preferredTransport',
        'ssh', 'monitorHttp',
      };
      const sshFields = {
        'ip', 'port', 'user', 'pwd', 'keyPath', 'identityFiles', 'pubKeyId', 'jumpId', 'jumpIds',
        'allowLegacyAlgorithms', 'alterUrl',
      };
      const monitorFields = {'addr', 'fallbackAddr', 'user', 'pwd', 'allowInsecure'};
      if (decoded.keys.any((key) => !fields.contains(key))) throw const FormatException();
      for (final (key, allowed) in [('ssh', sshFields), ('monitorHttp', monitorFields)]) {
        final value = decoded[key];
        if (value != null && (value is! Map<String, dynamic> || value.keys.any((key) => !allowed.contains(key)))) {
          throw const FormatException();
        }
      }
      return decoded;
    } on TimeoutException {
      throw const _RequestError(408, 'Request body timed out');
    } on FormatException {
      throw const _RequestError(400, 'Invalid JSON or unsupported fields');
    }
  }
}

final class _RequestError implements Exception {
  const _RequestError(this.status, this.message);

  final int status;
  final String message;
}
