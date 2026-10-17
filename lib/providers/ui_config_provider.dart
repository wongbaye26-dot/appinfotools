import 'package:apk_info_tool/config.dart';
import 'package:apk_info_tool/widgets/title_value_layout.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'ui_config_provider.freezed.dart';
part 'ui_config_provider.g.dart';

@freezed
abstract class UiConfig with _$UiConfig {
  const factory UiConfig({
    required int textMaxLines,
    required double titleWidth,
  }) = _UiConfig;
}

@riverpod
class UiConfigState extends _$UiConfigState {
  @override
  UiConfig build() {
    return UiConfig(
      textMaxLines: Config.maxLines.value,
      // 夹紧到可用区间：旧版本存下来的值可能小于 `kMinDetailTitleWidth`
      // （那时滑块下限是 40），不夹的话界面上会显示一个放不下中文标签的宽度。
      titleWidth: Config.titleWidth.value.clamp(
        kMinDetailTitleWidth,
        kMaxDetailTitleWidth,
      ),
    );
  }

  void updateTitleWidth(double value) {
    state = state.copyWith(titleWidth: value);
    Config.titleWidth.updateValue(value);
  }

  void updateTextMaxLines(int value) {
    state = state.copyWith(textMaxLines: value);
    Config.maxLines.updateValue(value);
  }
}
