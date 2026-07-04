# WiFi电能质量监控程序

程序仅依赖Python 3标准库，可在Arch Linux和Windows上运行。它连接FPGA的ESP8266 TCP服务器，在浏览器中显示实时数据，并把有效帧同时写入CSV和SQLite数据库。

## 使用步骤

1. 电脑连接WiFi `STEP_FPGA`，密码 `12345678`。
2. 确认FPGA已经下载最新编译结果并处于上电状态。
3. 在工作目录执行：

   Arch Linux：

   ```bash
   python3 wifi_monitor/monitor.py
   ```

   Windows PowerShell或CMD：

   ```text
   py wifi_monitor\monitor.py
   ```

4. 程序默认打开 `http://127.0.0.1:8765/`。
5. CSV和SQLite数据库默认保存到 `wifi_monitor/data/`。

页面中的“历史回放”可选择数据库中的任意会话，支持播放、暂停、拖动和调速。“故障报告”会统计当前会话的故障次数、持续时间、测量范围和状态时间轴，可通过浏览器打印为PDF。

网页将FPGA上传的RMS、Peak和瞬时ADC原始码换算为ADC引脚处的实际电压，主指标、趋势曲线、状态变更表和故障报告均以V为单位，同时在主指标下保留原始码值。换算采用底板3.3 V参考电压和8位ADC量化关系：

```text
电压(V) = 原始码值 × 3.3 / 256
```

RMS和Peak是去除ADC中心偏置后的交流有效值与交流峰值；瞬时ADC电压包含输入信号约1.65 V的直流偏置。若在ADC输入前增加了非1倍的外部放大或分压电路，还需要再除以该前端传递系数才能得到被测信号源端电压。

CSV第一行的最后一列保存WiFi字段缩写及全称说明，第二行是数据列名。后续每条记录的最后一列`wifi_raw_frame`保存通过WiFi收到的完整原始帧。

若浏览器没有自动打开，可手动访问上述地址。使用 `Ctrl+C` 停止程序。

## 常用参数

```bash
python3 wifi_monitor/monitor.py --no-browser
python3 wifi_monitor/monitor.py --http-port 8876
python3 wifi_monitor/monitor.py --csv ./capture.csv
python3 wifi_monitor/monitor.py --database ./power_quality.db
python3 wifi_monitor/monitor.py --demo
```

`--demo`不连接FPGA，可用于单独检查监控页面。

## 新帧格式

```text
PQ,R=065,P=089,F=050,T=0,M=0,Z=0,A=0,E=02,D=044,S=0012,U=000,G=1,N=007,C=HH
```

- `G=1`表示运行，`G=0`表示暂停。
- `N`是`000`到`999`的循环帧序号。
- `C`是两位十六进制异或校验值。
- 校验范围从帧首`P`开始，到`N`字段最后一位结束，不包括`,C=HH`和换行符。
