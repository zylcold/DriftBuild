你是资深 Swift / macOS / iOS DevOps / CI/CD / 构建系统工程师。

请从 0 实现一个完整项目：

项目名：DriftBuild

一句话目标：
用 Swift 实现一个局域网 iOS 远程构建系统。开发机不需要安装 Xcode，通过 CLI 自动发现局域网内 Mac 构建机，配对认证后提交 Git 仓库构建任务，实时查看日志，并下载构建结果。

==================================================
一、核心目标
==================================================

1. B 机器：开发机
- 可以是 Mac / Linux。
- 不要求安装 Xcode。
- 安装 drift CLI 后即可使用。
- 通过 Git 仓库提交远程构建任务。
- 可以自动发现局域网内构建机。
- 可以自助配对认证。
- 可以查看构建状态、日志、下载结果。

2. A 机器：Mac 构建机
- 必须是 macOS。
- 已安装 Xcode。
- 运行 drift-server。
- 负责 git clone/fetch。
- 负责 pod install。
- 负责 xcodebuild。
- 负责生成 build.log、summary、artifact。
- 负责 Bonjour 广播服务。
- 负责 token 认证。

3. 第一版只支持：
- Debug
- iOS Simulator Build
- Swift / Objective-C
- xcodebuild clean build
- CODE_SIGNING_ALLOWED=NO

4. 第一版不做：
- archive
- export ipa
- App Store
- TestFlight
- 证书管理
- Web UI
- 多 server 中央调度

==================================================
二、技术栈要求
==================================================

必须使用 Swift 实现整个项目。

Swift Package：
- 一个 Swift Package
- 两个 executable target：
  - drift
  - drift-server

服务端：
- Swift 5.10+
- Vapor 4
- Network.framework
- Foundation
- Swift Concurrency
- Process 调用 git / pod / xcodebuild / zip

客户端：
- Swift 5.10+
- ArgumentParser
- Network.framework
- URLSession
- Foundation

依赖建议：
- Vapor
- swift-argument-parser
- ZIPFoundation 可选
- 不使用 Python
- 不使用 Node.js
- 不使用 Ruby 实现业务逻辑
- 不使用 Docker 作为运行前提
- 不依赖 Jenkins / Fastlane / Woodpecker

==================================================
三、项目目录结构
==================================================

DriftBuild/
  Package.swift
  README.md
  LICENSE
  .gitignore

  Sources/
    DriftCLI/
      main.swift
      Commands/
        DiscoverCommand.swift
        PairCommand.swift
        ServersCommand.swift
        SubmitCommand.swift
        StatusCommand.swift
        LogsCommand.swift
        ArtifactCommand.swift
        CancelCommand.swift
        VersionCommand.swift
      Core/
        CLIConfig.swift
        HTTPClient.swift
        BonjourBrowser.swift
        OutputPrinter.swift
        Models.swift
        Errors.swift
        Utils.swift

    DriftServer/
      main.swift
      ServerApp.swift
      Routes/
        HealthRoutes.swift
        AuthRoutes.swift
        BuildRoutes.swift
      Core/
        ServerConfig.swift
        BonjourPublisher.swift
        AuthManager.swift
        JobQueue.swift
        JobRunner.swift
        GitManager.swift
        XcodebuildRunner.swift
        ArtifactManager.swift
        StateStore.swift
        ProcessRunner.swift
        Models.swift
        Errors.swift
        Utils.swift

  Tests/
    DriftBuildTests/
      AuthManagerTests.swift
      StateStoreTests.swift
      LogOffsetTests.swift
      ModelsTests.swift

  .github/
    workflows/
      release.yml

==================================================
四、命令设计
==================================================

CLI 可执行文件名：

drift

Server 可执行文件名：

drift-server

----------------------------------------
drift discover
----------------------------------------

功能：
自动发现局域网内 drift-server。

示例：
drift discover
drift discover --timeout 5
drift discover --json

输出：
NAME              HOST              PORT   XCODE        VERSION
mac-mini-01       192.168.1.20      8000   Xcode 16.2   0.1.0

----------------------------------------
drift pair
----------------------------------------

功能：
与某台 drift-server 配对认证。

示例：
drift pair
drift pair --server http://192.168.1.20:8000
drift pair --name yunlong-macbook

行为：
1. 如果未传 --server，自动 discover。
2. 如果发现多台 server，让用户选择。
3. 调用 /api/auth/pair/start。
4. 显示 pairing code。
5. 轮询 /api/auth/pair/status/{pairing_id}。
6. 配对成功后保存 token 到 ~/.driftbuild/config.json。

----------------------------------------
drift servers
----------------------------------------

