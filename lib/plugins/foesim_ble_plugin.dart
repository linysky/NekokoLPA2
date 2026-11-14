import 'package:flutter/material.dart';

import '../adapter/ble/ble_adapter.dart';
import '../adapter/ble/foesim_ble_adapter.dart';
import '../models/euicc_profile.dart';
import 'plugin_base.dart';

/// Adds FOESIM / 7eSIM Bluetooth eSIM readers (`eSIM-BLE-XXXXXXXX`).
///
/// The reader advertises service 0x4553 but uses a private characteristic
/// layout (write 0x494d, notify 0x4553), so it must not fall through to the
/// built-in ESTKme-RED adapter.
class FoesimBlePlugin extends ProfilePlugin {
  static final BleReaderKind kind = BleReaderKind(
    id: 'foesim_ble',
    label: 'FOESIM',
    matches: (displayName, advertisedName) =>
        _matches(displayName) || _matches(advertisedName),
    createAdapter: FoesimBleAdapter.new,
    icon: Icons.bluetooth,
    scanKeywords: const <String>['eSIM-BLE'],
    scanServiceUuids: const <String>[
      '00004553-0000-1000-8000-00805f9b34fb',
    ],
  );

  static bool _matches(String name) {
    final upper = name.toUpperCase();
    return upper.contains('-BLE-') || upper.contains('-BLER-');
  }

  @override
  String get id => 'foesim_ble';

  @override
  String get name => 'FOESIM';

  @override
  bool isMatch(EuiccProfile profile) => false;

  @override
  List<BleReaderKind> get bleReaderKinds => <BleReaderKind>[kind];
}
