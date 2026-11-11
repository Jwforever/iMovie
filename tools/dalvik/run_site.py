#!/usr/bin/env python3
"""按 OK影视 的调用顺序跑一个采集器：init(context, ext) → home/category/detail/player。

    python run_site.py inner.dex Auete home
    python run_site.py inner.dex Auete category 电影 1
"""
import json
import os
import sys
import time

from dvm import VM, JObject, JArray, JThrow, ClassInfo, describe


def make_context():
    return JObject(ClassInfo('Landroid/content/Context;'))


def run(dex_path, short_name, action, *argv):
    vm = VM(dex_path)
    vm.trace = os.environ.get('DVM_TRACE') == '1'
    cname = 'Lcom/github/catvod/spider/%s;' % short_name
    if not vm.cls(cname):
        print('没有这个类:', short_name)
        return 1
    spider = JObject(vm.cls(cname))
    ctor = vm.find_method(cname, '<init>', [])
    vm.invoke(ctor, [], spider)

    init = vm.find_method(cname, 'init', ['Landroid/content/Context;', 'Ljava/lang/String;'])
    if init:
        try:
            vm.invoke(init, [make_context(), ''], spider)
        except JThrow as exc:
            print('init 失败:', describe(exc.obj))

    if action == 'home':
        m = vm.find_method(cname, 'homeContent', ['Z'])
        args = [1]
    elif action == 'category':
        m = vm.find_method(cname, 'categoryContent',
                           ['Ljava/lang/String;', 'Ljava/lang/String;', 'Z', 'Ljava/util/HashMap;'])
        args = [argv[0] if argv else '', argv[1] if len(argv) > 1 else '1', 1,
                JObject(ClassInfo('Ljava/util/HashMap;'))]
    elif action == 'detail':
        m = vm.find_method(cname, 'detailContent', ['Ljava/util/List;'])
        args = [JArray('[Ljava/lang/String;', list(argv))]
    elif action == 'search':
        m = vm.find_method(cname, 'searchContent',
                           ['Ljava/lang/String;', 'Z'])
        args = [argv[0] if argv else '', 0]
    else:
        m = None
        args = []
    if not m:
        print('没有方法:', action)
        return 2

    t0 = time.time()
    try:
        out = vm.invoke(m, args, spider)
    except JThrow as exc:
        print('异常:', describe(exc.obj))
        for url, code in vm.http_log[-5:]:
            print('   http', code, url[:110])
        return 3
    except Exception as exc:
        print('解释器报错:', type(exc).__name__, exc)
        print('调用栈尾部:', ' <- '.join(vm.stack[-12:]))
        seen = {}
        for name in vm.stack:
            seen[name] = seen.get(name, 0) + 1
        top = sorted(seen.items(), key=lambda kv: -kv[1])[:6]
        print('重复最多:', top)
        print('热点:', sorted(vm.per_method.items(), key=lambda kv: -kv[1])[:10])
        import traceback
        traceback.print_exc()
        for url, code in vm.http_log[-5:]:
            print('   http', code, url[:110])
        return 4
    print('耗时 %.2fs  调用 %d 次  指令 %d 步' % (time.time() - t0, vm.calls, vm.steps))
    top = sorted(vm.per_method.items(), key=lambda kv: -kv[1])[:10]
    print('热点:', top)
    for url, code in vm.http_log[-8:]:
        print('   http', code, url[:120])
    if isinstance(out, str):
        print(out[:3000])
    else:
        print(out)
    return 0


def _main():
    path = sys.argv[1]
    name = sys.argv[2]
    act = sys.argv[3] if len(sys.argv) > 3 else 'home'
    return run(path, name, act, *sys.argv[4:])


if __name__ == '__main__':
    import threading
    sys.setrecursionlimit(30000)
    threading.stack_size(64 * 1024 * 1024)
    box = {}
    t = threading.Thread(target=lambda: box.setdefault('code', _main()))
    t.start()
    t.join()
    sys.exit(box.get('code', 1))
