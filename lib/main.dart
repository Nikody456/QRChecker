import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:universal_html/html.dart' as html;
import 'package:logging/logging.dart';
import 'package:google_fonts/google_fonts.dart';

// Initialize logger
final _logger = Logger('QRChecker');

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });
  runApp(const MyApp());
}

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
  bool isFlashOn = false;
  bool isBackCamera = true;
  Rect? qrCodeRect;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'QR Checker',
          style: GoogleFonts.roboto(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: cameraController,
            fit: BoxFit.cover,
            onDetect: (capture) async {
              final barcode = capture.barcodes.first;
              final rawValue = barcode.rawValue;
              if (rawValue != null && scannedData == null) {
                // Calculate QR code position
                final size = MediaQuery.of(context).size;
                final width = size.width * 0.6;
                final height = width;
                final left = (size.width - width) / 2;
                final top = (size.height - height) / 2;
                setState(() {
                  qrCodeRect = Rect.fromLTWH(left, top, width, height);
                });
                
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
              } else if (rawValue != null) {
                // Update QR code position while scanning
                final size = MediaQuery.of(context).size;
                final width = size.width * 0.6;
                final height = width;
                final left = (size.width - width) / 2;
                final top = (size.height - height) / 2;
                setState(() {
                  qrCodeRect = Rect.fromLTWH(left, top, width, height);
                });
              }
            },
          ),
          if (qrCodeRect != null)
            Positioned.fromRect(
              rect: qrCodeRect!,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.green,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          if (isProcessing) const Center(child: CircularProgressIndicator()),
          if (!showDetails && !isProcessing)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildIconButton(
                      icon: Icons.photo_library,
                      onPressed: pickImageAndScan,
                    ),
                    _buildIconButton(
                      icon: Icons.flash_on,
                      onPressed: toggleFlash,
                      isActive: isFlashOn,
                    ),
                    _buildIconButton(
                      icon: Icons.flip_camera_ios,
                      onPressed: toggleCamera,
                    ),
                  ],
                ),
              ),
            ),
          if (showDetails && !isProcessing) _buildDetailsPanel(),
        ],
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onPressed,
    bool isActive = false,
  }) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.2 * 255),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(
          icon,
          color: isActive ? Colors.black : Colors.white,
          size: 28,
        ),
        onPressed: onPressed,
      ),
    );
  }

  void toggleFlash() {
    setState(() {
      isFlashOn = !isFlashOn;
      cameraController.toggleTorch();
    });
  }

  void toggleCamera() {
    setState(() {
      isBackCamera = !isBackCamera;
      cameraController.switchCamera();
    });
  }

  Widget _buildDetailsPanel() {
    return Container(
      margin: const EdgeInsets.only(top: 50),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85 * 255),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Text(
            isSafe == true ? '✅ Ссылка безопасна' : '🚨 Подозрительная ссылка',
            style: GoogleFonts.roboto(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isSafe == true ? Colors.green : Colors.red,
            ),
          ),
          const SizedBox(height: 16),
          _buildInfoCard(
            title: 'Ссылка в QR-коде:',
            content: scannedData ?? '-',
          ),
          if (finalUrl != null && finalUrl != scannedData) ...[
            const SizedBox(height: 12),
            _buildInfoCard(
              title: 'Реальный адрес назначения:',
              content: finalUrl!,
              isUrl: true,
            ),
            const SizedBox(height: 8),
            Text(
              'Редиректов: $redirectCount',
              style: GoogleFonts.roboto(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
          ],
          if (domainInfo != null) ...[
            const SizedBox(height: 16),
            ...domainInfo!.entries.map(
              (e) => _buildInfoCard(
                title: '${e.key}:',
                content: e.value,
              ),
            ),
          ],
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () {
              setState(() {
                scannedData = null;
                finalUrl = null;
                isSafe = null;
                showDetails = false;
                domainInfo = null;
                qrCodeRect = null;
              });
              cameraController.start();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              'Сканировать снова',
              style: GoogleFonts.roboto(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String content,
    bool isUrl = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1 * 255),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.roboto(
              fontWeight: FontWeight.bold,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            content,
            style: GoogleFonts.roboto(
              color: isUrl ? Colors.blue : Colors.white,
              decoration: isUrl ? TextDecoration.underline : null,
            ),
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
    Set<String> visitedUrls = {current};

    while (hops < 10) {
      if (!mounted) return current; // Check if widget is still mounted
      try {
        final response = await http.get(
          Uri.parse(current),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
          },
        );
        final location = response.headers['location'];
        if ((response.isRedirect ||
                response.statusCode == 301 ||
                response.statusCode == 302) &&
            location != null) {
          final nextUrl = Uri.parse(location).toString();
          if (visitedUrls.contains(nextUrl)) break;
          visitedUrls.add(nextUrl);
          current = nextUrl;
          hops++;
        } else {
          break;
        }
      } catch (e) {
        _logger.warning('Error resolving URL: $e');
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
        if (!mounted) return;
        final reader = html.FileReader();
        final file = uploadInput.files!.first;
        reader.readAsArrayBuffer(file);
        reader.onLoadEnd.listen((event) async {
          if (!mounted) return;
          try {
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

            if (!mounted) return;
            setState(() => isProcessing = false);

            if (barcodes.isEmpty) {
              if (!mounted) return;
              await showDialog(
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
              if (!mounted) return;
              setState(() => isProcessing = true);

              try {
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
              } catch (e) {
                _logger.warning('Error processing URL: $e');
                if (!mounted) return;
                setState(() => isProcessing = false);
                await showDialog(
                  context: context,
                  builder:
                      (_) => const AlertDialog(
                        title: Text('Ошибка'),
                        content: Text('Не удалось обработать URL.'),
                      ),
                );
              }
            }
          } catch (e) {
            _logger.warning('Error processing image: $e');
            if (!mounted) return;
            setState(() => isProcessing = false);
            await showDialog(
              context: context,
              builder:
                  (_) => const AlertDialog(
                    title: Text('Ошибка'),
                    content: Text('Не удалось обработать изображение.'),
                  ),
            );
          }
        });
      });
      return;
    } else {
      try {
        final picker = ImagePicker();
        final picked = await picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1920,
          maxHeight: 1920,
          imageQuality: 85,
        );

        if (picked != null) {
          if (!mounted) return;
          try {
            setState(() => isProcessing = true);
            final inputImage = InputImage.fromFilePath(picked.path);
            final scanner = BarcodeScanner();
            final barcodes = await scanner.processImage(inputImage);
            await scanner.close();

            if (!mounted) return;
            setState(() => isProcessing = false);

            if (barcodes.isEmpty) {
              if (!mounted) return;
              await showDialog(
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
              if (!mounted) return;
              setState(() => isProcessing = true);

              try {
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
              } catch (e) {
                _logger.warning('Error processing URL: $e');
                if (!mounted) return;
                setState(() => isProcessing = false);
                await showDialog(
                  context: context,
                  builder:
                      (_) => const AlertDialog(
                        title: Text('Ошибка'),
                        content: Text('Не удалось обработать URL.'),
                      ),
                );
              }
            }
          } catch (e) {
            _logger.warning('Error processing image: $e');
            if (!mounted) return;
            setState(() => isProcessing = false);
            await showDialog(
              context: context,
              builder:
                  (_) => const AlertDialog(
                    title: Text('Ошибка'),
                    content: Text('Не удалось обработать изображение.'),
                  ),
            );
          }
        }
      } catch (e) {
        _logger.warning('Error picking image: $e');
        if (!mounted) return;
        await showDialog(
          context: context,
          builder:
              (_) => const AlertDialog(
                title: Text('Ошибка'),
                content: Text('Не удалось выбрать изображение.'),
              ),
        );
      }
    }
  }
}
