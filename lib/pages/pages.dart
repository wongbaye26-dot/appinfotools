enum Pages {
  home,
  info,
  setting,
}

abstract class PageBase {
  final Pages page;

  PageBase(this.page);
}
