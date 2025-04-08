import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

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
      redirectCount = 1;
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

  Future<void> pickImageAndScan() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      final inputImage = InputImage.fromFilePath(picked.path);
      final scanner = BarcodeScanner();
      final barcodes = await scanner.processImage(inputImage);
      scanner.close();

      if (barcodes.isEmpty) {
        if (context.mounted) {
          showDialog(
            context: context,
            builder:
                (_) => const AlertDialog(
                  title: Text('QR-код не найден'),
                  content: Text('Пожалуйста, выбери другое изображение.'),
                ),
          );
        }
        return;
      }

      final rawValue = barcodes.first.rawValue;
      if (rawValue != null) {
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
    }
  }

  void launchUrl(String url) {
    debugPrint('Открываем ссылку: $url');
  }
}
