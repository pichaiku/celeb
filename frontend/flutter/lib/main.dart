import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img_lib;
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Get list of available cameras
  List<CameraDescription> cameras = [];
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Failed to fetch camera devices: $e");
  }

  // Set system UI style to match our dark premium theme
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0B0F19),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(CelebMatchApp(cameras: cameras));
}

class CelebMatchApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const CelebMatchApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CelebMatch AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B5CF6),
          brightness: Brightness.dark,
          primary: const Color(0xFF8B5CF6),
          secondary: const Color(0xFF6366F1),
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      ),
      home: CelebMatchHome(cameras: cameras),
    );
  }
}

class CelebMatchHome extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CelebMatchHome({super.key, required this.cameras});

  @override
  State<CelebMatchHome> createState() => _CelebMatchHomeState();
}

class _CelebMatchHomeState extends State<CelebMatchHome>
    with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isModelLoaded = false;
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  bool _isUploadMode = false;
  bool _isUploadProcessing = false;
  int _cameraIndex = 0;
  Uint8List? _selectedImageBytes;
  String? _uploadErrorMessage;
  final ImagePicker _imagePicker = ImagePicker();

  // Scanning animation controller
  late AnimationController _scanningController;

  // Inference Results State
  String _topCelebrity = "Initializing...";
  double _topConfidence = 0.0;
  List<MapEntry<String, double>> _allPredictions = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();

    // Set up scanning bar animation
    _scanningController = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat(reverse: true);

    _loadModelAndLabels();
  }

  Future<void> _loadModelAndLabels() async {
    try {
      // Load interpreter options (can be customized for CPU threads)
      final options = InterpreterOptions()..threads = 2;

      // Load TFLite Model from assets
      _interpreter = await Interpreter.fromAsset(
        'assets/cnn_celeb.tflite',
        options: options,
      );

      // Load Labels file
      final labelData = await rootBundle.loadString(
        'assets/cnn_label_index.txt',
      );
      final lines = labelData.split('\n');
      final Map<int, String> tempLabels = {};
      for (var line in lines) {
        final cleanLine = line.trim();
        if (cleanLine.isNotEmpty && cleanLine.contains(':')) {
          final parts = cleanLine.split(':');
          if (parts.length >= 2) {
            final name = parts[0].trim();
            final idx = int.tryParse(parts[1].trim());
            if (idx != null) {
              tempLabels[idx] = name;
            }
          }
        }
      }

      // Sort labels by index keys
      final sortedKeys = tempLabels.keys.toList()..sort();
      _labels = sortedKeys.map((k) => tempLabels[k]!).toList();

      setState(() {
        _isModelLoaded = true;
      });

      if (!_isUploadMode) {
        _initCamera();
      }
    } catch (e) {
      debugPrint("Initialization error: $e");
      setState(() {
        _errorMessage =
            "Failed to load AI Model or Labels. Please check your asset configuration.";
        _topCelebrity = "Setup Error";
      });
    }
  }

  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) {
      setState(() {
        _errorMessage = "No camera devices detected on this device.";
        _topCelebrity = "No Camera";
      });
      return;
    }

    if (_cameraController != null) {
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      await _cameraController!.dispose();
      _cameraController = null;
    }

    // Default to the front-facing camera for selfies if available
    if (_cameraController == null) {
      for (int i = 0; i < widget.cameras.length; i++) {
        if (widget.cameras[i].lensDirection == CameraLensDirection.front) {
          _cameraIndex = i;
          break;
        }
      }
    }

    _cameraController = CameraController(
      widget.cameras[_cameraIndex],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
        _errorMessage = null;
      });

      // Start streaming camera frames for real-time predictions
      _cameraController!.startImageStream(_processCameraFrame);
    } catch (e) {
      debugPrint("Camera setup error: $e");
      setState(() {
        _errorMessage =
            "Could not initialize camera. Please grant camera permission.";
      });
    }
  }

  void _toggleCamera() async {
    if (widget.cameras.length < 2) return;

    // Throttle frames processing
    _isProcessing = true;

    if (_cameraController != null) {
      await _cameraController!.stopImageStream();
      await _cameraController!.dispose();
      _cameraController = null;
    }

    setState(() {
      _isCameraInitialized = false;
      _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;
    });

    _isProcessing = false;
    await _initCamera();
  }

  void _processCameraFrame(CameraImage image) async {
    if (!_isModelLoaded ||
        _isProcessing ||
        _interpreter == null ||
        _isUploadMode) {
      return;
    }
    _isProcessing = true;

    try {
      final originalImage = _convertCameraImage(image);
      if (originalImage == null) return;
      _runInference(originalImage);
    } catch (e) {
      debugPrint("Inference Error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  void _runInference(img_lib.Image originalImage) {
    final size = originalImage.width < originalImage.height
        ? originalImage.width
        : originalImage.height;
    final xOffset = (originalImage.width - size) ~/ 2;
    final yOffset = (originalImage.height - size) ~/ 2;
    final cropped = img_lib.copyCrop(
      originalImage,
      x: xOffset,
      y: yOffset,
      width: size,
      height: size,
    );
    final resized = img_lib.copyResize(cropped, width: 224, height: 224);

    final input = List.generate(
      1,
      (i) => List.generate(
        224,
        (y) => List.generate(224, (x) => List.generate(3, (c) => 0.0)),
      ),
    );

    for (var y = 0; y < 224; y++) {
      for (var x = 0; x < 224; x++) {
        final pixel = resized.getPixel(x, y);
        input[0][y][x][0] = pixel.r / 255.0;
        input[0][y][x][1] = pixel.g / 255.0;
        input[0][y][x][2] = pixel.b / 255.0;
      }
    }

    final output = List.generate(1, (i) => List.filled(10, 0.0));
    _interpreter!.run(input, output);

    final predictionsList = output[0];
    double maxConf = -1.0;
    int maxIdx = -1;
    final List<MapEntry<String, double>> matches = [];
    for (int i = 0; i < predictionsList.length; i++) {
      final conf = predictionsList[i];
      final name = i < _labels.length ? _labels[i] : "Class $i";
      matches.add(MapEntry(name, conf));

      if (conf > maxConf) {
        maxConf = conf;
        maxIdx = i;
      }
    }

    matches.sort((a, b) => b.value.compareTo(a.value));

    if (mounted) {
      setState(() {
        _topCelebrity = maxIdx < _labels.length ? _labels[maxIdx] : "Unknown";
        _topConfidence = maxConf;
        _allPredictions = matches;
      });
    }
  }

  Future<void> _selectImage() async {
    try {
      final pickedImage = await _imagePicker.pickImage(
        source: ImageSource.gallery,
      );
      if (pickedImage == null) return;

      final bytes = await pickedImage.readAsBytes();
      if (img_lib.decodeImage(bytes) == null) {
        throw const FormatException(
          "The selected file is not a supported image.",
        );
      }

      if (!mounted) return;
      setState(() {
        _selectedImageBytes = bytes;
        _uploadErrorMessage = null;
        _allPredictions = [];
        _topCelebrity = "Ready to scan";
        _topConfidence = 0.0;
      });
    } catch (e) {
      debugPrint("Photo selection error: $e");
      if (!mounted) return;
      setState(() {
        _uploadErrorMessage =
            "Could not open this photo. Please choose another image.";
      });
    }
  }

  Future<void> _scanSelectedImage() async {
    final bytes = _selectedImageBytes;
    if (bytes == null ||
        !_isModelLoaded ||
        _isProcessing ||
        _interpreter == null) {
      return;
    }

    setState(() {
      _isUploadProcessing = true;
      _uploadErrorMessage = null;
    });
    _isProcessing = true;

    try {
      await Future<void>.delayed(Duration.zero);
      final decodedImage = img_lib.decodeImage(bytes);
      if (decodedImage == null) {
        throw const FormatException(
          "The selected file is not a supported image.",
        );
      }
      _runInference(decodedImage);
    } catch (e) {
      debugPrint("Uploaded photo scan error: $e");
      if (mounted) {
        setState(() {
          _uploadErrorMessage =
              "Could not scan this photo. Please try another image.";
        });
      }
    } finally {
      _isProcessing = false;
      if (mounted) {
        setState(() {
          _isUploadProcessing = false;
        });
      }
    }
  }

  Future<void> _setUploadMode(bool uploadMode) async {
    if (_isUploadMode == uploadMode) return;

    if (uploadMode) {
      if (_cameraController?.value.isStreamingImages ?? false) {
        await _cameraController!.stopImageStream();
      }
      if (!mounted) return;
      setState(() {
        _isUploadMode = true;
        _errorMessage = null;
      });
      return;
    }

    setState(() {
      _isUploadMode = false;
      _uploadErrorMessage = null;
    });
    if (_cameraController?.value.isInitialized ?? false) {
      if (!(_cameraController?.value.isStreamingImages ?? false)) {
        await _cameraController!.startImageStream(_processCameraFrame);
      }
    } else {
      await _initCamera();
    }
  }

  // Camera image conversion helper
  img_lib.Image? _convertCameraImage(CameraImage cameraImage) {
    try {
      if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        return _convertYUV420ToImage(cameraImage);
      } else if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
        return _convertBGRA8888ToImage(cameraImage);
      }
    } catch (e) {
      debugPrint("Failed to convert image frame: $e");
    }
    return null;
  }

  // YUV420 to RGB
  img_lib.Image _convertYUV420ToImage(CameraImage cameraImage) {
    final width = cameraImage.width;
    final height = cameraImage.height;

    final uvRowStride = cameraImage.planes[1].bytesPerRow;
    final uvPixelStride = cameraImage.planes[1].bytesPerPixel ?? 1;

    final outImage = img_lib.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int uvIndex = uvRowStride * (y >> 1) + (x >> 1) * uvPixelStride;
        final int index = y * width + x;

        final yp = cameraImage.planes[0].bytes[index];
        final up = cameraImage.planes[1].bytes[uvIndex];
        final vp = cameraImage.planes[2].bytes[uvIndex];

        // Convert YUV to RGB
        int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
        int g = (yp - up * 4654 / 1024 + vp * -9360 / 1024 + 135).round().clamp(
          0,
          255,
        );
        int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

        outImage.setPixelRgb(x, y, r, g, b);
      }
    }
    return outImage;
  }

  // BGRA8888 to RGB
  img_lib.Image _convertBGRA8888ToImage(CameraImage cameraImage) {
    final bytes = cameraImage.planes[0].bytes;
    return img_lib.Image.fromBytes(
      width: cameraImage.width,
      height: cameraImage.height,
      bytes: bytes.buffer,
      order: img_lib.ChannelOrder.bgra,
    );
  }

  @override
  void dispose() {
    _scanningController.dispose();
    if (_cameraController != null) {
      _cameraController!.dispose();
    }
    if (_interpreter != null) {
      _interpreter!.close();
    }
    super.dispose();
  }

  Widget _buildModeButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF6D28D9) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? Colors.white : Colors.white60,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUploadWorkspace(double screenWidth) {
    final previewSize = screenWidth < 390 ? screenWidth * 0.52 : 220.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: previewSize,
            height: previewSize,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: _selectedImageBytes == null
                ? InkWell(
                    onTap: _selectImage,
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 48,
                          color: Color(0xFF8B5CF6),
                        ),
                        SizedBox(height: 12),
                        Text(
                          "Choose a photo to scan",
                          style: TextStyle(
                            color: Color(0xFFCBD5E1),
                            fontSize: 13,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          "Select an image from your device",
                          style: TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  )
                : Image.memory(_selectedImageBytes!, fit: BoxFit.contain),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isUploadProcessing ? null : _selectImage,
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: Text(
                    _selectedImageBytes == null
                        ? "Choose Photo"
                        : "Change Photo",
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFCBD5E1),
                    side: const BorderSide(color: Color(0xFF334155)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed:
                      _selectedImageBytes != null &&
                          _isModelLoaded &&
                          !_isUploadProcessing
                      ? _scanSelectedImage
                      : null,
                  icon: _isUploadProcessing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.search, size: 18),
                  label: Text(_isUploadProcessing ? "Scanning" : "Run Scan"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6D28D9),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFF334155),
                    disabledForegroundColor: Colors.white54,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          if (_uploadErrorMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _uploadErrorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0F172A), Color(0xFF090D16)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Column(
            children: [
              // Header title
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "CelebMatch AI",
                          style: GoogleFonts.outfit(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: Color(0xFF10B981),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _isUploadMode
                                  ? "Photo Upload Scanner"
                                  : "Real-time Neural Scanner",
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF94A3B8),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (!_isUploadMode && widget.cameras.length >= 2)
                      IconButton(
                        onPressed: _toggleCamera,
                        icon: const Icon(Icons.flip_camera_ios_outlined),
                        color: Colors.white70,
                        tooltip: "Switch Camera",
                      ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      _buildModeButton(
                        label: "Live Scan",
                        icon: Icons.camera_alt_outlined,
                        selected: !_isUploadMode,
                        onPressed: () => _setUploadMode(false),
                      ),
                      _buildModeButton(
                        label: "Upload Photo",
                        icon: Icons.upload_file,
                        selected: _isUploadMode,
                        onPressed: () => _setUploadMode(true),
                      ),
                    ],
                  ),
                ),
              ),

              // Error display or Viewfinder
              Expanded(
                flex: 9,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isUploadMode)
                      Expanded(
                        child: SingleChildScrollView(
                          child: _buildUploadWorkspace(screenWidth),
                        ),
                      )
                    else if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.red.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: Colors.red,
                                size: 48,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                "Hardware Error",
                                style: GoogleFonts.outfit(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: Colors.red.shade300,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _errorMessage!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFCBD5E1),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (!_isCameraInitialized)
                      const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFF8B5CF6),
                        ),
                      )
                    else
                      // Viewfinder Container
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final preferredSize = screenWidth * 0.72;
                            final availableHeight =
                                constraints.maxHeight.isFinite
                                ? constraints.maxHeight
                                : preferredSize;
                            final viewfinderSize =
                                preferredSize < availableHeight
                                ? preferredSize
                                : availableHeight;
                            final cameraSize = viewfinderSize * (0.70 / 0.72);

                            return Center(
                              child: SizedBox(
                                width: viewfinderSize,
                                height: viewfinderSize,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    // Shadow blur backdrop
                                    Container(
                                      width: viewfinderSize,
                                      height: viewfinderSize,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(
                                              0xFF8B5CF6,
                                            ).withValues(alpha: 0.15),
                                            blurRadius: 50,
                                            spreadRadius: 8,
                                          ),
                                        ],
                                      ),
                                    ),

                                    // Camera Preview
                                    Container(
                                      width: cameraSize,
                                      height: cameraSize,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: const Color(
                                            0xFF8B5CF6,
                                          ).withValues(alpha: 0.4),
                                          width: 3,
                                        ),
                                      ),
                                      child: ClipOval(
                                        child: AspectRatio(
                                          aspectRatio: 1.0,
                                          child: CameraPreview(
                                            _cameraController!,
                                          ),
                                        ),
                                      ),
                                    ),

                                    // Scanning Animation Line Overlay
                                    SizedBox(
                                      width: cameraSize,
                                      height: cameraSize,
                                      child: ClipOval(
                                        child: AnimatedBuilder(
                                          animation: _scanningController,
                                          builder: (context, child) {
                                            return Stack(
                                              children: [
                                                Positioned(
                                                  top:
                                                      _scanningController
                                                          .value *
                                                      (cameraSize - 4),
                                                  left: 0,
                                                  right: 0,
                                                  child: Container(
                                                    height: 4,
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                        0xFF8B5CF6,
                                                      ),
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color:
                                                              const Color(
                                                                0xFF8B5CF6,
                                                              ).withValues(
                                                                alpha: 0.8,
                                                              ),
                                                          blurRadius: 10,
                                                          spreadRadius: 2,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      ),
                                    ),

                                    // Scanning target grid overlay
                                    IgnorePointer(
                                      child: Container(
                                        width: cameraSize,
                                        height: cameraSize,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.transparent,
                                          border: Border.all(
                                            color: Colors.white12,
                                            width: 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),

              // Match Display Cards (Hero prediction)
              Expanded(
                flex: 11,
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: Color(0xFF131B2E),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(32),
                      topRight: Radius.circular(32),
                    ),
                    border: Border(
                      top: BorderSide(color: Colors.white12, width: 1),
                    ),
                  ),
                  child: Column(
                    children: [
                      // Top indicator line
                      Container(
                        margin: const EdgeInsets.only(top: 12, bottom: 8),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF334155),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),

                      // Hero Predict Match
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        child: Column(
                          children: [
                            const Text(
                              "CLOSEST MATCH",
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF8B5CF6),
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _topCelebrity,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.outfit(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "${(_topConfidence * 100).toStringAsFixed(1)}% Similarity",
                              style: GoogleFonts.outfit(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF6366F1),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const Divider(color: Colors.white10, height: 1),

                      // List of other predictions
                      Expanded(
                        child: _allPredictions.isEmpty
                            ? const Center(
                                child: Text(
                                  "Scanning frame...",
                                  style: TextStyle(color: Color(0xFF64748B)),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 16,
                                ),
                                itemCount: _allPredictions.length,
                                itemBuilder: (context, index) {
                                  final match = _allPredictions[index];
                                  final percentage = (match.value * 100)
                                      .toStringAsFixed(1);
                                  final isTop = index == 0;

                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              match.key,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: isTop
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                                color: isTop
                                                    ? const Color(0xFF8B5CF6)
                                                    : const Color(0xFFCBD5E1),
                                              ),
                                            ),
                                            Text(
                                              "$percentage%",
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: isTop
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                                color: isTop
                                                    ? const Color(0xFF8B5CF6)
                                                    : const Color(0xFF94A3B8),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 5),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          child: LinearProgressIndicator(
                                            value: match.value,
                                            minHeight: 6,
                                            backgroundColor: Colors.white
                                                .withValues(alpha: 0.04),
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  isTop
                                                      ? const Color(0xFF8B5CF6)
                                                      : Colors.indigo.shade400,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
