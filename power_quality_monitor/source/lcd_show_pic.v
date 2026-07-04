module lcd_show_pic
(
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    input  wire        wr_done,
    input  wire        show_pic_flag,

    // 填入UI模板的电能质量数据
    input  wire [2:0]  fault_type,
    input  wire [7:0]  rms_value,
    input  wire [7:0]  peak_value,
    input  wire [7:0]  freq_value,
    input  wire [4:0]  event_count,
    input  wire [15:0] display_time_bcd,
    input  wire        display_time_is_fault,
    input  wire        system_running,

    // 冻结波形接口
    input  wire        freeze_active,
    input  wire [7:0]  wave_data,
    output reg         read_next,

    output wire [8:0]  show_pic_data,
    output wire        show_pic_done,
    output wire        en_write_show_pic
);

    // 横屏LCD区域：320 x 240
    localparam [8:0] LCD_WIDTH_MAX  = 9'd319;
    localparam [8:0] LCD_HEIGHT_MAX = 9'd239;
    localparam [9:0] LINE_BYTE_MAX  = 10'd639; // 320像素 * 2字节 - 1

    // 波形叠加区域
    localparam [8:0] WAVE_X0     = 9'd10;
    localparam [8:0] WAVE_Y0     = 9'd114;
    localparam [8:0] WAVE_Y1     = 9'd232;
    localparam [8:0] WAVE_CENTER = 9'd173;
    localparam [8:0] WAVE_WIDTH  = 9'd200;
    localparam [8:0] WAVE_AMP    = 9'd40;
    localparam [8:0] WAVE_READ_LATENCY = 9'd3;
    localparam [8:0] WAVE_READ_TOTAL   = WAVE_WIDTH + WAVE_READ_LATENCY;

    localparam [2:0] STATE0     = 3'd0; // 空闲
    localparam [2:0] PRE_READ   = 3'd1; // 预读冻结波形采样
    localparam [2:0] STATE1     = 3'd2; // 设置显示窗口
    localparam [2:0] STATE2     = 3'd3; // 连续输出像素
    localparam [2:0] DONE       = 3'd4;

    reg [2:0] state;
    reg       wr_done_d;

    reg [3:0] cnt_set_windows;
    reg       state1_finish_flag;

    reg [8:0] cnt_y;
    reg [9:0] cnt_byte;
    reg [8:0] data;

    // 波形采样缓存
    reg [7:0] wave_ram [0:199];
    reg [8:0] wave_rd_ptr;

    wire       wr_done_pulse = wr_done & ~wr_done_d;
    wire [8:0] pixel_x = cnt_byte[9:1];
    wire [8:0] pixel_y = cnt_y;
    wire [15:0] pixel_rgb565;

    // 可选波形叠加后的最终像素
    reg         wave_pixel;
    reg  [8:0]  wave_idx;
    reg  signed [8:0]  wave_signed;
    reg  signed [17:0] wave_scaled;
    reg  signed [17:0] wave_offset;
    reg  signed [17:0] wave_y;
    wire [15:0] final_rgb = wave_pixel ? 16'h0000 : pixel_rgb565;

    ui_template ui_template_inst
    (
        .x            (pixel_x),
        .y            (pixel_y),
        .fault_type   (fault_type),
        .rms_value    (rms_value),
        .peak_value   (peak_value),
        .freq_value   (freq_value),
        .event_count  (event_count),
        .display_time_bcd(display_time_bcd),
        .display_time_is_fault(display_time_is_fault),
        .system_running(system_running),
        .freeze_active(freeze_active),
        .rgb565       (pixel_rgb565)
    );

    always @(posedge sys_clk or negedge sys_rst_n)
        if(!sys_rst_n)
            wr_done_d <= 1'b0;
        else
            wr_done_d <= wr_done;

    // 主状态机
    always @(posedge sys_clk or negedge sys_rst_n)
        if(!sys_rst_n)
            state <= STATE0;
        else
            case(state)
                STATE0:   state <= show_pic_flag ? PRE_READ : STATE0;
                PRE_READ: state <= (wave_rd_ptr == WAVE_READ_TOTAL) ? STATE1 : PRE_READ;
                STATE1:   state <= state1_finish_flag ? STATE2 : STATE1;
                STATE2:   state <= (cnt_y == LCD_HEIGHT_MAX && cnt_byte == LINE_BYTE_MAX && wr_done_pulse) ? DONE : STATE2;
                DONE:     state <= STATE0;
                default:  state <= STATE0;
            endcase

    // 每帧开始时预读WAVE_WIDTH个波形采样
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            wave_rd_ptr <= 9'd0;
            read_next   <= 1'b0;
        end else begin
            read_next <= 1'b0;
            if (state == PRE_READ) begin
                if (wave_rd_ptr < WAVE_READ_TOTAL) begin
                    if (wave_rd_ptr >= WAVE_READ_LATENCY)
                        wave_ram[wave_rd_ptr - WAVE_READ_LATENCY] <= wave_data;
                    read_next <= 1'b1;
                    wave_rd_ptr <= wave_rd_ptr + 1'b1;
                end
            end else begin
                wave_rd_ptr <= 9'd0;
            end
        end
    end

    always @(posedge sys_clk or negedge sys_rst_n)
        if(!sys_rst_n)
            cnt_set_windows <= 4'd0;
        else if(state != STATE1)
            cnt_set_windows <= 4'd0;
        else if(wr_done_pulse)
            cnt_set_windows <= cnt_set_windows + 1'b1;

    always @(posedge sys_clk or negedge sys_rst_n)
        if(!sys_rst_n)
            state1_finish_flag <= 1'b0;
        else if(state == STATE1 && cnt_set_windows == 4'd10 && wr_done_pulse)
            state1_finish_flag <= 1'b1;
        else
            state1_finish_flag <= 1'b0;

    always @(posedge sys_clk or negedge sys_rst_n)
        if(!sys_rst_n)
            cnt_byte <= 10'd0;
        else if(state != STATE2)
            cnt_byte <= 10'd0;
        else if(wr_done_pulse)
            cnt_byte <= (cnt_byte == LINE_BYTE_MAX) ? 10'd0 : cnt_byte + 1'b1;

    always @(posedge sys_clk or negedge sys_rst_n)
        if(!sys_rst_n)
            cnt_y <= 9'd0;
        else if(state != STATE2)
            cnt_y <= 9'd0;
        else if(wr_done_pulse && cnt_byte == LINE_BYTE_MAX && cnt_y < LCD_HEIGHT_MAX)
            cnt_y <= cnt_y + 1'b1;

    // 波形叠加计算（组合逻辑）
    always @(*) begin
        wave_pixel = 1'b0;
        wave_idx = 9'd0;
        wave_signed = 9'sd0;
        wave_scaled = 18'sd0;
        wave_offset = 18'sd0;
        wave_y = 18'sd0;
        if (pixel_x >= WAVE_X0 && pixel_x < WAVE_X0 + WAVE_WIDTH &&
            pixel_y >= WAVE_Y0 && pixel_y <= WAVE_Y1) begin
            wave_idx = pixel_x - WAVE_X0;
            wave_signed = $signed({1'b0, wave_ram[wave_idx]}) - $signed(9'sd128);
            wave_scaled = wave_signed * $signed({1'b0, WAVE_AMP});
            wave_offset = wave_scaled >>> 7;
            wave_y = $signed({9'd0, WAVE_CENTER}) - wave_offset;
            if ($signed({9'd0, pixel_y}) == wave_y ||
                $signed({9'd0, pixel_y}) == wave_y + 18'sd1 ||
                $signed({9'd0, pixel_y}) == wave_y - 18'sd1)
                wave_pixel = 1'b1;
        end
    end

    always @(posedge sys_clk or negedge sys_rst_n)
        if(!sys_rst_n)
            data <= 9'h000;
        else if(state == STATE1)
            case(cnt_set_windows)
                4'd0:  data <= 9'h02A;              // 列地址设置
                4'd1:  data <= {1'b1, 8'h00};      // X起点高字节
                4'd2:  data <= {1'b1, 8'h00};      // X起点低字节
                4'd3:  data <= {1'b1, 8'h01};      // X终点高字节：319 = 0x013F
                4'd4:  data <= {1'b1, 8'h3F};      // X终点低字节
                4'd5:  data <= 9'h02B;              // 行地址设置
                4'd6:  data <= {1'b1, 8'h00};      // Y起点高字节
                4'd7:  data <= {1'b1, 8'h00};      // Y起点低字节
                4'd8:  data <= {1'b1, 8'h00};      // Y终点高字节：239 = 0x00EF
                4'd9:  data <= {1'b1, 8'hEF};      // Y终点低字节
                4'd10: data <= 9'h02C;              // 写显存
                default: data <= 9'h000;
            endcase
        else if(state == STATE2)
            data <= cnt_byte[0] ? {1'b1, final_rgb[7:0]} : {1'b1, final_rgb[15:8]};
        else
            data <= data;

    assign show_pic_data = data;
    assign en_write_show_pic = (state == STATE1 || state == STATE2);
    assign show_pic_done = (state == DONE);

endmodule
