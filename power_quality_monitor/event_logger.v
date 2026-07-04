//==============================================================================
// 模块：event_logger
// 说明：基于AT24C02的事件记录器，使用循环FIFO（28条记录 x 8字节）
//   记录格式（8字节）：
//     [0] 事件ID（0~255，溢出回绕）
//     [1] 故障类型（3'bxxx扩展到8位）
//     [2:3] 时间戳（外部16位秒计数，65536秒回绕）
//     [4] 峰值
//     [5] RMS值
//     [6] 频率信息（period_cnt低字节）
//     [7] 持续时间（秒，0~255饱和）
//   写入由alarm_trigger触发。由于简单I2C主机需要完成一次EEPROM写周期
//   后才能接收下一条命令，因此按字节逐个写入。
//   循环缓存：28条记录（0~27），AT24C02地址0x00~0xE0
//==============================================================================

module event_logger (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        alarm_trigger,
    input  wire [2:0]  fault_type,
    input  wire [7:0]  peak_value,
    input  wire [7:0]  rms_value,
    input  wire [7:0]  freq_value,     // period_cnt[7:0]
    input  wire [15:0] timestamp_sec,  // 系统启动后的秒计数
    input  wire        duration_update_trigger,
    input  wire [7:0]  duration_value,
    
    // I2C主机接口
    output reg         i2c_start,
    output reg  [7:0]  i2c_dev_addr,
    output reg  [7:0]  i2c_reg_addr,
    output reg         i2c_has_reg,
    output reg         i2c_rw,
    output reg  [7:0]  i2c_wdata,
    input  wire [7:0]  i2c_rdata,
    input  wire        i2c_ack_err,
    input  wire        i2c_done,
    output reg         i2c_next,
    
    // 状态输出
    output reg  [4:0]  record_count,   // 0~28
    output reg         log_busy
);

    //==========================================================================
    // 循环缓存指针
    //==========================================================================
    reg [4:0]  wr_ptr;       // 0~27
    reg [7:0]  event_id;

    //==========================================================================
    // 状态机
    //==========================================================================
    localparam IDLE           = 3'd0;
    localparam START_BYTE     = 3'd1;
    localparam WAIT_BYTE      = 3'd2;
    localparam INC_PTR        = 3'd3;  // 推进指针
    localparam UPDATE_DURATION= 3'd4;
    localparam WAIT_DURATION  = 3'd5;

    reg [2:0]  state;
    reg [2:0]  byte_cnt;
    reg [7:0]  record_buf [0:7];
    reg [7:0]  current_record_base;
    reg [7:0]  last_record_base;
    reg        have_last_record;
    reg        pending_duration_update;
    reg [7:0]  pending_duration_value;

    //==========================================================================
    // 记录缓存组装与写入控制
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            wr_ptr     <= 5'd0;
            event_id   <= 8'd0;
            record_count<= 5'd0;
            log_busy   <= 1'b0;
            i2c_start  <= 1'b0;
            i2c_dev_addr<= 8'hA0;
            i2c_reg_addr<= 8'd0;
            i2c_has_reg <= 1'b1;
            i2c_rw      <= 1'b0;
            i2c_wdata   <= 8'd0;
            i2c_next    <= 1'b0;
            byte_cnt   <= 3'd0;
            current_record_base <= 8'd0;
            last_record_base <= 8'd0;
            have_last_record <= 1'b0;
            pending_duration_update <= 1'b0;
            pending_duration_value <= 8'd0;
        end else begin
            i2c_start <= 1'b0;
            i2c_next  <= 1'b0;

            if (duration_update_trigger) begin
                pending_duration_update <= 1'b1;
                pending_duration_value  <= duration_value;
            end

            case (state)
                //----------------------------------------------------------
                // IDLE：等待报警触发
                //----------------------------------------------------------
                IDLE: begin
                    log_busy <= 1'b0;
                    if (alarm_trigger) begin
                        log_busy <= 1'b1;
                        current_record_base <= {wr_ptr, 3'b000};
                        // 组装记录
                        record_buf[0] <= event_id;
                        record_buf[1] <= {5'd0, fault_type};
                        record_buf[2] <= timestamp_sec[15:8];
                        record_buf[3] <= timestamp_sec[7:0];
                        record_buf[4] <= peak_value;
                        record_buf[5] <= rms_value;
                        record_buf[6] <= freq_value;
                        record_buf[7] <= 8'd0;  // 故障解除后回写持续时间
                        
                        state <= START_BYTE;
                        byte_cnt <= 3'd0;
                    end else if (duration_update_trigger && have_last_record) begin
                        log_busy <= 1'b1;
                        i2c_dev_addr <= 8'hA0;
                        i2c_reg_addr <= last_record_base + 8'd7;
                        i2c_has_reg  <= 1'b1;
                        i2c_rw       <= 1'b0;
                        i2c_wdata    <= duration_value;
                        i2c_start    <= 1'b1;
                        pending_duration_update <= 1'b0;
                        state <= WAIT_DURATION;
                    end else if (pending_duration_update && have_last_record) begin
                        log_busy <= 1'b1;
                        i2c_dev_addr <= 8'hA0;
                        i2c_reg_addr <= last_record_base + 8'd7;
                        i2c_has_reg  <= 1'b1;
                        i2c_rw       <= 1'b0;
                        i2c_wdata    <= pending_duration_value;
                        i2c_start    <= 1'b1;
                        pending_duration_update <= 1'b0;
                        state <= WAIT_DURATION;
                    end
                end

                //----------------------------------------------------------
                // START_BYTE：启动一次AT24C02随机字节写
                //----------------------------------------------------------
                START_BYTE: begin
                    i2c_dev_addr <= 8'hA0;          // AT24C02写地址
                    i2c_reg_addr <= {wr_ptr, 3'b000} + {5'd0, byte_cnt};
                    i2c_has_reg  <= 1'b1;
                    i2c_rw       <= 1'b0;
                    i2c_wdata    <= record_buf[byte_cnt];
                    i2c_start    <= 1'b1;
                    state        <= WAIT_BYTE;
                end

                //----------------------------------------------------------
                // WAIT_BYTE：等待I2C主机完成该字节写入
                //----------------------------------------------------------
                WAIT_BYTE: begin
                    if (i2c_done) begin
                        if (i2c_ack_err) begin
                            state <= IDLE;
                            log_busy <= 1'b0;
                        end else if (byte_cnt == 3'd7) begin
                            state <= INC_PTR;
                        end else begin
                            byte_cnt <= byte_cnt + 1'b1;
                            state <= START_BYTE;
                        end
                    end
                end

                //----------------------------------------------------------
                // INC_PTR：推进循环缓存指针
                //----------------------------------------------------------
                INC_PTR: begin
                    event_id <= event_id + 1'b1;
                    last_record_base <= current_record_base;
                    have_last_record <= 1'b1;
                    if (wr_ptr < 5'd27)
                        wr_ptr <= wr_ptr + 1'b1;
                    else
                        wr_ptr <= 5'd0;
                    
                    if (record_count < 5'd28)
                        record_count <= record_count + 1'b1;
                    
                    if (pending_duration_update) begin
                        i2c_dev_addr <= 8'hA0;
                        i2c_reg_addr <= current_record_base + 8'd7;
                        i2c_has_reg  <= 1'b1;
                        i2c_rw       <= 1'b0;
                        i2c_wdata    <= pending_duration_value;
                        i2c_start    <= 1'b1;
                        pending_duration_update <= 1'b0;
                        state <= WAIT_DURATION;
                    end else begin
                        log_busy <= 1'b0;
                        state <= IDLE;
                    end
                end

                //----------------------------------------------------------
                // UPDATE_DURATION：回写最近一条事件的持续时间
                //----------------------------------------------------------
                UPDATE_DURATION: begin
                    i2c_dev_addr <= 8'hA0;
                    i2c_reg_addr <= last_record_base + 8'd7;
                    i2c_has_reg  <= 1'b1;
                    i2c_rw       <= 1'b0;
                    i2c_wdata    <= pending_duration_value;
                    i2c_start    <= 1'b1;
                    pending_duration_update <= 1'b0;
                    state <= WAIT_DURATION;
                end

                //----------------------------------------------------------
                // WAIT_DURATION：等待持续时间回写完成
                //----------------------------------------------------------
                WAIT_DURATION: begin
                    if (i2c_done) begin
                        log_busy <= 1'b0;
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
