//==============================================================================
// 模块：dac081s101_driver
// 说明：DAC081S101的SPI驱动（8位、1.6MSPS）
//       SCLK = 6.25MHz（50MHz / 8）
//       帧格式：16个SCLK周期（4位控制 + 8位数据 + 4位无关）
//       DAC在SCLK下降沿锁存Din。本模块在上升沿更新Din，
//       保证数据在随后的下降沿前已经稳定。
//==============================================================================

module dac081s101_driver (
    input  wire        clk,          // 50MHz系统时钟
    input  wire        rst_n,        // 低电平有效复位
    input  wire        dac_trig,     // 高电平触发一次转换
    input  wire [7:0]  dac_data,     // 待输出的8位数据
    output reg         dac_busy,     // 转换过程中保持高电平
    
    // DAC081S101 SPI接口
    output reg         dac_sync_n,   // 片选，低电平有效
    output reg         dac_sclk,     // SPI时钟
    output reg         dac_sdi       // 串行数据输出（MOSI）
);

    //==========================================================================
    // 状态机
    //==========================================================================
    localparam IDLE     = 3'b000;
    localparam CS_SETUP = 3'b001;  // 第一个SCLK前的CS低电平建立
    localparam TRANSFER = 3'b010;  // 16个SCLK周期传输
    localparam CS_HOLD  = 3'b011;  // 最后一个SCLK后的CS高电平保持
    localparam FINISH   = 3'b100;

    // 时钟分频：50MHz / 8 = 6.25MHz SCLK
    localparam SCLK_DIV_MAX = 4'd7;  // 0~7
    localparam SCLK_RISE    = 4'd3;  // SCLK拉高时刻

    //==========================================================================
    // 内部寄存器
    //==========================================================================
    reg [2:0]  state;
    reg [3:0]  clk_div;     // 0~7分频计数器
    reg [4:0]  bit_cnt;     // 0~15位计数器
    reg [15:0] shift_reg;   // SPI移位寄存器

    //==========================================================================
    // 主状态机
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            dac_sync_n <= 1'b1;
            dac_sclk   <= 1'b0;
            dac_sdi    <= 1'b0;
            dac_busy   <= 1'b0;
            clk_div    <= 4'd0;
            bit_cnt    <= 5'd0;
            shift_reg  <= 16'd0;
        end else begin
            case (state)
                //--------------------------------------------------------------
                // IDLE：等待dac_trig触发
                //--------------------------------------------------------------
                IDLE: begin
                    dac_sync_n <= 1'b1;
                    dac_sclk   <= 1'b0;
                    dac_busy   <= 1'b0;
                    clk_div    <= 4'd0;
                    bit_cnt    <= 5'd0;
                    
                    if (dac_trig) begin
                        state      <= CS_SETUP;
                        dac_sync_n <= 1'b0;   // 拉低SYNC
                        dac_busy   <= 1'b1;
                        // 帧格式：4'b0000 + dac_data + 4'b0000
                        shift_reg  <= {4'b0000, dac_data, 4'b0000};
                    end
                end
                
                //--------------------------------------------------------------
                // CS_SETUP：第一个时钟前等待一个完整SCLK周期，
                //           同时将首位（MSB）预装到dac_sdi。
                //--------------------------------------------------------------
                CS_SETUP: begin
                    if (clk_div == SCLK_DIV_MAX) begin
                        clk_div <= 4'd0;
                        state   <= TRANSFER;
                        dac_sdi <= shift_reg[15];  // 预装MSB
                    end else begin
                        clk_div <= clk_div + 1'b1;
                    end
                end
                
                //--------------------------------------------------------------
                // TRANSFER：准确产生16个SCLK周期。
                //   DAC在SCLK下降沿采样Din。本模块在上升沿更新dac_sdi，
                //   并在每个下降沿期间保持不变，以满足DAC输入保持时间。
                //--------------------------------------------------------------
                TRANSFER: begin
                    if (clk_div == SCLK_DIV_MAX) begin
                        // 下降沿：DAC锁存前一个上升沿给出的数据位，
                        // 此处不改变dac_sdi。
                        clk_div  <= 4'd0;
                        dac_sclk <= 1'b0;
                        
                        if (bit_cnt == 5'd15) begin
                            // 16位传输完成
                            state   <= CS_HOLD;
                            bit_cnt <= 5'd0;
                        end else begin
                            bit_cnt   <= bit_cnt + 1'b1;
                            shift_reg <= {shift_reg[14:0], 1'b0};
                        end
                    end else begin
                        clk_div <= clk_div + 1'b1;
                        
                        // 上升沿：给出下一位数据。DAC锁存前，
                        // 该位会稳定保持半个SCLK周期。
                        if (clk_div == SCLK_RISE) begin
                            dac_sclk <= 1'b1;
                            dac_sdi  <= shift_reg[15];
                        end
                    end
                end
                
                //--------------------------------------------------------------
                // CS_HOLD：拉高SYNC前等待一个完整SCLK周期
                //--------------------------------------------------------------
                CS_HOLD: begin
                    dac_sclk <= 1'b0;
                    dac_sdi  <= 1'b0;
                    if (clk_div == SCLK_DIV_MAX) begin
                        clk_div    <= 4'd0;
                        state      <= FINISH;
                        dac_sync_n <= 1'b1;   // 拉高SYNC
                    end else begin
                        clk_div <= clk_div + 1'b1;
                    end
                end
                
                //--------------------------------------------------------------
                // FINISH：清除busy并返回IDLE
                //--------------------------------------------------------------
                FINISH: begin
                    dac_busy <= 1'b0;
                    state    <= IDLE;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
