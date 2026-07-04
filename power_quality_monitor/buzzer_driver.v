//==============================================================================
// 模块：buzzer_driver
// 说明：PWM蜂鸣器驱动，提示频率按故障类型映射
//   BEEP = B14，高电平有效（实际极性取决于三极管驱动）
//   50MHz时钟下PWM频率：
//     正常/静音：0Hz（关闭）
//     暂降：      1kHz  （周期=50000）
//     暂升：      2kHz  （周期=25000）
//     过频：      3kHz  （周期=16667）
//     欠频：      4kHz  （周期=12500）
//     削顶：      5kHz  （周期=10000）
//     畸变：      6kHz  （周期=8334）
//   占空比：50%
//==============================================================================

module buzzer_driver (
    input  wire        clk,          // 50MHz
    input  wire        rst_n,
    input  wire        alarm_level,   // 高电平表示响铃
    input  wire [2:0]  fault_type,    // 来自anomaly_detector
    output reg         buzzer         // B14
);

    //==========================================================================
    // 频率查找表（半周期计数值）
    //==========================================================================
    reg [15:0] half_period;

    always @(*) begin
        case (fault_type)
            3'b001:  half_period = 16'd25000;  // 暂降：1kHz
            3'b010:  half_period = 16'd12500;  // 暂升：2kHz
            3'b011:  half_period = 16'd8333;   // 过频：约3kHz
            3'b100:  half_period = 16'd6250;   // 欠频：4kHz
            3'b101:  half_period = 16'd5000;   // 削顶：5kHz
            3'b110:  half_period = 16'd4167;   // 畸变：约6kHz
            default: half_period = 16'd0;      // 正常：静音
        endcase
    end

    //==========================================================================
    // PWM发生器
    //==========================================================================
    reg [15:0] cnt;
    reg        pwm_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt       <= 16'd0;
            pwm_state <= 1'b0;
            buzzer    <= 1'b0;
        end else begin
            if (!alarm_level || half_period == 16'd0) begin
                cnt    <= 16'd0;
                buzzer <= 1'b0;
            end else begin
                if (cnt >= half_period - 1) begin
                    cnt       <= 16'd0;
                    pwm_state <= ~pwm_state;
                end else begin
                    cnt <= cnt + 1'b1;
                end
                buzzer <= pwm_state;
            end
        end
    end

endmodule
