import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/data/real_app.dart';
import 'src/domain/services.dart';
import 'src/ui/app.dart';
import 'src/ui/platform/real_platform.dart';
import 'src/ui/platform/services.dart';
import 'src/ui/state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) await BrowserContextMenu.disableContextMenu();
  await initPlatform();
  final prefs = await SharedPreferences.getInstance();
  final ZalosApp app = await createZalosApp();
  runApp(
    ProviderScope(
      overrides: [
        zalosAppProvider.overrideWithValue(app),
        sharedPrefsProvider.overrideWithValue(prefs),
        platformProvider.overrideWithValue(RealPlatform()),
      ],
      child: const ZalosRoot(),
    ),
  );
}
