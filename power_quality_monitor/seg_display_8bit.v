//==============================================================================
// 模块：seg_display_8bit
// 说明：八位七段数码管动态扫描控制器
//   共阴极，段码高电平有效
//   输出：{seg[7:0], dig[7:0]}送往hc595_driver
//   扫描速率：50MHz下每位1ms = 50,000周期
//==============================================================================

module seg_display_8bit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] disp_data,    // 8位 x 4位十六进制显示数据
    output reg  [15:0] seg_dig,      // {seg[7:0], dig[7:0]}
    output reg         load,
    input  wire        busy
);

    localparam SCAN_MAX = 16'd49999;  // 1ms

    reg [15:0] scan_cnt;
    reg [2:0]  digit_idx;

    function [7:0] hex_to_seg;
        input [3:0] hex;
        case (hex)
            4'h0: hex_to_seg = 8'b0011_1111;
            4'h1: hex_to_seg = 8'b0000_0110;
            4'h2: hex_to_seg = 8'b0101_1011;
            4'h3: hex_to_seg = 8'b0100_1111;
            4'h4: hex_to_seg = 8'b0110_0110;
            4'h5: hex_to_seg = 8'b0110_1101;
            4'h6: hex_to_seg = 8'b0111_1101;
            4'h7: hex_to_seg = 8'b0000_0111;
            4'h8: hex_to_seg = 8'b0111_1111;
            4'h9: hex_to_seg = 8'b0110_1111;
            4'hA: hex_to_seg = 8'b0111_0111;
            4'hB: hex_to_seg = 8'b0111_1100;
            4'hC: hex_to_seg = 8'b0011_1001;
            4'hD: hex_to_seg = 8'b0101_1110;
            4'hE: hex_to_seg = 8'b0111_1001;
            4'hF: hex_to_seg = 8'b0111_0001;
        endcase
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt  <= 16'd0;
            digit_idx <= 3'd0;
            seg_dig   <= 16'h0000;
            load      <= 1'b0;
        end else begin
            load <= 1'b0;
            if (scan_cnt == SCAN_MAX) begin
                scan_cnt  <= 16'd0;
                digit_idx <= digit_idx + 1'b1;
                seg_dig[15:8] <= hex_to_seg(disp_data[digit_idx*4 +: 4]);
                seg_dig[7:0]  <= ~(8'b1 << (3'd7 - digit_idx));
                load          <= 1'b1;
            end else begin
                scan_cnt <= scan_cnt + 1'b1;
            end
        end
    end

endmodule
