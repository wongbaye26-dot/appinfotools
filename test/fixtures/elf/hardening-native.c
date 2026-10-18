// 加固属性夹具的源码：故意触发栈保护（局部数组 + 用户输入），
// 这样 -fstack-protector 会真的导入 __stack_chk_fail。
#include <string.h>
#include <stdlib.h>

int exported_copy(const char *src) {
  char buf[32];
  strcpy(buf, src);          // 会触发 canary
  return (int)strlen(buf);
}

int exported_alloc(int n) {
  void *p = malloc((size_t)n);
  free(p);
  return p != 0;
}
