// Builds the Android app and publishes it so installed apps can update themselves.
//
//   npm run release                         bump the build number, build, publish
//   npm run release -- --notes "Fixed X"    text shown in the update dialog
//   npm run release -- --min                installed older versions MUST update
//   npm run release -- --version 1.2.0      also change the visible version name
//   npm run release -- --skip-build         publish the APK already built
//   npm run release -- --keep               don't bump the build number
//
// The APK and version.json go to the public `app-updates` bucket in Supabase
// Storage. Phones read version.json; if its versionCode is higher than the
// installed build they offer the update. (Needs android/key.properties so every
// release is signed with the same key - Android refuses updates otherwise.)
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const tus = require('tus-js-client');
const { supabase } = require('../src/clients');

const ROOT = path.resolve(__dirname, '..', '..');
const PUBSPEC = path.join(ROOT, 'pubspec.yaml');
const BUCKET = 'app-updates';

const args = process.argv.slice(2);
const flag = (n) => args.includes(`--${n}`);
const opt = (n) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i + 1] : undefined; };

function readVersion() {
  const m = fs.readFileSync(PUBSPEC, 'utf8').match(/^version:\s*([\d.]+)\+(\d+)\s*$/m);
  if (!m) throw new Error('Could not read "version: x.y.z+N" from pubspec.yaml');
  return { name: m[1], build: Number(m[2]) };
}

function writeVersion(name, build) {
  const txt = fs.readFileSync(PUBSPEC, 'utf8').replace(/^version:\s*.*$/m, `version: ${name}+${build}`);
  fs.writeFileSync(PUBSPEC, txt);
}


// Retries a step that failed because the connection dropped.
async function retry(label, fn, tries = 8) {
  for (let i = 1; ; i++) {
    try { return await fn(); }
    catch (e) {
      if (i >= tries) throw e;
      console.log(`  ${label}: ${e.message}; retrying (${i}/${tries - 1})...`);
      await new Promise((r) => setTimeout(r, Math.min(2000 * i, 15000)));
    }
  }
}

// Large files go up in resumable 6 MB pieces that retry on their own, so a flaky
// connection slows the upload down instead of failing it.
function uploadResumable(buffer, objectName, contentType) {
  return new Promise((resolve, reject) => {
    let lastPct = -1;
    const up = new tus.Upload(buffer, {
      endpoint: `${process.env.SUPABASE_URL}/storage/v1/upload/resumable`,
      retryDelays: [0, 2000, 5000, 10000, 20000, 30000, 30000, 30000],
      headers: { authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`, 'x-upsert': 'true' },
      uploadDataDuringCreation: true,
      removeFingerprintOnSuccess: true,
      metadata: { bucketName: BUCKET, objectName, contentType, cacheControl: '3600' },
      chunkSize: 6 * 1024 * 1024, // Supabase requires exactly 6 MB pieces
      onError: reject,
      onProgress: (sent, total) => {
        const pct = Math.floor((sent / total) * 100 / 10) * 10;
        if (pct !== lastPct) { lastPct = pct; console.log(`  uploading ${objectName}: ${pct}%`); }
      },
      onSuccess: resolve,
    });
    up.start();
  });
}

(async () => {
  if (!fs.existsSync(path.join(ROOT, 'android', 'key.properties'))) {
    throw new Error('android/key.properties is missing: releases must be signed with the release key.');
  }
  const current = readVersion();
  const name = opt('version') || current.name;
  const build = flag('keep') || flag('skip-build') ? current.build : current.build + 1;
  if (!flag('skip-build')) {
    writeVersion(name, build);
    console.log(`Building version ${name}+${build} (arm64)...`);
    const r = spawnSync('flutter',
      ['build', 'apk', '--release', '--target-platform', 'android-arm64', '--dart-define-from-file=app.env'],
      { cwd: ROOT, stdio: 'inherit', shell: true });
    if (r.status !== 0) { writeVersion(current.name, current.build); throw new Error('flutter build failed'); }
  }

  const apkPath = path.join(ROOT, 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk');
  const apk = fs.readFileSync(apkPath);
  const sha256 = crypto.createHash('sha256').update(apk).digest('hex');
  const mb = apk.length / 1048576;
  console.log(`APK: ${mb.toFixed(1)} MB, sha256 ${sha256.slice(0, 12)}...`);
  if (mb > 49) console.warn('Warning: over 50 MB - the free Supabase plan will reject this upload.');

  // Public bucket (created on first release).
  const made = await retry('create bucket', () => supabase.storage.createBucket(BUCKET, { public: true, fileSizeLimit: 52428800 }));
  if (made.error && !/already exists|duplicate/i.test(made.error.message)) throw made.error;
  await retry('update bucket', () => supabase.storage.updateBucket(BUCKET, { public: true, fileSizeLimit: 52428800 }));

  const pub = (f) => `${process.env.SUPABASE_URL}/storage/v1/object/public/${BUCKET}/${f}`;
  const apkName = `arrows-bar-${build}.apk`;
  await uploadResumable(apk, apkName, 'application/vnd.android.package-archive');

  // A later build must be published before it can be marked as the minimum.
  const manifest = {
    versionCode: build,
    versionName: name,
    apkUrl: pub(apkName),
    sha256,
    notes: opt('notes') || '',
    minVersionCode: flag('min') ? build : (await retry('read version', currentMin)),
    publishedAt: new Date().toISOString(),
  };
  const mv = await retry('publish version.json', () => supabase.storage.from(BUCKET).upload('version.json', Buffer.from(JSON.stringify(manifest, null, 2)), {
    contentType: 'application/json', upsert: true, cacheControl: '30',
  }));
  if (mv.error) throw mv.error;

  console.log('\nPublished.');
  console.log(`  version : ${name} (build ${build})${flag('min') ? '  [required update]' : ''}`);
  console.log(`  APK     : ${manifest.apkUrl}`);
  console.log('  Installed apps will offer this update the next time they are opened.');
  if (!flag('skip-build') && !flag('keep')) console.log(`  Remember to commit the version bump in pubspec.yaml (${name}+${build}).`);
})().catch((e) => { console.error('\nRelease failed:', e.message || e); process.exit(1); });

// Keep the existing "must update" floor unless --min raises it.
async function currentMin() {
  const { data, error } = await supabase.storage.from(BUCKET).download('version.json');
  if (error || !data) return 0; // nothing published yet
  return JSON.parse(await data.text()).minVersionCode || 0;
}
