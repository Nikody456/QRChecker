import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:universal_html/html.dart' as html;

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
  int redirectCount = 0;
  bool isProcessing = false;
  Map<String, String>? domainInfo;
  final cameraController = MobileScannerController();
  final resolvedLinksCache = <String, String>{};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR Checker')),
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
                if (!mounted) return;
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
          if (isProcessing) const Center(child: CircularProgressIndicator()),
          if (!showDetails && !isProcessing)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: FloatingActionButton.extended(
                  onPressed: pickImageAndScan,
                  label: const Text('Фото из галереи'),
                  icon: const Icon(Icons.photo),
                ),
              ),
            ),
          if (showDetails && !isProcessing) _buildDetailsPanel(),
        ],
      ),
    );
  }

  Widget _buildDetailsPanel() {
    return Container(
      margin: const EdgeInsets.only(top: 50),
      padding: const EdgeInsets.all(16),
      color: Colors.black.withOpacity(0.85),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Text(
            isSafe == true ? '✅ Ссылка безопасна' : '🚨 Подозрительная ссылка',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isSafe == true ? Colors.green : Colors.red,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Ссылка в QR-коде:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(scannedData ?? '-'),
          const SizedBox(height: 12),
          if (finalUrl != null && finalUrl != scannedData)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Реальный адрес назначения:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(finalUrl!, style: const TextStyle(color: Colors.blue)),
                Text('Редиректов: $redirectCount'),
              ],
            ),
          const SizedBox(height: 12),
          if (domainInfo != null)
            ...domainInfo!.entries.map(
              (e) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${e.key}:',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(e.value),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () {
              setState(() {
                scannedData = null;
                finalUrl = null;
                isSafe = null;
                showDetails = false;
                domainInfo = null;
              });
              cameraController.start();
            },
            child: const Text('Сканировать снова'),
          ),
        ],
      ),
    );
  }

  bool checkIfUrlIsSafe(String url) {
    final lower = url.toLowerCase();
    return !lower.contains('bit.ly') &&
        !lower.contains('http://') &&
        !RegExp(r'^https?:\\/\\/\\d{1,3}(\\.\\d{1,3}){3}').hasMatch(lower);
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
    final foundWords = suspiciousWords.where((w) => url.contains(w)).toList();

    info['TLD'] = domain.split('.').last;
    info['Протокол'] = url.startsWith('https') ? 'HTTPS' : 'HTTP';
    info['Содержит слова'] =
        foundWords.isNotEmpty ? foundWords.join(', ') : '-';

    return info;
  }

  Future<void> pickImageAndScan() async {
    if (kIsWeb) {
      final uploadInput = html.FileUploadInputElement();
      uploadInput.accept = 'image/*';
      uploadInput.click();
      uploadInput.onChange.listen((event) async {
        final reader = html.FileReader();
        final file = uploadInput.files!.first;
        reader.readAsArrayBuffer(file);
        reader.onLoadEnd.listen((event) async {
          setState(() => isProcessing = true);
          final bytes = reader.result as Uint8List;
          final inputImage = InputImage.fromBytes(
            bytes: bytes,
            metadata: InputImageMetadata(
              size: Size(1000, 1000),
              rotation: InputImageRotation.rotation0deg,
              format: InputImageFormat.nv21,
              bytesPerRow: 1000,
            ),
          );
          final scanner = BarcodeScanner();
          final barcodes = await scanner.processImage(inputImage);
          await scanner.close();
          setState(() => isProcessing = false);
          if (barcodes.isEmpty) {
            showDialog(
              context: context,
              builder:
                  (_) => const AlertDialog(
                    title: Text('QR-код не найден'),
                    content: Text('Попробуйте другое изображение.'),
                  ),
            );
            return;
          }
          final rawValue = barcodes.first.rawValue;
          if (rawValue != null) {
            setState(() => isProcessing = true);
            final realUrl = await resolveFinalUrl(rawValue);
            final safe = checkIfUrlIsSafe(realUrl);
            final info = await fetchDomainInfo(realUrl);
            if (!mounted) return;
            setState(() {
              scannedData = rawValue;
              finalUrl = realUrl;
              isSafe = safe;
              showDetails = true;
              domainInfo = info;
              isProcessing = false;
            });
            cameraController.stop();
          }
        });
      });
      return;
    }

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      setState(() => isProcessing = true);
      final inputImage = InputImage.fromFilePath(picked.path);
      final scanner = BarcodeScanner();
      final barcodes = await scanner.processImage(inputImage);
      await scanner.close();
      if (!mounted) return;
      setState(() => isProcessing = false);
      if (barcodes.isEmpty) {
        showDialog(
          context: context,
          builder:
              (_) => const AlertDialog(
                title: Text('QR-код не найден'),
                content: Text('Попробуйте другое изображение.'),
              ),
        );
        return;
      }
      final rawValue = barcodes.first.rawValue;
      if (rawValue != null) {
        setState(() => isProcessing = true);
        final realUrl = await resolveFinalUrl(rawValue);
        final safe = checkIfUrlIsSafe(realUrl);
        final info = await fetchDomainInfo(realUrl);
        if (!mounted) return;
        setState(() {
          scannedData = rawValue;
          finalUrl = realUrl;
          isSafe = safe;
          showDetails = true;
          domainInfo = info;
          isProcessing = false;
        });
        cameraController.stop();
      }
    }
  }
}
