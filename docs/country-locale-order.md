# 国家/地区导航的语言排序

国家行、展开列表和索引统一按当前界面语言更新。国家 ID、筛选值和回调仍使用目录身份。

| 界面语言 | 排序与索引 |
| --- | --- |
| 简体中文 | 国名拼音及字母索引，秘鲁使用 bì lǔ |
| 繁体中文 | 笔画排序及首字笔画数索引 |
| English | 英文国名字母顺序 |
| Français | 法文国名本地化顺序，États-Unis 位于 E |
| Español | 西文国名本地化顺序及字母索引 |
| 日本語 | 已核实国名读音的五十音顺序及行索引，中国归入た行，日本归入な行 |
| 한국어 | 韩文国名排序及初声索引，미국 归入ㅁ |

七语言的固定国名词表由 ICU 生成同一份离线排序表，所有平台共用；输入为现有 CLDR 译名。日文汉字使用有限词表中的明确读音前缀，未将汉字按汉语拼音处理。繁体中文笔画数据来自 Unicode Unihan 17.0.0。新增国名或修改翻译后须重新生成词表，覆盖测试会检测漂移。

规范：https://unicode.org/reports/tr35/tr35-collation.html
生成：`python tools/catalog/generate_country_collation.py --unihan Unihan-17.0.0.zip`
出处、ICU 版本和输入哈希见 `tools/catalog/country_collation_provenance.json`；Unicode 许可随应用资源提供。

本次修正仅针对用户确认的国家/地区选择列表。
