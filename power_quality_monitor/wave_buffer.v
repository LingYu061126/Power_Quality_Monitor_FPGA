//==============================================================================
// 模块：wave_buffer
// 说明：用于波形捕获的1024 x 8位简单双口RAM
//   A端口：写入ADC采样流
//   B端口：读取给LCD显示
//   由Quartus推断为M9K块RAM（8kbit < 9kbit）
//==============================================================================

module wave_buffer (
    input  wire        clk,
    input  wire [9:0]  wr_addr,
    input  wire [7:0]  wr_data,
    input  wire        wr_en,
    input  wire [9:0]  rd_addr,
    output reg  [7:0]  rd_data
);

    reg [7:0] mem [0:1023];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end

endmodule
