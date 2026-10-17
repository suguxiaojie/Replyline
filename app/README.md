# Replyline app

本目录为基于 Tendedero v1.5.0（`cf87e6ebc275d4f2cc42900e55f88a52d3ce9e46`）修改的 Swift 应用源码。

完整说明见 [项目 README](../README.md)，规范见 [AGENTS.md](../AGENTS.md)，状态见 [ROADMAP.md](../ROADMAP.md)。

```sh
swift test
swift scripts/check-strings.swift
scripts/build-app.sh
# 从菜单正常退出 Replyline 后安装。
scripts/install-app.sh
open /Applications/Replyline.app
```

当前本地版本为 0.3.10（27），构建产物为 `build/Replyline.app`，日常安装位置固定为 `/Applications/Replyline.app`。应用支持 macOS 14 及以上的 Apple silicon 和 Intel，使用已批准的 Apple Development 证书签名；本地 `.signing-identity` 由 Git 忽略，证书不可用时构建失败。安装时校验新版满足已安装版本的代码身份要求。签名配置与授权更新验证见项目 README。

晾衣架最小交互几何及原生话术内容位于 `CardPresentation.swift`，拖动交接由 `LinePanel.swift` 的 AppKit 结束回调与 `PeggedView.swift` 的动画完成回调驱动。素材管理、编辑和预览的共享界面角色位于 `SettingsTheme.swift`、`LibraryInterface.swift`，列表／网格位于 `LibraryBrowser.swift`，锚点缩放位于 `PreviewImage.swift`。参考动效的 MIT 声明位于 `ThirdPartyNotices/`，构建时复制到应用资源；未引入第三方运行时。

release 构建完成后运行 `scripts/package-dmg.sh`，生成 DMG 与 SHA-256 文件；镜像沿用应用的已批准证书，不覆盖已有同版本安装包，输出位于 `build/`。本机证书配置不随源码发布，安装包签名不代表已完成 Apple 公证。

上游设计与代码来自 [alejandrobujan/tendedero](https://github.com/alejandrobujan/tendedero)，保留 [MIT 版权声明与品牌限制](LICENSE)。应用包使用 Replyline 名称与原创图标。`docs/` 中保留的是上游资料，不能视为本修改版的使用说明或可重新分发的品牌资产。
