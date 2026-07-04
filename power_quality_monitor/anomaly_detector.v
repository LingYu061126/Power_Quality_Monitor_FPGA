//==============================================================================
// 模块：anomaly_detector
// 说明：基于阈值的异常检测，支持手动故障模式覆盖
//   手动模式（fault_mode != 0）：直接输出，无延迟
//   自动模式（fault_mode = 0）：10ms一致性确认，避免噪声抖动
//==============================================================================

module anomaly_detector #(
    parameter [7:0]  NOMINAL_RMS = 8'd64,
    parameter [7:0]  SAG_THR     = 8'd58,
    parameter [7:0]  SWELL_THR   = 8'd70,
    parameter [15:0] OVFRQ_THR   = 16'd198,
    parameter [15:0] UNFRQ_THR   = 16'd202,
    parameter [4:0]  CREST_LOW   = 5'd12,
    parameter [4:0]  CREST_HIGH  = 5'd16,
    parameter [9:0]  DEBOUNCE    = 10'd100      // 10kHz下10ms
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_trig,
    input  wire [7:0]  rms_value,
    input  wire        rms_valid,
    input  wire [15:0] period_cnt,
    input  wire        period_valid,
    input  wire [7:0]  peak_value,
    input  wire        peak_valid,
    input  wire [2:0]  fault_mode,
    output reg  [2:0]  fault_type,
    output reg         alarm_trigger,
    output reg         alarm_level
);

    //==========================================================================
    // 峰均比检测
    //==========================================================================
    wire [11:0] peak_x10 = peak_value * 4'd10;
    wire [11:0] rms_x12  = rms_value  * CREST_LOW;
    wire [11:0] rms_x16  = rms_value  * CREST_HIGH;
    wire crest_too_low  = peak_x10 < rms_x12;
    wire crest_too_high = peak_x10 > rms_x16;
    wire clipping       = crest_too_low;
    wire distortion     = crest_too_high;

    //==========================================================================
    // 阈值条件
    //==========================================================================
    wire sag      = rms_value < SAG_THR;
    wire swell    = rms_value > SWELL_THR;
    wire overfreq = period_cnt <= OVFRQ_THR;
    wire underfreq= period_cnt >= UNFRQ_THR;

    //==========================================================================
    // 原始检测结果（组合逻辑，不消抖）
    //==========================================================================
    reg [2:0] detected_fault;
    always @(*) begin
        if (fault_mode != 3'b000)
            detected_fault = fault_mode;       // 手动模式：立即输出
        else if (overfreq && period_valid)
            detected_fault = 3'b011;
        else if (underfreq && period_valid)
            detected_fault = 3'b100;
        else if (sag && rms_valid)
            detected_fault = 3'b001;
        else if (swell && rms_valid)
            detected_fault = 3'b010;
        else if (clipping && peak_valid)
            detected_fault = 3'b101;
        else if (distortion && peak_valid)
            detected_fault = 3'b110;
        else
            detected_fault = 3'b000;
    end

    //==========================================================================
    // 消抖：检测结果持续一致10ms后才更新stable_fault
    //==========================================================================
    reg [2:0]  stable_fault;
    reg [9:0]  debounce_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_fault <= 3'b000;
            debounce_cnt <= 10'd0;
        end else if (sample_trig) begin
            if (fault_mode != 3'b000) begin
                stable_fault <= fault_mode;
                debounce_cnt <= 10'd0;
            end else if (detected_fault == stable_fault) begin
                debounce_cnt <= 10'd0;         // 已稳定，清零计数器
            end else begin
                if (debounce_cnt < DEBOUNCE)
                    debounce_cnt <= debounce_cnt + 1'b1;
                else begin
                    debounce_cnt <= 10'd0;
                    stable_fault <= detected_fault;  // 10ms确认后更新
                end
            end
        end
    end

    //==========================================================================
    // 输出寄存器
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_type    <= 3'b000;
            alarm_trigger <= 1'b0;
            alarm_level   <= 1'b0;
        end else if (sample_trig) begin
            alarm_trigger <= (stable_fault != 3'b000) && (stable_fault != fault_type);
            alarm_level   <= (stable_fault != 3'b000);
            fault_type    <= stable_fault;
        end
    end

endmodule
