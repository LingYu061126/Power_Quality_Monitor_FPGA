# 电能质量监测与故障记录 Quartus 工程

本目录为 FPGA 端主工程，目标器件为 MAX 10 `10M08SAM153I7G`。

## 主要功能

- DDS 生成 50 Hz 正弦波。
- DAC081S101 输出正常或故障测试波形。
- ADC081S101 回采模拟信号。
- 计算 RMS、Peak 和频率。
- 检测暂降、暂升、过频、欠频、削顶和谐波畸变。
- LCD 显示实时/冻结波形和测量状态。
- 矩阵键盘控制故障触发、解除冻结、清除故障、回放和随机故障。
- AT24C02 EEPROM 记录故障事件。
- CH340 串口与 ESP8266 WiFi 数据回传。

## 关键文件

| 文件 | 作用 |
| --- | --- |
| `power_quality_monitor.v` | 系统顶层 |
| `waveform_gen.v` | DDS 正弦波与故障波形生成 |
| `dac081s101_driver.v` | DAC SPI 驱动 |
| `adc081s101_driver.v` | ADC SPI 驱动 |
| `rms_calculator.v` / `isqrt_16bit.v` | RMS 与整数平方根 |
| `peak_detector.v` | 半周期峰值检测 |
| `freq_detector.v` | 带滞回过零频率检测 |
| `anomaly_detector.v` | 故障判据与报警 |
| `freeze_controller.v` / `wave_buffer.v` | 波形缓存与冻结 |
| `lcd_driver.v` / `source/*.v` | LCD 初始化、刷屏和 UI |
| `key_scan.v` | 4x4 矩阵键盘扫描 |
| `event_logger.v` / `i2c_master.v` | EEPROM 事件记录 |
| `uart_tx.v` | UART 发送器 |
| `wifi_telemetry_tx.v` | ESP8266 初始化和 WiFi 遥测 |

## 编译

1. 使用 Quartus Prime 打开 `power_quality_monitor.qpf`。
2. 执行 `Compile Design`。
3. 下载 `output_files/power_quality_monitor.sof`。

`output_files/`、`db/` 和中间报告默认不提交到 Git。

## 注意事项

- `KEY4` 控制运行/暂停，上电默认暂停。
- `KEY3` 用于 ADC 中心校准。
- WiFi 发送帧格式见 `../docs/wifi_protocol.md`。
- 本地网页监控程序见 `../wifi_monitor/`。
