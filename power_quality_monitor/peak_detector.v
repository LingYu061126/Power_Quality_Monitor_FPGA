//==============================================================================
// 模块：peak_detector
// 说明：带独立过零检测的半周期峰值检测器
//==============================================================================

module peak_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_trig,
    input  wire [7:0]  adc_data,
    input  wire [7:0]  adc_center,
    output reg  [7:0]  peak_value,
    output reg         peak_valid
);

    wire signed [8:0] adc_center_signed = $signed({1'b0, adc_center});
    wire signed [8:0] adc_signed = $signed({1'b0, adc_data}) - adc_center_signed;

    localparam WAIT_LOW  = 2'd0;
    localparam WAIT_HIGH = 2'd1;
    localparam WAIT_LOW2 = 2'd2;

    reg [1:0] zc_state;
    reg [15:0] cnt;

    reg signed [8:0] max_val;
    reg signed [8:0] min_val;

    // 预先计算-min_val，避免对表达式结果进行位选择。
    wire signed [8:0] neg_min_val;
    assign neg_min_val = -min_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            peak_value <= 8'd0;
            peak_valid <= 1'b0;
            max_val    <= 9'sd0;
            min_val    <= 9'sd0;
            zc_state   <= WAIT_LOW;
        end else if (sample_trig) begin
            peak_valid <= 1'b0;

            if (adc_signed > max_val) max_val <= adc_signed;
            if (adc_signed < min_val) min_val <= adc_signed;

            case (zc_state)
                WAIT_LOW: begin
                    if (adc_signed < -15) begin
                        zc_state <= WAIT_HIGH;
                        max_val  <= adc_signed;
                        min_val  <= adc_signed;
                    end
                end

                WAIT_HIGH: begin
                    if (adc_signed > 15) begin
                        zc_state <= WAIT_LOW2;
                        // 使用neg_min_val，避免直接使用(-min_val)[7:0]。
                        peak_value <= (max_val > neg_min_val) ? max_val[7:0] : neg_min_val[7:0];
                        peak_valid <= 1'b1;
                        max_val <= adc_signed;
                        min_val <= adc_signed;
                    end
                end

                WAIT_LOW2: begin
                    if (adc_signed < -15) begin
                        zc_state <= WAIT_HIGH;
                        // 使用neg_min_val，避免直接使用(-min_val)[7:0]。
                        peak_value <= (max_val > neg_min_val) ? max_val[7:0] : neg_min_val[7:0];
                        peak_valid <= 1'b1;
                        max_val <= adc_signed;
                        min_val <= adc_signed;
                    end
                end

                default: zc_state <= WAIT_LOW;
            endcase
        end
    end

endmodule
