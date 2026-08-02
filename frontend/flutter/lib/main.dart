import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img_lib;
import 'package:google_fonts/google_fonts.dart';

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
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0B0F19),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

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

class _CelebMatchHomeState extends State<CelebMatchHome> with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isModelLoaded = false;
  bool _isProcessing = false;
  bool _isCameraInitialized = false;
  int _cameraIndex = 0;

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
      _interpreter = await Interpreter.fromAsset('assets/cnn_celeb.tflite', options: options);
      
      // Load Labels file
      final labelData = await rootBundle.loadString('assets/cnn_label_index.txt');
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

      _initCamera();
    } catch (e) {
      debugPrint("Initialization error: $e");
      setState(() {
        _errorMessage = "Failed to load AI Model or Labels. Please check your asset configuration.";
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
        _errorMessage = "Could not initialize camera. Please grant camera permission.";
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
    if (!_isModelLoaded || _isProcessing || _interpreter == null) return;
    _isProcessing = true;

    try {
      // 1. Convert frame format to image library representation
      img_lib.Image? originalImage = _convertCameraImage(image);
      if (originalImage == null) return;

      // 2. Crop to central square matching viewfinder
      int size = originalImage.width < originalImage.height ? originalImage.width : originalImage.height;
      int xOffset = (originalImage.width - size) ~/ 2;
      int yOffset = (originalImage.height - size) ~/ 2;
      
      img_lib.Image cropped = img_lib.copyCrop(
        originalImage,
        x: xOffset,
        y: yOffset,
        width: size,
        height: size,
      );
      
      // 3. Resize to 224x224 (required by CNN model input)
      img_lib.Image resized = img_lib.copyResize(
        cropped,
        width: 224,
        height: 224,
      );

      // 4. Transform to 4D tensor input: [1, 224, 224, 3] with values scaled [0, 1]
      var input = List.generate(
        1,
        (i) => List.generate(
          224,
          (y) => List.generate(
            224,
            (x) => List.generate(3, (c) => 0.0),
          ),
        ),
      );

      for (var y = 0; y < 224; y++) {
        for (var x = 0; x < 224; x++) {
          var pixel = resized.getPixel(x, y);
          input[0][y][x][0] = pixel.r / 255.0;
          input[0][y][x][1] = pixel.g / 255.0;
          input[0][y][x][2] = pixel.b / 255.0;
        }
      }

      // 5. Prepare output shape: [1, 10]
      var output = List.generate(1, (i) => List.filled(10, 0.0));

      // 6. Run model prediction
      _interpreter!.run(input, output);

      // 7. Extract predictions
      final List<double> predictionsList = output[0];
      
      double maxConf = -1.0;
      int maxIdx = -1;
      
      final List<MapEntry<String, double>> matches = [];
      for (int i = 0; i < predictionsList.length; i++) {
        final double conf = predictionsList[i];
        final String name = i < _labels.length ? _labels[i] : "Class $i";
        matches.add(MapEntry(name, conf));

        if (conf > maxConf) {
          maxConf = conf;
          maxIdx = i;
        }
      }

      // Sort matches descending by confidence
      matches.sort((a, b) => b.value.compareTo(a.value));

      if (mounted) {
        setState(() {
          _topCelebrity = maxIdx < _labels.length ? _labels[maxIdx] : "Unknown";
          _topConfidence = maxConf;
          _allPredictions = matches;
        });
      }
    } catch (e) {
      debugPrint("Inference Error: $e");
    } finally {
      // Re-enable frame processing
      _isProcessing = false;
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
        int g = (yp - up * 4654 / 1024 + vp * -9360 / 1024 + 135).round().clamp(0, 255);
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
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                              "Real-time Neural Scanner",
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
                    if (widget.cameras.length >= 2)
                      IconButton(
                        onPressed: _toggleCamera,
                        icon: const Icon(Icons.flip_camera_ios_outlined),
                        color: Colors.white70,
                        tooltip: "Switch Camera",
                      ),
                  ],
                ),
              ),

              // Error display or Viewfinder
              Expanded(
                flex: 9,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline, color: Colors.red, size: 48),
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
                        child: CircularProgressIndicator(color: Color(0xFF8B5CF6)),
                      )
                    else
                      // Viewfinder Container
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          // Shadow blur backdrop
                          Container(
                            width: screenWidth * 0.72,
                            height: screenWidth * 0.72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                                  blurRadius: 50,
                                  spreadRadius: 8,
                                )
                              ],
                            ),
                          ),

                          // Camera Preview
                          Container(
                            width: screenWidth * 0.70,
                            height: screenWidth * 0.70,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF8B5CF6).withValues(alpha: 0.4),
                                width: 3,
                              ),
                            ),
                            child: ClipOval(
                              child: AspectRatio(
                                aspectRatio: 1.0,
                                child: CameraPreview(_cameraController!),
                              ),
                            ),
                          ),

                          // Scanning Animation Line Overlay
                          SizedBox(
                            width: screenWidth * 0.70,
                            height: screenWidth * 0.70,
                            child: ClipOval(
                              child: AnimatedBuilder(
                                animation: _scanningController,
                                builder: (context, child) {
                                  return Stack(
                                    children: [
                                      Positioned(
                                        top: _scanningController.value * (screenWidth * 0.70 - 4),
                                        left: 0,
                                        right: 0,
                                        child: Container(
                                          height: 4,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF8B5CF6),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFF8B5CF6).withValues(alpha: 0.8),
                                                blurRadius: 10,
                                                spreadRadius: 2,
                                              )
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
                              width: screenWidth * 0.70,
                              height: screenWidth * 0.70,
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
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                                itemCount: _allPredictions.length,
                                itemBuilder: (context, index) {
                                  final match = _allPredictions[index];
                                  final percentage = (match.value * 100).toStringAsFixed(1);
                                  final isTop = index == 0;

                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              match.key,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: isTop ? FontWeight.bold : FontWeight.normal,
                                                color: isTop ? const Color(0xFF8B5CF6) : const Color(0xFFCBD5E1),
                                              ),
                                            ),
                                            Text(
                                              "$percentage%",
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: isTop ? FontWeight.bold : FontWeight.normal,
                                                color: isTop ? const Color(0xFF8B5CF6) : const Color(0xFF94A3B8),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 5),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(4),
                                          child: LinearProgressIndicator(
                                            value: match.value,
                                            minHeight: 6,
                                            backgroundColor: Colors.white.withValues(alpha: 0.04),
                                            valueColor: AlwaysStoppedAnimation<Color>(
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
              )
            ],
          ),
        ),
      ),
    );
  }
}
