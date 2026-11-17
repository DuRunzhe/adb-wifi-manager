#!/usr/bin/env python3
"""校验 menubar/i18n.swift 三张文案表的一致性。

检查项（任一不通过即以非 0 退出）：
  1. zhHans / zhHant / en 的键集合完全一致（无缺失、无多余）
  2. 每个 key 的占位符（%@ / %d / %%）数量在三种语言里一致
  3. menubar/main.swift 里 L.t("...") / L.has("...") 引用的 key 全部存在

规则来源见 AGENTS.md「发布前强制检查：多语言 + 无障碍」。
注意：正则无法正确处理 Swift 的多行字符串与转义引号，这里用手写词法扫描。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
I18N = os.path.join(ROOT, "menubar", "i18n.swift")
MAIN = os.path.join(ROOT, "menubar", "main.swift")
LANGS = ("zhHans", "zhHant", "en")


def parse_table(src, lang):
    """把 `private static let <lang>: [String: String] = [ ... ]` 解析成字典。"""
    m = re.search(r"private static let %s: \[String: String\] = \[(.*?)\n    \]" % lang, src, re.S)
    if not m:
        raise SystemExit("找不到语言表: %s" % lang)
    body = m.group(1)
    out, i = {}, 0
    while True:
        j = body.find('"', i)
        if j < 0:
            break
        # key
        k = j + 1
        key = []
        while body[k] != '"':
            if body[k] == "\\":
                key.append(body[k:k + 2])
                k += 2
                continue
            key.append(body[k])
            k += 1
        key = "".join(key)
        # value：普通字符串或 """ 多行字符串
        v = body.find(":", k) + 1
        while body[v] in " \t\n":
            v += 1
        if body.startswith('"""', v):
            end = body.find('"""', v + 3)
            out[key] = body[v + 3:end]
            i = end + 3
        else:
            v += 1
            val = []
            while body[v] != '"':
                if body[v] == "\\":
                    val.append(body[v:v + 2])
                    v += 2
                    continue
                val.append(body[v])
                v += 1
            out[key] = "".join(val)
            i = v + 1
    return out


def placeholders(text):
    return sorted(re.findall(r"%(?:@|d|%)", text))


def main():
    src = open(I18N, encoding="utf-8").read()
    tables = {lang: parse_table(src, lang) for lang in LANGS}
    base = tables["zhHans"]
    failed = False

    for lang, table in tables.items():
        diff = set(base) ^ set(table)
        if diff:
            print("✗ 键集合不一致 %s: %s" % (lang, sorted(diff)))
            failed = True

    for key in base:
        forms = {lang: tuple(placeholders(t.get(key, ""))) for lang, t in tables.items()}
        if len(set(forms.values())) != 1:
            print("✗ 占位符不一致 %s: %s" % (key, forms))
            failed = True

    code = open(MAIN, encoding="utf-8").read()
    used = set(re.findall(r'L\.t\("([a-zA-Z][\w.]*)"', code))
    used |= set(re.findall(r'L\.has\("([a-zA-Z][\w.]*)"', code))
    missing = sorted(k for k in used if k not in base)
    if missing:
        print("✗ main.swift 引用了不存在的 key: %s" % missing)
        failed = True

    if failed:
        return 1
    print("✓ i18n OK: %d keys × %d 语言" % (len(base), len(tables)))
    print("  注意：长文案截断、VoiceOver 属性等仍需人工/渲染确认（见 AGENTS.md）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
