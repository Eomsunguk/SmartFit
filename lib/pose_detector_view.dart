import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'camera_view.dart';
import 'pose_painter.dart';
import 'exercise_summary_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:math' as math;
import 'package:flutter_tts/flutter_tts.dart'; // TTS 추가

class PoseDetectorView extends StatefulWidget {
  final String exerciseType;
  const PoseDetectorView({super.key, required this.exerciseType});

  @override
  State<PoseDetectorView> createState() => _PoseDetectorViewState();
}

class _PoseDetectorViewState extends State<PoseDetectorView> {
  final PoseDetector _poseDetector = PoseDetector(options: PoseDetectorOptions());
  final FlutterTts _flutterTts = FlutterTts(); // TTS 인스턴스
  bool _canProcess = true;
  bool _isBusy = false;
  CustomPaint? _customPaint;

  String _feedbackText = "운동 분석 중...";
  Color _feedbackColor = Colors.white;
  double _accuracy = 0.0;
  int _reps = 0;
  bool _isSquatting = false;
  int _frameCount = 0;
  DateTime? _lastVoiceTime;

  @override
  void dispose() {
    _canProcess = false;
    _poseDetector.close();
    _flutterTts.stop(); // TTS 종료
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          CameraView(
            customPaint: _customPaint,
            onImage: (inputImage) {
              _processImage(inputImage);
            },
          ),
          _buildOverlayUI(),
        ],
      ),
    );
  }

  Widget _buildOverlayUI() {
    return Column(
      children: [
        _buildStatusBar(),
        Spacer(),
        _buildFeedback(),
        _buildFinishButton(),
      ],
    );
  }

  Widget _buildStatusBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 30),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("정확도: \${(_accuracy * 100).round()}%", style: TextStyle(color: Colors.greenAccent, fontSize: 18)),
              Text("반복 횟수: \$_reps 회", style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFeedback() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Center(
        child: Text(
          _feedbackText,
          style: TextStyle(color: _feedbackColor, fontSize: 22, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildFinishButton() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: ElevatedButton(
        onPressed: () async {
          String exerciseName = widget.exerciseType;
          double accuracyPercent = _accuracy * 100;
          double calories = _reps * 0.5;

          try {
            await _saveExerciseRecord(
              exerciseName: exerciseName,
              count: _reps,
              accuracy: accuracyPercent,
              calories: calories,
            );
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("운동 저장 중 오류 발생: \$e")));
            }
            return;
          }

          if (!mounted) return;

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ExerciseSummaryScreen(
                exerciseName: exerciseName,
                accuracy: _accuracy,
                reps: _reps,
                calories: calories,
              ),
            ),
          );
        },
        child: Text("운동 완료"),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
          textStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Future<void> _processImage(InputImage inputImage) async {
    if (!_canProcess || _isBusy) return;
    _isBusy = true;

    _frameCount += 1;
    if (_frameCount <= 5) {
      _isBusy = false;
      return;
    }

    final poses = await _poseDetector.processImage(inputImage);
    final size = inputImage.metadata?.size;
    final rotation = inputImage.metadata?.rotation;

    if (size != null && rotation != null) {
      final painter = PosePainter(poses, size, rotation);
      _customPaint = CustomPaint(painter: painter);
      _analyzePose(poses);
    } else {
      _customPaint = null;
    }

    _isBusy = false;
    if (mounted) {
      setState(() {});
    }
  }

  void _speak(String message) async {
    final now = DateTime.now();
    if (_lastVoiceTime == null || now.difference(_lastVoiceTime!).inSeconds > 3) {
      _lastVoiceTime = now;
      await _flutterTts.setLanguage("ko-KR");
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.speak(message);
    }
  }

  void _analyzePose(List<Pose> poses) {
    if (poses.isEmpty) {
      _feedbackText = "운동 감지 실패!";
      _feedbackColor = Colors.red;
      _accuracy = 0.0;
      return;
    }

    Pose pose = poses.first;
    _accuracy = _calculatePoseAccuracy([pose]);

    switch (widget.exerciseType) {
      case 'squat':
        _analyzeSquatPose(pose);
        break;
      case 'pushup':
        _analyzePushupPose(pose);
        break;
      case 'lunge':
        _analyzeLungePose(pose);
        break;
      default:
        _feedbackText = "지원하지 않는 운동입니다.";
    }
  }

  void _analyzeSquatPose(Pose pose) {
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip]?.y;
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip]?.y;
    final leftKnee = pose.landmarks[PoseLandmarkType.leftKnee]?.y;
    final rightKnee = pose.landmarks[PoseLandmarkType.rightKnee]?.y;

    if ([leftHip, rightHip, leftKnee, rightKnee].contains(null)) return;

    final avgHipY = (leftHip! + rightHip!) / 2;
    final avgKneeY = (leftKnee! + rightKnee!) / 2;
    final diff = avgHipY - avgKneeY;

    const downThreshold = -20.0;
    const upThreshold = -5.0;

    if (!_isSquatting && diff < downThreshold) {
      _isSquatting = true;
      _feedbackText = "⬇️ 앉는 중...";
      _feedbackColor = Colors.orange;
      _speak("자세가 잘못되었습니다");
    } else if (_isSquatting && diff > upThreshold) {
      _isSquatting = false;
      _reps += 1;
      _feedbackText = "⬆️ 좋아요! \$_reps 회 완료";
      _feedbackColor = Colors.greenAccent;
      _speak("잘하셨습니다");
      setState(() {});
    }
  }

  void _analyzePushupPose(Pose pose) {
    double? leftShoulderY = pose.landmarks[PoseLandmarkType.leftShoulder]?.y;
    double? rightShoulderY = pose.landmarks[PoseLandmarkType.rightShoulder]?.y;
    double? leftElbowY = pose.landmarks[PoseLandmarkType.leftElbow]?.y;
    double? rightElbowY = pose.landmarks[PoseLandmarkType.rightElbow]?.y;

    if ([leftShoulderY, rightShoulderY, leftElbowY, rightElbowY].contains(null)) return;

    double avgShoulderY = (leftShoulderY! + rightShoulderY!) / 2;
    double avgElbowY = (leftElbowY! + rightElbowY!) / 2;
    double diff = avgElbowY - avgShoulderY;

    const downThreshold = 20.0;
    const upThreshold = 10.0;

    if (!_isSquatting && diff > downThreshold) {
      _isSquatting = true;
      _feedbackText = "⬇️ 내려가는 중...";
      _feedbackColor = Colors.orange;
      _speak("자세가 잘못되었습니다");
    } else if (_isSquatting && diff < upThreshold) {
      _isSquatting = false;
      _reps += 1;
      _feedbackText = "⬆️ 좋아요! \$_reps 회 완료";
      _feedbackColor = Colors.greenAccent;
      _speak("잘하셨습니다");
      setState(() {});
    }
  }

  void _analyzeLungePose(Pose pose) {
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final leftKnee = pose.landmarks[PoseLandmarkType.leftKnee];
    final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];
    final rightKnee = pose.landmarks[PoseLandmarkType.rightKnee];
    final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];

    bool canUseLeft = leftHip != null && leftKnee != null && leftAnkle != null;
    bool canUseRight = rightHip != null && rightKnee != null && rightAnkle != null;
    if (!canUseLeft && !canUseRight) return;

    double angle;
    if (canUseLeft && canUseRight) {
      double leftAngle = _calculateAngle(leftHip!, leftKnee!, leftAnkle!);
      double rightAngle = _calculateAngle(rightHip!, rightKnee!, rightAnkle!);
      angle = math.min(leftAngle, rightAngle);
    } else if (canUseLeft) {
      angle = _calculateAngle(leftHip!, leftKnee!, leftAnkle!);
    } else {
      angle = _calculateAngle(rightHip!, rightKnee!, rightAnkle!);
    }

    const downThreshold = 100.0;
    const upThreshold = 150.0;

    if (!_isSquatting && angle < downThreshold) {
      _isSquatting = true;
      _feedbackText = "⬇️ 자세 유지 중...";
      _feedbackColor = Colors.orange;
      _speak("자세가 잘못되었습니다");
    } else if (_isSquatting && angle > upThreshold) {
      _isSquatting = false;
      _reps += 1;
      _feedbackText = "⬆️ 좋아요! \$_reps 회 완료";
      _feedbackColor = Colors.greenAccent;
      _speak("잘하셨습니다");
    }
    setState(() {});
  }

  double _calculateAngle(PoseLandmark a, PoseLandmark b, PoseLandmark c) {
    final ab = Offset(a.x - b.x, a.y - b.y);
    final cb = Offset(c.x - b.x, c.y - b.y);
    final dotProduct = ab.dx * cb.dx + ab.dy * cb.dy;
    final magnitude = ab.distance * cb.distance;
    final angleRad = math.acos(dotProduct / magnitude);
    return angleRad * 180 / math.pi;
  }

  double _calculatePoseAccuracy(List<Pose> poses) {
    int totalLandmarks = 33;
    int detectedLandmarks = poses.first.landmarks.length;
    return detectedLandmarks / totalLandmarks;
  }

  Future<void> _saveExerciseRecord({
    required String exerciseName,
    required int count,
    required double accuracy,
    required double calories,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    final dayEnd = dayStart.add(Duration(days: 1));
    final timeStr = DateFormat('HH:mm').format(now);
    final dayOfWeek = DateFormat('EEEE', 'ko_KR').format(now);

    final collection = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('exerciseRecords');

    final snapshot = await collection
        .where('exerciseName', isEqualTo: exerciseName)
        .where('date', isGreaterThanOrEqualTo: dayStart)
        .where('date', isLessThan: dayEnd)
        .get();

    if (snapshot.docs.isNotEmpty) {
      final doc = snapshot.docs.first;
      final data = doc.data();
      final updatedCount = (data['count'] ?? 0) + count;
      final updatedCalories = (data['calories'] ?? 0.0) + calories;
      final updatedAccuracy = ((data['accuracy'] ?? 0.0) + accuracy) / 2;

      await doc.reference.update({
        'count': updatedCount,
        'calories': updatedCalories,
        'accuracy': updatedAccuracy,
        'timeStr': timeStr,
        'date': now,
      });
    } else {
      await collection.add({
        'exerciseName': exerciseName,
        'count': count,
        'accuracy': accuracy,
        'calories': calories,
        'dayOfWeek': dayOfWeek,
        'date': now,
        'timeStr': timeStr,
        'timestamp': FieldValue.serverTimestamp(),
      });
    }
  }
}
