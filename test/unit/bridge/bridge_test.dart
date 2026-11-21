import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server_box/core/service/bridge/bridge.dart';
import 'package:server_box/data/provider/server/all.dart';
import 'package:server_box/data/provider/server/single.dart';
import 'package:server_box/data/store/stores.dart';
import 'package:server_box/src/rust/api/protocol.dart';

import '../../helpers/rust_lib_helper.dart';
import '../../helpers/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory dir;
  late File info;
  late ProviderContainer container;
  late Bridge bridge;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('serverbox-cli-test-');
    Paths.doc = dir.path;
    addTearDown(() => dir.delete(recursive: true));
  });

  setUp(() async {
    await openTestDb();
    addTearDown(closeTestDb);
    await Stores.init();
    addTearDown(getIt.reset);
    container = ProviderContainer();
    addTearDown(container.dispose);
    info = File('${dir.path}/bridge.json');
    bridge = await Bridge.start(container, info);
    addTearDown(bridge.stop);
  });

  test('writes a private discovery file and rejects missing credentials', () async {
    expect((await info.stat()).mode & 0x3f, 0);
    final discovery = jsonDecode(await info.readAsString()) as Map;
    final address = InternetAddress(discovery['socket'] as String, type: InternetAddressType.unix);
    expect((await File(address.address).parent.stat()).mode & 0x3f, 0);
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (_, _, _) => Socket.startConnect(address, 0);
    addTearDown(() => client.close(force: true));
    final uri = Uri.parse('http://localhost/v1/servers');
    final unauthenticated = await (await client.getUrl(uri)).close();
    expect(unauthenticated.statusCode, 401);
    await unauthenticated.drain<void>();

    final browser = await client.getUrl(uri);
    browser.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${discovery['token']}');
    browser.headers.set('origin', 'https://example.test');
    final response = await browser.close();
    expect(response.statusCode, 401);
    await response.drain<void>();
  });

  test('CLI updates the live provider and keeps stored credentials out of its output', () async {
    final passwordFile = File('${dir.path}/password');
    await passwordFile.writeAsString('test-password\n');
    addTearDown(passwordFile.delete);
    final added = await _cli(info, [
      'servers', 'add', 'test host',
      '--ssh-ip', '192.0.2.10', '--ssh-user', 'operator', '--ssh-port', '2222',
      '--ssh-password-file', passwordFile.path,
      '--monitor-addr', 'https://example.test:3770',
      '--monitor-password-file', passwordFile.path,
      '--no-auto-connect',
    ]);
    final id = (added['server'] as Map)['id'] as String;
    expect(id, isNotEmpty);
    expect(container.read(serverProvider(id)).spi.ssh?.pwd, 'test-password');
    expect(container.read(serverProvider(id)).spi.monitorHttp?.pwd, 'test-password');

    await _cli(info, ['servers', 'set', id, '--ssh-ip', '192.0.2.11']);
    final saved = container.read(serversProvider).servers[id]!;
    expect(saved.ssh?.ip, '192.0.2.11');
    expect(saved.ssh?.port, 2222);
    expect(saved.ssh?.user, 'operator');
    expect(saved.ssh?.pwd, 'test-password');
    expect(saved.monitorHttp?.pwd, 'test-password');
    expect(Stores.server.fetchOneRaw(id)?.ssh, saved.ssh);
    expect(Stores.server.fetchOneRaw(id)?.monitorHttp, saved.monitorHttp);
    expect(container.read(serverProvider(id)).spi, saved);

    final status = await _cli(info, ['status', id]);
    expect(status['connection'], 'disconnected');
    expect(Stores.server.fetchOneRaw(id)?.autoConnect, false);
    await _cli(info, ['servers', 'set', id, '--auto-connect']);
    expect(Stores.server.fetchOneRaw(id)?.autoConnect, true);
    final listed = await _cli(info, ['servers', 'list']);
    expect((listed['servers'] as List).single['id'], id);
    final shown = await _cli(info, ['servers', 'show', id]);
    expect((shown['server'] as Map)['id'], id);

    final key = File('${dir.path}/identity');
    await key.create();
    addTearDown(key.delete);
    await _cli(info, ['servers', 'set', id, '--ssh-key', key.path]);
    final ssh = Stores.server.fetchOneRaw(id)!.ssh!;
    expect(ssh.pwd, isNull);
    expect(ssh.resolvedIdentityFiles, [key.path]);

    await _cli(info, ['servers', 'remove', id, '--yes']);
    expect(Stores.server.fetchOneRaw(id), isNull);
    expect(container.read(serversProvider).servers, isEmpty);
  });

  test('CLI Monitor check logs in and reads authenticated capabilities', () async {
    await initRustLibForTest();
    final protocol = monitorProtocol();
    final agent = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => agent.close(force: true));
    agent.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      final (status, body) = switch (request.uri.path) {
        '/api/v1/health' => (200, {'protocol': protocol, 'min_client_protocol': 1}),
        '/api/v1/login' when (jsonDecode(text) as Map)['password'] == 'test-password' =>
          (200, {'token': 'test-token'}),
        '/api/v1/capabilities'
            when request.headers.value(HttpHeaders.authorizationHeader) == 'Bearer test-token' =>
          (200, {'version': '0.4.0'}),
        _ => (401, {'error': 'unauthorized'}),
      };
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    });
    final password = File('${dir.path}/monitor-password');
    await password.writeAsString('test-password');
    addTearDown(password.delete);
    final added = await _cli(info, [
      'servers', 'add', 'monitor', '--monitor-addr', 'http://127.0.0.1:${agent.port}',
      '--monitor-password-file', password.path,
    ]);
    final id = (added['server'] as Map)['id'] as String;
    final result = await _cli(info, ['monitor', 'check', id]);
    expect(result['reachable'], true);
    expect(result['version'], '0.4.0');
  });

  test('CLI rejects an invalid record and keeps multiple IP entries distinct', () async {
    final invalid = await _runCli(info, ['servers', 'add', 'broken']);
    expect(invalid.exitCode, 1);
    expect(invalid.stderr, contains('HTTP 400'));

    await _cli(info, ['servers', 'add', 'lab', '--ssh-ip', '192.0.2.10']);
    await _cli(info, ['servers', 'add', 'lab', '--ssh-ip', '192.0.2.20']);
    final entries = Stores.server.fetch();
    expect(entries.map((server) => server.id).toSet(), hasLength(2));
    expect(entries.map((server) => server.ssh?.ip), unorderedEquals(['192.0.2.10', '192.0.2.20']));
  });
}

Future<ProcessResult> _runCli(File file, List<String> args) {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final dart = flutterRoot == null ? 'dart' : '$flutterRoot/bin/dart';
  return Process.run(dart, ['tool/serverbox.dart', ...args], environment: {'SBM_BRIDGE_FILE': file.path});
}

Future<Map<String, dynamic>> _cli(File file, List<String> args) async {
  final result = await _runCli(file, args);
  expect(result.exitCode, 0, reason: result.stderr as String);
  expect(result.stdout, isNot(contains('test-password')));
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}
