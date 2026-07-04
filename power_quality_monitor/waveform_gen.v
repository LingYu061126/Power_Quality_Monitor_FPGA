//==============================================================================
// 模块：waveform_gen
// 说明：带故障注入功能的DDS正弦波发生器
//==============================================================================

module waveform_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_trig,
    input  wire [2:0]  fault_mode,
    input  wire [7:0]  amplitude,
    output reg  [7:0]  wave_out,
    output wire        wave_valid
);

    //==========================================================================
    // DDS相位累加器
    //==========================================================================
    localparam F_50HZ   = 32'd21474836;
    localparam F_50_5HZ = 32'd21679585;
    localparam F_49_5HZ = 32'd21270087;
    localparam F_150HZ  = 32'd64424509;

    reg [31:0] phase_acc;
    reg [31:0] phase_acc_h;

    wire [7:0] addr  = phase_acc[31:24];
    wire [7:0] addr_h = phase_acc_h[31:24];

    //==========================================================================
    // 可综合正弦查找表
    //   本工程中Quartus对$readmemh ROM推断优化异常，因此DDS改用
    //   四分之一波形表配合对称关系生成完整正弦。
    //==========================================================================
    function [6:0] qsin_lut;
        input [6:0] idx;
        begin
            case (idx)
                7'd0:  qsin_lut = 7'd0;
                7'd1:  qsin_lut = 7'd3;
                7'd2:  qsin_lut = 7'd6;
                7'd3:  qsin_lut = 7'd9;
                7'd4:  qsin_lut = 7'd12;
                7'd5:  qsin_lut = 7'd16;
                7'd6:  qsin_lut = 7'd19;
                7'd7:  qsin_lut = 7'd22;
                7'd8:  qsin_lut = 7'd25;
                7'd9:  qsin_lut = 7'd28;
                7'd10: qsin_lut = 7'd31;
                7'd11: qsin_lut = 7'd34;
                7'd12: qsin_lut = 7'd37;
                7'd13: qsin_lut = 7'd40;
                7'd14: qsin_lut = 7'd43;
                7'd15: qsin_lut = 7'd46;
                7'd16: qsin_lut = 7'd49;
                7'd17: qsin_lut = 7'd51;
                7'd18: qsin_lut = 7'd54;
                7'd19: qsin_lut = 7'd57;
                7'd20: qsin_lut = 7'd60;
                7'd21: qsin_lut = 7'd63;
                7'd22: qsin_lut = 7'd65;
                7'd23: qsin_lut = 7'd68;
                7'd24: qsin_lut = 7'd71;
                7'd25: qsin_lut = 7'd73;
                7'd26: qsin_lut = 7'd76;
                7'd27: qsin_lut = 7'd78;
                7'd28: qsin_lut = 7'd81;
                7'd29: qsin_lut = 7'd83;
                7'd30: qsin_lut = 7'd85;
                7'd31: qsin_lut = 7'd88;
                7'd32: qsin_lut = 7'd90;
                7'd33: qsin_lut = 7'd92;
                7'd34: qsin_lut = 7'd94;
                7'd35: qsin_lut = 7'd96;
                7'd36: qsin_lut = 7'd98;
                7'd37: qsin_lut = 7'd100;
                7'd38: qsin_lut = 7'd102;
                7'd39: qsin_lut = 7'd104;
                7'd40: qsin_lut = 7'd106;
                7'd41: qsin_lut = 7'd107;
                7'd42: qsin_lut = 7'd109;
                7'd43: qsin_lut = 7'd111;
                7'd44: qsin_lut = 7'd112;
                7'd45: qsin_lut = 7'd113;
                7'd46: qsin_lut = 7'd115;
                7'd47: qsin_lut = 7'd116;
                7'd48: qsin_lut = 7'd117;
                7'd49: qsin_lut = 7'd118;
                7'd50: qsin_lut = 7'd120;
                7'd51: qsin_lut = 7'd121;
                7'd52: qsin_lut = 7'd122;
                7'd53: qsin_lut = 7'd122;
                7'd54: qsin_lut = 7'd123;
                7'd55: qsin_lut = 7'd124;
                7'd56: qsin_lut = 7'd125;
                7'd57: qsin_lut = 7'd125;
                7'd58: qsin_lut = 7'd126;
                7'd59: qsin_lut = 7'd126;
                7'd60: qsin_lut = 7'd126;
                7'd61: qsin_lut = 7'd127;
                7'd62: qsin_lut = 7'd127;
                7'd63: qsin_lut = 7'd127;
                7'd64: qsin_lut = 7'd127;
                default: qsin_lut = 7'd127;
            endcase
        end
    endfunction

    function signed [8:0] sine_signed;
        input [7:0] phase;
        reg [6:0] mag;
        begin
            case (phase[7:6])
                2'b00: mag = qsin_lut({1'b0, phase[5:0]});
                2'b01: mag = qsin_lut(7'd64 - {1'b0, phase[5:0]});
                2'b10: mag = qsin_lut({1'b0, phase[5:0]});
                default: mag = qsin_lut(7'd64 - {1'b0, phase[5:0]});
            endcase
            sine_signed = phase[7] ? -$signed({2'b00, mag}) : $signed({2'b00, mag});
        end
    endfunction

    // 所有模式下均按 amplitude/128 缩放有符号正弦值。
    wire signed [8:0]  signed_base_raw = sine_signed(addr);
    wire signed [17:0] signed_base_mult = signed_base_raw * $signed({1'b0, amplitude});
    wire signed [17:0] signed_base_scaled = signed_base_mult >>> 7;
    wire signed [8:0]  signed_base = signed_base_scaled[8:0];

    wire signed [8:0]  signed_harm_raw = sine_signed(addr_h);
    wire signed [17:0] signed_harm_mult = signed_harm_raw * $signed({1'b0, amplitude});
    wire signed [17:0] signed_harm_scaled = signed_harm_mult >>> 7;
    wire signed [8:0]  signed_harm = signed_harm_scaled[8:0];

    //==========================================================================
    // 调制与故障注入
    //==========================================================================
    reg signed [9:0] modulated;

    // 算术右移辅助量
    wire signed [8:0] signed_base_div2 = {signed_base[8], signed_base[8:1]};
    wire signed [9:0] signed_harm_div4 = {signed_harm[8], signed_harm[8], signed_harm[8:2]};
    wire signed [8:0] clip_limit = $signed({1'b0, (amplitude >> 1) + (amplitude >> 3)});

    always @(*) begin
        case (fault_mode)
            3'b001:  modulated = signed_base_div2;                          // 暂降（50%幅值）
            3'b010:  modulated = signed_base + signed_base_div2;            // 暂升（150%幅值）
            3'b011:  modulated = signed_base;                              // 过频（幅值不变）
            3'b100:  modulated = signed_base;                              // 欠频（幅值不变）
            3'b101:  begin                                                   // 削顶故障
                if (signed_base > clip_limit)
                    modulated = clip_limit;
                else if (signed_base < -clip_limit)
                    modulated = -clip_limit;
                else
                    modulated = signed_base;
            end
            3'b110:  modulated = signed_base - signed_harm_div4;            // 谐波畸变
            default: modulated = signed_base;                               // 正常
        endcase
    end

    //==========================================================================
    // 限幅到0~255范围
    //==========================================================================
    wire signed [9:0] clipped = (modulated > $signed(10'sd127)) ? $signed(10'sd127) :
                                (modulated < -$signed(10'sd127)) ? -$signed(10'sd127) :
                                modulated;

       //==========================================================================
    // 输出寄存器，带0~255硬限幅
    //==========================================================================
    wire signed [10:0] final_val = $signed(11'sd128) + $signed({clipped[9], clipped});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc   <= 32'd0;
            phase_acc_h <= 32'd0;
            wave_out    <= 8'd128;
        end else if (sample_trig) begin
            case (fault_mode)
                3'b011:  phase_acc <= phase_acc + F_50_5HZ;
                3'b100:  phase_acc <= phase_acc + F_49_5HZ;
                default: phase_acc <= phase_acc + F_50HZ;
            endcase
            phase_acc_h <= phase_acc_h + F_150HZ;

            // 硬限幅到 0~255，防止负数截断
            if (final_val > 11'd255)
                wave_out <= 8'd255;
            else if (final_val < 11'd0)
                wave_out <= 8'd0;
            else
                wave_out <= final_val[7:0];
        end
    end

    assign wave_valid = sample_trig;

endmodule
