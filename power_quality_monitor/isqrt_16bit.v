//==============================================================================
// 模块：isqrt_16bit
// 说明：16位无符号输入的整数平方根
//   算法：非恢复型（二进制长除法）平方根
//   延迟：start脉冲后8个时钟周期
//   输出：floor(sqrt(din))，8位无符号
//==============================================================================

module isqrt_16bit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [15:0] din,
    output reg  [7:0]  dout,
    output reg         done
);

    localparam IDLE = 2'd0;
    localparam CALC = 2'd1;
    localparam FIN  = 2'd2;

    reg [1:0]  state;
    reg [15:0] rem;      // 当前余数
    reg [15:0] op;       // 操作数，每次迭代左移2位
    reg [7:0]  root;     // 当前平方根结果
    reg [3:0]  iter;     // 迭代计数器：7 -> 0

    // 单次迭代的组合逻辑
    wire [15:0] rem_shifted = {rem[13:0], op[15:14]};
    wire [15:0] test_val    = {root, 2'b01};          // (root<<2) + 1
    wire        rem_ge_test = rem_shifted >= test_val;
    wire [15:0] rem_next    = rem_ge_test ? (rem_shifted - test_val) : rem_shifted;
    wire [7:0]  root_next   = rem_ge_test ? ({root[6:0], 1'b1}) : ({root[6:0], 1'b0});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done  <= 1'b0;
            dout  <= 8'd0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        state <= CALC;
                        op    <= din;
                        rem   <= 16'd0;
                        root  <= 8'd0;
                        iter  <= 4'd7;      // 共8次迭代
                    end
                end

                CALC: begin
                    op   <= op << 2;
                    rem  <= rem_next;
                    root <= root_next;

                    if (iter == 4'd0)
                        state <= FIN;
                    else
                        iter <= iter - 1'b1;
                end

                FIN: begin
                    dout  <= root;          // root已保存最终结果
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
