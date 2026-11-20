class AppConstants {
  static const String appName = 'PayNux Agent';
  static const String version = '1.1.0';
  static const String packageName = 'com.pocketdev.paynuxagent';

  /// Matches ANSI escape sequences (e.g. color codes in terminal output).
  static final ansiEscape = RegExp(r'\x1b\[[0-9;]*[a-zA-Z]');

  static const String authorName = 'PaijoAhmad';
  static const String authorEmail = 'paijo.ahmad@jabber.ru';
  static const String githubUrl = 'https://github.com/pay/PayNux-Agent.git';
  static const String license = 'MIT';

  static const String githubApiLatestRelease =
      'https://api.github.com/repos/pay/PayNux-Agent/releases/latest';

  static const String orgName = 'PayNux';
  static const String orgEmail = 'paijo.ahmad@jabber.ru';

  static const String gatewayHost = '127.0.0.1';
  static const int gatewayPort = 18789;
  static const String gatewayUrl = 'http://$gatewayHost:$gatewayPort';

  static const String ubuntuRootfsUrl =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-';
  static const String rootfsArm64 = '${ubuntuRootfsUrl}arm64.tar.gz';
  static const String rootfsArmhf = '${ubuntuRootfsUrl}armhf.tar.gz';
  static const String rootfsAmd64 = '${ubuntuRootfsUrl}amd64.tar.gz';

  static const int healthCheckIntervalMs = 5000;
  static const int maxAutoRestarts = 5;

  static const String channelName = 'com.pocketdev.paynuxagent/native';
  static const String eventChannelName =
      'com.pocketdev.paynuxagent/gateway_logs';
  static const String terminalControlEventChannelName =
      'com.pocketdev.paynuxagent/terminal_control';

  static String getRootfsUrl(String arch) {
    switch (arch) {
      case 'aarch64':
        return rootfsArm64;
      case 'arm':
        return rootfsArmhf;
      case 'x86_64':
        return rootfsAmd64;
      default:
        return rootfsArm64;
    }
  }
}
