import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/main.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:idb_shim/idb.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:slugify/slugify.dart';
import 'package:universal_io/io.dart';

FilesystemService fs = Get.isRegistered<FilesystemService>() ? Get.find<FilesystemService>() : Get.put(FilesystemService());

class FilesystemService extends GetxService {
  late Directory appDocDir;
  late final PackageInfo packageInfo;
  AndroidDeviceInfo? androidInfo;
  late final Database webDb;
  late final Uint8List noVideoPreviewIcon;
  late final Uint8List unplayableVideoIcon;
  final RxBool fontExistsOnDisk = false.obs;

  Future<void> init({bool headless = false}) async {
    if (!kIsWeb) {
      //ignore: unnecessary_cast, we need this as a workaround
      appDocDir = (kIsDesktop ? await getApplicationSupportDirectory() : await getApplicationDocumentsDirectory()) as Directory;
      bool? useCustomPath = ss.prefs.getBool("use-custom-path");
      String? customStorePath = ss.prefs.getString("custom-path");
      if (Platform.isWindows && useCustomPath == true && customStorePath != null) {
        appDocDir = Directory(customStorePath);
      }
      if (!headless) {
        final file = await loadAsset("assets/images/no-video-preview.png");
        noVideoPreviewIcon = file.buffer.asUint8List();
        final file2 = await loadAsset("assets/images/unplayable-video.png");
        unplayableVideoIcon = file2.buffer.asUint8List();
      }
    }
    packageInfo = await PackageInfo.fromPlatform();
    if (!headless && Platform.isAndroid) {
      androidInfo = await DeviceInfoPlugin().androidInfo;
    }
  }

  void checkFont() async {
    if (!kIsWeb) {
      EmojiFonts font = ss.settings.emojiFont;
      final file = File("${fs.appDocDir.path}/font/${font.name}.ttf");
      final exists = await file.exists();
      if (exists) {
        final bytes = await file.readAsBytes();
        fontExistsOnDisk.value = true;
        final fontLoader = FontLoader(font.fontName);
        final cachedFontBytes = ByteData.view(bytes.buffer);
        fontLoader.addFont(
          Future<ByteData>.value(cachedFontBytes),
        );
        await fontLoader.load();
      }
    } else {
      final idbFactory = idbFactoryBrowser;
      idbFactory.open("BlueBubbles.db", version: 1, onUpgradeNeeded: (VersionChangeEvent e) {
        final db = (e.target as OpenDBRequest).result;
        if (!db.objectStoreNames.contains("BBStore")) {
          db.createObjectStore("BBStore");
        }
      }).then((_db) async {
        webDb = _db;
        final txn = webDb.transaction("BBStore", idbModeReadOnly);
        final store = txn.objectStore("BBStore");
        Uint8List? bytes = await store.getObject("iosFont") as Uint8List?;
        await txn.completed;

        if (!isNullOrEmpty(bytes)!) {
          fontExistsOnDisk.value = true;
          final fontLoader = FontLoader("Apple Color Emoji");
          final cachedFontBytes = ByteData.view(bytes!.buffer);
          fontLoader.addFont(
            Future<ByteData>.value(cachedFontBytes),
          );
          await fontLoader.load();
        }
      });
    }
  }

  void deleteDB() {
    if (kIsWeb) return;
    attachmentBox.removeAll();
    chatBox.removeAll();
    fcmDataBox.removeAll();
    contactBox.removeAll();
    handleBox.removeAll();
    messageBox.removeAll();
    themeBox.removeAll();
  }

  String uriToFilename(String? uri, String? mimeType) {
    // Handle any unknown cases
    String? ext = mimeType != null ? mimeType.split('/')[1] : null;
    ext = (ext != null && ext.contains('+')) ? ext.split('+')[0] : ext;
    if (uri == null) return (ext != null) ? 'unknown.$ext' : 'unknown';

    // Get the filename
    String filename = uri;
    if (filename.contains('/')) {
      filename = filename.split('/').last;
    }

    // Get the extension
    if (filename.contains('.')) {
      List<String> split = filename.split('.');
      ext = split[1];
      filename = split[0];
    }

    // Slugify the filename
    filename = slugify(filename, delimiter: '_');

    // Rebuild the filename
    return (ext != null && ext.isNotEmpty) ? '$filename.$ext' : filename;
  }
}