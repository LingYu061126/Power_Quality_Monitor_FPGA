//==============================================================================
// 模块：uart_tx
// 说明：UART发送器，115200波特率，8N1格式
//   50MHz / 115200 = 434.027，取434个周期/bit
//   格式：起始位(0) + D0~D7 + 停止位(1)
//==============================================================================

module uart_tx (
    input  wire        clk,          // 50MHz
    input  wire        rst_n,
    input  wire [7:0]  tx_data,
    input  wire        tx_start,     // 发送启动脉冲
    output reg         tx_busy,      // 发送过程中保持高电平
    output reg         txd           // UART发送线
);

    localparam BIT_PERIOD = 9'd434;

    //==========================================================================
    // 状态机
    //==========================================================================
    localparam IDLE  = 2'd0;
    localparam START = 2'd1;
    localparam DATA  = 2'd2;
    localparam STOP  = 2'd3;

    reg [1:0]  state;
    reg [8:0]  bit_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  shift_reg;

    //==========================================================================
    // 主逻辑
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            txd       <= 1'b1;
            tx_busy   <= 1'b0;
            bit_cnt   <= 9'd0;
            bit_idx   <= 4'd0;
            shift_reg <= 8'd0;
        end else begin
            case (state)
                //----------------------------------------------------------
                // IDLE：等待tx_start
                //----------------------------------------------------------
                IDLE: begin
                    txd     <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        state     <= START;
                        tx_busy   <= 1'b1;
                        shift_reg <= tx_data;
                        bit_cnt   <= 9'd0;
                    end
                end

                //----------------------------------------------------------
                // START：发送起始位(0)
                //----------------------------------------------------------
                START: begin
                    txd <= 1'b0;
                    if (bit_cnt == BIT_PERIOD - 1) begin
                        bit_cnt <= 9'd0;
                        state   <= DATA;
                        bit_idx <= 4'd0;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                //----------------------------------------------------------
                // DATA：发送8位数据，低位先发
                //----------------------------------------------------------
                DATA: begin
                    txd <= shift_reg[bit_idx];
                    if (bit_cnt == BIT_PERIOD - 1) begin
                        bit_cnt <= 9'd0;
                        if (bit_idx == 4'd7) begin
                            state <= STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                //----------------------------------------------------------
                // STOP：发送停止位(1)
                //----------------------------------------------------------
                STOP: begin
                    txd <= 1'b1;
                    if (bit_cnt == BIT_PERIOD - 1) begin
                        bit_cnt <= 9'd0;
                        state   <= IDLE;
                        tx_busy <= 1'b0;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
