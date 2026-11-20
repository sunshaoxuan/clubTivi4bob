# BobTV App Store 审核材料

此目录描述材料生成方式，不包含个人联系电话、账号密码、SMTP 凭据或苹果私钥。材料由 `tools/app_store/prepare_review_bundle.py` 生成到仓库外的私有输出目录。

生成物分为商店可公开文案、私有审核资料、许可附件、原始截图和提交阻塞清单。审核说明涵盖用户导入与同步、节目指南、字幕服务、可选账号、设备生物验证及当前网络边界。未启用或未经验证的功能不作为已通过项目。

运行：

```sh
python3 tools/app_store/prepare_review_bundle.py --output /absolute/private/output
```

使用带 Pillow、ReportLab 和 pypdf 的 Python。生成器不会上传 App Store Connect，不会发布网站、切换资源服务器、修改应用源码或读取账号密钥。

正式提交前运行：

```sh
python3 tools/app_store/validate_review_bundle.py /absolute/private/output --strict
```

严格模式在签名 Archive、最终源码冻结、审核账号、公网演示资源、支持页面、隐私清单或商店必填项尚未确认时返回失败。生成材料成功不代表可以直接提交。

## 个人身份

个人开发者不需要虚构公司。开发者及销售商名称以 Apple 核验的个人法定姓名为准。审核联系人与公开支持联系人分开处理；版权所有者字段也需要确认。应用可以保留 BobTV 品牌名称。

参考资料按生成当日核对，收录于材料的 `sources.json`。不在材料中保证审核通过或对开发者实际提供的全部内容作统一授权声明。
