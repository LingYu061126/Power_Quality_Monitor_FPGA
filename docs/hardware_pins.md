# 硬件与引脚说明

本项目使用 STEP-MAX10M08 核心板和 STEP BaseBoard V4.0 底板。引脚分配以工程内 `.qsf` 文件为准，本文档列出主要外设接口，便于检查和答辩说明。

## 1. 电能质量项目主要接口

工程：`power_quality_monitor/power_quality_monitor.qpf`

| 信号 | 方向 | 功能 |
| --- | --- | --- |
| `clk_12m` | input | 核心板 12 MHz 时钟 |
| `rst_n` | input | KEY1 低有效复位 |
| `key2` | input | 解除冻结 |
| `key3` | input | ADC 中心校准 |
| `key4` | input | 运行/暂停切换 |
| `sw[3:0]` | input | 拨码开关故障模式与显示模式 |
| `adc_cs_n` | output | ADC081S101 片选 |
| `adc_sclk` | output | ADC081S101 SPI 时钟 |
| `adc_sdata` | input | ADC081S101 串行数据 |
| `dac_sync_n` | output | DAC081S101 同步/片选 |
| `dac_sclk` | output | DAC081S101 SPI 时钟 |
| `dac_sdi` | output | DAC081S101 串行数据 |
| `lcd_*` | output | ST7789V LCD SPI 与控制信号 |
| `rck_595` | output | 74HC595 锁存时钟 |
| `sclk_595` | output | 74HC595 移位时钟 |
| `din_595` | output | 74HC595 串行数据 |
| `row[3:0]` | output | 4x4 矩阵键盘行扫描 |
| `col[3:0]` | input | 4x4 矩阵键盘列输入 |
| `i2c_scl` | inout | AT24C02 I2C 时钟 |
| `i2c_sda` | inout | AT24C02 I2C 数据 |
| `rxd_ch340` | output | FPGA 到 CH340 |
| `txd_ch340` | input | CH340 到 FPGA |
| `rxd_wifi` | output | FPGA 到 ESP8266 |
| `txd_wifi` | input | ESP8266 到 FPGA |

说明：底板串口丝印常从外设角度命名，工程中已按“FPGA 输出接外设 RXD，FPGA 输入接外设 TXD”的方向处理。

## 2. 比赛计分系统引脚

工程：`Game/game_score.qpf`

| 信号 | 管脚 | 功能 |
| --- | --- | --- |
| `clk_12m` | `PIN_J5` | 12 MHz 系统时钟 |
| `rst_n` | `PIN_J9` | KEY1 低有效复位 |
| `key3` | `PIN_J11` | 红队加分 |
| `key4` | `PIN_J14` | 蓝队加分 |
| `rck_595` | `PIN_A14` | 74HC595 锁存时钟 |
| `sclk_595` | `PIN_B13` | 74HC595 移位时钟 |
| `din_595` | `PIN_B15` | 74HC595 串行数据 |

## 3. 数码管驱动

底板 8 位共阴极数码管由两片级联 74HC595 驱动：

- 段码高电平有效。
- 位选低电平有效。
- FPGA 只需要输出 `RCK`、`SCK`、`DIN` 三根线。
- 动态扫描时逐位输出段选和位选，人眼看到的是多位同时显示。

## 4. WiFi 模块

ESP8266 由 FPGA 发送 AT 指令配置为 SoftAP TCP 服务器：

- SSID：`STEP_FPGA`
- 密码：`12345678`
- IP：`192.168.4.1`
- 端口：`8686`
- 串口：`115200 8N1`
