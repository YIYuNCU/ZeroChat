import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum CountdownUnit { minutes, hours }

class CountdownIntervalResult {
  final int minMinutes;
  final int maxMinutes;

  const CountdownIntervalResult({
    required this.minMinutes,
    required this.maxMinutes,
  });
}

class CountdownIntervalDialog extends StatefulWidget {
  final int initialMinMinutes;
  final int initialMaxMinutes;

  const CountdownIntervalDialog({
    super.key,
    required this.initialMinMinutes,
    required this.initialMaxMinutes,
  });

  @override
  State<CountdownIntervalDialog> createState() =>
      _CountdownIntervalDialogState();
}

class _CountdownIntervalDialogState extends State<CountdownIntervalDialog> {
  static const int _minimumMinutes = 1;
  static const int _maximumMinutes = 24 * 60;
  static const int _hourStepMinutes = 6;

  late final TextEditingController _minController;
  late final TextEditingController _maxController;
  CountdownUnit _unit = CountdownUnit.hours;

  @override
  void initState() {
    super.initState();
    _minController = TextEditingController();
    _maxController = TextEditingController();
    _setControllerValues(widget.initialMinMinutes, widget.initialMaxMinutes);
  }

  @override
  void dispose() {
    _minController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  String _formatMinutes(int minutes) {
    if (_unit == CountdownUnit.minutes) {
      return '$minutes';
    }
    final value = minutes / 60;
    return value
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  void _setControllerValues(int minMinutes, int maxMinutes) {
    _minController.text = _formatMinutes(minMinutes);
    _maxController.text = _formatMinutes(maxMinutes);
  }

  int? _parseMinutes(String value) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || !parsed.isFinite) {
      return null;
    }
    if (_unit == CountdownUnit.minutes && parsed != parsed.roundToDouble()) {
      return null;
    }
    return _unit == CountdownUnit.minutes
        ? parsed.round()
        : (parsed * 60).round();
  }

  String? _fieldError(int? value) {
    if (value == null) {
      return '请输入有效数字';
    }
    if (value < _minimumMinutes || value > _maximumMinutes) {
      return _unit == CountdownUnit.minutes
          ? '范围为 1-1440 分钟'
          : '范围为 0.02-24 小时';
    }
    return null;
  }

  bool get _isValid {
    final minMinutes = _parseMinutes(_minController.text);
    final maxMinutes = _parseMinutes(_maxController.text);
    return _fieldError(minMinutes) == null &&
        _fieldError(maxMinutes) == null &&
        minMinutes! <= maxMinutes!;
  }

  void _changeUnit(CountdownUnit unit) {
    if (unit == _unit) return;
    final minMinutes = _parseMinutes(_minController.text);
    final maxMinutes = _parseMinutes(_maxController.text);
    if (minMinutes == null || maxMinutes == null) return;
    setState(() {
      _unit = unit;
      _setControllerValues(minMinutes, maxMinutes);
    });
  }

  void _step(TextEditingController controller, int direction) {
    final current = _parseMinutes(controller.text) ?? _minimumMinutes;
    final step = _unit == CountdownUnit.minutes ? 1 : _hourStepMinutes;
    final next = (current + step * direction).clamp(
      _minimumMinutes,
      _maximumMinutes,
    );
    setState(() {
      controller.text = _formatMinutes(next);
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
    });
  }

  Widget _buildNumberInput({
    required String label,
    required TextEditingController controller,
    required bool isMinimum,
  }) {
    final value = _parseMinutes(controller.text);
    final relationInvalid =
        _parseMinutes(_minController.text) != null &&
        _parseMinutes(_maxController.text) != null &&
        _parseMinutes(_minController.text)! >
            _parseMinutes(_maxController.text)!;
    final error =
        _fieldError(value) ??
        (relationInvalid ? (isMinimum ? '不能大于最大值' : '不能小于最小值') : null);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(label),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: InputDecoration(
              errorText: error,
              suffixText: _unit == CountdownUnit.minutes ? '分钟' : '小时',
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 40,
          height: 56,
          child: Column(
            children: [
              Expanded(
                child: IconButton(
                  key: ValueKey('${isMinimum ? 'min' : 'max'}-increment'),
                  tooltip: '增加$label',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.expand(),
                  icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                  onPressed: () => _step(controller, 1),
                ),
              ),
              Expanded(
                child: IconButton(
                  key: ValueKey('${isMinimum ? 'min' : 'max'}-decrement'),
                  tooltip: '减少$label',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.expand(),
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  onPressed: () => _step(controller, -1),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('倒计时区间'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<CountdownUnit>(
                segments: const [
                  ButtonSegment(
                    value: CountdownUnit.minutes,
                    label: Text('分钟'),
                  ),
                  ButtonSegment(value: CountdownUnit.hours, label: Text('小时')),
                ],
                selected: {_unit},
                onSelectionChanged: (selection) => _changeUnit(selection.first),
              ),
            ),
            const SizedBox(height: 20),
            _buildNumberInput(
              label: '最小值',
              controller: _minController,
              isMinimum: true,
            ),
            const SizedBox(height: 12),
            _buildNumberInput(
              label: '最大值',
              controller: _maxController,
              isMinimum: false,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _isValid
              ? () => Navigator.pop(
                  context,
                  CountdownIntervalResult(
                    minMinutes: _parseMinutes(_minController.text)!,
                    maxMinutes: _parseMinutes(_maxController.text)!,
                  ),
                )
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
