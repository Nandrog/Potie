// Network test: needs internet and the live server, so it only runs on request:
//   flutter test test/net_fallback_test.dart --dart-define=RUN_NET=1
import 'package:flutter_test/flutter_test.dart';
import 'package:potie/data/resilient_http.dart';

const _run = bool.fromEnvironment('RUN_NET');
const _host = 'arrows-bar-api-sni7.onrender.com';

void main() {
  test('finds the server address without using the network DNS', () async {
    final ips = await resolveViaDoh(_host);
    expect(ips, isNotEmpty);
    expect(ips.every((i) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(i)), isTrue);
  }, skip: _run ? false : 'set --dart-define=RUN_NET=1');

  test('reaches /health even when normal DNS lookup fails', () async {
    final client = createApiClient();
    final res = await client
        .get(Uri.parse('https://$_host/health'))
        .timeout(const Duration(seconds: 90));
    expect(res.statusCode, 200);
    expect(res.body, contains('"ok":true'));
    client.close();
  }, skip: _run ? false : 'set --dart-define=RUN_NET=1');
}
