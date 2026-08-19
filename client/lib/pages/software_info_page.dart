import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SoftwareInfoPage extends StatefulWidget {
  const SoftwareInfoPage({super.key});

  @override
  State<SoftwareInfoPage> createState() => _SoftwareInfoPageState();
}

class _SoftwareInfoPageState extends State<SoftwareInfoPage> {
  static const _fallbackVersion = '1.6.2';
  static const _fallbackBuildNumber = '83';

  PackageInfo? _packageInfo;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _packageInfo = packageInfo);
    } catch (_) {
      // The fallback keeps version information available during plugin errors.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final packageInfo = _packageInfo;
    final appName = packageInfo?.appName.isNotEmpty == true
        ? packageInfo!.appName
        : 'ZeroChat';
    final version = packageInfo?.version.isNotEmpty == true
        ? packageInfo!.version
        : _fallbackVersion;
    final buildNumber = packageInfo?.buildNumber.isNotEmpty == true
        ? packageInfo!.buildNumber
        : _fallbackBuildNumber;

    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(title: const Text('软件信息')),
      body: ListView(
        children: [
          const SizedBox(height: 10),
          Container(
            color: Colors.white,
            child: Column(
              children: [
                _InfoRow(label: '应用名称', value: appName),
                const Divider(height: 1, indent: 16),
                _InfoRow(
                  label: '当前版本',
                  value: _loading ? '正在读取...' : '$version ($buildNumber)',
                ),
                const Divider(height: 1, indent: 16),
                _InfoRow(
                  label: '构建号',
                  value: _loading ? '正在读取...' : buildNumber,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 15, color: Color(0xFF888888)),
            ),
          ),
        ],
      ),
    );
  }
}
