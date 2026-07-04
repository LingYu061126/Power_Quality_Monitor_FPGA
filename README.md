# FPGA电能质量监测与故障记录系统

本仓库整理了基于 STEP-MAX10M08 核心板和 STEP BaseBoard V4.0 底板完成的 FPGA 实验项目，主要包括电能质量监测系统、WiFi 本地监控程序，以及一个比赛计分系统示例工程。

## 主要内容

- `power_quality_monitor/`：电能质量监测与故障记录 Quartus 工程。
- `wifi_monitor/`：电脑端 WiFi/TCP 数据接收、网页监控、SQLite 记录和 CSV 导出程序。
- `docs/`：硬件引脚、使用步骤、WiFi 数据协议和 GitHub 上传说明。

## 电能质量项目功能

- DDS 正弦波生成与 DAC081S101 输出。
- ADC081S101 采样与 ADC 中心校准。
- RMS、Peak、频率检测。
- 电压暂降、暂升、过频、欠频、削顶和谐波畸变故障注入与检测。
- LCD 实时波形、冻结波形、故障回放、运行时间和故障时间显示。
- 矩阵键盘手动触发、随机故障触发、解除冻结、清除故障和故障回放。
- AT24C02 EEPROM 故障事件记录。
- CH340 串口基础通信和 ESP8266 WiFi 遥测。
- 本地网页端显示实际电压值、趋势曲线、故障时间轴、历史回放和故障报告。

## 硬件平台

- 核心板：STEP-MAX10M08。
- FPGA：Intel/Altera MAX 10，`10M08SAM153I7G`。
- 底板：STEP BaseBoard V4.0。
- 主要外设：ADC081S101、DAC081S101、ST7789V SPI-LCD、8 位数码管、74HC595、矩阵键盘、AT24C02、CH340、ESP8266。

## 快速开始

### 编译 FPGA 工程

1. 使用 Quartus Prime 打开 `power_quality_monitor/power_quality_monitor.qpf`。
2. 执行 `Compile Design`。
3. 使用 Programmer 下载生成的 `.sof` 文件。

### 运行 WiFi 监控程序

FPGA 下载并上电后，电脑连接 ESP8266 热点：

- SSID：`STEP_FPGA`
- 密码：`12345678`
- TCP：`192.168.4.1:8686`

运行本地监控页面：

```bash
cd wifi_monitor
python3 monitor.py
```

默认浏览器访问：

```text
http://127.0.0.1:8765/
```

演示模式不需要连接 FPGA：

```bash
cd wifi_monitor
python3 monitor.py --demo
```

## 文档

- [使用步骤](docs/usage.md)
- [硬件引脚说明](docs/hardware_pins.md)
- [WiFi 遥测协议](docs/wifi_protocol.md)
- [GitHub 上传说明](docs/github_upload.md)


## License

MIT License. 课程报告、实验指导书、截图等第三方或个人文档默认不纳入本仓库源码授权范围。