功能：
管理已配对 server。

示例：
drift servers
drift servers --default mac-mini-01
drift servers --remove mac-mini-01

----------------------------------------
drift submit
----------------------------------------

功能：
提交构建任务。

示例：
drift submit \
  --repo git@gitlab.xxx.com:ios/YourApp.git \
  --branch feature/test \
  --commit abc123 \
  --workspace YourApp.xcworkspace \
  --scheme YourScheme \
  --wait \
  --download

参数：
--server 可选，不传时使用 default server
--repo 必填
--branch 可选，不传时尝试 git rev-parse --abbrev-ref HEAD
--commit 可选，不传时尝试 git rev-parse HEAD
--workspace 可选
--project 可选
--scheme 必填
--configuration 默认 Debug
--include-xcresult 默认 false
--timeout 默认 3600
--wait 是否等待完成
--download 是否完成后下载 artifact
--output 默认 ./remote-build-output

行为：
1. POST /api/builds。
2. 打印 job_id。
3. 如果 --wait，每 2 秒轮询状态。
4. 每 2 秒按 offset 拉取增量日志。
5. 如果 --download，下载 result.zip。
6. 解压到 ./remote-build-output/{job_id}/result/。
7. 打印 summary.txt。
8. 成功 exit 0，失败 exit 非 0。

----------------------------------------
drift status
----------------------------------------

示例：
drift status --job-id xxx

----------------------------------------
drift logs
----------------------------------------

示例：
drift logs --job-id xxx
drift logs --job-id xxx --follow

----------------------------------------
drift artifact
----------------------------------------

示例：
drift artifact --job-id xxx --output ./remote-build-output

----------------------------------------
drift cancel
----------------------------------------

示例：
drift cancel --job-id xxx

----------------------------------------
drift version
----------------------------------------

输出 CLI 版本。

==================================================
五、drift-server 命令设计
==================================================

----------------------------------------
drift-server run
----------------------------------------

示例：
drift-server run
drift-server run --host 0.0.0.0 --port 8000
drift-server run --data-dir ~/ios-build-server
drift-server run --concurrency 1

----------------------------------------
drift-server approve
----------------------------------------

示例：
drift-server approve --code 482913
drift-server approve --pairing-id pair_xxx

功能：
批准配对请求。

----------------------------------------
drift-server clients
----------------------------------------

列出已认证客户端。

----------------------------------------
drift-server revoke
----------------------------------------

示例：
drift-server revoke --client-id xxx

撤销客户端。

----------------------------------------
drift-server version
----------------------------------------

输出版本。

==================================================
六、服务发现
==================================================

优先使用 Apple Bonjour / mDNS。

服务类型：
_driftbuild._tcp.local.

服务名：
DriftBuild-{hostname}

TXT records：
version=0.1.0
name={hostname}
port=8000
auth=pairing
xcode={xcode_version}
max_jobs=1

服务端：
使用 Network.framework 发布 Bonjour 服务。

客户端：
使用 Network.framework 发现 Bonjour 服务。

要求：
- discover 默认等待 3 秒。
- 支持 --timeout。
- 支持 --json。
- 如果发现不到，提示用户手动指定 --server。

==================================================
七、自助认证
==================================================

采用：
Pairing Code + Bearer Token。

----------------------------------------
POST /api/auth/pair/start
----------------------------------------

匿名接口。

请求：
{
  "clientName": "yunlong-macbook",
  "clientId": "uuid"
}

返回：
{
  "pairingId": "pair_xxx",
  "pairingCode": "482913",
  "expiresIn": 300
}

要求：
- pairing code 为 6 位数字。
- 5 分钟过期。
- 同 clientId 重复请求时复用未过期 pairing。
- 服务端控制台打印配对请求和 code。

----------------------------------------
GET /api/auth/pair/status/{pairingId}
----------------------------------------

返回：
{
  "status": "pending"
}

或：

{
  "status": "approved",
  "token": "dbt_xxx",
  "serverName": "mac-mini-01",
  "serverUrl": "http://192.168.1.20:8000"
}

状态：
pending
approved
rejected
expired

----------------------------------------
POST /api/auth/pair/approve
----------------------------------------

请求：
{
  "pairingId": "pair_xxx"
}

或：
{
  "pairingCode": "482913"
}

要求：
第一版 approve 只允许 localhost 或 drift-server approve 命令调用。

----------------------------------------
DELETE /api/auth/clients/{clientId}
----------------------------------------

撤销客户端 token。

----------------------------------------
token 存储
----------------------------------------

服务端：
~/ios-build-server/auth/clients.json

只保存 tokenHash：
sha256(token)

