//==============================================================================
// 模块：key_scan
// 说明：4x4矩阵键盘扫描器，带10ms扫描周期与消抖
//   扫描速率：每行2.5ms（400Hz），完整矩阵扫描周期10ms
//   消抖：连续3次完整矩阵扫描一致（30ms）后确认
//   输出：key_code（4位，0~15）、key_valid（单周期脉冲）、key_pressed（电平）
//   引脚：ROW为输出，COL为输入（带上拉）
//==============================================================================

module key_scan (
    input  wire        clk,          // 50MHz
    input  wire        rst_n,
    output reg  [3:0]  row,          // ROW1~4行线
    input  wire [3:0]  col,          // COL1~4列线
    output reg  [3:0]  key_code,     // 0~15
    output reg         key_valid,    // 按键确认时产生单周期脉冲
    output reg         key_pressed   // 任意按键保持按下时为高电平
);

    //==========================================================================
    // 扫描时序：50MHz下每行2.5ms = 125,000个周期
    //==========================================================================
    localparam SCAN_INTERVAL = 17'd125000;
    reg [16:0] scan_cnt;
    reg [1:0]  scan_row;     // 0~3行索引

    //==========================================================================
    // 行驱动：低电平有效扫描（每次仅拉低一行）
    //==========================================================================
    always @(*) begin
        case (scan_row)
            2'd0: row = 4'b1110;  // ROW1拉低
            2'd1: row = 4'b1101;  // ROW2拉低
            2'd2: row = 4'b1011;  // ROW3拉低
            2'd3: row = 4'b0111;  // ROW4拉低
        endcase
    end

    //==========================================================================
    // 原始按键译码（组合逻辑）。5'h10表示“无按键”，
    // 因此0~15共16个键值仍全部可用。
    //==========================================================================
    localparam [4:0] NO_KEY = 5'd16;

    reg [4:0] raw_code;

    always @(*) begin
        raw_code = NO_KEY;
        if (col != 4'b1111) begin
            case ({scan_row, col})
                {2'd0, 4'b1110}: raw_code = 5'd0;
                {2'd0, 4'b1101}: raw_code = 5'd1;
                {2'd0, 4'b1011}: raw_code = 5'd2;
                {2'd0, 4'b0111}: raw_code = 5'd3;
                {2'd1, 4'b1110}: raw_code = 5'd4;
                {2'd1, 4'b1101}: raw_code = 5'd5;
                {2'd1, 4'b1011}: raw_code = 5'd6;
                {2'd1, 4'b0111}: raw_code = 5'd7;
                {2'd2, 4'b1110}: raw_code = 5'd8;
                {2'd2, 4'b1101}: raw_code = 5'd9;
                {2'd2, 4'b1011}: raw_code = 5'd10;
                {2'd2, 4'b0111}: raw_code = 5'd11;
                {2'd3, 4'b1110}: raw_code = 5'd12;
                {2'd3, 4'b1101}: raw_code = 5'd13;
                {2'd3, 4'b1011}: raw_code = 5'd14;
                {2'd3, 4'b0111}: raw_code = 5'd15;
                default: raw_code = NO_KEY;
            endcase
        end
    end

    //==========================================================================
    // 消抖：连续3次完整矩阵扫描结果一致（30ms）
    //==========================================================================
    reg [4:0]  scan_code;
    reg [4:0]  db_code_0, db_code_1;
    reg        stable_pressed;
    wire [4:0] full_scan_code = (scan_code != NO_KEY) ? scan_code : raw_code;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt <= 17'd0;
            scan_row <= 2'd0;
            scan_code<= NO_KEY;
            db_code_0<= NO_KEY;
            db_code_1<= NO_KEY;
            stable_pressed<= 1'b0;
            key_valid <= 1'b0;
            key_pressed <= 1'b0;
            key_code  <= 4'd0;
        end else begin
            key_valid <= 1'b0;

            // 扫描计时器
            if (scan_cnt == SCAN_INTERVAL - 1) begin
                scan_cnt <= 17'd0;

                if (scan_row == 2'd3) begin
                    scan_row <= 2'd0;

                    // 每完成一次4行扫描后移位消抖寄存器。
                    db_code_1 <= db_code_0;
                    db_code_0 <= full_scan_code;
                    scan_code <= NO_KEY;

                    // 使用本次完整扫描和前两次扫描检查一致性。
                    if (full_scan_code == db_code_0 &&
                        db_code_0 == db_code_1 &&
                        full_scan_code != NO_KEY) begin
                        if (!stable_pressed) begin
                            stable_pressed <= 1'b1;
                            key_valid      <= 1'b1;
                            key_code       <= full_scan_code[3:0];
                            key_pressed    <= 1'b1;
                        end
                    end else if (full_scan_code == NO_KEY &&
                                 db_code_0 == NO_KEY &&
                                 db_code_1 == NO_KEY) begin
                        stable_pressed <= 1'b0;
                        key_pressed    <= 1'b0;
                    end
                end else begin
                    scan_row <= scan_row + 1'b1;
                    if (scan_code == NO_KEY && raw_code != NO_KEY)
                        scan_code <= raw_code;
                end
            end else begin
                scan_cnt <= scan_cnt + 1'b1;
            end
        end
    end

endmodule
