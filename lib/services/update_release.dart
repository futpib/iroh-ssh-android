/// One verified GitHub release asset, selected for the installed build.
class UpdateRelease {
  const UpdateRelease({
    required this.tag,
    required this.assetName,
    required this.url,
    required this.digest,
    required this.size,
  });

  final String tag;
  final String assetName;
  final Uri url;
  final String digest;
  final int size;
  String get version => tag.replaceFirst(RegExp(r'^v'), '').split('+').first;
  int get baseCode => int.parse(tag.split('+').last);

  factory UpdateRelease.fromJson(Map<String, dynamic> json, String assetName) {
    final tag = json['tag_name'];
    if (json['draft'] != false ||
        json['prerelease'] != false ||
        tag is! String ||
        !RegExp(r'^v?\d+(?:\.\d+)*\+[1-9]\d*$').hasMatch(tag)) {
      throw const FormatException('Invalid stable release');
    }
    final assets = json['assets'];
    if (assets is! List) throw const FormatException('Missing release assets');
    final matches = assets
        .whereType<Map>()
        .where((a) => a['name'] == assetName)
        .toList();
    if (matches.length != 1) {
      throw const FormatException('No matching APK in this release');
    }
    final asset = matches.single;
    final size = asset['size'];
    final digest = asset['digest'];
    final url = Uri.tryParse(
      asset['browser_download_url'] is String
          ? asset['browser_download_url']
          : '',
    );
    if (size is! int ||
        size <= 0 ||
        size > 512 * 1024 * 1024 ||
        digest is! String ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest) ||
        url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        url.port != 443 ||
        url.pathSegments.join('/') !=
            'futpib/iroh-ssh-android/releases/download/$tag/$assetName') {
      throw const FormatException('Invalid APK download metadata');
    }
    return UpdateRelease(
      tag: tag,
      assetName: assetName,
      url: url,
      digest: digest.substring(7).toLowerCase(),
      size: size,
    );
  }

  Map<String, Object> get verification => {
    'version': version,
    'baseCode': baseCode,
    'assetName': assetName,
    'digest': digest,
    'size': size,
  };
}
