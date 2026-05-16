你是资深 Swift / macOS / iOS DevOps 工程师。

请从 0 实现一个项目：

DriftBuild

目标：

实现一个局域网 iOS 远程构建系统。

开发机不需要安装 Xcode，通过 CLI 自动发现局域网内 Mac 构建机，配对认证后提交 Git 仓库构建任务，实时查看日志，并下载构建结果。

⸻

一、核心架构

系统包含两个部分：

1. drift-server（运行在 Mac 构建机）

职责：

* 发布局域网服务
* 接收构建请求
* Git 拉取代码
* pod install
* xcodebuild
* 生成日志与 artifact
* 管理客户端认证

要求：

* macOS
* 已安装 Xcode

⸻

2. drift CLI（运行在开发机）

职责：

* 自动发现 server
* 配对认证
* 提交构建
* 查看日志
* 下载 artifact

要求：

* 不依赖 Xcode
* 尽量只依赖 Swift toolchain / Command Line Tools

⸻

二、技术栈

整个项目必须使用 Swift 实现。

要求：

* Swift Package
* 两个 executable target：
    * drift
    * drift-server

推荐技术：

* Vapor
* ArgumentParser
* Network.framework
* Foundation
* Swift Concurrency

不要使用：

* Python
* Node.js
* Ruby 实现主逻辑
* Docker 作为运行前提

⸻

三、核心功能

drift discover

自动发现局域网内 drift-server。

优先使用：

* Bonjour / mDNS

如果不可用：

* UDP Broadcast fallback

⸻

drift pair

首次配对认证。

流程：

1. discover server
2. 用户选择 server
3. 请求 pairing code
4. server 管理员批准
5. client 保存 token

要求：

* Bearer Token
* pairing code 5 分钟过期
* server 只保存 token hash
* token 存储到：
    ~/.driftbuild/config.json

⸻

drift submit

通过 Git 仓库提交构建任务。

示例：

drift submit 
–repo git@gitlab.xxx.com:ios/YourApp.git 
–branch feature/test 
–commit abc123 
–scheme YourScheme 
–wait 
–download

功能：

* 创建 job
* 轮询状态
* 实时日志
* 下载 result.zip
* 打印 summary

⸻

drift logs

支持实时日志：

drift logs –job-id xxx –follow

⸻

drift artifact

下载 artifact。

⸻

drift cancel

取消构建任务。

⸻

四、构建逻辑

Server 通过 Git 拉代码。

要求：

* clone / fetch
* checkout branch
* reset commit
* submodule update

支持：

* CocoaPods
* Swift Package Manager

⸻

五、xcodebuild

仅支持：

* Debug
* iOS Simulator
* Swift / Objective-C

使用：

xcodebuild clean build

要求：

* CODE_SIGNING_ALLOWED=NO
* 不 archive
* 不导出 IPA

⸻

六、构建结果

每个 job 输出：

* build.log
* summary.txt
* errors.txt
* warnings.txt
* meta.json
* result.zip
* Build.xcresult（可选）

要求：

* 实时写日志
* 支持 offset 增量读取
* 即使失败也生成 result.zip

⸻

七、并发与队列

要求：

* FIFO
* 同 repo 串行
* 默认并发 1
* 支持后续扩展多节点

⸻

八、HTTP API

实现：

* health
* auth
* builds
* logs
* artifact
* cancel

使用：

* JSON
* Bearer Token

⸻

九、安全要求

要求：

* 只面向可信局域网
* token 不写日志
* subprocess 不使用 shell
* repo URL 做合法性校验
* revoke 后 token 立即失效

⸻

十、GitHub Release

提供 GitHub Actions：

目标：

* 自动构建 drift
* 自动构建 drift-server
* 发布 GitHub Release
* 生成 macOS arm64 二进制压缩包

安装方式示例：

curl -L https://github.com/{owner}/DriftBuild/releases/latest/download/driftbuild-macos-arm64.tar.gz -o driftbuild.tar.gz

⸻

十一、README

README 必须包含：

* 架构说明
* 安装
* discover
* pair
* submit
* logs
* artifact
* 常见问题
* 安全说明

⸻

十二、自检

实现完成后请自检：

* drift discover 是否可用
* drift pair 是否可用
* 未认证是否不能 submit
* token 是否只保存 hash
* submit 是否能创建 job
* build.log 是否实时写入
* timeout 是否终止子进程
* 构建失败是否仍生成 result.zip
* CLI 是否不依赖完整 Xcode
* GitHub Actions 是否能生成 release
* 是否避免 shell 注入风险

请输出：

1. 完整项目代码
2. Package.swift
3. README.md
4. GitHub Actions workflow
5. 安装说明
6. 使用示例
7. 自检结果