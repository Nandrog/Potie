import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../data/resilient_http.dart';

/// A published release, read from `version.json` in the public `app-updates`
/// storage bucket (see server/scripts/release.js).
class UpdateInfo {
  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.url,
    required this.sha256,
    this.notes = '',
    this.minVersionCode = 0,
  });

  final int versionCode;
  final String versionName;
  final String url;
  final String sha256;
  final String notes;

  /// Installed builds older than this must update before they can be used.
  final int minVersionCode;

  factory UpdateInfo.fromJson(Map<String, dynamic> j) => UpdateInfo(
        versionCode: (j['versionCode'] as num).toInt(),
        versionName: j['versionName'] as String? ?? '',
        url: j['apkUrl'] as String,
        sha256: (j['sha256'] as String? ?? '').toLowerCase(),
        notes: j['notes'] as String? ?? '',
        minVersionCode: (j['minVersionCode'] as num?)?.toInt() ?? 0,
      );
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Self-update for the Android app: no reinstalling APK files by hand.
/// Android still asks the user to confirm the install (and to allow installs
/// from this app the first time), and only accepts an APK signed with the
/// same key as the installed app.
class Updater {
  Updater({String? supabaseUrl, http.Client? client})
      : _base = supabaseUrl ?? const String.fromEnvironment('SUPABASE_URL'),
        _client = client ?? createApiClient();

  final String _base;
  final http.Client _client;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Uri get _versionUrl => Uri.parse(
      '$_base/storage/v1/object/public/app-updates/version.json'
      '?t=${DateTime.now().millisecondsSinceEpoch}'); // skip stale CDN copies

  /// The build number of the installed app.
  static Future<int> installedBuild() async =>
      int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

  /// Returns the newer release, or null if the app is up to date (or no
  /// release has been published yet).
  Future<UpdateInfo?> check({int? currentBuild}) async {
    final res = await _client
        .get(_versionUrl)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 404 || res.statusCode == 400) return null;
    if (res.statusCode != 200) {
      throw UpdateException('Could not check for updates (${res.statusCode}).');
    }
    final info = UpdateInfo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    final mine = currentBuild ?? await installedBuild();
    return info.versionCode > mine ? info : null;
  }

  /// True when this installed build is too old to keep running.
  static bool isMandatory(UpdateInfo info, int currentBuild) =>
      currentBuild < info.minVersionCode;

  /// Downloads the APK, reporting progress 0..1, and verifies its checksum.
  Future<File> download(UpdateInfo info, void Function(double) onProgress) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/arrows-bar-${info.versionCode}.apk');
    if (await file.exists()) await file.delete();

    final req = http.Request('GET', Uri.parse(info.url));
    final res = await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw UpdateException('Download failed (${res.statusCode}).');
    }
    final total = res.contentLength ?? 0;
    var got = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress(got / total);
      }
    } finally {
      await sink.close();
    }
    if (info.sha256.isNotEmpty) {
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (digest != info.sha256) {
        await file.delete();
        throw UpdateException('The download was damaged. Please try again.');
      }
    }
    return file;
  }

  /// Hands the APK to Android's installer.
  Future<void> install(File apk) async {
    final r = await OpenFilex.open(apk.path,
        type: 'application/vnd.android.package-archive');
    if (r.type != ResultType.done) {
      throw UpdateException(
          'Could not start the installer. Allow "Install unknown apps" for Arrows Bar in Android settings, then try again.');
    }
  }

  void close() => _client.close();
}
