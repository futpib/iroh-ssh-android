import 'package:dartssh2/dartssh2.dart';

Future<SSHClient> connectAuthenticatedSsh({
  required String host,
  required int port,
  required String username,
  required List<SSHIdentity> identities,
  required SSHPasswordRequestHandler onPasswordRequest,
  required SSHUserInfoRequestHandler onUserInfoRequest,
  SSHHostkeyVerifyHandler? onVerifyHostKey,
  SSHUserauthBannerHandler? onUserauthBanner,
  void Function(SSHClient)? onClientCreated,
}) async {
  for (var usePassword = false; ; usePassword = true) {
    final socket = await SSHSocket.connect(host, port);
    SSHClient? client;
    var interactivePrompted = false;
    try {
      client = SSHClient(
        socket,
        username: username,
        identities: identities,
        onVerifyHostKey: onVerifyHostKey,
        onPasswordRequest: usePassword ? onPasswordRequest : null,
        onUserInfoRequest: (request) {
          interactivePrompted = true;
          return onUserInfoRequest(request);
        },
        onUserauthBanner: onUserauthBanner,
      );
      onClientCreated?.call(client);
      await client.authenticated;
      return client;
    } on SSHAuthFailError {
      client?.close();
      if (client == null) socket.close();
      if (usePassword || interactivePrompted) rethrow;
      // dartssh2 asks for a password before learning the server's methods.
    } catch (_) {
      client?.close();
      if (client == null) socket.close();
      rethrow;
    }
  }
}
