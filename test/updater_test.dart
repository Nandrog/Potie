import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:potie/core/updater.dart';

Updater updaterFor(http.Response Function(http.Request) handler) => Updater(
      supabaseUrl: 'https://example.supabase.co',
      client: MockClient((r) async => handler(r)),
    );

String manifest({int code = 5, int min = 0}) => jsonEncode({
      'versionCode': code,
      'versionName': '1.2.0',
      'apkUrl': 'https://example.supabase.co/storage/v1/object/public/app-updates/arrows-bar-$code.apk',
      'sha256': 'ABCDEF',
      'notes': 'Fixes',
      'minVersionCode': min,
    });

void main() {
  test('offers a newer release', () async {
    final u = updaterFor((r) {
      expect(r.url.path, '/storage/v1/object/public/app-updates/version.json');
      return http.Response(manifest(code: 5), 200);
    });
    final info = await u.check(currentBuild: 4);
    expect(info, isNotNull);
    expect(info!.versionCode, 5);
    expect(info.versionName, '1.2.0');
    expect(info.sha256, 'abcdef'); // normalised to lower case
    expect(info.notes, 'Fixes');
  });

  test('nothing to do when already up to date or ahead', () async {
    final u = updaterFor((_) => http.Response(manifest(code: 5), 200));
    expect(await u.check(currentBuild: 5), isNull);
    expect(await u.check(currentBuild: 9), isNull);
  });

  test('no release published yet (404) is not an error', () async {
    final u = updaterFor((_) => http.Response('{"error":"not found"}', 404));
    expect(await u.check(currentBuild: 1), isNull);
  });

  test('server errors are reported', () async {
    final u = updaterFor((_) => http.Response('oops', 500));
    await expectLater(u.check(currentBuild: 1), throwsA(isA<UpdateException>()));
  });

  test('old builds below the minimum are forced to update', () async {
    final u = updaterFor((_) => http.Response(manifest(code: 7, min: 6), 200));
    final info = (await u.check(currentBuild: 5))!;
    expect(Updater.isMandatory(info, 5), isTrue);
    expect(Updater.isMandatory(info, 6), isFalse);
  });
}
