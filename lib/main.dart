import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QR Checker',
      theme: ThemeData.dark(),
      home: const QRScannerPage(),
    );
  }
}

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({super.key});
  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  String? scannedData;
  String? finalUrl;
  bool? isSafe;
  bool showDetails = false;
  bool showFullLink = false;
  int redirectCount = 0;
  MobileScannerController cameraController = MobileScannerController();
  Map<String, String>? domainInfo;
  final Map<String, String> resolvedLinksCache = {};

  bool checkIfUrlIsSafe(String url) {
    final lowerUrl = url.toLowerCase();
    return !(lowerUrl.contains('bit.ly') ||
        lowerUrl.contains('http://') ||
        RegExp(r'^https?:\/\/\d{1,3}(\.\d{1,3}){3}').hasMatch(lowerUrl));
  }

  Future<String> resolveFinalUrl(String url) async {
    if (resolvedLinksCache.containsKey(url)) {
      redirectCount = 1; // считаем как минимум 1 редирект если из кэша
      return resolvedLinksCache[url]!;
    }

    String current = url;
    int hops = 0;

    while (true) {
      try {
        final response = await http.head(
          Uri.parse(current),
          headers: {'User-Agent': 'curl/7.64.1'},
        );

        final location = response.headers['location'];
        if ((response.isRedirect ||
                response.statusCode == 301 ||
                response.statusCode == 302) &&
            location != null) {
          current = location;
          hops++;
        } else {
          break;
        }
      } catch (_) {
        break;
      }
    }

    redirectCount = hops;
    resolvedLinksCache[url] = current;
    return current;
  }

  Future<Map<String, String>> fetchDomainInfo(String url) async {
    final uri = Uri.parse(url);
    final domain = uri.host;
    final info = <String, String>{};

    try {
      final ipRes = await http.get(Uri.parse('https://ipwho.is/$domain'));
      if (ipRes.statusCode == 200) {
        final data = jsonDecode(ipRes.body);
        final ip = data['ip']?.toString();
        if (ip == null ||
            ip.startsWith('192.') ||
            ip.startsWith('127.') ||
            ip == '95.24.164.32') {
          info['IP'] = 'Не удалось определить';
          info['Страна'] = 'Не удалось определить';
          info['Хостинг'] = 'Не удалось определить';
        } else {
          info['IP'] = ip;
          info['Страна'] = data['country'] ?? 'Неизвестно';
          info['Хостинг'] = data['connection']?['isp'] ?? 'Неизвестно';
        }
      }
    } catch (_) {}

    try {
      final rdapRes = await http.get(
        Uri.parse('https://rdap.org/domain/$domain'),
      );
      if (rdapRes.statusCode == 200) {
        final data = jsonDecode(rdapRes.body);
        final registration = (data['events'] as List?)?.firstWhere(
          (e) => e['eventAction'] == 'registration',
          orElse: () => null,
        );
        if (registration != null) {
          info['Создан'] =
              registration['eventDate']?.toString().split('T').first ??
              'Неизвестно';
        }
      }
    } catch (_) {}

    final suspiciousWords = [
      'login',
      'secure',
      'account',
      'verify',
      'update',
      'steam',
      'telegram',
      'wallet',
    ];
    final foundWords =
        suspiciousWords.where((word) => url.contains(word)).toList();

    info['TLD'] = domain.split('.').last;
    info['Протокол'] = url.startsWith('https') ? 'HTTPS' : 'HTTP';
    info['Содержит слова'] =
        foundWords.isNotEmpty ? foundWords.join(', ') : '-';

    return info;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          MobileScanner(
            controller: cameraController,
            fit: BoxFit.cover,
            onDetect: (capture) async {
              final barcode = capture.barcodes.first;
              final rawValue = barcode.rawValue;
              if (rawValue != null && scannedData == null) {
                final realUrl = await resolveFinalUrl(rawValue);
                final safe = checkIfUrlIsSafe(realUrl);
                final info = await fetchDomainInfo(realUrl);
                setState(() {
                  scannedData = rawValue;
                  finalUrl = realUrl;
                  isSafe = safe;
                  showDetails = true;
                  domainInfo = info;
                });
                cameraController.stop();
              }
            },
          ),

          if (!showDetails)
            Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.greenAccent, width: 2),
                ),
              ),
            ),

          if (showDetails && finalUrl != null)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.95),
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      color: isSafe! ? Colors.green : Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isSafe! ? Icons.check_circle : Icons.block,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            isSafe!
                                ? 'Ссылка безопасна'
                                : 'Подозрительная ссылка',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Ссылка в QR-коде:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              scannedData!,
                              style: const TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Реальный адрес назначения:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            InkWell(
                              onTap: () => launchUrl(finalUrl!),
                              child: Text(
                                finalUrl!,
                                style: const TextStyle(
                                  color: Colors.blue,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                            if (redirectCount > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  'Редиректов: $redirectCount',
                                  style: const TextStyle(
                                    color: Colors.orangeAccent,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 20),
                            const Text(
                              'Информация о сайте:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            if (domainInfo != null)
                              ...domainInfo!.entries.map(
                                (e) => Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${e.key}: ',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Expanded(child: Text(e.value)),
                                    ],
                                  ),
                                ),
                              )
                            else
                              const Text('Информация о домене не найдена.'),
                          ],
                        ),
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              setState(() {
                                scannedData = null;
                                finalUrl = null;
                                isSafe = null;
                                showDetails = false;
                                showFullLink = false;
                                domainInfo = null;
                                redirectCount = 0;
                              });
                              cameraController.start();
                            },
                            child: const Text('Сканировать снова'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void launchUrl(String url) {
    debugPrint('Открываем ссылку: $url');
  }
}
