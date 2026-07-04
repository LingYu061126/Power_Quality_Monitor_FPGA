//==============================================================================
// 模块：freeze_controller
// 说明：波形冻结控制，解除冻结后带锁定冷却时间
//==============================================================================

module freeze_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_trig,
    input  wire [7:0]  adc_data,
    input  wire        alarm_trigger,
    input  wire [2:0]  fault_type,
    input  wire        read_next,
    input  wire        unfreeze_trig,
    output reg  [9:0]  wr_addr,
    output reg  [7:0]  wr_data,
    output reg         wr_en,
    output reg  [9:0]  rd_addr,
    output reg         freeze_active,
    output reg  [9:0]  trigger_addr,
    output reg  [2:0]  fault_type_latch
);

    localparam RUNNING   = 2'd0;
    localparam POST_TRIG = 2'd1;
    localparam FROZEN    = 2'd2;

    localparam LOCKOUT_TIME = 16'd5000;  // 10kHz下500ms
    localparam DISPLAY_SAMPLES = 10'd200;
    localparam PRE_TRIGGER_SAMPLES = 10'd100;

    reg [1:0]  state;
    reg [9:0]  wr_ptr;
    reg [9:0]  post_cnt;
    reg [15:0] lockout_cnt;
    reg        lockout_active;
    reg [9:0]  display_start_addr;
    reg [9:0]  frozen_start_addr;
    reg        read_next_d;

    wire       read_start = read_next & ~read_next_d;

    //==========================================================================
    // 主状态机
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= RUNNING;
            wr_ptr         <= 10'd0;
            post_cnt       <= 10'd0;
            trigger_addr   <= 10'd0;
            fault_type_latch<= 3'd0;
            freeze_active  <= 1'b0;
            wr_en          <= 1'b0;
            wr_addr        <= 10'd0;
            wr_data        <= 8'd0;
            rd_addr        <= 10'd0;
            lockout_cnt    <= 16'd0;
            lockout_active <= 1'b0;
            display_start_addr <= 10'd0;
            frozen_start_addr  <= 10'd0;
            read_next_d    <= 1'b0;
        end else begin
            read_next_d <= read_next;

            case (state)
                //--------------------------------------------------------------
                // RUNNING：自由运行，实时读写
                //--------------------------------------------------------------
                RUNNING: begin
                    wr_en         <= 1'b0;
                    freeze_active <= 1'b0;

                    // 解除冻结后的锁定倒计时
                    if (lockout_active) begin
                        if (sample_trig && lockout_cnt > 16'd0)
                            lockout_cnt <= lockout_cnt - 1'b1;
                        else if (lockout_cnt == 16'd0)
                            lockout_active <= 1'b0;
                    end else if (alarm_trigger) begin
                        state          <= POST_TRIG;
                        trigger_addr   <= wr_ptr;
                        post_cnt       <= 10'd0;
                        fault_type_latch<= fault_type;
                    end

                    if (sample_trig) begin
                        wr_en   <= 1'b1;
                        wr_ptr  <= wr_ptr + 1'b1;
                        wr_addr <= wr_ptr;
                        wr_data <= adc_data;
                        display_start_addr <= wr_ptr - DISPLAY_SAMPLES + 1'b1;
                    end

                    if (read_start) begin
                        rd_addr <= display_start_addr;
                    end else if (read_next) begin
                        rd_addr <= rd_addr + 1'b1;
                    end
                end

                //--------------------------------------------------------------
                // POST_TRIG：触发后继续捕获512个采样
                //--------------------------------------------------------------
                POST_TRIG: begin
                    wr_en <= 1'b0;
                    if (sample_trig) begin
                        wr_en    <= 1'b1;
                        wr_ptr   <= wr_ptr + 1'b1;
                        wr_addr  <= wr_ptr;
                        wr_data  <= adc_data;
                        post_cnt <= post_cnt + 1'b1;
                        if (post_cnt == 10'd511) begin
                            state             <= FROZEN;
                            frozen_start_addr <= trigger_addr - PRE_TRIGGER_SAMPLES;
                            rd_addr           <= trigger_addr - PRE_TRIGGER_SAMPLES;
                        end
                    end
                end

                //--------------------------------------------------------------
                // FROZEN：停止写入，循环回放冻结波形
                //--------------------------------------------------------------
                FROZEN: begin
                    wr_en         <= 1'b0;
                    freeze_active <= 1'b1;
                    if (read_start)
                        rd_addr <= frozen_start_addr;
                    else if (read_next)
                        rd_addr <= rd_addr + 1'b1;
                    if (unfreeze_trig) begin
                        state          <= RUNNING;
                        wr_ptr         <= 10'd0;
                        display_start_addr <= 10'd0;
                        lockout_active <= 1'b1;
                        lockout_cnt    <= LOCKOUT_TIME;
                    end
                end

                default: state <= RUNNING;
            endcase
        end
    end

endmodule
