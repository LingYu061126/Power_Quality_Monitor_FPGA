//==============================================================================
// 模块：hc595_driver
// 说明：用于八位七段数码管的74HC595级联驱动
//   两片595级联：前8位为段码，后8位为位选（或按硬件相反）
//   SCLK = 12.5MHz（50MHz/4），16位更新耗时约1.28us
//   引脚：RCK=A14，SCK=B13，DIN=B15
//==============================================================================

module hc595_driver (
    input  wire        clk,          // 50MHz
    input  wire        rst_n,
    input  wire [15:0] data,         // {seg[7:0], dig[7:0]}
    input  wire        load,         // 启动移位的脉冲
    output reg         rck,          // 595_RCK (A14)
    output reg         sclk,          // 595_SCK (B13)
    output reg         din,          // 595_DIN (B15)
    output reg         busy
);

    localparam IDLE  = 2'd0;
    localparam SHIFT = 2'd1;
    localparam LATCH = 2'd2;

    reg [1:0]  state;
    reg [4:0]  bit_cnt;
    reg [15:0] shift_reg;
    reg [1:0]  phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            rck     <= 1'b0;
            sclk     <= 1'b0;
            din     <= 1'b0;
            busy    <= 1'b0;
            bit_cnt <= 5'd0;
            phase   <= 2'd0;
        end else begin
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    rck  <= 1'b0;
                    if (load) begin
                        state     <= SHIFT;
                        busy      <= 1'b1;
                        shift_reg <= data;
                        bit_cnt   <= 5'd0;
                        phase     <= 2'd0;
                    end
                end

                SHIFT: begin
                    case (phase)
                        2'd0: begin din <= shift_reg[15]; sclk <= 1'b0; phase <= 2'd1; end
                        2'd1: begin sclk <= 1'b1; phase <= 2'd2; end  // 上升沿采样
                        2'd2: begin shift_reg <= {shift_reg[14:0], 1'b0}; sclk <= 1'b1; phase <= 2'd3; end
                        2'd3: begin
                            sclk <= 1'b0;
                            if (bit_cnt == 5'd15) state <= LATCH;
                            else begin bit_cnt <= bit_cnt + 1'b1; phase <= 2'd0; end
                        end
                    endcase
                end

                LATCH: begin rck <= 1'b1; state <= IDLE; end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
