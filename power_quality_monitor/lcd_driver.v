//==============================================================================
// 模块：lcd_driver
// 说明：LCD显示子系统顶层封装。
//   复用lab13_picture_display中的参考架构：
//     - lcd_write     ：9位SPI（模式0）字节写入器
//     - lcd_init      ：ST7789V初始化与全屏清屏
//     - control       ：初始化数据/显示数据选择，并重新触发帧刷新
//     - lcd_show_pic  ：设置显示窗口并连续输出像素
//     - ui_template   ：背景边框、标签、标志和动态文本
//
//   本工程已由pll_clock提供50MHz时钟，因此该封装直接接收clk/rst_n，
//   不再在内部例化PLL。频率显示值在此处由完整周期计数换算得到。
//==============================================================================

module lcd_driver (
    input  wire        clk,          // 50MHz系统时钟
    input  wire        rst_n,        // 低电平有效复位

    // 需要显示的电能质量数据
    input  wire        freeze_active,
    input  wire [7:0]  wave_data,
    output wire        read_next,
    input  wire [2:0]  fault_type,
    input  wire [7:0]  rms_value,
    input  wire [7:0]  peak_value,
    input  wire [15:0] freq_cnt,      // freq_detector输出的完整周期计数
    input  wire [4:0]  event_count,   // event_logger记录计数
    input  wire [15:0] display_time_bcd,
    input  wire        display_time_is_fault,
    input  wire        system_running,

    // LCD物理接口
    output wire        lcd_rst,
    output wire        lcd_blk,
    output wire        lcd_dc,
    output wire        lcd_sclk,
    output wire        lcd_mosi,
    output wire        lcd_cs
);

    // 背光常亮
    assign lcd_blk = 1'b1;

    // 将周期计数转换为紧凑的显示值。检测器主要用于49.5/50/50.5Hz教学点，
    // 因此用阈值判断代替LCD像素路径上的慢速组合除法器。
    wire [7:0] freq_hz;
    assign freq_hz = (freq_cnt == 16'd0)  ? 8'd0  :
                     (freq_cnt <= 16'd198) ? 8'd51 :
                     (freq_cnt >= 16'd202) ? 8'd49 :
                                             8'd50;

    // 内部连线
    wire [8:0] data;
    wire       en_write;
    wire       wr_done;

    wire [8:0] init_data;
    wire       en_write_init;
    wire       init_done;

    wire [8:0] show_pic_data;
    wire       en_write_show_pic;
    wire       show_pic_done;
    wire       show_pic_flag;

    // SPI字节写入模块
    lcd_write lcd_write_inst (
        .sys_clk_50MHz (clk),
        .sys_rst_n     (rst_n),
        .data          (data),
        .en_write      (en_write),
        .wr_done       (wr_done),
        .cs            (lcd_cs),
        .dc            (lcd_dc),
        .sclk          (lcd_sclk),
        .mosi          (lcd_mosi)
    );

    // 控制选择器：选择初始化数据或图像数据，并逐帧重新触发
    control control_inst (
        .sys_clk_50MHz     (clk),
        .sys_rst_n         (rst_n),
        .init_data         (init_data),
        .en_write_init     (en_write_init),
        .init_done         (init_done),
        .show_pic_data     (show_pic_data),
        .en_write_show_pic (en_write_show_pic),
        .show_pic_done     (show_pic_done),
        .show_pic_flag     (show_pic_flag),
        .data              (data),
        .en_write          (en_write)
    );

    // LCD初始化模块
    lcd_init lcd_init_inst (
        .sys_clk_50MHz (clk),
        .sys_rst_n     (rst_n),
        .wr_done       (wr_done),
        .lcd_rst       (lcd_rst),
        .init_data     (init_data),
        .en_write      (en_write_init),
        .init_done     (init_done)
    );

    // 显示流模块：UI模板 + 冻结波形叠加
    lcd_show_pic lcd_show_pic_inst (
        .sys_clk           (clk),
        .sys_rst_n         (rst_n),
        .wr_done           (wr_done),
        .show_pic_flag     (show_pic_flag),
        .fault_type        (fault_type),
        .rms_value         (rms_value),
        .peak_value        (peak_value),
        .freq_value        (freq_hz),
        .event_count       (event_count),
        .display_time_bcd  (display_time_bcd),
        .display_time_is_fault(display_time_is_fault),
        .system_running    (system_running),
        .freeze_active     (freeze_active),
        .wave_data         (wave_data),
        .read_next         (read_next),
        .show_pic_data     (show_pic_data),
        .show_pic_done     (show_pic_done),
        .en_write_show_pic (en_write_show_pic)
    );

endmodule
