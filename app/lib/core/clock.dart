import 'package:flutter/services.dart';

/// Milissegundos desde o boot (`elapsedRealtime` no Android, `systemUptime` no
/// iOS): mexer no relógio do sistema não muda. No iOS não conta o tempo em repouso.
Future<int> uptimeMs() async => (await const MethodChannel('direct/clock').invokeMethod<int>('uptime'))!;
