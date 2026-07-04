//==============================================================================
// 模块：rms_calculator
// 说明：8位交流采样的滑动窗口RMS计算器
//   - 窗口深度：256点（10kHz下25.6ms，约1.28个50Hz周期）
//   - 输入：8位无符号ADC采样
//   - 输出：8位无符号RMS值
//   - 延迟：每个采样约11个50MHz时钟周期，远小于100us采样间隔
//   - 存储：256 x 16位循环缓存（由Quartus推断为M9K RAM）
//   - 防溢出：使用24位累加器
//==============================================================================

module rms_calculator (
    input  wire        clk,          // 50MHz系统时钟
    input  wire        rst_n,        // 低电平有效复位
    input  wire        sample_trig,  // 10kHz单周期采样脉冲
    input  wire [7:0]  adc_data,     // ADC输出的8位无符号采样
    input  wire [7:0]  adc_center,   // 校准后的ADC零点
    output reg  [7:0]  rms_value,    // RMS计算结果
    output reg         rms_valid,    // rms_value更新时产生一个周期脉冲
    output wire [15:0] debug_mean    // 平方均值（开方前），用于调试
);

    //==========================================================================
    // 1. 直流偏置去除与平方计算
    //    adc_data (0~255) -> 以adc_center为中心的有符号值 -> 平方
    //==========================================================================
    reg [7:0] sample_data;
    wire signed [8:0] adc_center_signed = $signed({1'b0, adc_center});
    wire signed [8:0] adc_signed = $signed({1'b0, sample_data}) - adc_center_signed;
    wire signed [17:0] sq_signed  = adc_signed * adc_signed;   // 18位有符号平方结果
    wire [15:0] new_sq = sq_signed[15:0];                      // 最大约为(255 - 75)^2 = 32400

    //==========================================================================
    // 2. 平方值循环缓存（256 x 16位）
    //    由Quartus推断为altsyncram / M9K。
    //    读：READ_OLD状态下异步（组合）读
    //    写：WRITE_NEW状态下同步写
    //==========================================================================
    reg [15:0] sq_buffer [0:255];
    reg [7:0]  wr_ptr;
    reg [7:0]  rd_ptr;

    //==========================================================================
    // 3. 累加器与填充控制
    //    最大和 = 256 * 32400 = 8,294,400 < 2^24，因此24位足够。
    //==========================================================================
    reg [23:0] sum_sq;
    reg [8:0]  fill_cnt;         // 0~256；fill_cnt[8]表示缓存已填满
    wire       buffer_full = fill_cnt[8];

    //==========================================================================
    // 4. 状态机
    //==========================================================================
    localparam IDLE        = 3'd0;
    localparam READ_OLD    = 3'd1;
    localparam UPDATE_SUM  = 3'd2;
    localparam WRITE_NEW   = 3'd3;
    localparam ISQRT_START = 3'd4;
    localparam ISQRT_WAIT  = 3'd5;
    localparam OUTPUT_RMS  = 3'd6;

    reg [2:0]  state;
    reg [15:0] old_sq;
    reg [15:0] mean_val;
    reg [23:0] next_sum_sq;
    reg        isqrt_start;

    wire [7:0] isqrt_result;
    wire       isqrt_done;

    //==========================================================================
    // 5. 整数平方根实例（16位输入，8位输出）
    //==========================================================================
    isqrt_16bit u_isqrt (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (isqrt_start),
        .din    (mean_val),
        .dout   (isqrt_result),
        .done   (isqrt_done)
    );

    assign debug_mean = mean_val;

    //==========================================================================
    // 6. 主状态机
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            wr_ptr      <= 8'd0;
            rd_ptr      <= 8'd0;
            sum_sq      <= 24'd0;
            fill_cnt    <= 9'd0;
            rms_value   <= 8'd0;
            rms_valid   <= 1'b0;
            isqrt_start <= 1'b0;
            old_sq      <= 16'd0;
            mean_val    <= 16'd0;
            next_sum_sq <= 24'd0;
            sample_data <= 8'd127;
        end else begin
            rms_valid   <= 1'b0;
            isqrt_start <= 1'b0;

            case (state)
                //--------------------------------------------------------------
                // IDLE：等待采样触发
                //--------------------------------------------------------------
                IDLE: begin
                    if (sample_trig) begin
                        sample_data <= adc_data;
                        state       <= READ_OLD;
                        rd_ptr      <= wr_ptr;   // 最旧采样位于当前wr_ptr
                    end
                end

                //--------------------------------------------------------------
                // READ_OLD：从缓存中取出最旧平方值
                //--------------------------------------------------------------
                READ_OLD: begin
                    if (buffer_full)
                        old_sq <= sq_buffer[rd_ptr];
                    else
                        old_sq <= 16'd0;    // 缓存尚未填满，无需扣除旧值
                    state <= UPDATE_SUM;
                end

                //--------------------------------------------------------------
                // UPDATE_SUM：滑动窗口累加
                //--------------------------------------------------------------
                UPDATE_SUM: begin
                    if (buffer_full) begin
                        next_sum_sq <= sum_sq - old_sq + new_sq;
                        sum_sq      <= sum_sq - old_sq + new_sq;
                    end else begin
                        next_sum_sq <= sum_sq + new_sq;
                        sum_sq      <= sum_sq + new_sq;
                    end
                    state <= WRITE_NEW;
                end

                //--------------------------------------------------------------
                // WRITE_NEW：写入新采样，推进指针并计算均值
                //--------------------------------------------------------------
                WRITE_NEW: begin
                    sq_buffer[wr_ptr] <= new_sq;
                    wr_ptr <= wr_ptr + 1'b1;

                    if (!buffer_full)
                        fill_cnt <= fill_cnt + 1'b1;

                    mean_val <= next_sum_sq[23:8];  // 除以256（右移8位）
                    state <= ISQRT_START;
                end

                //--------------------------------------------------------------
                // ISQRT_START：启动整数平方根计算
                //--------------------------------------------------------------
                ISQRT_START: begin
                    isqrt_start <= 1'b1;
                    state <= ISQRT_WAIT;
                end

                //--------------------------------------------------------------
                // ISQRT_WAIT：等待平方根计算完成（8个周期）
                //--------------------------------------------------------------
                ISQRT_WAIT: begin
                    if (isqrt_done)
                        state <= OUTPUT_RMS;
                end

                //--------------------------------------------------------------
                // OUTPUT_RMS：锁存结果并产生有效脉冲
                //--------------------------------------------------------------
                OUTPUT_RMS: begin
                    rms_value <= isqrt_result;
                    rms_valid <= buffer_full;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
