# 使用步骤

## 1. 电能质量 Quartus 工程

工程目录：

```text
power_quality_monitor/
```

打开工程：

```text
power_quality_monitor/power_quality_monitor.qpf
```

基本流程：

1. 打开 Quartus Prime。
2. `File -> Open Project` 选择 `.qpf`。
3. 执行 `Compile Design`。
4. 打开 `Tools -> Programmer`。
5. 选择生成的 `.sof`，下载到 MAX10 核心板。

注意：仓库默认不保存 `output_files/` 和 `.sof/.pof`。克隆仓库后需要重新编译生成下载文件。

## 2. 电能质量项目板上操作

常用控制：

- `KEY1`：系统复位。
- `KEY2`：解除波形冻结。
- `KEY3`：ADC 中心校准。
- `KEY4`：运行/暂停切换，上电默认暂停。
- 矩阵键盘 `0`：清除故障。
- 矩阵键盘 `1~5`：触发暂降、暂升、过频、欠频、削顶。
- 矩阵键盘 `6`：只解除冻结，不清除故障。
- 矩阵键盘 `7`：触发谐波畸变。
- 矩阵键盘 `8~D`：查看对应故障波形。
- 矩阵键盘 `E`：控制权交还拨码开关。
- 矩阵键盘 `F`：伪随机触发一种故障。

显示：

- LCD 显示实时/冻结波形、RMS、Peak、频率、事件数、运行时间和故障时间。
- 核心板数码管显示故障类型码和关键测量值。
- LED/蜂鸣器给出故障状态提示。

## 3. WiFi 监控程序

进入目录：

```bash
cd wifi_monitor
```

连接真实 FPGA：

```bash
python3 monitor.py
```

演示模式：

```bash
python3 monitor.py --demo
```

不自动打开浏览器：

```bash
python3 monitor.py --no-browser
```

指定网页端口：

```bash
python3 monitor.py --http-port 8876
```

默认输出：

- CSV：`wifi_monitor/data/power_quality_*.csv`
- SQLite：`wifi_monitor/data/power_quality.db`

这些运行数据默认不提交到 Git。

## 4. WiFi 调试

电脑连接热点：

```text
SSID: STEP_FPGA
Password: 12345678
```

TCP 目标：

```text
192.168.4.1:8686
```

若连接失败，优先检查：

1. FPGA 是否下载最新工程并运行。
2. ESP8266 是否使用正确串口方向。
3. 电脑是否连接到了 `STEP_FPGA` 热点。
4. 防火墙是否阻止本地 Python 程序访问网络。
