//==============================================================================
// 模块：i2c_master
// 说明：AT24C02用I2C主机（100kHz，写周期5ms）
//   SCL = M4，SDA = P3（开漏，外部上拉）
//   接口流程：cmd_start -> 命令传输 -> ... -> 停止
//   字节级操作：写字节/读字节，并检测ACK
//   5ms延迟：50MHz下250,000个周期，写停止后自动插入
//==============================================================================

module i2c_master (
    input  wire        clk,          // 50MHz
    input  wire        rst_n,
    inout  wire        i2c_scl,       // M4
    inout  wire        i2c_sda,       // P3
    
    // 命令接口
    input  wire        cmd_start,     // 启动一次事务的脉冲
    input  wire [7:0]  cmd_dev_addr,  // 7位器件地址 + R/W位
    input  wire [7:0]  cmd_reg_addr,  // AT24C02内部存储地址
    input  wire        cmd_has_reg,   // 本次事务是否包含寄存器/存储地址
    input  wire        cmd_rw,        // 0=写，1=读
    input  wire [7:0]  cmd_wdata,     // 写入数据字节
    output reg  [7:0]  cmd_rdata,     // 读出数据字节
    output reg         cmd_ack_err,   // 从机NACK时置高
    output reg         cmd_done,      // 事务完成时产生脉冲
    input  wire        cmd_next       // 突发传输中进入下一字节的脉冲
);

    //==========================================================================
    // I2C时序：100kHz -> 500周期/bit（4倍细分：每1/4 bit为125周期）
    //==========================================================================
    localparam QUARTER = 8'd125;     // 每1/4 bit为125周期
    localparam HALF    = 8'd250;    // 每半bit为250周期
    localparam FULL    = 9'd500;   // 每bit为500周期

    //==========================================================================
    // SCL/SDA控制（开漏：0=拉低，1=释放/高阻）
    //==========================================================================
    reg scl_out, sda_out;
    wire sda_in;

    assign i2c_scl = scl_out ? 1'bz : 1'b0;
    assign i2c_sda = sda_out ? 1'bz : 1'b0;
    assign sda_in  = i2c_sda;

    //==========================================================================
    // 状态机
    //==========================================================================
    localparam IDLE      = 4'd0;
    localparam START_1   = 4'd1;
    localparam START_2   = 4'd2;
    localparam TX_BYTE   = 4'd3;
    localparam RX_ACK    = 4'd4;
    localparam RX_BYTE   = 4'd5;
    localparam TX_NACK   = 4'd6;
    localparam STOP_1    = 4'd7;
    localparam STOP_2    = 4'd8;
    localparam WAIT_5MS  = 4'd9;
    localparam DONE      = 4'd10;

    localparam STEP_DEV   = 2'd0;
    localparam STEP_REG   = 2'd1;
    localparam STEP_DATA  = 2'd2;
    localparam STEP_DEV_R = 2'd3;

    reg [3:0]  state;
    reg [8:0]  bit_timer;
    reg [3:0]  bit_cnt;
    reg [7:0]  shift_reg;
    reg [7:0]  dev_wr;
    reg [7:0]  dev_rd;
    reg [7:0]  reg_addr;
    reg [7:0]  data_latch;
    reg        has_reg;
    reg        rw_flag;
    reg [1:0]  tx_step;
    reg [17:0] wait_cnt;   // 5ms = 250,000周期

    //==========================================================================
    // 主状态机
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            scl_out     <= 1'b1;
            sda_out     <= 1'b1;
            bit_timer   <= 9'd0;
            bit_cnt     <= 4'd0;
            shift_reg   <= 8'd0;
            dev_wr      <= 8'hA0;
            dev_rd      <= 8'hA1;
            reg_addr    <= 8'd0;
            data_latch  <= 8'd0;
            has_reg     <= 1'b0;
            rw_flag     <= 1'b0;
            tx_step     <= STEP_DEV;
            cmd_done    <= 1'b0;
            cmd_ack_err <= 1'b0;
            cmd_rdata   <= 8'd0;
            wait_cnt    <= 18'd0;
        end else begin
            cmd_done <= 1'b0;

            case (state)
                IDLE: begin
                    scl_out   <= 1'b1;
                    sda_out   <= 1'b1;
                    bit_timer <= 9'd0;
                    bit_cnt   <= 4'd0;
                    if (cmd_start) begin
                        dev_wr      <= {cmd_dev_addr[7:1], 1'b0};
                        dev_rd      <= {cmd_dev_addr[7:1], 1'b1};
                        reg_addr    <= cmd_reg_addr;
                        data_latch  <= cmd_wdata;
                        has_reg     <= cmd_has_reg;
                        rw_flag     <= cmd_rw;
                        tx_step     <= STEP_DEV;
                        cmd_ack_err <= 1'b0;
                        state       <= START_1;
                    end
                end

                // 总线空闲/重复起始准备：先释放两根线。
                START_1: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1;
                    if (bit_timer == HALF - 1'b1) begin
                        bit_timer <= 9'd0;
                        state <= START_2;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                // 产生START条件，然后装载tx_step选择的字节。
                START_2: begin
                    sda_out <= 1'b0;
                    if (bit_timer == HALF - 1'b1) begin
                        bit_timer <= 9'd0;
                        bit_cnt <= 4'd0;
                        scl_out <= 1'b0;
                        state <= TX_BYTE;
                        case (tx_step)
                            STEP_DEV:   shift_reg <= (has_reg || !rw_flag) ? dev_wr : dev_rd;
                            STEP_REG:   shift_reg <= reg_addr;
                            STEP_DATA:  shift_reg <= data_latch;
                            STEP_DEV_R: shift_reg <= dev_rd;
                        endcase
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                // 发送一个字节，MSB先发。
                TX_BYTE: begin
                    if (bit_timer == 9'd0)
                        sda_out <= shift_reg[7];

                    if (bit_timer == QUARTER - 1'b1) begin
                        scl_out <= 1'b1;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == HALF + QUARTER - 1'b1) begin
                        scl_out <= 1'b0;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == FULL - 1'b1) begin
                        bit_timer <= 9'd0;
                        shift_reg <= {shift_reg[6:0], 1'b0};
                        if (bit_cnt == 4'd7) begin
                            bit_cnt <= 4'd0;
                            state <= RX_ACK;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                // 释放SDA并采样从机ACK。
                RX_ACK: begin
                    if (bit_timer == 9'd0)
                        sda_out <= 1'b1;

                    if (bit_timer == QUARTER - 1'b1) begin
                        scl_out <= 1'b1;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == HALF + QUARTER - 1'b1) begin
                        if (sda_in)
                            cmd_ack_err <= 1'b1;
                        scl_out <= 1'b0;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == FULL - 1'b1) begin
                        bit_timer <= 9'd0;
                        bit_cnt <= 4'd0;
                        if (cmd_ack_err || sda_in) begin
                            state <= STOP_1;
                        end else begin
                            case (tx_step)
                                STEP_DEV: begin
                                    if (has_reg) begin
                                        tx_step <= STEP_REG;
                                        shift_reg <= reg_addr;
                                        state <= TX_BYTE;
                                    end else if (rw_flag) begin
                                        state <= RX_BYTE;
                                    end else begin
                                        tx_step <= STEP_DATA;
                                        shift_reg <= data_latch;
                                        state <= TX_BYTE;
                                    end
                                end
                                STEP_REG: begin
                                    if (rw_flag) begin
                                        tx_step <= STEP_DEV_R;
                                        state <= START_1;  // 随机读需要重复起始
                                    end else begin
                                        tx_step <= STEP_DATA;
                                        shift_reg <= data_latch;
                                        state <= TX_BYTE;
                                    end
                                end
                                STEP_DATA: begin
                                    state <= STOP_1;
                                end
                                STEP_DEV_R: begin
                                    state <= RX_BYTE;
                                end
                            endcase
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                // 接收一个字节，MSB先收。
                RX_BYTE: begin
                    if (bit_timer == 9'd0)
                        sda_out <= 1'b1;

                    if (bit_timer == QUARTER - 1'b1) begin
                        scl_out <= 1'b1;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == HALF + QUARTER - 1'b1) begin
                        shift_reg <= {shift_reg[6:0], sda_in};
                        if (bit_cnt == 4'd7)
                            cmd_rdata <= {shift_reg[6:0], sda_in};
                        scl_out <= 1'b0;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == FULL - 1'b1) begin
                        bit_timer <= 9'd0;
                        if (bit_cnt == 4'd7) begin
                            bit_cnt <= 4'd0;
                            state <= TX_NACK;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                // 单字节读以NACK结束。
                TX_NACK: begin
                    if (bit_timer == 9'd0)
                        sda_out <= 1'b1;

                    if (bit_timer == QUARTER - 1'b1) begin
                        scl_out <= 1'b1;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == HALF + QUARTER - 1'b1) begin
                        scl_out <= 1'b0;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == FULL - 1'b1) begin
                        bit_timer <= 9'd0;
                        state <= STOP_1;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                // STOP条件：SDA先拉低，释放SCL后再释放SDA。
                STOP_1: begin
                    if (bit_timer == 9'd0) begin
                        sda_out <= 1'b0;
                        scl_out <= 1'b0;
                    end

                    if (bit_timer == QUARTER - 1'b1) begin
                        scl_out <= 1'b1;
                        bit_timer <= bit_timer + 1'b1;
                    end else if (bit_timer == HALF - 1'b1) begin
                        bit_timer <= 9'd0;
                        state <= STOP_2;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                STOP_2: begin
                    if (bit_timer == QUARTER - 1'b1)
                        sda_out <= 1'b1;

                    if (bit_timer == HALF - 1'b1) begin
                        bit_timer <= 9'd0;
                        if (!rw_flag && !cmd_ack_err) begin
                            wait_cnt <= 18'd250000;
                            state <= WAIT_5MS;
                        end else begin
                            state <= DONE;
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                WAIT_5MS: begin
                    if (wait_cnt == 18'd0) begin
                        state <= DONE;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                DONE: begin
                    cmd_done <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
