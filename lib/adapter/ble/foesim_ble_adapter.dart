import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ble/ble.dart';
import 'package:logging/logging.dart';

import '../euicc_adapter.dart';
import '../../utils/error_codes.dart';
import 'ble_adapter.dart';
import 'ble_transport_utils.dart';

/// FOESIM / 7eSIM Bluetooth eSIM reader (advertises as `eSIM-BLE-XXXXXXXX`).
///
/// It uses the same framed APDU tunnel as ESTKme-RED:
///
///   0x04 | len_lo | len_hi | `<payload>`
///
/// but with a different characteristic layout and no Claim/PowerOn handshake.
/// Verified against a real reader on 2026-11-13; see docs/TECHNICAL_DESIGN.md.
class FoesimBleAdapter extends BaseAdapter implements BleAdapter {
  static final Logger _log = Logger('FoesimBleAdapter');

  FoesimBleAdapter() : super(_log);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothCharacteristic? _rxChar;
  StreamSubscription? _rxSub;
  StreamSubscription? _connSub;

  // On-device GATT (bleak, E8:05:ED:E5:63:FC):
  //   service 00004553-...
  //     0000494d-...  write, write-without-response  (host -> reader)
  //     00004553-...  notify, CCCD 00002902-...      (reader -> host)
  final Guid serviceUuid = Guid('4553');
  final Guid txCharUuid = Guid('494d');
  final Guid rxCharUuid = Guid('4553');

  final StreamController<EuiccPortState> _stateController =
      StreamController<EuiccPortState>.broadcast();

  @override
  Stream<EuiccPortState> get stateStream => _stateController.stream;

  @override
  bool get requiresRefresh => false;

  @override
  String? get lastAtr => null;

  @override
  Future<List<Reader>> listReaders({bool force = false}) async {
    return connectedReader != null ? [connectedReader!] : <Reader>[];
  }

  @override
  Future<void> connect(Reader reader) async {
    return await runExclusive(() async {
      updateConnectedReader(reader);
      // Reader ids are "<type>: <name>|<deviceId>".
      final deviceId = reader.id.split('|').last;
      _device = BluetoothDevice.fromId(deviceId);
      log.info('Connecting to FOESIM BLE device: $deviceId');
      try {
        await connectBleDevice(_device!, log, progress: connectProgress);

        await _connSub?.cancel();
        _connSub = _device!.connectionState.listen((state) {
          if (state == BluetoothConnectionState.disconnected) {
            log.warning('FOESIM BLE disconnected unexpectedly');
            _txChar = null;
            _rxChar = null;
            updateConnectedReader(null);
            _stateController.add(EuiccPortState.closed);
          }
        });

        reportConnectStep(ReaderConnectStep.discoveringServices);
        final services = await _device!.discoverServices();
        final service = services.firstWhere(
          (s) => s.uuid == serviceUuid,
          orElse: () => throw AppException(
            AppErrorCode.ERROR_BLUETOOTH_SERVICE_NOT_FOUND,
            message: 'FOESIM BLE service (4553) not found',
          ),
        );

        _txChar = service.characteristics.firstWhere(
          (c) => c.uuid == txCharUuid,
          orElse: () => throw AppException(
            AppErrorCode.ERROR_BLUETOOTH_CHARACTERISTIC_NOT_FOUND,
            message: 'FOESIM TX characteristic (494d) not found',
          ),
        );
        _rxChar = service.characteristics.firstWhere(
          (c) => c.uuid == rxCharUuid,
          orElse: () => throw AppException(
            AppErrorCode.ERROR_BLUETOOTH_CHARACTERISTIC_NOT_FOUND,
            message: 'FOESIM RX characteristic (4553) not found',
          ),
        );
        log.info('Found characteristics - TX: $txCharUuid, RX: $rxCharUuid');

        reportConnectStep(ReaderConnectStep.enablingNotifications);
        await _rxChar!.setNotifyValue(true);

        // The vendor app opens its logical channel with this control frame
        // before issuing SELECT AID. A real reader answers with a short
        // status frame (observed: 04 02 00 69 88). Any well-formed frame is
        // accepted here; the APDU layer handles the actual status word.
        reportConnectStep(ReaderConnectStep.initializing);
        await _transmit(
          0x04,
          Uint8List.fromList(<int>[0x00, 0x70, 0x00, 0x00, 0x01]),
        );

        _stateController.add(EuiccPortState.open);
      } catch (e) {
        log.shout('Connection failed: $e');
        await disconnect();
        if (e is TimeoutException) {
          throw AppException(
            AppErrorCode.ERROR_BLUETOOTH_TIMEOUT,
            originalError: e,
          );
        }
        throw AppException(
          AppErrorCode.ERROR_BLUETOOTH_CONNECT_FAILED,
          originalError: e,
        );
      }
    });
  }