不要明文保存 token。

客户端：
~/.driftbuild/config.json

保存：
{
  "servers": [
    {
      "name": "mac-mini-01",
      "url": "http://192.168.1.20:8000",
      "token": "dbt_xxx",
      "pairedAt": "...",
      "lastUsedAt": "..."
    }
  ],
  "defaultServer": "mac-mini-01"
}

所有构建接口必须携带：
Authorization: Bearer dbt_xxx

==================================================
八、HTTP API
==================================================

----------------------------------------
GET /api/health
----------------------------------------

匿名接口。

返回：
{
  "name": "mac-mini-01",
  "version": "0.1.0",
  "xcode": "Xcode 16.2",
  "status": "ok"
}

----------------------------------------
POST /api/builds
----------------------------------------

需要认证。

请求：
{
  "repo": "git@gitlab.xxx.com:ios/YourApp.git",
  "branch": "feature/test",
  "commit": "abc123",
  "workspace": "YourApp.xcworkspace",
  "project": null,
  "scheme": "YourScheme",
  "configuration": "Debug",
  "includeXcresult": false,
  "timeoutSeconds": 3600
}

返回：
{
  "jobId": "20260512_xxxxxx",
  "status": "queued"
}

----------------------------------------
GET /api/builds/{jobId}
----------------------------------------

需要认证。

返回：
{
  "jobId": "...",
  "status": "running",
  "stage": "building",
  "elapsedSeconds": 123,
  "exitCode": null,
  "artifactReady": false
}

状态：
queued
preparing
fetching
installingDependencies
building
packaging
success
failed
timeout
canceled

----------------------------------------
GET /api/builds/{jobId}/log?offset=0
----------------------------------------

需要认证。

返回：
{
  "offset": 12345,
  "log": "增量日志"
}

要求：
offset 使用字节偏移。

----------------------------------------
GET /api/builds/{jobId}/artifact
----------------------------------------

需要认证。

下载 result.zip。

----------------------------------------
DELETE /api/builds/{jobId}
----------------------------------------

需要认证。

取消任务。

==================================================
九、文件系统状态
==================================================

默认数据目录：

~/ios-build-server/

结构：

~/ios-build-server/
  auth/
    clients.json
    pairings.json

  repos/
    {repoHash}/

  jobs/
    {jobId}/
      state.json
      build.log
      meta.json
      summary.txt
      errors.txt
      warnings.txt
      result.zip
      Build.xcresult/

  derived-data/
    {jobId}/

repoHash：
sha1(repoURL) 前 12 位。

jobId：
yyyyMMdd_HHmmss_随机6位。

==================================================
十、Git 策略
==================================================

每个 repo 使用固定缓存目录：

~/ios-build-server/repos/{repoHash}/

流程：

如果目录不存在：
git clone repo .

如果目录存在：
git fetch --all --prune

然后：
git checkout branch
git reset --hard commit
git clean -fd
git submodule update --init --recursive

要求：
- subprocess 使用 Process。
- 不使用 shell=True。
- 所有参数使用数组传递。
- 同一个 repo 必须加锁，避免并发操作。

==================================================
十一、依赖处理
==================================================

如果仓库根目录存在 Podfile：

如果存在 Gemfile：
bundle install
bundle exec pod install

否则：
pod install

SPM：
不手动处理，允许 xcodebuild 自动解析。

所有输出写入 build.log。

==================================================
十二、workspace/project 探测
==================================================

规则：

1.
如果传 workspace：
使用 -workspace

2.
否则如果传 project：
使用 -project

3.
否则自动查找仓库根目录：

如果只有一个 .xcworkspace：
使用它

否则如果只有一个 .xcodeproj：
使用它

如果多个：
构建失败，并在 summary.txt 中提示显式传 --workspace 或 --project。

scheme 必填。

==================================================
十三、xcodebuild
==================================================

命令：

xcodebuild clean build \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -resultBundlePath "$OUTPUT_DIR/Build.xcresult" \
  CODE_SIGNING_ALLOWED=NO

如果使用 project，则改为：
-project "$PROJECT"

要求：
- 只做 simulator build。
- 不签名。
- 不 archive。
- 不导出 IPA。
- 支持 Swift。
- 支持 Objective-C。
- 编译 stdout/stderr 实时追加到 build.log。

==================================================
十四、日志和 artifact
==================================================

每个 job 输出：

build.log
meta.json
summary.txt
errors.txt
warnings.txt
result.zip
Build.xcresult/

errors.txt 提取：
- error:
- fatal error:
- BUILD FAILED
- linker command failed

warnings.txt 提取：
- warning:

