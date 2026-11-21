import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _usage = '''
ServerBox CLI

  servers list
  servers show ID
  servers add NAME OPTIONS
  servers set ID OPTIONS
  servers remove ID --yes
  keys list
  status ID
  monitor check ID

Options for add and set
  --name NAME                    Rename an existing record
  --ssh-ip HOST --ssh-port PORT --ssh-user USER
  --ssh-key PATH                 Use a local IdentityFile and clear the saved SSH password
  --ssh-key-id ID                Use a key already imported into ServerBox
  --ssh-password-file PATH       Read a password from a file, or use - for stdin
  --ssh-jump ID                  Use another saved server as the jump host
  --ssh-legacy-algorithms        Permit legacy algorithms for this record
  --monitor-addr URL --monitor-fallback URL
  --monitor-password-file PATH   Read the Monitor password from a file, or - for stdin
  --monitor-user USER            Set the account for older Monitor agents
  --allow-insecure-monitor       Permit plaintext Monitor HTTP away from loopback
  --prefer ssh|monitor           Choose which transport polls for status
  --tag TAG                      Replace tags with the given values (repeatable)
  --local                        Monitor this device
  --auto-connect                 Enable automatic status polling
  --no-auto-connect              Disable automatic status polling

Results are JSON. Launch the desktop app with SBM_BRIDGE=on first.
''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || const ['help', '-h', '--help'].contains(args.first)) {
    stdout.write(_usage);
    return;
  }
  try {
    final (method, path, body) = await _parse(args);
    final bridge = await _Bridge.read();
    final result = await bridge.send(method, path, body).timeout(const Duration(seconds: 25));
    stdout.writeln(jsonEncode(result));
  } on _CliError catch (e) {
    stderr.writeln(e.message);
    exitCode = e.code;
  } on TimeoutException {
    stderr.writeln('ServerBox request timed out. Check the current record before retrying a write.');
    exitCode = 1;
  } on SocketException {
    stderr.writeln('Cannot reach the local ServerBox bridge. Check that the app is running with SBM_BRIDGE=on.');
    exitCode = 1;
  } on HttpException {
    stderr.writeln('The local ServerBox bridge closed the connection.');
    exitCode = 1;
  } on FileSystemException {
    stderr.writeln('Cannot read a requested local file.');
    exitCode = 1;
  } on FormatException {
    stderr.writeln('The ServerBox bridge returned invalid data.');
    exitCode = 1;
  }
}

Future<(String, List<String>, Map<String, Object?>?)> _parse(List<String> args) async {
  const servers = ['v1', 'servers'];
  switch (args) {
    case ['servers', 'list']:
      return ('GET', servers, null);
    case ['keys', 'list']:
      return ('GET', ['v1', 'keys'], null);
    case ['servers', 'show', final id]:
      return ('GET', [...servers, id], null);
    case ['servers', 'add', final name, ...final options] when !name.startsWith('-'):
      return ('POST', servers, {'name': name, ...await _options(options)});
    case ['servers', 'set', final id, ...final options] when options.isNotEmpty:
      return ('PATCH', [...servers, id], await _options(options));
    case ['servers', 'remove', final id, '--yes']:
      return ('DELETE', [...servers, id], null);
    case ['status', final id]:
      return ('GET', [...servers, id, 'status'], null);
    case ['monitor', 'check', final id]:
      return ('GET', [...servers, id, 'monitor'], null);
    default:
      throw const _CliError('Invalid command. Run serverbox.dart --help for usage.', 64);
  }
}

Future<Map<String, Object?>> _options(List<String> options) async {
  final record = <String, Object?>{};
  final ssh = <String, Object?>{};
  final monitor = <String, Object?>{};
  final tags = <String>[];
  String? sshPasswordFile;
  String? monitorPasswordFile;

  for (var i = 0; i < options.length; i++) {
    final option = options[i];
    String value() {
      if (i + 1 == options.length || options[i + 1].startsWith('--')) {
        throw _CliError('Missing value for $option', 64);
      }
      return options[++i];
    }
    switch (option) {
      case '--name':
        record['name'] = value();
      case '--ssh-ip':
        ssh['ip'] = value();
      case '--ssh-port':
        final port = int.tryParse(value());
        if (port == null || port < 1 || port > 65535) {
          throw const _CliError('SSH port must be between 1 and 65535', 64);
        }
        ssh['port'] = port;
      case '--ssh-user':
        ssh['user'] = value();
      case '--ssh-key':
        final path = value();
        final home = Platform.environment['HOME'];
        final file = File(path.startsWith('~/') && home != null ? '$home/${path.substring(2)}' : path).absolute;
        if (!await file.exists()) throw const _CliError('SSH key file does not exist', 64);
        ssh['identityFiles'] = [file.path];
        ssh['keyPath'] = file.path;
        ssh['pubKeyId'] = null;
        ssh['pwd'] = null;
      case '--ssh-key-id':
        ssh['pubKeyId'] = value();
        ssh['identityFiles'] = null;
        ssh['keyPath'] = null;
        ssh['pwd'] = null;
      case '--ssh-password-file':
        sshPasswordFile = value();
      case '--ssh-jump':
        final id = value();
        ssh['jumpIds'] = [id];
        ssh['jumpId'] = id;
      case '--ssh-legacy-algorithms':
        ssh['allowLegacyAlgorithms'] = true;
      case '--monitor-addr':
        monitor['addr'] = value();
      case '--monitor-fallback':
        monitor['fallbackAddr'] = value();
      case '--monitor-user':
        monitor['user'] = value();
      case '--monitor-password-file':
        monitorPasswordFile = value();
      case '--allow-insecure-monitor':
        monitor['allowInsecure'] = true;
      case '--prefer':
        record['preferredTransport'] = switch (value()) {
          'ssh' => 'ssh',
          'monitor' => 'monitorHttp',
          _ => throw const _CliError('Expected --prefer ssh or --prefer monitor', 64),
        };
      case '--tag':
        tags.add(value());
      case '--local':
        record['local'] = true;
      case '--auto-connect':
        record['autoConnect'] = true;
      case '--no-auto-connect':
        record['autoConnect'] = false;
      default:
        throw _CliError('Unknown option $option', 64);
    }
  }
  if (sshPasswordFile == '-' && monitorPasswordFile == '-') {
    throw const _CliError('Only one password can be read from stdin', 64);
  }
  if (sshPasswordFile != null) ssh['pwd'] = await _readPassword(sshPasswordFile);
  if (monitorPasswordFile != null) monitor['pwd'] = await _readPassword(monitorPasswordFile);
  if (ssh.isNotEmpty) record['ssh'] = ssh;
  if (monitor.isNotEmpty) record['monitorHttp'] = monitor;
  if (tags.isNotEmpty) record['tags'] = tags;
  return record;
}

Future<String> _readPassword(String path) async {
  final stream = path == '-' ? stdin : File(path).openRead();
  final bytes = <int>[];
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > 4096) throw const _CliError('Password file is too large', 64);
    bytes.addAll(chunk);
  }
  final text = utf8.decode(bytes);
  if (text.endsWith('\r\n')) return text.substring(0, text.length - 2);
  if (text.endsWith('\n')) return text.substring(0, text.length - 1);
  return text;
}

final class _Bridge {
  const _Bridge(this.address, this.token);

  final InternetAddress address;
  final String token;

  static Future<_Bridge> read() async {
    final env = Platform.environment;
    final home = env['HOME'];
    final dataDir = switch (Platform.operatingSystem) {
      'macos' when home != null => '$home/Library/Application Support',
      'linux' when env['XDG_DATA_HOME']?.startsWith('/') ?? false => env['XDG_DATA_HOME'],
      'linux' when home != null => '$home/.local/share',
      _ => null,
    };
    final path = env['SBM_BRIDGE_FILE'] ?? (dataDir == null ? null : '$dataDir/ServerBox/bridge.json');
    if (path == null) throw const _CliError('The CLI requires a macOS or Linux build.');
    final file = File(path);
    final info = await file.stat();
    if (info.type == FileSystemEntityType.notFound) {
      throw const _CliError('No bridge discovery file. Launch ServerBox with SBM_BRIDGE=on.');
    }
    if (info.type != FileSystemEntityType.file || info.mode & 0x3f != 0 || info.size > 4096) {
      throw const _CliError('Invalid bridge discovery file permissions or size.');
    }
    final data = jsonDecode(await file.readAsString());
    if (data case {'socket': final String socket, 'token': final String token, 'api': 1}
        when socket.startsWith('/') && RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(token)) {
      final socketDir = await File(socket).parent.stat();
      if (socketDir.type == FileSystemEntityType.directory && socketDir.mode & 0x3f == 0) {
        return _Bridge(InternetAddress(socket, type: InternetAddressType.unix), token);
      }
    }
    throw const _CliError('Unsupported or invalid bridge discovery file.');
  }

  Future<Object?> send(String method, List<String> path, Map<String, Object?>? body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (_, _, _) => Socket.startConnect(address, 0);
    try {
      final uri = Uri(scheme: 'http', host: 'localhost', pathSegments: path);
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final decoded = jsonDecode(await utf8.decoder.bind(response).join());
      if (response.statusCode != 200) {
        final error = decoded is Map ? decoded['error'] : null;
        throw _CliError('${error ?? 'Bridge request failed'} (HTTP ${response.statusCode})');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }
}

final class _CliError implements Exception {
  const _CliError(this.message, [this.code = 1]);

  final String message;
  final int code;
}
