import 'package:permission_handler/permission_handler.dart';

class MediaPermissionService {
  Future<bool> ensureCameraAndMicrophone() async {
    final camera = await Permission.camera.request();
    final microphone = await Permission.microphone.request();
    return camera.isGranted && microphone.isGranted;
  }

  Future<bool> ensureMicrophone() async {
    final microphone = await Permission.microphone.request();
    return microphone.isGranted;
  }

  Future<bool> ensurePhotos() async {
    final photos = await Permission.photos.request();
    if (photos.isGranted || photos.isLimited) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }
}