  @override
  Future<void> disconnect() async {
    return await runExclusive(() async {
      log.info('Disconnecting from FOESIM BLE device...');
      await _rxSub?.cancel();
      _rxSub = null;
      await _connSub?.cancel();
      _connSub = null;
      await _device?.disconnect();
      _device = null;
      _txChar = null;
      _rxChar = null;
      updateConnectedReader(null);
      _stateController.add(EuiccPortState.closed);
      log.info('Disconnected.');
    });
  }

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) async {
    // 04 | LEN | APDU  ->  CMD | LEN | DATA+SW
    final resp = await _transmit(0x04, apdu);
    if (resp.length < 3) {
      log.warning('APDU << Error: Invalid response length (${resp.length})');
      throw AppException(
        AppErrorCode.ERROR_TRANSACTION_FAILED,
        message: 'Invalid response from FOESIM BLE',
      );
    }
    return resp.sublist(3);
  }

  Future<Uint8List> _transmit(int cmd, Uint8List? payload) async {
    if (_device == null || _txChar == null || _rxChar == null) {
      throw AppException(
        AppErrorCode.ERROR_BLUETOOTH_CONNECT_FAILED,
        message: 'FOESIM BLE not connected',
      );
    }

    final payloadLen = payload?.length ?? 0;
    final header = Uint8List(3);
    header[0] = cmd;
    header[1] = payloadLen & 0xFF;
    header[2] = (payloadLen >> 8) & 0xFF;
    final request = Uint8List.fromList(<int>[...header, ...?payload]);

    final completer = Completer<Uint8List>();
    final buffer = <int>[];
    var expectedLength = -1;

    _rxSub = _rxChar!.onValueReceived.listen((data) {
      buffer.addAll(data);
      if (expectedLength == -1 && buffer.length >= 3) {
        expectedLength = buffer[1] + (buffer[2] << 8) + 3;
      }
      if (expectedLength != -1 &&
          buffer.length >= expectedLength &&
          !completer.isCompleted) {
        completer.complete(Uint8List.fromList(buffer));
      }
    });

    try {
      await _writeChunks(request);
      return await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw AppException(
          AppErrorCode.ERROR_BLUETOOTH_TIMEOUT,
          message: 'FOESIM BLE transmission timeout',
        ),
      );
    } finally {
      await _rxSub?.cancel();
      _rxSub = null;
    }
  }

  /// The vendor app always writes without response, 15 ms between slices.
  /// `writeBleChunks` would pick a write-with-response here because the
  /// characteristic advertises both, so the framing stays local.
  Future<void> _writeChunks(Uint8List data) async {
    final chunkSize = calculateBleWriteChunkSize(_device!.mtuNow);
    for (var offset = 0; offset < data.length; offset += chunkSize) {
      final end = math.min(offset + chunkSize, data.length);
      await _txChar!.write(
        Uint8List.sublistView(data, offset, end),
        withoutResponse: true,
      );
      await Future.delayed(const Duration(milliseconds: 15));
    }
  }

  @override
  Future<Channel> openChannel({List<String>? aids}) async {
    return await openLogicalChannel(aids: aids);
  }
}
