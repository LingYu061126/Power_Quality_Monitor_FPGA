# WiFi 遥测协议

FPGA 通过 ESP8266 建立 SoftAP TCP 服务器，电脑端程序连接 `192.168.4.1:8686` 后接收 ASCII 遥测帧。

## 帧格式

```text
PQ,R=065,P=089,F=050,T=0,M=0,Z=0,A=0,E=02,D=044,S=0012,U=000,G=1,N=007,C=HH
```

完整发送时包含 `\r\n`，当前帧长为 77 字节。

## 字段说明

| 字段 | 全称 | 含义 |
| --- | --- | --- |
| `PQ` | Power Quality | 帧头 |
| `R` | Root Mean Square | RMS 原始码 |
| `P` | Peak | Peak 原始码 |
| `F` | Frequency | 频率，单位 Hz |
| `T` | Fault Type | 检测出的故障类型 |
| `M` | Fault Mode | 当前故障注入模式 |
| `Z` | Freeze Status | 波形冻结状态 |
| `A` | Alarm Status | 报警状态 |
| `E` | Event Count | 故障事件计数 |
| `D` | ADC Data | ADC 瞬时采样码 |
| `S` | System Time | FPGA 运行时间，四位 BCD 秒数 |
| `U` | Fault Duration | 当前或最近故障持续时间，单位秒 |
| `G` | Run/Stop Status | `1` 运行，`0` 暂停 |
| `N` | Frame Number | `000~999` 循环帧序号 |
| `C` | Checksum | 两位十六进制异或校验 |

## 故障编码

| 编码 | 类型 |
| --- | --- |
| `0` | 正常 |
| `1` | 电压暂降 |
| `2` | 电压暂升 |
| `3` | 过频 |
| `4` | 欠频 |
| `5` | 削顶 |
| `6` | 谐波畸变 |

## 校验规则

校验值为 ASCII 字节逐字节异或：

```text
C = XOR("PQ,R=...N=007")
```

校验范围从帧首 `P` 开始，到 `N` 字段最后一位结束，不包含 `,C=HH` 和换行符。

电脑端监控程序会：

- 验证 `C` 字段。
- 解析 `N` 字段并统计丢帧。
- 校验失败或格式错误的帧写入 `frame_errors` 表。

## 实际电压换算

底板 ADC 参考电压为 3.3 V，ADC 为 8 位量化：

```text
V = code * 3.3 / 256
```

网页端显示：

- `R`：ADC 输入端交流 RMS 电压。
- `P`：ADC 输入端交流峰值电压。
- `D`：ADC 输入端瞬时电压，包含约 1.65 V 直流偏置。

如果 ADC 前端存在额外放大或分压，信号源端电压还需要除以前端传递系数。
