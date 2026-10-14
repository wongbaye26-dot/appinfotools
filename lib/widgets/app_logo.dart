import 'package:flutter/material.dart';

/// 应用标识。
///
/// 用仓库里的应用图标，而不是 Material 的通用图标（`Icons.inventory_2`）——
/// 侧边栏顶部与概览页横幅是品牌露出最固定的位置，放通用图标等于放弃了它们。
///
/// 圆角比例 0.22 与图标自身的圆角一致，裁切后不会露出深色方角。
class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset(
        'assets/image/icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 资源缺失时退回通用图标，而不是在界面上留一个报错块。
        errorBuilder: (context, error, stackTrace) => SizedBox(
          width: size,
          height: size,
          child: Icon(Icons.inventory_2, size: size * 0.55),
        ),
      ),
    );
  }
}