summary.txt 包含：
- 构建结果
- jobId
- repo
- branch
- commit
- scheme
- configuration
- duration
- exitCode
- 前 50 条 error
- 前 50 条 warning

result.zip 包含：
- meta.json
- summary.txt
- build.log
- errors.txt
- warnings.txt
- 如果 includeXcresult=true，则包含 Build.xcresult.zip

==================================================
十五、队列与并发
==================================================

默认：
BUILD_CONCURRENCY=1

要求：
- FIFO
- 同一 repo 串行
- 同一 repo + branch 如果有多个 queued job，只保留最新 job，旧 job 标记 canceled
- running job 不强制取消
- 支持后续扩展多 Mac 中央调度，但第一版不实现

==================================================
十六、超时
==================================================

timeoutSeconds：
默认 3600
最大 7200

idle timeout：
默认 600 秒

如果超时：
- 终止 xcodebuild 进程树
- 状态改为 timeout
- 生成 summary.txt
- 生成 result.zip

==================================================
十七、安全要求
==================================================

- 只面向可信局域网。
- token 不打印到日志。
- token 不放 URL query。
- 服务端只保存 token hash。
- repo URL 做合法性校验。
- subprocess 不使用 shell。
- pair code 5 分钟过期。
- approve 默认只允许本机命令。
- 认证失败返回 401。
- revoke 后 token 立即失效。

==================================================
十八、GitHub 自动构建与发布
==================================================

请提供 GitHub Actions workflow：

.github/workflows/release.yml

目标：
当 push tag：
v*

自动构建 release。

要求：
1. macOS runner 构建 Swift Package。
2. 构建两个二进制：
   - drift
   - drift-server
3. 生成压缩包：
   - driftbuild-macos-arm64.tar.gz
   - driftbuild-macos-x86_64.tar.gz
4. 每个包包含：
   - drift
   - drift-server
   - README.md
5. 上传到 GitHub Release。
6. 生成 SHA256 校验文件。

如果跨架构复杂，至少先实现 macOS arm64。
README 中说明 x86_64 后续支持。

CLI 安装方式示例：

curl -L https://github.com/{owner}/DriftBuild/releases/latest/download/driftbuild-macos-arm64.tar.gz -o driftbuild.tar.gz
tar -xzf driftbuild.tar.gz
sudo mv drift drift-server /usr/local/bin/

==================================================
十九、README
==================================================

README.md 必须包含：

1. DriftBuild 是什么。
2. 架构图。
3. Server 安装。
4. CLI 安装。
5. GitHub Release 安装方式。
6. drift-server run 示例。
7. drift discover 示例。
8. drift pair 示例。
9. drift submit 示例。
10. drift logs 示例。
11. drift artifact 示例。
12. 数据目录说明。
13. 安全说明。
14. 常见问题：
   - discover 找不到
   - macOS 防火墙
   - token 失效
   - xcodebuild not found
   - scheme not found
   - pod install 失败
   - SPM 失败
   - 构建超时
   - result.zip 太大
15. 后续规划：
   - Archive
   - IPA
   - Web UI
   - 多 Mac 中央调度
   - 企业微信通知
   - GitLab Webhook
   - 构建缓存

==================================================
二十、测试要求
==================================================

至少实现以下单元测试：

1. token hash 校验。
2. pairing code 过期。
3. client revoke。
4. job state 编解码。
5. log offset 读取。
6. repo hash 生成。
7. artifact 文件列表生成。
8. CLI config 读写。

==================================================
二十一、自检要求
==================================================

实现完成后，请逐项自检并输出自检结果：

1. 是否完全使用 Swift。
2. 是否生成 drift 和 drift-server 两个 target。
3. drift discover 是否可用。
4. drift pair 是否可用。
5. 未认证是否不能 submit。
6. token 是否只保存 hash。
7. revoke 后 token 是否失效。
8. submit 是否能创建 job。
9. build.log 是否实时写入。
10. logs offset 是否正确。
11. 构建失败是否仍能生成 result.zip。
12. includeXcresult=false 是否不会打包 xcresult。
13. workspace/project 自动探测是否正确。
14. scheme 缺失是否明确报错。
15. xcodebuild 不存在是否明确报错。
16. timeout 是否能终止子进程。
17. CLI 在无 Xcode 机器上是否能运行。
18. GitHub Actions 是否能构建 release 包。
19. README 是否包含完整使用说明。
20. 是否避免 shell 注入风险。

请输出：
1. 完整项目代码。
2. Package.swift。
3. README.md。
4. GitHub Actions release.yml。
5. 安装说明。
6. 使用示例。
7. 自检结果。