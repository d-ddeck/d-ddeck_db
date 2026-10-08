import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Runs in an isolate. Preserve animations and unsupported formats unchanged.
Uint8List? resizeUploadImage(String path) {
  final source = File(path);
  if (source.lengthSync() > 25 * 1024 * 1024) return null;
  final bytes = source.readAsBytesSync();
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.numFrames > 1 ||
      info.width * info.height > 40000000) {
    return null;
  }
  final decoded = decoder!.decode(bytes);
  if (decoded == null) return null;
  final oriented = img.bakeOrientation(decoded);
  if (oriented.width <= 1600 && oriented.height <= 1600) return null;
  // 기본값(nearest)은 크게 줄일 때 경계가 계단처럼 깨진다. 주변 화소 평균으로 줄인다.
  final resized = img.copyResize(
    oriented,
    width: oriented.width >= oriented.height ? 1600 : null,
    height: oriented.height > oriented.width ? 1600 : null,
    interpolation: img.Interpolation.average,
  );
  return Uint8List.fromList(img.encodeJpg(resized, quality: 90));
}
