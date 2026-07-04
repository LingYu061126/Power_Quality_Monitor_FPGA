//==============================================================================
// 模块：freq_detector
// 说明：带滞回的过零频率检测器
//   - 滞回：采样值必须越过校准ADC中点的上下阈值
//   - 输出：period_cnt = 相邻正向过零之间的采样点数
//            50Hz -> 约200，50.5Hz -> 约198，49.5Hz -> 约202
//   - 同时输出zero_cross脉冲，可用于峰值检测同步
//==============================================================================

module freq_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_trig,     // 10kHz采样脉冲
    input  wire [7:0]  adc_data,        // 无符号ADC采样
    input  wire [7:0]  adc_center,      // 校准后的ADC零点
    output reg  [15:0] period_cnt,      // 以采样点数表示的周期
    output reg         period_valid,    // 每个周期产生一个单周期脉冲
    output reg         zero_cross       // 正向过零脉冲
);

    //==========================================================================
    // 有符号转换与滞回阈值
    //==========================================================================
    wire signed [8:0] adc_center_signed = $signed({1'b0, adc_center});
    wire signed [8:0] adc_signed = $signed({1'b0, adc_data}) - adc_center_signed;
    // 滞回规则：先低于-15，再高于+15，才计为一次正向过零。

    //==========================================================================
    // 状态机
    //==========================================================================
    localparam WAIT_LOW  = 2'd0;   // 等待信号低于-15
    localparam WAIT_HIGH = 2'd1;   // 等待信号高于+15
    localparam WAIT_LOW2 = 2'd2;   // 正向过零后，等待负向越过阈值

    reg [1:0] zc_state;
    reg [15:0] cnt;

    //==========================================================================
    // 主逻辑
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            period_cnt  <= 16'd0;
            period_valid<= 1'b0;
            zero_cross  <= 1'b0;
            cnt         <= 16'd0;
            zc_state    <= WAIT_LOW;
        end else if (sample_trig) begin
            // 默认输出
            period_valid <= 1'b0;
            zero_cross   <= 1'b0;
            cnt          <= cnt + 1'b1;

            case (zc_state)
                //----------------------------------------------------------
                // WAIT_LOW：信号低于-15后使能检测器
                //----------------------------------------------------------
                WAIT_LOW: begin
                    if (adc_signed < -15) begin
                        zc_state <= WAIT_HIGH;
                    end
                end

                //----------------------------------------------------------
                // WAIT_HIGH：检测正向过零
                //----------------------------------------------------------
                WAIT_HIGH: begin
                    if (adc_signed > 15) begin
                        zc_state    <= WAIT_LOW2;
                        zero_cross  <= 1'b1;
                        period_cnt  <= cnt;
                        period_valid<= 1'b1;
                        cnt         <= 16'd1;  // 复位计数，并将当前采样记为1
                    end
                end

                //----------------------------------------------------------
                // WAIT_LOW2：等待负向越过阈值，完成一次循环准备
                //----------------------------------------------------------
                WAIT_LOW2: begin
                    if (adc_signed < -15) begin
                        zc_state <= WAIT_HIGH;
                    end
                end

                default: zc_state <= WAIT_LOW;
            endcase
        end
    end

endmodule
