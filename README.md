# 巨魔歌词桌面 — DesktopLyrics 1.0.0

原创越狱插件（SpringBoard）：正在放的歌，歌词飘在桌面上。

- **浮窗**：桌面上的 3D 水面墙样式浮窗（歌名＋歌手、当前那句词大字立体、下一句小字、进度条），可以拖动，位置会记住。
- **跟歌走**：读系统正在放的歌（MediaRemote），QQ 音乐、酷我、任何 App 放什么就跟什么。
- **词的来源**：先找我们自己的 3D 歌词墙数据（16 首）；没有的歌去 LRCLIB（免费公开歌词接口，不用 key）找带时间轴的词，找回来存在本机；实在找不到就显示「暂无歌词」——绝不编词。
- **时间同步**：墙内数据按每句时长推进（近似）；LRCLIB 的词用真时间戳（真同步）。暂停就停在当前那句。
- **只有歌词**：窗上没有按钮、不点按、不做别的功能。设置里只有一个启用开关。

## 文件

- `Tweak.xm` — 插件全部代码（原创；无字面量字符串，Linux 交叉工具链要求）
- `GHDLyricsData.h` — 墙内 16 首歌的词（生成文件，源数据见 hidden_files/lyrics_data.json）
- `Makefile` / `control` / `DesktopLyrics.plist` — Theos 工程、包信息、SpringBoard 过滤
- `prefs/` — 设置页（只有一个启用开关）

## 构建

本地冒烟：`bash hidden_files/build_smoke_1.0.0.sh`（在 /tmp 编，umask 022，rootless）。
正式编包走 GitHub Actions（macOS），推＋编＋部署分开批。
