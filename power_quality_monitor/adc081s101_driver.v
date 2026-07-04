//==============================================================================
// 模块：adc081s101_driver
// 说明：ADC081S101的SPI驱动（8位、1MSPS、单通道）
//       目标平台：MAX10 10M08SAM，50MHz系统时钟
//
//              STEP BaseBoard指导书将ADC081S101描述为SPI模式3：
//              CPOL = 1，CPHA = 1。SCLK空闲为高电平，ADC在SCLK下降沿
//              后更新SDATA，FPGA在上升沿采样SDATA。完整ADC帧包含
//              16个SCLK周期：3个前导0 + DB7..DB0 + 5个尾随0。
//
//              ADC侧以约735ksps连续运行：
//              50MHz / (16 * 4 + 4) = 735.3ksps，SCLK为12.5MHz。
//              sample_trig保持为10kHz系统采样脉冲；每次脉冲到来时，
//              最近一次完整ADC转换结果通过一个data_valid脉冲送给测量模块。
//==============================================================================

module adc081s101_driver (
    input  wire        clk,          // 系统时钟，50MHz
    input  wire        rst_n,        // 低电平有效复位
    input  wire        sample_trig,  // 该脉冲到来时输出最近一次ADC采样
    output reg  [7:0]  adc_data,     // 送往系统层的8位采样值
    output reg         data_valid,   // adc_data就绪时产生一个clk宽度脉冲

    // ADC081S101 SPI接口
    output reg         adc_cs_n,     // 片选，低电平有效
    output reg         adc_sclk,     // SPI时钟，空闲为高电平
    input  wire        adc_sdata     // ADC串行数据输入
);

    //==========================================================================
    // 时序参数
    //==========================================================================
    localparam CS_GAP   = 1'b0;
    localparam TRANSFER = 1'b1;

    // 50MHz / 4 = 12.5MHz SCLK，占空比50%。
    localparam [3:0] SCLK_DIV_MAX  = 4'd3;
    localparam [3:0] SCLK_FALL_DIV = 4'd1;
    localparam [3:0] SCLK_RISE_DIV = 4'd3;
    localparam [4:0] LAST_BIT      = 5'd15;
    localparam [3:0] CS_GAP_LAST   = 4'd3;  // 两帧之间间隔4个clk周期

    //==========================================================================
    // 内部寄存器
    //==========================================================================
    reg        state;
    reg [3:0]  clk_div;
    reg [3:0]  gap_cnt;
    reg [4:0]  bit_cnt;
    reg [15:0] shift_reg;
    reg [7:0]  latest_sample;
    reg        sample_ready;

    wire [15:0] shift_next = {shift_reg[14:0], adc_sdata};

    //==========================================================================
    // 主状态机
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= CS_GAP;
            adc_cs_n      <= 1'b1;
            adc_sclk      <= 1'b1;
            clk_div       <= 4'd0;
            gap_cnt       <= 4'd0;
            bit_cnt       <= 5'd0;
            shift_reg     <= 16'd0;
            latest_sample <= 8'd0;
            sample_ready  <= 1'b0;
            adc_data      <= 8'd0;
            data_valid    <= 1'b0;
        end else begin
            data_valid <= 1'b0;

            if (sample_trig && sample_ready) begin
                adc_data   <= latest_sample;
                data_valid <= 1'b1;
            end

            case (state)
                //--------------------------------------------------------------
                // CS_GAP：短暂取消ADC片选，SCLK保持空闲高电平。
                //--------------------------------------------------------------
                CS_GAP: begin
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b1;
                    clk_div  <= 4'd0;
                    bit_cnt  <= 5'd0;

                    if (gap_cnt == CS_GAP_LAST) begin
                        gap_cnt   <= 4'd0;
                        state     <= TRANSFER;
                        adc_cs_n  <= 1'b0;
                        shift_reg <= 16'd0;
                    end else begin
                        gap_cnt <= gap_cnt + 1'b1;
                    end
                end

                //--------------------------------------------------------------
                // TRANSFER：SPI模式3。下降沿促使ADC更新下一位，
                // 上升沿采样稳定后的数据位。
                //--------------------------------------------------------------
                TRANSFER: begin
                    adc_cs_n <= 1'b0;

                    if (clk_div == SCLK_FALL_DIV)
                        adc_sclk <= 1'b0;

                    if (clk_div == SCLK_RISE_DIV) begin
                        adc_sclk  <= 1'b1;
                        shift_reg <= shift_next;
                        clk_div   <= 4'd0;

                        if (bit_cnt == LAST_BIT) begin
                            latest_sample <= shift_next[12:5];
                            sample_ready  <= 1'b1;
                            state         <= CS_GAP;
                            adc_cs_n      <= 1'b1;
                            bit_cnt       <= 5'd0;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end else begin
                        clk_div <= clk_div + 1'b1;
                    end
                end

                default: begin
                    state    <= CS_GAP;
                    adc_cs_n <= 1'b1;
                    adc_sclk <= 1'b1;
                end
            endcase
        end
    end

endmodule
